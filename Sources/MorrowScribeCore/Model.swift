import Foundation

public struct AXSnapshotNode: Codable, Hashable, Sendable {
    public let path: String
    public let depth: Int
    public let role: String
    public let title: String
    public let value: String
    public let description: String
    public let identifier: String
    public let parentPath: String?

    public init(
        path: String,
        depth: Int,
        role: String,
        title: String,
        value: String,
        description: String,
        identifier: String,
        parentPath: String?
    ) {
        self.path = path
        self.depth = depth
        self.role = role
        self.title = title
        self.value = value
        self.description = description
        self.identifier = identifier
        self.parentPath = parentPath
    }

    public var visibleText: String {
        [title, value, description]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public struct CaptionCandidate: Codable, Hashable, Sendable {
    public let speaker: String?
    public let text: String
    public let confidence: Double
    public let sourcePath: String

    public init(speaker: String?, text: String, confidence: Double, sourcePath: String) {
        self.speaker = speaker
        self.text = text
        self.confidence = confidence
        self.sourcePath = sourcePath
    }
}

public struct TranscriptEntry: Codable, Hashable, Sendable {
    public let id: UUID
    public let sequence: Int
    public let observedAt: Date
    public let speaker: String?
    public let text: String
    public let source: String
    public let confidence: Double

    public init(
        id: UUID = UUID(),
        sequence: Int,
        observedAt: Date = Date(),
        speaker: String?,
        text: String,
        source: String = "slack_ax",
        confidence: Double
    ) {
        self.id = id
        self.sequence = sequence
        self.observedAt = observedAt
        self.speaker = speaker
        self.text = text
        self.source = source
        self.confidence = confidence
    }
}

public struct MeetingMetadata: Codable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let platform: String
    public let startedAt: Date
    public var endedAt: Date?
    public var participants: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        platform: String = "slack",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        participants: [String] = []
    ) {
        self.id = id
        self.title = title
        self.platform = platform
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.participants = participants
    }
}

public struct AXChangeEvent: Codable, Sendable {
    public let observedAt: Date
    public let kind: String
    public let node: AXSnapshotNode
    public let context: [String]

    public init(observedAt: Date = Date(), kind: String, node: AXSnapshotNode, context: [String]) {
        self.observedAt = observedAt
        self.kind = kind
        self.node = node
        self.context = context
    }
}
