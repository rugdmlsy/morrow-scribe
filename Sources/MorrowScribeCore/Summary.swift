import Foundation

public enum SummaryConfidence: String, Codable, Hashable, Sendable {
    case high
    case medium
    case low
}

public struct SummaryEvidence: Codable, Hashable, Sendable {
    public let speaker: String?
    public let timestamp: String?
    public let quote: String?

    public init(speaker: String? = nil, timestamp: String? = nil, quote: String? = nil) {
        self.speaker = Self.cleanOptional(speaker)
        self.timestamp = Self.cleanOptional(timestamp)
        self.quote = Self.cleanOptional(quote)
    }

    public var isEmpty: Bool {
        speaker == nil && timestamp == nil && quote == nil
    }

    private static func cleanOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

public struct SummaryPoint: Codable, Hashable, Sendable, Identifiable {
    public let text: String
    public let evidence: SummaryEvidence?
    public let confidence: SummaryConfidence

    public init(text: String, evidence: SummaryEvidence? = nil, confidence: SummaryConfidence = .medium) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.evidence = evidence?.isEmpty == false ? evidence : nil
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey { case text, evidence, confidence }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let confidenceRaw = try container.decodeIfPresent(String.self, forKey: .confidence)
        self.init(
            text: try container.decode(String.self, forKey: .text),
            evidence: try container.decodeIfPresent(SummaryEvidence.self, forKey: .evidence),
            confidence: confidenceRaw.flatMap(SummaryConfidence.init(rawValue:)) ?? .medium
        )
    }

    public var id: String {
        [text, evidence?.timestamp ?? "", evidence?.speaker ?? ""].joined(separator: "|")
    }
}

public enum SummaryActionExplicitness: String, Codable, Hashable, Sendable {
    case explicit
    case inferred
}

public struct SummaryActionItem: Codable, Hashable, Sendable, Identifiable {
    public let text: String
    public let owner: String?
    public let deadline: String?
    public let explicitness: SummaryActionExplicitness
    public let evidence: SummaryEvidence?
    public let confidence: SummaryConfidence

    public init(
        text: String,
        owner: String? = nil,
        deadline: String? = nil,
        explicitness: SummaryActionExplicitness = .explicit,
        evidence: SummaryEvidence? = nil,
        confidence: SummaryConfidence = .medium
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.owner = Self.cleanOptional(owner)
        self.deadline = Self.cleanOptional(deadline)
        self.explicitness = explicitness
        self.evidence = evidence?.isEmpty == false ? evidence : nil
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case text, owner, deadline, explicitness, evidence, confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let explicitnessRaw = try container.decodeIfPresent(String.self, forKey: .explicitness)
        let confidenceRaw = try container.decodeIfPresent(String.self, forKey: .confidence)
        self.init(
            text: try container.decode(String.self, forKey: .text),
            owner: try container.decodeIfPresent(String.self, forKey: .owner),
            deadline: try container.decodeIfPresent(String.self, forKey: .deadline),
            explicitness: explicitnessRaw.flatMap(SummaryActionExplicitness.init(rawValue:)) ?? .inferred,
            evidence: try container.decodeIfPresent(SummaryEvidence.self, forKey: .evidence),
            confidence: confidenceRaw.flatMap(SummaryConfidence.init(rawValue:)) ?? .medium
        )
    }

    public var id: String {
        [text, owner ?? "", deadline ?? ""].joined(separator: "|")
    }

    private static func cleanOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

public struct SummarySection: Codable, Hashable, Sendable, Identifiable {
    public let title: String
    public let bullets: [SummaryPoint]

    public init(title: String, bullets: [SummaryPoint]) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bullets = bullets.filter { !$0.text.isEmpty }
    }

    private enum CodingKeys: String, CodingKey { case title, bullets }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try container.decode(String.self, forKey: .title),
            bullets: try container.decodeIfPresent([SummaryPoint].self, forKey: .bullets) ?? []
        )
    }

    public var id: String { title }
}

