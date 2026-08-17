import Foundation

public enum CaptionHeuristics {
    private static let captionContextKeywords = [
        "caption", "captions", "closed caption", "subtitle", "subtitles", "transcript",
        "字幕", "实时字幕", "转录"
    ]

    private static let huddleKeywords = ["huddle", "抱团"]

    private static let controlNoise = [
        "开启字幕", "关闭字幕", "显示字幕", "隐藏字幕", "captions on", "captions off",
        "抱团", "huddle", "麦克风", "microphone", "摄像头", "camera", "共享屏幕", "share screen",
        "字幕正在以english (us)生成。", "更改抱团语言"
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

    /// Prefer Slack's persistent side-by-side transcript surface. Only fall back to the
    /// transient overlay captions when that surface is not present at all.
    public static func extractCandidates(from nodes: [AXSnapshotNode]) -> [CaptionCandidate] {
        if hasSideBySideSurface(in: nodes) {
            return extractSideBySideCandidates(from: nodes)
        }
        let overlay = extractOverlayCandidates(from: nodes)
        if !overlay.isEmpty { return overlay }
        return extractGenericCandidates(from: nodes)
    }

    public static func preferredSource(from nodes: [AXSnapshotNode]) -> CaptionSource? {
        if hasSideBySideSurface(in: nodes) { return .slackSideBySide }
        if !extractOverlayCandidates(from: nodes).isEmpty { return .slackOverlay }
        if !extractGenericCandidates(from: nodes).isEmpty { return .slackGeneric }
        return nil
    }

    public static func hasSideBySideSurface(in nodes: [AXSnapshotNode]) -> Bool {
        let children = childMap(nodes)
        for node in nodes where node.role == "AXGroup" {
            let text = clean(node.visibleText).lowercased()
            guard text == "字幕" || text == "captions" else { continue }
            if descendants(of: node.path, in: nodes).contains(where: { child in
                guard child.role == "AXList" else { return false }
                let label = clean(child.visibleText).lowercased()
                return label == "转录" || label == "transcript" || label == "transcription"
            }) {
                return true
            }
            // Keep the direct-child map touched here so UI variants with a shallow list
            // remain covered without relying on a fixed path depth.
            if (children[node.path] ?? []).contains(where: { $0.role == "AXList" }) { return true }
        }
        return false
    }

    public static func extractSideBySideCandidates(from nodes: [AXSnapshotNode]) -> [CaptionCandidate] {
        let transcriptLists = nodes.filter { node in
            guard node.role == "AXList" else { return false }
            let label = clean(node.visibleText).lowercased()
            guard label == "转录" || label == "transcript" || label == "transcription" else { return false }
            return ancestorContext(for: node, in: Dictionary(uniqueKeysWithValues: nodes.map { ($0.path, $0) }), maxLevels: 4)
                .contains(where: { value in
                    let lower = value.lowercased()
                    return lower == "字幕" || lower == "captions" || lower.contains("次要视图")
                })
        }

        var output: [CaptionCandidate] = []
        var seen = Set<String>()
        for list in transcriptLists {
            let prefix = list.path + "."
            let rows = Dictionary(grouping: nodes.filter { $0.path.hasPrefix(prefix) }) { node -> String in
                let suffix = node.path.dropFirst(prefix.count)
                return String(suffix.split(separator: ".").first ?? "")
            }
            for rowKey in rows.keys.sorted(by: numericStringOrder) {
                guard !rowKey.isEmpty else { continue }
                let rowNodes = (rows[rowKey] ?? []).sorted { pathOrder($0.path, $1.path) }
                let texts = rowNodes
                    .filter { $0.role == "AXStaticText" }
                    .map { clean($0.visibleText) }
                    .filter { !$0.isEmpty }
                guard texts.count >= 2 else { continue }
                let speaker = texts[0]
                guard isPlausibleSpeaker(speaker),
                      let text = texts.dropFirst().first(where: isPlausibleCaptionText) else { continue }
                let signature = "\(speaker)\u{0}\(text)"
                guard seen.insert(signature).inserted else { continue }
                output.append(CaptionCandidate(
                    speaker: speaker,
                    text: text,
                    confidence: 0.995,
                    sourcePath: list.path + "." + rowKey,
                    source: .slackSideBySide
                ))
            }
        }
        return output.sorted { pathOrder($0.sourcePath, $1.sourcePath) }
    }

    public static func extractOverlayCandidates(from nodes: [AXSnapshotNode]) -> [CaptionCandidate] {
        let children = childMap(nodes)
        var output: [CaptionCandidate] = []
        var seen = Set<String>()

        // Slack 4.51 overlay captions expose each utterance as a group whose direct
        // static-text children are: speaker name, a standalone colon, and caption text.
        for group in nodes where group.role == "AXGroup" {
            let direct = (children[group.path] ?? []).filter { $0.role == "AXStaticText" }
            guard direct.count >= 3 else { continue }

            for index in 0...(direct.count - 3) {
                let speaker = clean(direct[index].visibleText)
                let separator = clean(direct[index + 1].visibleText)
                let text = clean(direct[index + 2].visibleText)
                guard separator == ":" || separator == "：",
                      isPlausibleSpeaker(speaker),
                      isPlausibleCaptionText(text) else { continue }
                let signature = "\(speaker)\u{0}\(text)"
                if seen.insert(signature).inserted {
                    output.append(CaptionCandidate(
                        speaker: speaker,
                        text: text,
                        confidence: 0.99,
                        sourcePath: group.path,
                        source: .slackOverlay
                    ))
                }
            }
        }
        return output.sorted { pathOrder($0.sourcePath, $1.sourcePath) }
    }

    private static func extractGenericCandidates(from nodes: [AXSnapshotNode]) -> [CaptionCandidate] {
        let byPath = Dictionary(uniqueKeysWithValues: nodes.map { ($0.path, $0) })
        var output: [CaptionCandidate] = []
        var seen = Set<String>()
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
                    sourcePath: node.path,
                    source: .slackGeneric
                ))
            }
        }
        return output.sorted { pathOrder($0.sourcePath, $1.sourcePath) }
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

    private static func childMap(_ nodes: [AXSnapshotNode]) -> [String: [AXSnapshotNode]] {
        Dictionary(grouping: nodes.compactMap { node -> (String, AXSnapshotNode)? in
            guard let parent = node.parentPath else { return nil }
            return (parent, node)
        }, by: { $0.0 }).mapValues { pairList in
            pairList.map(\.1).sorted { pathOrder($0.path, $1.path) }
        }
    }

    private static func descendants(of path: String, in nodes: [AXSnapshotNode]) -> [AXSnapshotNode] {
        let prefix = path + "."
        return nodes.filter { $0.path.hasPrefix(prefix) }
    }

    private static func numericStringOrder(_ lhs: String, _ rhs: String) -> Bool {
        if let l = Int(lhs), let r = Int(rhs) { return l < r }
        return lhs < rhs
    }

    private static func pathOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        return left.lexicographicallyPrecedes(right)
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
