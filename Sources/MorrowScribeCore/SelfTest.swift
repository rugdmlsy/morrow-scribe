import Foundation

public enum SelfTestError: Error, CustomStringConvertible {
    case failed(String)

    public var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

public enum MorrowScribeSelfTest {
    public static func run() throws -> [String] {
        var passed: [String] = []

        let accumulator = TranscriptAccumulator()
        guard accumulator.ingest(CaptionCandidate(speaker: "Alice", text: "hello", confidence: 1, sourcePath: "x")) == nil else {
            throw SelfTestError.failed("accumulator emitted an unfinished partial")
        }
        guard accumulator.ingest(CaptionCandidate(speaker: "Alice", text: "hello world", confidence: 1, sourcePath: "x")) == nil else {
            throw SelfTestError.failed("accumulator failed to coalesce a growing partial")
        }
        let finalized = accumulator.ingest(CaptionCandidate(speaker: "Bob", text: "yes", confidence: 1, sourcePath: "y"))
        guard finalized?.speaker == "Alice", finalized?.text == "hello world", accumulator.flush()?.text == "yes" else {
            throw SelfTestError.failed("accumulator speaker transition failed")
        }
        passed.append("transcript accumulator")

        let overlayNodes = [
            AXSnapshotNode(path: "0", depth: 0, role: "AXGroup", title: "", value: "", description: "", identifier: "", parentPath: nil),
            AXSnapshotNode(path: "0.0", depth: 1, role: "AXStaticText", title: "", value: "Alice", description: "", identifier: "", parentPath: "0"),
            AXSnapshotNode(path: "0.1", depth: 1, role: "AXStaticText", title: "", value: ":", description: "", identifier: "", parentPath: "0"),
            AXSnapshotNode(path: "0.2", depth: 1, role: "AXStaticText", title: "", value: "overlay text", description: "", identifier: "", parentPath: "0"),
        ]
        let overlayCandidates = CaptionHeuristics.extractCandidates(from: overlayNodes)
        guard overlayCandidates.count == 1,
              overlayCandidates[0].speaker == "Alice",
              overlayCandidates[0].text == "overlay text",
              overlayCandidates[0].source == .slackOverlay else {
            throw SelfTestError.failed("overlay caption fallback failed")
        }

        let sideBySideNodes = [
            AXSnapshotNode(path: "1", depth: 0, role: "AXGroup", title: "", value: "字幕", description: "", identifier: "", parentPath: nil),
            AXSnapshotNode(path: "1.0", depth: 1, role: "AXList", title: "", value: "转录", description: "", identifier: "", parentPath: "1"),
            AXSnapshotNode(path: "1.0.0", depth: 2, role: "AXGroup", title: "", value: "", description: "", identifier: "", parentPath: "1.0"),
            AXSnapshotNode(path: "1.0.0.0", depth: 3, role: "AXStaticText", title: "", value: "字幕正在以English (US)生成。", description: "", identifier: "", parentPath: "1.0.0"),
            AXSnapshotNode(path: "1.0.1", depth: 2, role: "AXGroup", title: "", value: "", description: "", identifier: "", parentPath: "1.0"),
            AXSnapshotNode(path: "1.0.1.1.0", depth: 4, role: "AXStaticText", title: "", value: "Alice", description: "", identifier: "", parentPath: "1.0.1.1"),
            AXSnapshotNode(path: "1.0.1.2.0", depth: 4, role: "AXStaticText", title: "", value: "persistent text", description: "", identifier: "", parentPath: "1.0.1.2"),
        ]
        let preferredNodes = overlayNodes + sideBySideNodes
        let preferredCandidates = CaptionHeuristics.extractCandidates(from: preferredNodes)
        guard preferredCandidates.count == 1,
              preferredCandidates[0].speaker == "Alice",
              preferredCandidates[0].text == "persistent text",
              preferredCandidates[0].source == .slackSideBySide,
              CaptionHeuristics.preferredSource(from: preferredNodes) == .slackSideBySide else {
            throw SelfTestError.failed("side-by-side captions were not preferred over overlay")
        }
        passed.append("caption source preference")

        func candidate(_ speaker: String, _ text: String, _ path: String) -> CaptionCandidate {
            CaptionCandidate(speaker: speaker, text: text, confidence: 1, sourcePath: path)
        }
        let oldBuffer = [candidate("Alice", "one", "0"), candidate("Alice", "yes", "1"), candidate("Bob", "two", "2")]
        let shifted = [candidate("Alice", "yes", "0"), candidate("Bob", "two", "1"), candidate("Alice", "yes", "2")]
        let shiftedDelta = CaptionStream.delta(previous: oldBuffer, current: shifted)
        guard shiftedDelta.count == 1, shiftedDelta[0].speaker == "Alice", shiftedDelta[0].text == "yes" else {
            throw SelfTestError.failed("caption rolling-buffer diff suppressed a legitimate repeated utterance")
        }
        let partialOld = [candidate("Alice", "hello", "0")]
        let partialNew = [candidate("Alice", "hello world", "0")]
        let partialDelta = CaptionStream.delta(previous: partialOld, current: partialNew)
        guard partialDelta.count == 1, partialDelta[0].text == "hello world" else {
            throw SelfTestError.failed("caption rolling-buffer diff missed a growing partial")
        }
        let overlayHistory = [candidate("Alice", "two", "o0"), candidate("Bob", "three", "o1")]
        let persistentHistory = [
            candidate("Alice", "one", "s0"),
            candidate("Alice", "two", "s1"),
            candidate("Bob", "three", "s2"),
            candidate("Bob", "four", "s3"),
        ]
        let switchedDelta = CaptionStream.delta(previous: overlayHistory, current: persistentHistory)
        guard switchedDelta.count == 1, switchedDelta[0].text == "four" else {
            throw SelfTestError.failed("overlay-to-side-by-side switch replayed persistent history")
        }
        passed.append("caption stream diff")

        let control = CollectorControl()
        guard !control.isStopRequested else {
            throw SelfTestError.failed("collector control started stopped")
        }
        control.stop()
        guard control.isStopRequested else {
            throw SelfTestError.failed("collector control did not stop")
        }
        passed.append("collector control")

        let entries = [TranscriptEntry(sequence: 1, speaker: "Alice", text: "We will ship Friday.", confidence: 1)]
        let prompt = MeetingExport.summaryPrompt(entries: entries)
        guard prompt.contains("## Decisions"), prompt.contains("## Action Items"), prompt.contains("[Alice] We will ship Friday.") else {
            throw SelfTestError.failed("summary prompt contract failed")
        }
        passed.append("summary prompt")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("morrow-scribe-self-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try MeetingStore(title: "Self Test", baseDirectory: tmp)
        try store.appendTranscript(TranscriptEntry(sequence: 1, speaker: "Alice", text: "hello", confidence: 1))
        try store.finish()
        let roundTrip = try MeetingExport.transcriptEntries(in: store.directory)
        guard roundTrip.count == 1, roundTrip[0].speaker == "Alice", roundTrip[0].text == "hello" else {
            throw SelfTestError.failed("meeting store round-trip failed")
        }
        passed.append("meeting store round-trip")

        let library = try MeetingLibrary.loadAll(root: tmp)
        guard library.count == 1,
              library[0].metadata.title == "Self Test",
              library[0].transcript.contains("Alice") else {
            throw SelfTestError.failed("meeting library failed to load saved meeting")
        }
        passed.append("meeting library")

        return passed
    }
}
