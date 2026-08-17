import AppKit
import ApplicationServices
import Foundation

public enum HuddleControllerError: Error, CustomStringConvertible {
    case slackNotRunning
    case accessibilityNotTrusted
    case noHuddleWindow
    case noHuddleToolbar
    case noPreferencesControl
    case noCaptionViewControl

    public var description: String {
        switch self {
        case .slackNotRunning: return "Slack is not running"
        case .accessibilityNotTrusted: return "Accessibility access is not granted"
        case .noHuddleWindow: return "no active Slack Huddle window"
        case .noHuddleToolbar: return "active Huddle has no accessible Huddle toolbar"
        case .noPreferencesControl: return "Slack automatic-caption preference was not found"
        case .noCaptionViewControl: return "Slack side-by-side caption view control was not found"
        }
    }
}

public enum CaptionDisplayMode: String, Sendable {
    case sideBySide = "side_by_side"
    case overlay = "overlay"
}

public struct HuddleStatus: Sendable {
    public let active: Bool
    public let windowTitle: String?
    public let captionsEnabled: Bool?
    public let captionMode: CaptionDisplayMode?

    public init(
        active: Bool,
        windowTitle: String?,
        captionsEnabled: Bool?,
        captionMode: CaptionDisplayMode? = nil
    ) {
        self.active = active
        self.windowTitle = windowTitle
        self.captionsEnabled = captionsEnabled
        self.captionMode = captionMode
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
            captionsEnabled: captionsAreActive(in: huddle),
            captionMode: captionDisplayMode(in: huddle)
        )
    }

    /// Fast monitoring path for long-lived recording sessions. Unlike `status()`, this does
    /// not foreground Slack and does not wait for a Huddle to appear. Slack not running is
    /// treated as an inactive source rather than an error so recording can begin first.
    public func passiveStatus() throws -> HuddleStatus {
        guard AXIsProcessTrusted() else { throw HuddleControllerError.accessibilityNotTrusted }
        guard let slack = NSRunningApplication.runningApplications(
            withBundleIdentifier: SlackAXSession.slackBundleIdentifier
        ).first else {
            return HuddleStatus(active: false, windowTitle: nil, captionsEnabled: nil)
        }

        let app = AXUIElementCreateApplication(slack.processIdentifier)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        // Electron can expose an empty AX window list while Slack is fully in the background,
        // but the native macOS Window menu remains accessible and contains an item whose title
        // is the live Huddle window title (for example `抱团：#社交 - Test - Slack`). Use that
        // semantic signal first so monitoring never has to foreground Slack just to discover it.
        if let menuBar: AXUIElement = attribute(app, kAXMenuBarAttribute as CFString),
           let huddleItem = find(menuBar, where: { element in
               guard stringAttribute(element, kAXRoleAttribute as CFString) == "AXMenuItem" else { return false }
               return SlackAXSession.isHuddleWindowTitle(
                   stringAttribute(element, kAXTitleAttribute as CFString)
               )
           }) {
            return HuddleStatus(
                active: true,
                windowTitle: stringAttribute(huddleItem, kAXTitleAttribute as CFString),
                captionsEnabled: nil,
                captionMode: nil
            )
        }

        // Keep direct AX window discovery as a compatibility fallback for Slack builds whose
        // native Window menu structure changes.
        for attempt in 0..<3 {
            let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute as CFString) ?? []
            if let huddle = preferredHuddleWindow(in: windows) {
                return HuddleStatus(
                    active: true,
                    windowTitle: stringAttribute(huddle, kAXTitleAttribute as CFString),
                    captionsEnabled: nil,
                    captionMode: nil
                )
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.06) }
        }
        return HuddleStatus(active: false, windowTitle: nil, captionsEnabled: nil)
    }

    /// Select Slack's persistent side-by-side transcript as the preferred Huddle view.
    /// The collector treats failure here as non-fatal and falls back to overlay captions.
    @discardableResult
    public func preferSideBySideCaptions() throws -> Bool {
        let context = try bootstrapSlack(waitForHuddle: true)
        defer { restore(context) }
        guard let huddle = preferredHuddleWindow(in: context.windows) else {
            throw HuddleControllerError.noHuddleWindow
        }
        _ = AXUIElementPerformAction(huddle, kAXRaiseAction as CFString)
        var captionsTab: AXUIElement?
        for _ in 0..<10 {
            captionsTab = find(huddle, where: { element in
                guard stringAttribute(element, kAXRoleAttribute as CFString) == "AXRadioButton" else { return false }
                let title = stringAttribute(element, kAXTitleAttribute as CFString).lowercased()
                return title == "字幕" || title == "captions"
            })
            if captionsTab != nil { break }
            Thread.sleep(forTimeInterval: 0.10)
        }
        guard let captionsTab else {
            throw HuddleControllerError.noCaptionViewControl
        }
        if stringAttribute(captionsTab, kAXValueAttribute as CFString) != "1" {
            _ = AXUIElementPerformAction(captionsTab, kAXPressAction as CFString)
            for _ in 0..<8 {
                Thread.sleep(forTimeInterval: 0.10)
                if stringAttribute(captionsTab, kAXValueAttribute as CFString) == "1" { break }
            }
        }
        return stringAttribute(captionsTab, kAXValueAttribute as CFString) == "1"
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
        windows.first(where: { element in
            let title = stringAttribute(element, kAXTitleAttribute as CFString)
            return SlackAXSession.isHuddleWindowTitle(title)
        })
    }

    private func captionDisplayMode(in huddle: AXUIElement) -> CaptionDisplayMode? {
        if let captionsTab = find(huddle, where: { element in
            guard stringAttribute(element, kAXRoleAttribute as CFString) == "AXRadioButton" else { return false }
            let title = stringAttribute(element, kAXTitleAttribute as CFString).lowercased()
            return title == "字幕" || title == "captions"
        }), stringAttribute(captionsTab, kAXValueAttribute as CFString) == "1" {
            return .sideBySide
        }
        return captionsAreActive(in: huddle) ? .overlay : nil
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