public struct MeetingSummary: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let tldr: [SummaryPoint]
    public let decisions: [SummaryPoint]
    public let actionItems: [SummaryActionItem]
    public let nextSteps: [SummaryPoint]
    public let openQuestions: [SummaryPoint]
    public let risks: [SummaryPoint]
    public let sections: [SummarySection]
    public let sourceWarnings: [String]

    public init(
        schemaVersion: Int = 1,
        tldr: [SummaryPoint],
        decisions: [SummaryPoint] = [],
        actionItems: [SummaryActionItem] = [],
        nextSteps: [SummaryPoint] = [],
        openQuestions: [SummaryPoint] = [],
        risks: [SummaryPoint] = [],
        sections: [SummarySection] = [],
        sourceWarnings: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.tldr = tldr.filter { !$0.text.isEmpty }
        self.decisions = decisions.filter { !$0.text.isEmpty }
        self.actionItems = actionItems.filter { !$0.text.isEmpty }
        self.nextSteps = nextSteps.filter { !$0.text.isEmpty }
        self.openQuestions = openQuestions.filter { !$0.text.isEmpty }
        self.risks = risks.filter { !$0.text.isEmpty }
        self.sections = sections.filter { !$0.title.isEmpty && !$0.bullets.isEmpty }
        self.sourceWarnings = sourceWarnings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tldr, decisions, actionItems, nextSteps, openQuestions, risks, sections, sourceWarnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            tldr: try container.decodeIfPresent([SummaryPoint].self, forKey: .tldr) ?? [],
            decisions: try container.decodeIfPresent([SummaryPoint].self, forKey: .decisions) ?? [],
            actionItems: try container.decodeIfPresent([SummaryActionItem].self, forKey: .actionItems) ?? [],
            nextSteps: try container.decodeIfPresent([SummaryPoint].self, forKey: .nextSteps) ?? [],
            openQuestions: try container.decodeIfPresent([SummaryPoint].self, forKey: .openQuestions) ?? [],
            risks: try container.decodeIfPresent([SummaryPoint].self, forKey: .risks) ?? [],
            sections: try container.decodeIfPresent([SummarySection].self, forKey: .sections) ?? [],
            sourceWarnings: try container.decodeIfPresent([String].self, forKey: .sourceWarnings) ?? []
        )
    }

    public static func decodeModelOutput(_ output: String) throws -> MeetingSummary {
        let json = try extractJSONObject(from: output)
        do {
            let decoded = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
            return MeetingSummary(
                schemaVersion: decoded.schemaVersion,
                tldr: decoded.tldr,
                decisions: decoded.decisions,
                actionItems: decoded.actionItems,
                nextSteps: decoded.nextSteps,
                openQuestions: decoded.openQuestions,
                risks: decoded.risks,
                sections: decoded.sections,
                sourceWarnings: decoded.sourceWarnings
            )
        } catch {
            throw SummaryError.invalidStructuredResponse(String(describing: error))
        }
    }

    public var markdown: String {
        var out = "# Meeting Summary\n\n"
        Self.appendPoints(&out, title: "TL;DR", points: tldr)
        Self.appendPoints(&out, title: "Decisions", points: decisions)

        if !actionItems.isEmpty {
            out += "## Action Items\n\n"
            for item in actionItems {
                var suffix: [String] = []
                if let owner = item.owner { suffix.append("Owner: \(owner)") }
                if let deadline = item.deadline { suffix.append("Deadline: \(deadline)") }
                if item.explicitness == .inferred { suffix.append("inferred") }
                let metadata = suffix.isEmpty ? "" : " — \(suffix.joined(separator: "; "))"
                out += "- [ ] \(item.text)\(metadata)\n"
                Self.appendEvidence(&out, evidence: item.evidence, confidence: item.confidence)
            }
            out += "\n"
        }

        Self.appendPoints(&out, title: "Next Steps", points: nextSteps)
        Self.appendPoints(&out, title: "Open Questions", points: openQuestions)
        Self.appendPoints(&out, title: "Risks / Blockers", points: risks)

        for section in sections {
            Self.appendPoints(&out, title: section.title, points: section.bullets)
        }

        if !sourceWarnings.isEmpty {
            out += "## Source Quality\n\n"
            for warning in sourceWarnings { out += "- \(warning)\n" }
            out += "\n"
        }
        return out
    }

    public var isEmpty: Bool {
        tldr.isEmpty && decisions.isEmpty && actionItems.isEmpty && nextSteps.isEmpty &&
            openQuestions.isEmpty && risks.isEmpty && sections.isEmpty
    }

    private static func appendPoints(_ out: inout String, title: String, points: [SummaryPoint]) {
        guard !points.isEmpty else { return }
        out += "## \(title)\n\n"
        for point in points {
            out += "- \(point.text)\n"
            appendEvidence(&out, evidence: point.evidence, confidence: point.confidence)
        }
        out += "\n"
    }

    private static func appendEvidence(
        _ out: inout String,
        evidence: SummaryEvidence?,
        confidence: SummaryConfidence
    ) {
        var metadata: [String] = []
        if let timestamp = evidence?.timestamp { metadata.append(timestamp) }
        if let speaker = evidence?.speaker { metadata.append(speaker) }
        if confidence != .high { metadata.append("\(confidence.rawValue) confidence") }
        if let quote = evidence?.quote {
            let prefix = metadata.isEmpty ? "" : "\(metadata.joined(separator: " · ")) — "
            out += "  - Evidence: \(prefix)“\(quote)”\n"
        } else if !metadata.isEmpty {
            out += "  - Evidence: \(metadata.joined(separator: " · "))\n"
        }
    }

    private static func extractJSONObject(from output: String) throws -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last else {
            throw SummaryError.invalidStructuredResponse("response did not contain a JSON object")
        }
        return String(trimmed[first...last])
    }
}

