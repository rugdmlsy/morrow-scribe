import AppKit
import ApplicationServices
import Foundation

public enum ZoomAXError: Error, CustomStringConvertible {
    case zoomNotRunning
    case accessibilityNotTrusted
    case noMeetingWindow
    case staleWindow

    public var description: String {
        switch self {
        case .zoomNotRunning: return "Zoom is not running"
        case .accessibilityNotTrusted: return "Accessibility access is not granted to the collector process"
        case .noMeetingWindow: return "Zoom has no accessible meeting window"
        case .staleWindow: return "captured Zoom meeting window is no longer readable"
        }
    }
}

public final class ZoomAXSession: @unchecked Sendable {
    public static let zoomBundleIdentifier = "us.zoom.xos"

    private var applicationElement: AXUIElement?
    private var retainedWindow: AXUIElement?
    private(set) public var zoomPID: pid_t?

    public init() {}

    public var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    public static func isMeetingWindowTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "zoom meeting"
            || normalized == "zoom会议"
            || normalized.hasPrefix("zoom meeting ")
            || normalized.hasPrefix("zoom webinar")
            || normalized.hasPrefix("zoom网络研讨会")
    }

    public static func passiveStatus() throws -> RecordingProviderProbe {
        guard AXIsProcessTrusted() else { throw ZoomAXError.accessibilityNotTrusted }
        guard let zoom = NSRunningApplication.runningApplications(
            withBundleIdentifier: zoomBundleIdentifier
        ).first else {
            return .inactive
        }

        let app = AXUIElementCreateApplication(zoom.processIdentifier)
        for attempt in 0..<3 {
            let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute as CFString) ?? []
            if let meeting = preferredMeetingWindow(in: windows) {
                return RecordingProviderProbe(
                    active: true,
                    detail: stringAttribute(meeting, kAXTitleAttribute as CFString)
                )
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.08) }
        }
        return .inactive
    }

    public func bootstrap() throws {
        guard accessibilityTrusted else { throw ZoomAXError.accessibilityNotTrusted }
        guard let zoom = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.zoomBundleIdentifier
        ).first else {
            throw ZoomAXError.zoomNotRunning
        }

        let app = AXUIElementCreateApplication(zoom.processIdentifier)
        var meeting: AXUIElement?
        for attempt in 0..<4 {
            let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute as CFString) ?? []
            meeting = Self.preferredMeetingWindow(in: windows)
            if meeting != nil { break }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.10) }
        }
        guard let meeting else { throw ZoomAXError.noMeetingWindow }

        applicationElement = app
        retainedWindow = meeting
        zoomPID = zoom.processIdentifier
    }

    public func windowTitle() throws -> String {
        guard let retainedWindow else { throw ZoomAXError.noMeetingWindow }
        let title = stringAttribute(retainedWindow, kAXTitleAttribute as CFString)
        guard !title.isEmpty else { throw ZoomAXError.staleWindow }
        return title
    }

    public var isAttachedToMeeting: Bool {
        guard let retainedWindow else { return false }
        return Self.isMeetingWindowTitle(stringAttribute(retainedWindow, kAXTitleAttribute as CFString))
    }

    public func ensureFresh() throws {
        do {
            let title = try windowTitle()
            guard Self.isMeetingWindowTitle(title) else { throw ZoomAXError.staleWindow }
        } catch {
            try bootstrap()
        }
    }

    public func snapshot(maxDepth: Int = 32, maxNodes: Int = 20_000) throws -> [AXSnapshotNode] {
        guard let retainedWindow else { throw ZoomAXError.noMeetingWindow }
        if stringAttribute(retainedWindow, kAXRoleAttribute as CFString).isEmpty {
            throw ZoomAXError.staleWindow
        }

        var output: [AXSnapshotNode] = []
        output.reserveCapacity(512)

        func walk(_ element: AXUIElement, depth: Int, path: String, parentPath: String?) {
            guard depth <= maxDepth, output.count < maxNodes else { return }
            output.append(AXSnapshotNode(
                path: path,
                depth: depth,
                role: stringAttribute(element, kAXRoleAttribute as CFString),
                title: stringAttribute(element, kAXTitleAttribute as CFString),
                value: stringAttribute(element, kAXValueAttribute as CFString),
                description: stringAttribute(element, kAXDescriptionAttribute as CFString),
                identifier: stringAttribute(element, kAXIdentifierAttribute as CFString),
                parentPath: parentPath
            ))
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute as CFString) ?? []
            for (index, child) in children.enumerated() {
                walk(child, depth: depth + 1, path: "\(path).\(index)", parentPath: path)
            }
        }

        walk(retainedWindow, depth: 0, path: "0", parentPath: nil)
        return output
    }

    private static func preferredMeetingWindow(in windows: [AXUIElement]) -> AXUIElement? {
        windows.first {
            isMeetingWindowTitle(stringAttribute($0, kAXTitleAttribute as CFString))
        }
    }
}

public enum ZoomCaptionHeuristics {
    private static let captionKeywords = ["caption", "captions", "subtitle", "subtitles", "transcript", "字幕", "转写", "轉寫"]

    public static func hasCaptionSurface(in nodes: [AXSnapshotNode]) -> Bool {
        !captionRoots(in: nodes).isEmpty
    }

    public static func extractCandidates(from nodes: [AXSnapshotNode]) -> [CaptionCandidate] {
        var output: [CaptionCandidate] = []
        for root in captionRoots(in: nodes) {
            let prefix = root.path + "."
            let textNodes = nodes.filter { node in
                node.path.hasPrefix(prefix)
                    && node.role == "AXStaticText"
                    && !cleanText(node).isEmpty
            }

            let grouped = Dictionary(grouping: textNodes) { $0.parentPath ?? "" }
            for parentPath in grouped.keys.sorted() {
                guard let group = grouped[parentPath] else { continue }
                let values = group.sorted { $0.path < $1.path }.map(cleanText).filter { !$0.isEmpty }
                guard values.count >= 2 else { continue }
                let speaker = values[0]
                let text = values.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !speaker.isEmpty, !text.isEmpty else { continue }
                output.append(CaptionCandidate(
                    speaker: speaker,
                    text: text,
                    confidence: 1,
                    sourcePath: parentPath,
                    source: .zoomNative
                ))
            }
        }
        return deduplicate(output)
    }

    private static func captionRoots(in nodes: [AXSnapshotNode]) -> [AXSnapshotNode] {
        nodes.filter { node in
            guard node.role == "AXTable" || node.role == "AXList" else { return false }
            let blob = [node.title, node.value, node.description, node.identifier]
                .joined(separator: " ")
                .lowercased()
            return captionKeywords.contains { blob.contains($0) }
        }
    }

    private static func cleanText(_ node: AXSnapshotNode) -> String {
        for value in [node.value, node.title, node.description] {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return ""
    }

    private static func deduplicate(_ candidates: [CaptionCandidate]) -> [CaptionCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = "\(candidate.speaker ?? "")\u{1f}\(candidate.text)\u{1f}\(candidate.sourcePath)"
            return seen.insert(key).inserted
        }
    }
}
