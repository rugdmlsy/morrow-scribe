import Foundation


public final class CaptionStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var candidates: [CaptionCandidate] = []

    public init() {}

    public func snapshot() -> [CaptionCandidate] {
        lock.lock()
        defer { lock.unlock() }
        return candidates
    }

    public func update(_ newCandidates: [CaptionCandidate]) {
        lock.lock()
        candidates = newCandidates
        lock.unlock()
    }
}

public enum CaptionStream {
    /// Return only candidates that are new or updated compared with Slack's previous
    /// rolling caption buffer.
    ///
    /// Slack keeps several recent utterances visible and shifts them upward as new speech
    /// arrives. Comparing exact signatures with a time window would incorrectly suppress a
    /// legitimate repeated phrase. Instead, find the longest exact overlap between the old
    /// buffer's suffix and the new buffer's prefix; only the non-overlapping tail is new.
    public static func delta(
        previous: [CaptionCandidate],
        current: [CaptionCandidate]
    ) -> [CaptionCandidate] {
        guard !current.isEmpty else { return [] }
        guard !previous.isEmpty else { return current }

        let maxOverlap = min(previous.count, current.count)
        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            let oldStart = previous.count - overlap
            var matches = true
            for offset in 0..<overlap {
                if !sameUtterance(previous[oldStart + offset], current[offset]) {
                    matches = false
                    break
                }
            }
            if matches {
                return Array(current.dropFirst(overlap))
            }
        }

        // When switching from transient overlay captions to the persistent side-by-side
        // transcript, the previous rolling buffer may appear anywhere inside the longer
        // current history rather than at its prefix. Align the longest suffix of the old
        // buffer to the latest matching window in the new transcript and emit only items
        // after that window.
        if let end = latestEmbeddedSuffixEnd(previous: previous, current: current) {
            guard end < current.count else { return [] }
            return Array(current[end...])
        }

        // A growing partial usually changes only the last item. If paths are stable, keep
        // the changed item and anything after it rather than replaying the whole buffer.
        if let firstChanged = firstChangedStablePath(previous: previous, current: current) {
            return Array(current[firstChanged...])
        }
        return current
    }


    private static func latestEmbeddedSuffixEnd(
        previous: [CaptionCandidate],
        current: [CaptionCandidate]
    ) -> Int? {
        let maxOverlap = min(previous.count, current.count)
        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            let oldStart = previous.count - overlap
            guard current.count >= overlap else { continue }
            for newStart in stride(from: current.count - overlap, through: 0, by: -1) {
                var matches = true
                for offset in 0..<overlap {
                    if !sameUtterance(previous[oldStart + offset], current[newStart + offset]) {
                        matches = false
                        break
                    }
                }
                if matches { return newStart + overlap }
            }
        }
        return nil
    }

    private static func sameUtterance(_ lhs: CaptionCandidate, _ rhs: CaptionCandidate) -> Bool {
        lhs.speaker == rhs.speaker && lhs.text == rhs.text
    }

    private static func firstChangedStablePath(
        previous: [CaptionCandidate],
        current: [CaptionCandidate]
    ) -> Int? {
        let limit = min(previous.count, current.count)
        for index in 0..<limit {
            guard previous[index].sourcePath == current[index].sourcePath else { return nil }
            if !sameUtterance(previous[index], current[index]) { return index }
        }
        if current.count > previous.count { return limit }
        return nil
    }
}
