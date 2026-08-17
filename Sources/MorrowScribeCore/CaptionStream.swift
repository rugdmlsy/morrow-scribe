import Foundation

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

        // A growing partial usually changes only the last item. If paths are stable, keep
        // the changed item and anything after it rather than replaying the whole buffer.
        if let firstChanged = firstChangedStablePath(previous: previous, current: current) {
            return Array(current[firstChanged...])
        }
        return current
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
