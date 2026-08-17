import Foundation

public final class TranscriptAccumulator: @unchecked Sendable {
    private var current: CaptionCandidate?
    private var sequence = 0

    public init() {}

    public func ingest(_ candidate: CaptionCandidate, at date: Date = Date()) -> TranscriptEntry? {
        let normalized = CaptionCandidate(
            speaker: candidate.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
            text: candidate.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: candidate.confidence,
            sourcePath: candidate.sourcePath,
            source: candidate.source
        )
        guard !normalized.text.isEmpty else { return nil }

        guard let existing = current else {
            current = normalized
            return nil
        }

        if existing.speaker == normalized.speaker {
            if normalized.text == existing.text {
                return nil
            }

            // Native caption UIs revise punctuation and recognition hypotheses while an
            // utterance is still in progress. Zoom in particular can evolve a stable row
            // from `Zoom.` -> `Zoom, segment.` -> `Zoom segment alpha.`; raw string-prefix
            // matching would incorrectly finalize every revision. A stable source path is
            // a stronger signal that this is the same live caption row, so always replace
            // the in-progress candidate instead of emitting an intermediate transcript row.
            if existing.source == normalized.source,
               !existing.sourcePath.isEmpty,
               existing.sourcePath == normalized.sourcePath {
                current = normalized
                return nil
            }

            if normalized.text.hasPrefix(existing.text) || existing.text.hasPrefix(normalized.text) {
                if normalized.text.count >= existing.text.count {
                    current = normalized
                }
                return nil
            }
        }

        current = normalized
        return finalize(existing, at: date)
    }

    public func flush(at date: Date = Date()) -> TranscriptEntry? {
        guard let existing = current else { return nil }
        current = nil
        return finalize(existing, at: date)
    }

    private func finalize(_ candidate: CaptionCandidate, at date: Date) -> TranscriptEntry {
        sequence += 1
        return TranscriptEntry(
            sequence: sequence,
            observedAt: date,
            speaker: candidate.speaker,
            text: candidate.text,
            source: candidate.source.rawValue,
            confidence: candidate.confidence
        )
    }
}
