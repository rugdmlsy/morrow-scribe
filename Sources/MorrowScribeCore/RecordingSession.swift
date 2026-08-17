import Foundation


public final class RecordingStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    public init(_ initial: String = "Listening for a meeting") {
        value = initial
    }

    public func update(_ newValue: String) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    public var current: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public struct RecordingProviderProbe: Equatable, Sendable {
    public let active: Bool
    public let detail: String?

    public init(active: Bool, detail: String? = nil) {
        self.active = active
        self.detail = detail
    }

    public static let inactive = RecordingProviderProbe(active: false)
}

public enum RecordingAttachmentResult: Equatable, Sendable {
    case detached
    case stopped
}

/// A source of live meeting transcript data.
///
/// Providers deliberately own only one *attachment* at a time. `RecordingSession` owns the
/// longer-lived recording boundary, so providers can disappear and reappear (or a different
/// provider can take over) while every utterance continues to append to one MeetingStore.
/// A future Zoom integration should implement this protocol and can be added alongside Slack
/// without changing the recording/session or summarization layers.
public protocol RecordingProvider: Sendable {
    var id: String { get }
    var displayName: String { get }

    /// Lightweight, non-invasive discovery. This should not foreground the meeting app.
    func probe() throws -> RecordingProviderProbe

    /// Capture one continuous provider attachment and return when that meeting/source ends.
    func recordAttachment(
        store: MeetingStore,
        accumulator: TranscriptAccumulator,
        control: CollectorControl,
        options: CollectorOptions,
        onStatus: ((String) -> Void)?
    ) throws -> RecordingAttachmentResult
}

public enum RecordingProviderCatalog {
    /// Providers enabled for normal recording sessions.
    public static func defaultProviders() -> [any RecordingProvider] {
        [SlackRecordingProvider(), ZoomRecordingProvider()]
    }
}

public final class RecordingSession: @unchecked Sendable {
    private let store: MeetingStore
    private let providers: [any RecordingProvider]
    private let control: CollectorControl
    private let options: CollectorOptions
    private let accumulator = TranscriptAccumulator()

    public init(
        store: MeetingStore,
        providers: [any RecordingProvider],
        control: CollectorControl = CollectorControl(),
        options: CollectorOptions = CollectorOptions()
    ) {
        self.store = store
        self.providers = providers
        self.control = control
        self.options = options
    }

    public func run(onStatus: ((String) -> Void)? = nil) throws {
        let startedAt = Date()
        if let duration = options.duration {
            control.setDeadline(startedAt.addingTimeInterval(duration))
        }
        var lastWaitingMessage: String?
        defer {
            control.setDeadline(nil)
            try? store.finish()
        }

        onStatus?("Recording session started")

        while !shouldStop(startedAt: startedAt) {
            var attachedThisPass = false

            for provider in providers {
                if shouldStop(startedAt: startedAt) { break }

                let probe: RecordingProviderProbe
                do {
                    probe = try provider.probe()
                } catch {
                    onStatus?("\(provider.displayName) monitor unavailable: \(error)")
                    continue
                }
                guard probe.active else { continue }

                attachedThisPass = true
                lastWaitingMessage = nil
                if let detail = probe.detail, !detail.isEmpty {
                    onStatus?("\(provider.displayName) meeting detected: \(detail)")
                } else {
                    onStatus?("\(provider.displayName) meeting detected")
                }

                do {
                    let result = try provider.recordAttachment(
                        store: store,
                        accumulator: accumulator,
                        control: control,
                        options: options,
                        onStatus: onStatus
                    )
                    if result == .stopped { return }
                    onStatus?("\(provider.displayName) meeting ended; listening for another meeting")
                } catch {
                    // Meeting UIs are inherently transient. A window can vanish between probe
                    // and attach, or Electron can briefly drop its AX tree. Treat attachment
                    // failures as recoverable and continue monitoring until the user presses Stop.
                    onStatus?("\(provider.displayName) detached: \(error); listening for another meeting")
                }
                sleepInterruptibly(min(0.50, options.monitorInterval))
                break
            }

            if shouldStop(startedAt: startedAt) { break }
            if !attachedThisPass {
                let names = providers.map(\.displayName).joined(separator: ", ")
                let message = names.isEmpty
                    ? "Listening for a meeting source"
                    : "Listening for meetings: \(names)"
                if message != lastWaitingMessage {
                    onStatus?(message)
                    lastWaitingMessage = message
                }
                sleepInterruptibly(options.monitorInterval)
            }
        }
    }

    private func shouldStop(startedAt: Date) -> Bool {
        if control.isStopRequested { return true }
        if let duration = options.duration,
           Date().timeIntervalSince(startedAt) >= duration {
            return true
        }
        return false
    }

    private func sleepInterruptibly(_ interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        while !control.isStopRequested, Date() < deadline {
            Thread.sleep(forTimeInterval: min(0.10, max(0.01, deadline.timeIntervalSinceNow)))
        }
    }
}
