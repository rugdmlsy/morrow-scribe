import AppKit
import ApplicationServices
import Foundation

public enum HuddleControllerError: Error, CustomStringConvertible {
    case slackNotRunning
    case accessibilityNotTrusted
    case noHuddleWindow
    case noHuddleToolbar
    case noPreferencesControl

    public var description: String {
        switch self {
        case .slackNotRunning: return "Slack is not running"
        case .accessibilityNotTrusted: return "Accessibility access is not granted"
        case .noHuddleWindow: return "no active Slack Huddle window"
        case .noHuddleToolbar: return "active Huddle has no accessible Huddle toolbar"
        case .noPreferencesControl: return "Slack automatic-caption preference was not found"
        }
    }
}

public struct HuddleStatus: Sendable {
    public let active: Bool
    public let windowTitle: String?
    public let captionsEnabled: Bool?

    public init(active: Bool, windowTitle: String?, captionsEnabled: Bool?) {
        self.active = active
        self.windowTitle = windowTitle
        self.captionsEnabled = captionsEnabled
    }
}

/// Small controller for the few Huddle actions Morrow Scribe needs outside the collector.
///
/// The live transcript path is intentionally read-only: it observes Slack's Accessibility
/// tree. Caption enablement is configured through Slack's persistent "automatically turn on
/// captions" preference rather than repeatedly manipulating the transient Electron popup.
public final class SlackHuddleController: @unchecked Sendable {
    public init() {}

    public func status() throws -> HuddleStatus {
        let context = try bootstrapSlack(waitForHuddle: true)
        defer { restore(context) }
        guard let huddle = preferredHuddleWindow(in: context.windows) else {
            return HuddleStatus(active: false, windowTitle: nil, captionsEnabled: nil)
        }
        return HuddleStatus(
            active: true,
            windowTitle: stringAttribute(huddle, kAXTitleAttribute as CFString),
            captionsEnabled: captionsAreActive(in: huddle)
        )
    }

    /// Enable Slack's persistent "automatically turn on captions" Huddle preference.
    /// Returns true when the checkbox is confirmed enabled.
    @discardableResult
    public func enableAutomaticCaptionsPreference() throws -> Bool {
        let context = try bootstrapSlack(waitForHuddle: false)
        defer { restore(context) }

        if find(context.app, where: {
            stringAttribute($0, kAXRoleAttribute as CFString) == "AXRadioButton" &&
            stringAttribute($0, kAXTitleAttribute as CFString) == "音频和视频"
        }) == nil {
            guard let preferences = find(context.app, where: {
                stringAttribute($0, kAXRoleAttribute as CFString) == "AXMenuItem" &&
                stringAttribute($0, kAXTitleAttribute as CFString).contains("首选项")
            }) else {
                throw HuddleControllerError.noPreferencesControl
            }
            _ = AXUIElementPerformAction(preferences, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.75)
        }

        guard let audioVideo = find(context.app, where: {
            stringAttribute($0, kAXRoleAttribute as CFString) == "AXRadioButton" &&
            stringAttribute($0, kAXTitleAttribute as CFString) == "音频和视频"
        }) else {
            throw HuddleControllerError.noPreferencesControl
        }
        _ = AXUIElementPerformAction(audioVideo, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.55)

        guard let checkbox = find(context.app, where: {
            stringAttribute($0, kAXRoleAttribute as CFString) == "AXCheckBox" &&
            stringAttribute($0, kAXTitleAttribute as CFString).contains("自动开启字幕")
        }) else {
            throw HuddleControllerError.noPreferencesControl
        }
        if stringAttribute(checkbox, kAXValueAttribute as CFString) == "0" {
            _ = AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.25)
        }
        return stringAttribute(checkbox, kAXValueAttribute as CFString) == "1"
    }

    public func leave() throws {
        let context = try bootstrapSlack(waitForHuddle: true)
        defer { restore(context) }
        guard let huddle = preferredHuddleWindow(in: context.windows) else {
            throw HuddleControllerError.noHuddleWindow
        }
        guard let toolbar = find(huddle, where: {
            stringAttribute($0, kAXRoleAttribute as CFString) == "AXToolbar" &&
            stringAttribute($0, kAXDescriptionAttribute as CFString) == "抱团操作"
        }) else {
            throw HuddleControllerError.noHuddleToolbar
        }
        guard let leave = find(toolbar, where: {
            stringAttribute($0, kAXRoleAttribute as CFString) == "AXButton" &&
            stringAttribute($0, kAXDescriptionAttribute as CFString) == "退出抱团"
        }) else {
            throw HuddleControllerError.noHuddleToolbar
        }
        _ = AXUIElementPerformAction(leave, kAXPressAction as CFString)
    }

    private struct Context {
        let slack: NSRunningApplication
        let previous: NSRunningApplication?
        let app: AXUIElement
        let windows: [AXUIElement]
    }

    private func bootstrapSlack(waitForHuddle: Bool) throws -> Context {
        guard AXIsProcessTrusted() else { throw HuddleControllerError.accessibilityNotTrusted }
        guard let slack = NSRunningApplication.runningApplications(
            withBundleIdentifier: SlackAXSession.slackBundleIdentifier
        ).first else {
            throw HuddleControllerError.slackNotRunning
        }

        let previous = NSWorkspace.shared.frontmostApplication
        if previous?.processIdentifier != slack.processIdentifier {
            _ = slack.activate(options: [])
            Thread.sleep(forTimeInterval: 0.35)
        }
        let app = AXUIElementCreateApplication(slack.processIdentifier)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.12)

        var windows: [AXUIElement] = []
        let attempts = waitForHuddle ? 16 : 4
        for _ in 0..<attempts {
            windows = attribute(app, kAXWindowsAttribute as CFString) ?? []
            if !waitForHuddle || preferredHuddleWindow(in: windows) != nil { break }
            Thread.sleep(forTimeInterval: 0.125)
        }
        return Context(slack: slack, previous: previous, app: app, windows: windows)
    }

    private func restore(_ context: Context) {
        if let previous = context.previous,
           previous.processIdentifier != context.slack.processIdentifier {
            _ = previous.activate(options: [])
        }
    }

    private func preferredHuddleWindow(in windows: [AXUIElement]) -> AXUIElement? {
        windows.first(where: {
            stringAttribute($0, kAXTitleAttribute as CFString).hasPrefix("抱团：")
        })
    }

    private func captionsAreActive(in huddle: AXUIElement) -> Bool {
        // In Slack 4.51 the caption surface appears as an AXRadioButton titled "字幕".
        // A transient announcement "字幕已开启。" and speaker/text utterance groups may
        // also be present. The radio is stable even after the announcement disappears.
        if find(huddle, where: {
            stringAttribute($0, kAXRoleAttribute as CFString) == "AXRadioButton" &&
            stringAttribute($0, kAXTitleAttribute as CFString) == "字幕"
        }) != nil {
            return true
        }
        return find(huddle, where: {
            let text = [
                stringAttribute($0, kAXTitleAttribute as CFString),
                stringAttribute($0, kAXValueAttribute as CFString),
                stringAttribute($0, kAXDescriptionAttribute as CFString),
            ].joined(separator: " ")
            return text.contains("字幕已开启")
        }) != nil
    }
}

private func find(_ root: AXUIElement, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    var hit: AXUIElement?
    func walk(_ element: AXUIElement, depth: Int) {
        guard hit == nil, depth <= 52 else { return }
        if predicate(element) {
            hit = element
            return
        }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute as CFString) ?? []
        for child in children { walk(child, depth: depth + 1) }
    }
    walk(root, depth: 0)
    return hit
}
