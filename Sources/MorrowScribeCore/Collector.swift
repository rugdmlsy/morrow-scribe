import Foundation

public struct CollectorOptions: Sendable {
    public let pollInterval: TimeInterval
    public let learnMode: Bool
    public let duration: TimeInterval?
    public let monitorInterval: TimeInterval

    public init(
        pollInterval: TimeInterval = 0.25,
        learnMode: Bool = false,
        duration: TimeInterval? = nil,
        monitorInterval: TimeInterval = 0.75
    ) {
        self.pollInterval = max(0.10, pollInterval)
        self.learnMode = learnMode
        self.duration = duration
        self.monitorInterval = max(0.10, monitorInterval)
    }
}

public final class SlackCaptionCollector: @unchecked Sendable {
    private let session: SlackAXSession
    private let store: MeetingStore
    private let accumulator: TranscriptAccumulator
    private let options: CollectorOptions
    private let control: CollectorControl
    private let streamState: CaptionStreamState

    public init(
        session: SlackAXSession,
        store: MeetingStore,
        options: CollectorOptions,
        control: CollectorControl = CollectorControl(),
        accumulator: TranscriptAccumulator = TranscriptAccumulator(),
        streamState: CaptionStreamState = CaptionStreamState()
    ) {
        self.session = session
        self.store = store
        self.options = options
        self.control = control
        self.accumulator = accumulator
        self.streamState = streamState
    }

    /// Capture one currently-active Slack Huddle. The enclosing RecordingSession owns the
    /// longer recording lifetime and the final MeetingStore.finish() call.
    public func runAttachment(onStatus: ((String) -> Void)? = nil) throws -> RecordingAttachmentResult {
        var sideBySideSelected = false
        var lastPreferenceError: Error?
        for attempt in 0..<4 {
            do {
                if try SlackHuddleController().preferSideBySideCaptions() {
                    sideBySideSelected = true
                    break
                }
            } catch {
                lastPreferenceError = error
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.20) }
        }
        if sideBySideSelected {
            onStatus?("caption preference: side-by-side")
        } else {
            let detail = lastPreferenceError.map { ": \($0)" } ?? ""
            onStatus?("side-by-side unavailable; using overlay fallback when present\(detail)")
        }

        try session.bootstrap()
        guard session.isAttachedToHuddle else { return .detached }
        onStatus?("attached to Slack pid=\(session.slackPID ?? 0), window=\(try session.windowTitle())")

        var previous = try session.snapshot()
        var previousCandidates = streamState.snapshot()
        if previousCandidates.isEmpty {
            // A persistent side-by-side transcript can already contain older utterances when
            // Scribe attaches to a Huddle that was open before recording started. Treat that
            // existing history as the baseline; only caption changes observed after attach
            // belong to this recording session. On later detach/re-attach, streamState is kept
            // so the normal overlap logic still preserves continuity without replaying history.
            previousCandidates = CaptionHeuristics.extractCandidates(from: previous)
            streamState.update(previousCandidates)
        }
        var lastSource = CaptionHeuristics.preferredSource(from: previous)
        if let lastSource { onStatus?("caption source: \(lastSource.rawValue)") }

        while true {
            if control.isStopRequested { break }
            Thread.sleep(forTimeInterval: options.pollInterval)
            if control.isStopRequested { break }

            do {
                if !(try SlackHuddleController().passiveStatus()).active {
                    if let final = accumulator.flush() {
                        try store.appendTranscript(final)
                        onStatus?("\(final.speaker ?? "Unknown"): \(final.text)")
                    }
                    return .detached
                }
                try session.ensureFresh()
                guard session.isAttachedToHuddle else {
                    if let final = accumulator.flush() { try store.appendTranscript(final) }
                    return .detached
                }
                let current = try session.snapshot()

                if options.learnMode {
                    let changes = CaptionHeuristics.changedTextEvents(previous: previous, current: current)
                    for change in changes {
                        try store.appendAXEvent(change)
                    }
                    if !changes.isEmpty {
                        let interesting = changes.filter { change in
                            CaptionHeuristics.isHuddleRelated(change.node)
                            || change.context.contains(where: { context in
                                let lower = context.lowercased()
                                return lower.contains("caption") || lower.contains("字幕") || lower.contains("抱团")
                            })
                        }
                        if !interesting.isEmpty {
                            onStatus?("AX changes: \(interesting.count) huddle/caption-related")
                        }
                    }
                }

                let candidates = CaptionHeuristics.extractCandidates(from: current)
                let source = CaptionHeuristics.preferredSource(from: current)
                if source != lastSource {
                    onStatus?("caption source: \(source?.rawValue ?? "unavailable")")
                    lastSource = source
                }
                let delta = CaptionStream.delta(previous: previousCandidates, current: candidates)
                let now = Date()
                for candidate in delta {
                    if let finalized = accumulator.ingest(candidate, at: now) {
                        try store.appendTranscript(finalized)
                        onStatus?("\(finalized.speaker ?? "Unknown"): \(finalized.text)")
                    }
                }
                previousCandidates = candidates
                streamState.update(candidates)
                previous = current
            } catch SlackAXError.staleWindow {
                if !(try SlackHuddleController().passiveStatus()).active {
                    if let final = accumulator.flush() { try store.appendTranscript(final) }
                    return .detached
                }
                onStatus?("Slack window changed; reattaching")
                try session.bootstrap()
                previous = try session.snapshot()
            } catch SlackAXError.noWindow {
                if let final = accumulator.flush() { try store.appendTranscript(final) }
                return .detached
            }
        }

        if let final = accumulator.flush() {
            try store.appendTranscript(final)
            onStatus?("\(final.speaker ?? "Unknown"): \(final.text)")
        }
        return .stopped
    }

    /// Backwards-compatible single-Huddle entry point. New code should use RecordingSession.
    public func run(onStatus: ((String) -> Void)? = nil) throws {
        _ = try runAttachment(onStatus: onStatus)
        try store.finish()
    }
}

public final class SlackRecordingProvider: RecordingProvider, @unchecked Sendable {
    public let id = "slack"
    public let displayName = "Slack"
    private let streamState = CaptionStreamState()

    public init() {}

    public func probe() throws -> RecordingProviderProbe {
        let status = try SlackHuddleController().passiveStatus()
        return RecordingProviderProbe(active: status.active, detail: status.windowTitle)
    }

    public func recordAttachment(
        store: MeetingStore,
        accumulator: TranscriptAccumulator,
        control: CollectorControl,
        options: CollectorOptions,
        onStatus: ((String) -> Void)?
    ) throws -> RecordingAttachmentResult {
        let collector = SlackCaptionCollector(
            session: SlackAXSession(),
            store: store,
            options: options,
            control: control,
            accumulator: accumulator,
            streamState: streamState
        )
        return try collector.runAttachment(onStatus: onStatus)
    }
}
