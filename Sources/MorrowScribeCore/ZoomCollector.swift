import Foundation

public final class ZoomCaptionCollector: @unchecked Sendable {
    private let session: ZoomAXSession
    private let store: MeetingStore
    private let accumulator: TranscriptAccumulator
    private let options: CollectorOptions
    private let control: CollectorControl
    private let streamState: CaptionStreamState

    public init(
        session: ZoomAXSession,
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

    public func runAttachment(onStatus: ((String) -> Void)? = nil) throws -> RecordingAttachmentResult {
        try session.bootstrap()
        guard session.isAttachedToMeeting else { return .detached }
        onStatus?("attached to Zoom pid=\(session.zoomPID ?? 0), window=\(try session.windowTitle())")

        var previousCandidates = streamState.snapshot()
        var lastCaptionAvailability: Bool?

        while true {
            if control.isStopRequested { break }
            Thread.sleep(forTimeInterval: options.pollInterval)
            if control.isStopRequested { break }

            do {
                try session.ensureFresh()
                guard session.isAttachedToMeeting else {
                    if let final = accumulator.flush() { try store.appendTranscript(final) }
                    return .detached
                }

                let current = try session.snapshot()
                let available = ZoomCaptionHeuristics.hasCaptionSurface(in: current)
                if available != lastCaptionAvailability {
                    onStatus?(available ? "Zoom native captions available" : "Zoom meeting detected; waiting for captions to be shown")
                    lastCaptionAvailability = available
                }

                let candidates = ZoomCaptionHeuristics.extractCandidates(from: current)
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
            } catch ZoomAXError.staleWindow {
                onStatus?("Zoom meeting window changed; reattaching")
                do {
                    try session.bootstrap()
                } catch ZoomAXError.noMeetingWindow {
                    if let final = accumulator.flush() { try store.appendTranscript(final) }
                    return .detached
                } catch ZoomAXError.zoomNotRunning {
                    if let final = accumulator.flush() { try store.appendTranscript(final) }
                    return .detached
                }
            } catch ZoomAXError.noMeetingWindow {
                if let final = accumulator.flush() { try store.appendTranscript(final) }
                return .detached
            } catch ZoomAXError.zoomNotRunning {
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
}

public final class ZoomRecordingProvider: RecordingProvider, @unchecked Sendable {
    public let id = "zoom"
    public let displayName = "Zoom"
    private let streamState = CaptionStreamState()

    public init() {}

    public func probe() throws -> RecordingProviderProbe {
        try ZoomAXSession.passiveStatus()
    }

    public func recordAttachment(
        store: MeetingStore,
        accumulator: TranscriptAccumulator,
        control: CollectorControl,
        options: CollectorOptions,
        onStatus: ((String) -> Void)?
    ) throws -> RecordingAttachmentResult {
        let collector = ZoomCaptionCollector(
            session: ZoomAXSession(),
            store: store,
            options: options,
            control: control,
            accumulator: accumulator,
            streamState: streamState
        )
        return try collector.runAttachment(onStatus: onStatus)
    }
}
