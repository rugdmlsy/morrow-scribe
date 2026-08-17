import AppKit
import ApplicationServices
import Foundation

public enum SlackAXError: Error, CustomStringConvertible {
    case slackNotRunning
    case accessibilityNotTrusted
    case noWindow
    case staleWindow

    public var description: String {
        switch self {
        case .slackNotRunning: return "Slack is not running"
        case .accessibilityNotTrusted: return "Accessibility access is not granted to the collector process"
        case .noWindow: return "Slack has no accessible window"
        case .staleWindow: return "captured Slack window is no longer readable"
        }
    }
}

public final class SlackAXSession: @unchecked Sendable {
    public static let slackBundleIdentifier = "com.tinyspeck.slackmacgap"

    public static func isHuddleWindowTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return title.hasPrefix("抱团：")
            || title.hasPrefix("抱团:")
            || lower.hasPrefix("huddle:")
            || lower.hasPrefix("huddle：")
    }

    private var applicationElement: AXUIElement?
    private var retainedWindow: AXUIElement?
    private(set) public var slackPID: pid_t?
    private(set) public var bootstrappedAt: Date?

    public init() {}

    public var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public static func requestAccessibilityAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func bootstrap(restoreFocus: Bool = true) throws {
        guard accessibilityTrusted else { throw SlackAXError.accessibilityNotTrusted }
        guard let slack = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.slackBundleIdentifier
        ).first else {
            throw SlackAXError.slackNotRunning
        }

        let previous = NSWorkspace.shared.frontmostApplication
        if previous?.processIdentifier != slack.processIdentifier {
            _ = slack.activate(options: [])
            Thread.sleep(forTimeInterval: 0.40)
        }

        let app = AXUIElementCreateApplication(slack.processIdentifier)
        _ = AXUIElementSetAttributeValue(
            app,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        Thread.sleep(forTimeInterval: 0.15)

        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute as CFString) ?? []
        guard let window = Self.preferredWindow(in: windows) else {
            if restoreFocus, let previous, previous.processIdentifier != slack.processIdentifier {
                _ = previous.activate(options: [])
            }
            throw SlackAXError.noWindow
        }

        self.slackPID = slack.processIdentifier
        self.applicationElement = app
        self.retainedWindow = window
        self.bootstrappedAt = Date()

        if restoreFocus, let previous, previous.processIdentifier != slack.processIdentifier {
            _ = previous.activate(options: [])
            Thread.sleep(forTimeInterval: 0.10)
        }
    }

    public func windowTitle() throws -> String {
        guard let retainedWindow else { throw SlackAXError.noWindow }
        let title = stringAttribute(retainedWindow, kAXTitleAttribute as CFString)
        guard !title.isEmpty else { throw SlackAXError.staleWindow }
        return title
    }

    public func snapshot(maxDepth: Int = 40, maxNodes: Int = 20_000) throws -> [AXSnapshotNode] {
        guard let retainedWindow else { throw SlackAXError.noWindow }
        if stringAttribute(retainedWindow, kAXRoleAttribute as CFString).isEmpty {
            throw SlackAXError.staleWindow
        }

        var output: [AXSnapshotNode] = []
        output.reserveCapacity(512)

        func walk(_ element: AXUIElement, depth: Int, path: String, parentPath: String?) {
            guard depth <= maxDepth, output.count < maxNodes else { return }
            let node = AXSnapshotNode(
                path: path,
                depth: depth,
                role: stringAttribute(element, kAXRoleAttribute as CFString),
                title: stringAttribute(element, kAXTitleAttribute as CFString),
                value: stringAttribute(element, kAXValueAttribute as CFString),
                description: stringAttribute(element, kAXDescriptionAttribute as CFString),
                identifier: stringAttribute(element, kAXIdentifierAttribute as CFString),
                parentPath: parentPath
            )
            output.append(node)
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute as CFString) ?? []
            for (index, child) in children.enumerated() {
                walk(child, depth: depth + 1, path: "\(path).\(index)", parentPath: path)
            }
        }

        walk(retainedWindow, depth: 0, path: "0", parentPath: nil)
        return output
    }

    public func ensureFresh() throws {
        do {
            _ = try windowTitle()
        } catch {
            try bootstrap()
        }
    }

    public var isAttachedToHuddle: Bool {
        guard let retainedWindow else { return false }
        return Self.isHuddleWindowTitle(stringAttribute(retainedWindow, kAXTitleAttribute as CFString))
    }

    private static func preferredWindow(in windows: [AXUIElement]) -> AXUIElement? {
        if let huddle = windows.first(where: {
            isHuddleWindowTitle(stringAttribute($0, kAXTitleAttribute as CFString))
        }) {
            return huddle
        }
        if let preview = windows.first(where: {
            stringAttribute($0, kAXTitleAttribute as CFString).contains("抱团预览")
        }) {
            return preview
        }
        return windows.first(where: {
            stringAttribute($0, kAXTitleAttribute as CFString).contains("Slack")
        }) ?? windows.first
    }
}

func attribute<T>(_ element: AXUIElement, _ name: CFString) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value as? T
}

func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success, let value else { return "" }
    if let string = value as? String { return string }
    return String(describing: value)
}
