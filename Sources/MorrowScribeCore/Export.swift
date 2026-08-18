import Foundation

public enum MeetingExport {
    public static func transcriptEntries(in directory: URL) throws -> [TranscriptEntry] {
        let url = directory.appendingPathComponent("transcript.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let content = try String(contentsOf: url, encoding: .utf8)
        return try content
            .split(separator: "\n")
            .filter { !$0.isEmpty }
            .map { try decoder.decode(TranscriptEntry.self, from: Data($0.utf8)) }
    }

    public static func markdown(entries: [TranscriptEntry], title: String = "Meeting Transcript") -> String {
        var out = "# \(title)\n\n"
        for entry in entries {
            out += "**\(entry.speaker ?? "Unknown"):** \(entry.text)\n\n"
        }
        return out
    }

    public static func summaryPrompt(entries: [TranscriptEntry]) -> String {
        MeetingSummaryPrompt.build(entries: entries)
    }

    public static func writeSummary(_ summary: MeetingSummary, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let jsonURL = directory.appendingPathComponent("summary.json")
        let markdownURL = directory.appendingPathComponent("summary.md")
        try encoder.encode(summary).write(to: jsonURL, options: .atomic)
        try summary.markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
    }
}
