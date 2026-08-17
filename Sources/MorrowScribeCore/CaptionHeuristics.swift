import Foundation

public enum CaptionHeuristics {
    private static let captionContextKeywords = [
        "caption", "captions", "closed caption", "subtitle", "subtitles", "transcript",
        "字幕", "实时字幕", "转录"
    ]

    private static let huddleKeywords = ["huddle", "抱团"]

    private static let controlNoise = [
        "开启字幕", "关闭字幕", "显示字幕", "隐藏字幕", "captions on", "captions off",
        "抱团", "huddle", "麦克风", "microphone", "摄像头", "camera", "共享屏幕", "share screen"
    ]

    public static func isHuddleRelated(_ node: AXSnapshotNode) -> Bool {
        let text = node.visibleText.lowercased()
        return captionContextKeywords.contains(where: { text.contains($0.lowercased()) })
            || huddleKeywords.contains(where: { text.contains($0.lowercased()) })
    }

    public static func changedTextEvents(
        previous: [AXSnapshotNode],
        current: [AXSnapshotNode]
    ) -> [AXChangeEvent] {
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0) })
        let byPath = Dictionary(uniqueKeysWithValues: current.map { ($0.path, $0) })
        var output: [AXChangeEvent] = []

        for node in current where node.role == "AXStaticText" || node.role == "AXGroup" || node.role == "AXHeading" {
            let text = node.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let prior = old[node.path]
            guard prior?.visibleText != text else { continue }
            let context = ancestorContext(for: node, in: byPath, maxLevels: 4)
            output.append(AXChangeEvent(
                kind: prior == nil ? "appeared" : "changed",
                node: node,
                context: context
            ))
        }
        return output
    }

    public static func extractCandidates(from nodes: [AXSnapshotNode]) -> [CaptionCandidate] {
        let byPath = Dictionary(uniqueKeysWithValues: nodes.map { ($0.path, $0) })
        let children = Dictionary(grouping: nodes.compactMap { node -> (String, AXSnapshotNode)? in
            guard let parent = node.parentPath else { return nil }
            return (parent, node)
        }, by: { $0.0 }).mapValues { pairList in
            pairList.map(\.1).sorted { pathOrder($0.path, $1.path) }
        }

        var output: [CaptionCandidate] = []
        var seen = Set<String>()

        // Slack 4.51 Huddle live captions expose each utterance as a group whose direct
        // static-text children are: speaker name, a standalone colon, and caption text.
        // This is materially stronger than inferring a speaker from nearby labels.
        for group in nodes where group.role == "AXGroup" {
            let direct = (children[group.path] ?? []).filter { $0.role == "AXStaticText" }
            guard direct.count >= 3 else { continue }

            for index in 0...(direct.count - 3) {
                let speakerNode = direct[index]
                let separatorNode = direct[index + 1]
                let textNode = direct[index + 2]
                let speaker = clean(speakerNode.visibleText)
                let separator = clean(separatorNode.visibleText)
                let text = clean(textNode.visibleText)

                guard separator == ":" || separator == "：",
                      isPlausibleSpeaker(speaker),
                      isPlausibleCaptionText(text) else { continue }

                let signature = "\(speaker)\u{0}\(text)"
                if seen.insert(signature).inserted {
                    output.append(CaptionCandidate(
                        speaker: speaker,
                        text: text,
                        confidence: 0.99,
                        sourcePath: group.path
                    ))
                }
            }
        }

        if !output.isEmpty {
            return output.sorted { pathOrder($0.sourcePath, $1.sourcePath) }
        }

        // Compatibility fallback for Slack UI variants that expose caption text under a
        // caption-labelled ancestor but not the speaker/text triplet used by 4.51.
        for node in nodes where node.role == "AXStaticText" {
            let text = clean(node.visibleText)
            guard isPlausibleCaptionText(text) else { continue }
            let context = ancestorContext(for: node, in: byPath, maxLevels: 5)
            let contextBlob = context.joined(separator: " ").lowercased()
            let hasCaptionContext = captionContextKeywords.contains { contextBlob.contains($0.lowercased()) }
            guard hasCaptionContext else { continue }

            let signature = "\u{0}\(text)"
            if seen.insert(signature).inserted {
                output.append(CaptionCandidate(
                    speaker: nil,
                    text: text,
                    confidence: 0.68,
                    sourcePath: node.path
                ))
            }
        }
        return output.sorted { pathOrder($0.sourcePath, $1.sourcePath) }
    }

    private static func pathOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        return left.lexicographicallyPrecedes(right)
    }

    public static func ancestorContext(
        for node: AXSnapshotNode,
        in byPath: [String: AXSnapshotNode],
        maxLevels: Int
    ) -> [String] {
        var result: [String] = []
        var parent = node.parentPath
        var levels = 0
        while let path = parent, levels < maxLevels, let item = byPath[path] {
            let text = clean(item.visibleText)
            if !text.isEmpty { result.append(text) }
            parent = item.parentPath
            levels += 1
        }
        return result
    }

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPlausibleCaptionText(_ value: String) -> Bool {
        guard value.count >= 2, value.count <= 1_500 else { return false }
        let lower = value.lowercased()
        if controlNoise.contains(where: { lower == $0.lowercased() }) { return false }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return false }
        return value.rangeOfCharacter(from: .letters.union(.decimalDigits)) != nil
    }

    private static func isPlausibleSpeaker(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        let lower = value.lowercased()
        if controlNoise.contains(where: { lower.contains($0.lowercased()) }) { return false }
        if value.contains("。") || value.contains("？") || value.contains("！") { return false }
        return true
    }
}
