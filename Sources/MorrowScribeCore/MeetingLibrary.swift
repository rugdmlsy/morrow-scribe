import Foundation

public struct SavedMeeting: Identifiable, Hashable, Sendable {
    public let id: String
    public let directory: URL
    public let metadata: MeetingMetadata
    public let transcript: String
    public let summary: String?

    public init(directory: URL, metadata: MeetingMetadata, transcript: String, summary: String?) {
        self.id = directory.path
        self.directory = directory
        self.metadata = metadata
        self.transcript = transcript
        self.summary = summary
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

    private static func loadMeetingImpl(_ directory: URL) throws -> SavedMeeting? {
        let metadataURL = directory.appendingPathComponent("meeting.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(MeetingMetadata.self, from: Data(contentsOf: metadataURL))
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        let summaryURL = directory.appendingPathComponent("summary.md")
        let transcript = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        let summary = FileManager.default.fileExists(atPath: summaryURL.path)
            ? try? String(contentsOf: summaryURL, encoding: .utf8)
            : nil
        return SavedMeeting(directory: directory, metadata: metadata, transcript: transcript, summary: summary)
    }
}
