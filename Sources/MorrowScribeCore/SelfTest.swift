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

        let nodes = [
            AXSnapshotNode(path: "0", depth: 0, role: "AXGroup", title: "", value: "", description: "", identifier: "", parentPath: nil),
            AXSnapshotNode(path: "0.0", depth: 1, role: "AXStaticText", title: "", value: "Alice", description: "", identifier: "", parentPath: "0"),
            AXSnapshotNode(path: "0.1", depth: 1, role: "AXStaticText", title: "", value: ":", description: "", identifier: "", parentPath: "0"),
            AXSnapshotNode(path: "0.2", depth: 1, role: "AXStaticText", title: "", value: "hello world", description: "", identifier: "", parentPath: "0"),
        ]
        let candidates = CaptionHeuristics.extractCandidates(from: nodes)
        guard candidates.contains(where: { $0.speaker == "Alice" && $0.text == "hello world" }) else {
            throw SelfTestError.failed("caption heuristic failed to pair speaker and caption")
        }
        passed.append("caption heuristic")

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
        passed.append("caption stream diff")

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

        return passed
    }
}
