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
        let zoomAccumulator = TranscriptAccumulator()
        guard zoomAccumulator.ingest(CaptionCandidate(speaker: "wu wu", text: "Zoom.", confidence: 1, sourcePath: "z.0", source: .zoomNative)) == nil,
              zoomAccumulator.ingest(CaptionCandidate(speaker: "wu wu", text: "Zoom, segment.", confidence: 1, sourcePath: "z.0", source: .zoomNative)) == nil,
              zoomAccumulator.ingest(CaptionCandidate(speaker: "wu wu", text: "Zoom segment alpha.", confidence: 1, sourcePath: "z.0", source: .zoomNative)) == nil else {
            throw SelfTestError.failed("accumulator emitted a Zoom hypothesis revision")
        }
        let zoomFinalized = zoomAccumulator.ingest(CaptionCandidate(speaker: "wu wu", text: "Second utterance.", confidence: 1, sourcePath: "z.1", source: .zoomNative))
        guard zoomFinalized?.text == "Zoom segment alpha.", zoomAccumulator.flush()?.text == "Second utterance." else {
            throw SelfTestError.failed("accumulator failed to finalize a stable Zoom caption row")
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

        let zoomCaptionNodes = [
            AXSnapshotNode(path: "z", depth: 0, role: "AXWindow", title: "Zoom会议", value: "", description: "", identifier: "", parentPath: nil),
            AXSnapshotNode(path: "z.1", depth: 1, role: "AXTable", title: "", value: "", description: "字幕", identifier: "", parentPath: "z"),
            AXSnapshotNode(path: "z.1.0", depth: 2, role: "AXGroup", title: "", value: "", description: "", identifier: "", parentPath: "z.1"),
            AXSnapshotNode(path: "z.1.0.0", depth: 3, role: "AXGroup", title: "", value: "", description: "", identifier: "", parentPath: "z.1.0"),
            AXSnapshotNode(path: "z.1.0.0.0", depth: 4, role: "AXStaticText", title: "", value: "wu wu", description: "", identifier: "", parentPath: "z.1.0.0"),
            AXSnapshotNode(path: "z.1.0.0.1", depth: 4, role: "AXStaticText", title: "", value: "Hello hello. okay?", description: "", identifier: "", parentPath: "z.1.0.0"),
            AXSnapshotNode(path: "z.1.0.0.2", depth: 4, role: "AXStaticText", title: "", value: "Hello hello. okay?", description: "", identifier: "", parentPath: "z.1.0.0"),
        ]
        let zoomCandidates = ZoomCaptionHeuristics.extractCandidates(from: zoomCaptionNodes)
        guard ZoomAXSession.isMeetingWindowTitle("Zoom会议"),
              ZoomAXSession.isMeetingWindowTitle("wu wu的Zoom会议"),
              ZoomAXSession.isMeetingWindowTitle("Zoom Meeting"),
              ZoomCaptionHeuristics.hasCaptionSurface(in: zoomCaptionNodes),
              zoomCandidates.count == 1,
              zoomCandidates[0].speaker == "wu wu",
              zoomCandidates[0].text == "Hello hello. okay?",
              zoomCandidates[0].source == .zoomNative else {
            throw SelfTestError.failed("Zoom native caption Accessibility parser failed")
        }
        let zoomBaseline = CaptionCandidate(
            speaker: "wu wu",
            text: "Old Zoom text.",
            confidence: 1,
            sourcePath: "z.1.0.0",
            source: .zoomNative
        )
        let zoomExtended = CaptionCandidate(
            speaker: "wu wu",
            text: "Old Zoom text. New text after attach.",
            confidence: 1,
            sourcePath: "z.1.0.0",
            source: .zoomNative
        )
        guard ZoomCaptionHeuristics.removingAttachmentBaseline(from: zoomBaseline, baseline: zoomBaseline) == nil,
              ZoomCaptionHeuristics.removingAttachmentBaseline(from: zoomExtended, baseline: zoomBaseline)?.text == "New text after attach." else {
            throw SelfTestError.failed("Zoom attachment baseline replay suppression failed")
        }
        passed.append("Zoom native caption parser")

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

        let summaryStart = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            TranscriptEntry(
                sequence: 1,
                observedAt: summaryStart,
                speaker: "Alice",
                text: "We will ship Friday.",
                source: CaptionSource.slackSideBySide.rawValue,
                confidence: 1
            ),
            TranscriptEntry(
                sequence: 2,
                observedAt: summaryStart.addingTimeInterval(65),
                speaker: "Bob",
                text: "I'll update the prototype tomorrow.",
                source: CaptionSource.zoomNative.rawValue,
                confidence: 1
            ),
        ]
        let prompt = MeetingExport.summaryPrompt(entries: entries)
        guard prompt.contains("Empty is better than guessed"),
              prompt.contains("A decision is something actually agreed/decided"),
              prompt.contains("[00:00] [Alice] [slack_ax_side_by_side] We will ship Friday."),
              prompt.contains("[01:05] [Bob] [zoom_native_caption] I'll update the prototype tomorrow.") else {
            throw SelfTestError.failed("summary prompt contract failed")
        }
        let structuredSummary = try MeetingSummary.decodeModelOutput(
            """
            ```json
            {
              "schemaVersion": 1,
              "tldr": [{"text":"Ship Friday","evidence":{"speaker":"Alice","timestamp":"00:00","quote":"We will ship Friday."},"confidence":"high"}],
              "decisions": [{"text":"Friday is the ship target","evidence":{"speaker":"Alice","timestamp":"00:00","quote":"We will ship Friday."},"confidence":"high"}],
              "actionItems": [{"text":"Update the prototype","owner":"Bob","deadline":"tomorrow","explicitness":"explicit","evidence":{"speaker":"Bob","timestamp":"01:05","quote":"I'll update the prototype tomorrow."},"confidence":"high"}],
              "nextSteps": [],
              "openQuestions": [],
              "risks": [],
              "sections": [],
              "sourceWarnings": []
            }
            ```
            """
        )
        guard structuredSummary.actionItems.first?.owner == "Bob",
              structuredSummary.markdown.contains("## Decisions"),
              structuredSummary.markdown.contains("- [ ] Update the prototype — Owner: Bob; Deadline: tomorrow") else {
            throw SelfTestError.failed("structured summary parsing/export failed")
        }
        passed.append("structured summary")

        let evidenceProbe = MeetingSummary(
            tldr: [
                SummaryPoint(
                    text: "Ship Friday",
                    evidence: SummaryEvidence(speaker: "Wrong Speaker", timestamp: "99:99", quote: "We will ship Friday."),
                    confidence: .high
                ),
            ],
            decisions: [
                SummaryPoint(
                    text: "Invented evidence must be rejected",
                    evidence: SummaryEvidence(speaker: "Alice", timestamp: "00:00", quote: "This sentence never appeared."),
                    confidence: .high
                ),
            ]
        ).grounded(against: entries, timelineOrigin: summaryStart)
        let chunks = SummaryClient.transcriptChunks(entries: entries, maxCharacters: 70)
        guard evidenceProbe.tldr.first?.evidence?.speaker == "Alice",
              evidenceProbe.tldr.first?.evidence?.timestamp == "00:00",
              evidenceProbe.decisions.first?.evidence == nil,
              evidenceProbe.decisions.first?.confidence == .low,
              evidenceProbe.sourceWarnings.contains(where: { $0.contains("removed 1 model evidence") }),
              chunks.count == 2,
              MeetingSummaryPrompt.build(entries: chunks[1], timelineOrigin: summaryStart)
                .contains("[01:05] [Bob] [zoom_native_caption] I'll update the prototype tomorrow.") else {
            throw SelfTestError.failed("summary evidence grounding or chunk timeline failed")
        }
        passed.append("summary grounding and chunking")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("morrow-scribe-self-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try MeetingStore(title: "Self Test", baseDirectory: tmp)
        try store.appendTranscript(TranscriptEntry(sequence: 1, speaker: "Alice", text: "hello", confidence: 1))
        try store.finish()
        try MeetingExport.writeSummary(structuredSummary, to: store.directory)
        let roundTrip = try MeetingExport.transcriptEntries(in: store.directory)
        guard roundTrip.count == 1, roundTrip[0].speaker == "Alice", roundTrip[0].text == "hello" else {
            throw SelfTestError.failed("meeting store round-trip failed")
        }
        passed.append("meeting store round-trip")

        let library = try MeetingLibrary.loadAll(root: tmp)
        guard library.count == 1,
              library[0].metadata.title == "Self Test",
              library[0].transcript.contains("Alice"),
              library[0].structuredSummary?.decisions.count == 1,
              library[0].summary?.contains("## Action Items") == true else {
            throw SelfTestError.failed("meeting library failed to load saved meeting")
        }
        passed.append("meeting library")

        let originalDirectory = library[0].directory
        let renamedDirectory = try MeetingLibrary.renameMeeting(at: originalDirectory, to: "Renamed Meeting")
        guard renamedDirectory != originalDirectory,
              !FileManager.default.fileExists(atPath: originalDirectory.path),
              let renamed = try MeetingLibrary.loadMeeting(at: renamedDirectory),
              renamed.metadata.title == "Renamed Meeting",
              renamed.transcript.hasPrefix("# Renamed Meeting") else {
            throw SelfTestError.failed("meeting rename did not update directory, metadata, and transcript heading")
        }
        try MeetingLibrary.deleteMeeting(at: renamedDirectory)
        guard !FileManager.default.fileExists(atPath: renamedDirectory.path) else {
            throw SelfTestError.failed("meeting delete left the meeting directory behind")
        }
        passed.append("meeting rename/delete")

        let sessionRoot = tmp.appendingPathComponent("session", isDirectory: true)
        let sessionStore = try MeetingStore(title: "Cross Provider", baseDirectory: sessionRoot)
        let sessionControl = CollectorControl()
        let slackProvider = SelfTestRecordingProvider(
            id: "slack",
            displayName: "Slack",
            source: .slackGeneric,
            text: "Slack segment",
            stopAfterAttachment: false
        )
        let zoomProvider = SelfTestRecordingProvider(
            id: "zoom",
            displayName: "Zoom",
            source: .zoomNative,
            text: "Zoom segment",
            stopAfterAttachment: true
        )
        var recordingStatuses: [String] = []
        let recording = RecordingSession(
            store: sessionStore,
            providers: [slackProvider, zoomProvider],
            control: sessionControl,
            options: CollectorOptions(monitorInterval: 0.10)
        )
        try recording.run { recordingStatuses.append($0) }
        let crossProviderEntries = try MeetingExport.transcriptEntries(in: sessionStore.directory)
        guard crossProviderEntries.count == 2,
              crossProviderEntries.map(\.sequence) == [1, 2],
              crossProviderEntries[0].source == CaptionSource.slackGeneric.rawValue,
              crossProviderEntries[1].source == CaptionSource.zoomNative.rawValue,
              crossProviderEntries.map(\.text) == ["Slack segment", "Zoom segment"],
              recordingStatuses.contains(where: { $0.contains("Slack meeting ended") }),
              recordingStatuses.contains(where: { $0.contains("Zoom meeting detected") }),
              let finishedSession = try MeetingLibrary.loadMeeting(at: sessionStore.directory),
              finishedSession.metadata.endedAt != nil else {
            throw SelfTestError.failed("recording session did not preserve one transcript across provider detach/switch")
        }
        passed.append("cross-provider recording session")

        return passed
    }
}


private final class SelfTestRecordingProvider: RecordingProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    private let source: CaptionSource
    private let text: String
    private let stopAfterAttachment: Bool
    private var consumed = false

    init(
        id: String,
        displayName: String,
        source: CaptionSource,
        text: String,
        stopAfterAttachment: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.text = text
        self.stopAfterAttachment = stopAfterAttachment
    }

    func probe() throws -> RecordingProviderProbe {
        RecordingProviderProbe(active: !consumed, detail: consumed ? nil : "self-test")
    }

    func recordAttachment(
        store: MeetingStore,
        accumulator: TranscriptAccumulator,
        control: CollectorControl,
        options: CollectorOptions,
        onStatus: ((String) -> Void)?
    ) throws -> RecordingAttachmentResult {
        _ = accumulator.ingest(
            CaptionCandidate(
                speaker: displayName,
                text: text,
                confidence: 1,
                sourcePath: id,
                source: source
            )
        )
        guard let finalized = accumulator.flush() else {
            throw SelfTestError.failed("fake provider failed to finalize transcript")
        }
        try store.appendTranscript(finalized)
        consumed = true
        if stopAfterAttachment {
            control.stop()
            return .stopped
        }
        return .detached
    }
}
