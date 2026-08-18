import Foundation

public enum MeetingLibraryError: Error, CustomStringConvertible {
    case emptyTitle
    case notFound

    public var description: String {
        switch self {
        case .emptyTitle: return "meeting title cannot be empty"
        case .notFound: return "meeting directory was not found"
        }
    }
}


public struct SavedMeeting: Identifiable, Hashable, Sendable {
    public let id: String
    public let directory: URL
    public let metadata: MeetingMetadata
    public let transcript: String
    public let summary: String?
    public let structuredSummary: MeetingSummary?

    public init(
        directory: URL,
        metadata: MeetingMetadata,
        transcript: String,
        summary: String?,
        structuredSummary: MeetingSummary? = nil
    ) {
        self.id = directory.path
        self.directory = directory
        self.metadata = metadata
        self.transcript = transcript
        self.summary = summary
        self.structuredSummary = structuredSummary
    }
}

public enum MeetingLibrary {
    public static func loadAll(root: URL = MeetingStore.defaultRootDirectory()) throws -> [SavedMeeting] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let urls = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { try loadMeetingImpl($0) }.sorted {
            $0.metadata.startedAt > $1.metadata.startedAt
        }
    }

    public static func loadMeeting(at directory: URL) throws -> SavedMeeting? {
        try loadMeetingImpl(directory)
    }


    @discardableResult
    public static func renameMeeting(at directory: URL, to newTitle: String) throws -> URL {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MeetingLibraryError.emptyTitle }
        guard let saved = try loadMeetingImpl(directory) else { throw MeetingLibraryError.notFound }

        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        let timestamp = timestampPrefix(for: saved.metadata.startedAt)
        let slug = slugify(title)
        var target = parent.appendingPathComponent("\(timestamp)-\(slug)", isDirectory: true)
        var suffix = 2
        while target.standardizedFileURL != directory.standardizedFileURL && fm.fileExists(atPath: target.path) {
            target = parent.appendingPathComponent("\(timestamp)-\(slug)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        let original = directory
        var moved = false
        if target.standardizedFileURL != original.standardizedFileURL {
            try fm.moveItem(at: original, to: target)
            moved = true
        } else {
            target = original
        }

        do {
            var metadata = saved.metadata
            metadata.title = title
            try writeMetadata(metadata, to: target.appendingPathComponent("meeting.json"))
            try updateTranscriptHeading(in: target, title: title)
            return target
        } catch {
            if moved, !fm.fileExists(atPath: original.path) {
                try? fm.moveItem(at: target, to: original)
            }
            throw error
        }
    }

    public static func deleteMeeting(at directory: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              try loadMeetingImpl(directory) != nil else { throw MeetingLibraryError.notFound }
        try fm.removeItem(at: directory)
    }

    private static func writeMetadata(_ metadata: MeetingMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    private static func updateTranscriptHeading(in directory: URL, title: String) throws {
        let url = directory.appendingPathComponent("transcript.md")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var content = try String(contentsOf: url, encoding: .utf8)
        if content.hasPrefix("# ") {
            if let newline = content.firstIndex(of: "\n") {
                content = "# \(title)" + content[newline...]
            } else {
                content = "# \(title)\n"
            }
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func timestampPrefix(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func slugify(_ value: String) -> String {
        let allowed = value.lowercased().map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return "-"
        }
        let raw = String(allowed)
        let slug = raw.split(separator: "-", omittingEmptySubsequences: true).prefix(8).joined(separator: "-")
        return slug.isEmpty ? "meeting" : slug
    }

    private static func loadMeetingImpl(_ directory: URL) throws -> SavedMeeting? {
        let metadataURL = directory.appendingPathComponent("meeting.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(MeetingMetadata.self, from: Data(contentsOf: metadataURL))
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        let summaryURL = directory.appendingPathComponent("summary.md")
        let structuredSummaryURL = directory.appendingPathComponent("summary.json")
        let transcript = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        let summary = FileManager.default.fileExists(atPath: summaryURL.path)
            ? try? String(contentsOf: summaryURL, encoding: .utf8)
            : nil
        let structuredSummary: MeetingSummary?
        if FileManager.default.fileExists(atPath: structuredSummaryURL.path) {
            structuredSummary = try? JSONDecoder().decode(MeetingSummary.self, from: Data(contentsOf: structuredSummaryURL))
        } else {
            structuredSummary = nil
        }
        return SavedMeeting(
            directory: directory,
            metadata: metadata,
            transcript: transcript,
            summary: summary,
            structuredSummary: structuredSummary
        )
    }
}
