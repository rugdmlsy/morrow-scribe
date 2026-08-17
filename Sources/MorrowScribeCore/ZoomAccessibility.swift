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
        return normalized.contains("zoom meeting")
            || normalized.contains("zoom会议")
            || normalized.contains("zoom webinar")
            || normalized.contains("zoom网络研讨会")
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
            if let title = backgroundMeetingTitle(in: app) {
                return RecordingProviderProbe(active: true, detail: title)
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
        var meeting = Self.findMeetingWindow(in: app, attempts: 3)

        // Zoom 7.1 stops returning its meeting from AXWindows while it is in the
        // background, even though the meeting remains listed in the app menu bar.
        // Surface Zoom only long enough to obtain a stable AXUIElement reference,
        // then immediately restore whichever application the user was using.
        if meeting == nil, Self.backgroundMeetingTitle(in: app) != nil {
            let previous = NSWorkspace.shared.frontmostApplication
            if previous?.processIdentifier != zoom.processIdentifier {
                _ = zoom.activate(options: [.activateAllWindows])
                Thread.sleep(forTimeInterval: 0.35)
            }
            meeting = Self.findMeetingWindow(in: app, attempts: 6)
            if let previous, previous.processIdentifier != zoom.processIdentifier {
                _ = previous.activate(options: [])
            }
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

    private static func findMeetingWindow(in app: AXUIElement, attempts: Int) -> AXUIElement? {
        for attempt in 0..<attempts {
            let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute as CFString) ?? []
            if let meeting = preferredMeetingWindow(in: windows) { return meeting }
            if attempt + 1 < attempts { Thread.sleep(forTimeInterval: 0.10) }
        }
        return nil
    }

    private static func backgroundMeetingTitle(in app: AXUIElement) -> String? {
        guard let menuBar: AXUIElement = attribute(app, kAXMenuBarAttribute as CFString) else {
            return nil
        }
        var match: String?
        func walk(_ element: AXUIElement, depth: Int) {
            guard match == nil, depth <= 12 else { return }
            if stringAttribute(element, kAXRoleAttribute as CFString) == "AXMenuItem" {
                let title = stringAttribute(element, kAXTitleAttribute as CFString)
                if isMeetingWindowTitle(title) {
                    match = title
                    return
                }
            }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute as CFString) ?? []
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(menuBar, depth: 0)
        return match
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
                let rawValues = group.sorted { $0.path < $1.path }.map(cleanText).filter { !$0.isEmpty }
                // Zoom 7.1 may expose the same rendered caption through two adjacent
                // AXStaticText nodes (for example, the subtitle view plus its accessibility
                // mirror). Collapse only adjacent exact duplicates so a distinct translated
                // subtitle remains available rather than duplicating the whole utterance.
                let values = rawValues.reduce(into: [String]()) { result, value in
                    if result.last != value { result.append(value) }
                }
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

    public static func removingAttachmentBaseline(
        from candidate: CaptionCandidate,
        baseline: CaptionCandidate?
    ) -> CaptionCandidate? {
        guard let baseline,
              baseline.sourcePath == candidate.sourcePath,
              baseline.speaker == candidate.speaker else {
            return candidate
        }

        let oldText = baseline.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return nil }
        guard !oldText.isEmpty else { return candidate }
        if newText == oldText { return nil }

        guard newText.hasPrefix(oldText) else {
            // Zoom may recycle a caption row for a genuinely new utterance. If the new
            // text is not an extension of the attachment-time value, treat it as new.
            return candidate
        }

        let suffix = String(newText.dropFirst(oldText.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { return nil }
        return CaptionCandidate(
            speaker: candidate.speaker,
            text: suffix,
            confidence: candidate.confidence,
            sourcePath: candidate.sourcePath,
            source: candidate.source
        )
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
