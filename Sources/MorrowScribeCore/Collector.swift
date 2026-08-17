import Foundation

public struct CollectorOptions: Sendable {
    public let pollInterval: TimeInterval
    public let learnMode: Bool
    public let duration: TimeInterval?

    public init(pollInterval: TimeInterval = 0.25, learnMode: Bool = false, duration: TimeInterval? = nil) {
        self.pollInterval = max(0.10, pollInterval)
        self.learnMode = learnMode
        self.duration = duration
    }
}

public final class SlackCaptionCollector: @unchecked Sendable {
    private let session: SlackAXSession
    private let store: MeetingStore
    private let accumulator = TranscriptAccumulator()
    private let options: CollectorOptions

    public init(session: SlackAXSession, store: MeetingStore, options: CollectorOptions) {
        self.session = session
        self.store = store
        self.options = options
    }

    public func run(onStatus: ((String) -> Void)? = nil) throws {
        try session.bootstrap()
        onStatus?("attached to Slack pid=\(session.slackPID ?? 0), window=\(try session.windowTitle())")

        var previous = try session.snapshot()
        let started = Date()
        var previousCandidates: [CaptionCandidate] = []

        while true {
            if let duration = options.duration, Date().timeIntervalSince(started) >= duration { break }
            Thread.sleep(forTimeInterval: options.pollInterval)

            do {
                try session.ensureFresh()
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
                let delta = CaptionStream.delta(previous: previousCandidates, current: candidates)
                let now = Date()
                for candidate in delta {
                    if let finalized = accumulator.ingest(candidate, at: now) {
                        try store.appendTranscript(finalized)
                        onStatus?("\(finalized.speaker ?? "Unknown"): \(finalized.text)")
                    }
                }
                previousCandidates = candidates
                previous = current
            } catch SlackAXError.staleWindow {
                onStatus?("Slack window changed; reattaching")
                try session.bootstrap()
                previous = try session.snapshot()
            }
        }

        if let final = accumulator.flush() {
            try store.appendTranscript(final)
            onStatus?("\(final.speaker ?? "Unknown"): \(final.text)")
        }
        try store.finish()
    }
}
