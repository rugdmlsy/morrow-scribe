import Foundation

public final class MeetingStore: @unchecked Sendable {
    public let directory: URL
    private let metadataURL: URL
    private let transcriptURL: URL
    private let markdownURL: URL
    private let axEventsURL: URL
    private let encoder: JSONEncoder
    private var metadata: MeetingMetadata

    public init(
        title: String,
        baseDirectory: URL? = nil,
        now: Date = Date(),
        platform: String = "multi"
    ) throws {
        let root = baseDirectory ?? Self.defaultRootDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let slug = Self.slugify(title)
        directory = root.appendingPathComponent("\(formatter.string(from: now))-\(slug)", isDirectory: true)
        metadataURL = directory.appendingPathComponent("meeting.json")
        transcriptURL = directory.appendingPathComponent("transcript.jsonl")
        markdownURL = directory.appendingPathComponent("transcript.md")
        axEventsURL = directory.appendingPathComponent("ax-events.jsonl")
        metadata = MeetingMetadata(title: title, platform: platform, startedAt: now)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try persistMetadata()
        try "# \(title)\n\n".write(to: markdownURL, atomically: true, encoding: .utf8)
    }

    public static func defaultRootDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/Morrow Scribe", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
    }

    public func appendTranscript(_ entry: TranscriptEntry) throws {
        try appendJSONLine(entry, to: transcriptURL)
        let speaker = entry.speaker?.isEmpty == false ? entry.speaker! : "Unknown"
        let line = "- **\(speaker):** \(entry.text)\n"
        try appendText(line, to: markdownURL)
        if let speakerName = entry.speaker, !speakerName.isEmpty, !metadata.participants.contains(speakerName) {
            metadata.participants.append(speakerName)
            try persistMetadata()
        }
    }

    public func appendAXEvent(_ event: AXChangeEvent) throws {
        try appendJSONLine(event, to: axEventsURL)
    }

    public func finish(at date: Date = Date()) throws {
        metadata.endedAt = date
        try persistMetadata()
    }

    private func persistMetadata() throws {
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func appendJSONLine<T: Encodable>(_ value: T, to url: URL) throws {
        var data = try encoder.encode(value)
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func appendText(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private static func slugify(_ value: String) -> String {
        let allowed = value.lowercased().map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return "-"
        }
        let raw = String(allowed)
        return raw
            .split(separator: "-", omittingEmptySubsequences: true)
            .prefix(8)
            .joined(separator: "-")
    }
}
