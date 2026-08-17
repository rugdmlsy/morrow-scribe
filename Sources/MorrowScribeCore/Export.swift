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
        let transcript = entries.map { "[\($0.speaker ?? "Unknown")] \($0.text)" }.joined(separator: "\n")
        return """
        You are a meeting scribe. Produce a concise structured summary in Markdown with exactly these sections:
        ## TL;DR
        ## Decisions
        ## Action Items
        ## Research Questions
        ## Open Questions

        Preserve speaker attribution when it matters. Do not invent decisions, owners, or deadlines. If an item is uncertain, mark it as uncertain.

        Transcript:
        \(transcript)
        """
    }
}