public enum MeetingSummaryPrompt {
    public static func build(entries: [TranscriptEntry]) -> String {
        let firstDate = entries.first?.observedAt ?? Date()
        let transcript = entries.map { entry -> String in
            let elapsed = max(0, entry.observedAt.timeIntervalSince(firstDate))
            let timestamp = formatElapsed(elapsed)
            let speaker = entry.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? entry.speaker!.trimmingCharacters(in: .whitespacesAndNewlines)
                : "Unknown"
            return "[\(timestamp)] [\(speaker)] [\(entry.source)] \(entry.text)"
        }.joined(separator: "\n")

        return """
        You are Morrow Scribe, a meticulous meeting note-taker. Convert the transcript below into grounded, compact meeting intelligence.

        GROUNDING RULES (non-negotiable):
        - Use only information stated in this transcript. Never add outside knowledge or typical-meeting assumptions.
        - Empty is better than guessed. Do not invent names, decisions, owners, deadlines, dates, numbers, risks, or conclusions.
        - A decision is something actually agreed/decided, not merely discussed, proposed, or considered.
        - An action item is a concrete task or commitment. Set explicitness="explicit" only when the transcript clearly commits someone to it; otherwise use "inferred".
        - owner and deadline must be null unless explicitly supported by the transcript.
        - Preserve technical terms and proper nouns when the transcript supports them. Correct obvious caption errors only when context makes the correction unambiguous.
        - For important items, include one short evidence quote copied verbatim from the transcript plus its exact timestamp and speaker. Do not fabricate evidence.
        - Use confidence="low" when captions are ambiguous, speaker attribution is uncertain, or the conclusion requires interpretation.
        - Avoid filler such as “the meeting discussed”, “various topics”, or generic restatements.
        - Write the summary in the dominant language of the transcript, while preserving technical terms in their natural form.

        CONTENT RULES:
        - tldr: 2-5 concrete bullets covering the most important outcomes or state changes.
        - decisions: only actual decisions/agreement.
        - actionItems: tasks/commitments, with owner/deadline only when explicitly stated.
        - nextSteps: future directions or intended follow-ups that are useful but are not necessarily assigned tasks.
        - openQuestions: unresolved questions that remain open at the end of the transcript.
        - risks: explicit blockers, risks, concerns, or uncertainties that could materially affect the work.
        - sections: 0-4 additional topic-specific sections only when they add useful detail. Good examples include “Research Questions”, “Technical Notes”, or “Customer Feedback”. Do not create empty or redundant sections.
        - sourceWarnings: only concrete limitations visible in the transcript, such as missing speaker identity or clearly incomplete captions. Otherwise return [].

        Return ONLY one valid JSON object matching this exact shape. No Markdown fences and no prose outside JSON:
        {
          "schemaVersion": 1,
          "tldr": [
            {"text":"concrete takeaway","evidence":{"speaker":"name or null","timestamp":"MM:SS","quote":"short verbatim quote or null"},"confidence":"high|medium|low"}
          ],
          "decisions": [],
          "actionItems": [
            {"text":"task","owner":null,"deadline":null,"explicitness":"explicit|inferred","evidence":{"speaker":"name or null","timestamp":"MM:SS","quote":"short verbatim quote or null"},"confidence":"high|medium|low"}
          ],
          "nextSteps": [],
          "openQuestions": [],
          "risks": [],
          "sections": [
            {"title":"Topic-specific title","bullets":[{"text":"grounded note","evidence":null,"confidence":"high|medium|low"}]}
          ],
          "sourceWarnings": []
        }

        Transcript:
        ---
        \(transcript)
        ---
        """
    }

    private static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
