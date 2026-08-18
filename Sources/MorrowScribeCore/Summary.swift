import Foundation

public enum SummaryConfidence: String, Codable, Hashable, Sendable {
    case high
    case medium
    case low

    var rank: Int {
        switch self {
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }
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
    public let evidence: [SummaryEvidence]
    public let confidence: SummaryConfidence

    public init(text: String, evidence: [SummaryEvidence] = [], confidence: SummaryConfidence = .medium) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.evidence = Self.cleanEvidence(evidence)
        self.confidence = confidence
    }

    public init(text: String, evidence: SummaryEvidence?, confidence: SummaryConfidence = .medium) {
        self.init(text: text, evidence: evidence.map { [$0] } ?? [], confidence: confidence)
    }

    private enum CodingKeys: String, CodingKey { case text, evidence, confidence }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let confidenceRaw = try container.decodeIfPresent(String.self, forKey: .confidence)
        let decodedEvidence: [SummaryEvidence]
        if let array = try? container.decode([SummaryEvidence].self, forKey: .evidence) {
            decodedEvidence = array
        } else if let single = try container.decodeIfPresent(SummaryEvidence.self, forKey: .evidence) {
            // Backward compatibility with schemaVersion 1 summaries.
            decodedEvidence = [single]
        } else {
            decodedEvidence = []
        }
        self.init(
            text: try container.decode(String.self, forKey: .text),
            evidence: decodedEvidence,
            confidence: confidenceRaw.flatMap(SummaryConfidence.init(rawValue:)) ?? .medium
        )
    }

    public var id: String {
        [text, evidence.first?.timestamp ?? "", evidence.first?.speaker ?? ""].joined(separator: "|")
    }

    private static func cleanEvidence(_ evidence: [SummaryEvidence]) -> [SummaryEvidence] {
        var seen = Set<SummaryEvidence>()
        return evidence.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(4).map { $0 }
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
    public let evidence: [SummaryEvidence]
    public let confidence: SummaryConfidence

    public init(
        text: String,
        owner: String? = nil,
        deadline: String? = nil,
        explicitness: SummaryActionExplicitness = .explicit,
        evidence: [SummaryEvidence] = [],
        confidence: SummaryConfidence = .medium
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.owner = Self.cleanOptional(owner)
        self.deadline = Self.cleanOptional(deadline)
        self.explicitness = explicitness
        self.evidence = Self.cleanEvidence(evidence)
        self.confidence = confidence
    }

    public init(
        text: String,
        owner: String? = nil,
        deadline: String? = nil,
        explicitness: SummaryActionExplicitness = .explicit,
        evidence: SummaryEvidence?,
        confidence: SummaryConfidence = .medium
    ) {
        self.init(
            text: text,
            owner: owner,
            deadline: deadline,
            explicitness: explicitness,
            evidence: evidence.map { [$0] } ?? [],
            confidence: confidence
        )
    }

    private enum CodingKeys: String, CodingKey {
        case text, owner, deadline, explicitness, evidence, confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let explicitnessRaw = try container.decodeIfPresent(String.self, forKey: .explicitness)
        let confidenceRaw = try container.decodeIfPresent(String.self, forKey: .confidence)
        let decodedEvidence: [SummaryEvidence]
        if let array = try? container.decode([SummaryEvidence].self, forKey: .evidence) {
            decodedEvidence = array
        } else if let single = try container.decodeIfPresent(SummaryEvidence.self, forKey: .evidence) {
            decodedEvidence = [single]
        } else {
            decodedEvidence = []
        }
        self.init(
            text: try container.decode(String.self, forKey: .text),
            owner: try container.decodeIfPresent(String.self, forKey: .owner),
            deadline: try container.decodeIfPresent(String.self, forKey: .deadline),
            explicitness: explicitnessRaw.flatMap(SummaryActionExplicitness.init(rawValue:)) ?? .inferred,
            evidence: decodedEvidence,
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

    private static func cleanEvidence(_ evidence: [SummaryEvidence]) -> [SummaryEvidence] {
        var seen = Set<SummaryEvidence>()
        return evidence.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(4).map { $0 }
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

public enum SummaryPresentationMode: String, CaseIterable, Hashable, Sendable, Identifiable {
    case concise = "Concise"
    case detailed = "Detailed"
    public var id: String { rawValue }
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
        schemaVersion: Int = 2,
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

    public static func decodeModelOutput(
        _ output: String,
        entries: [TranscriptEntry],
        timelineOrigin: Date
    ) throws -> MeetingSummary {
        let json = try extractJSONObject(from: output)
        let decoded: ModelMeetingSummary
        do {
            decoded = try JSONDecoder().decode(ModelMeetingSummary.self, from: Data(json.utf8))
        } catch {
            throw SummaryError.invalidStructuredResponse(String(describing: error))
        }

        let catalog = MeetingSummaryPrompt.evidenceCatalog(entries: entries, timelineOrigin: timelineOrigin)
        var invalidReferenceCount = 0

        func resolve(_ refs: [String]) -> ([SummaryEvidence], Bool) {
            var result: [SummaryEvidence] = []
            var invalid = false
            for raw in refs.prefix(3) {
                let ref = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard let evidence = catalog[ref] else {
                    invalidReferenceCount += 1
                    invalid = true
                    continue
                }
                if !result.contains(evidence) { result.append(evidence) }
            }
            return (result, invalid)
        }

        func point(_ value: ModelSummaryPoint) -> SummaryPoint {
            let (evidence, invalid) = resolve(value.evidenceRefs)
            return SummaryPoint(
                text: value.text,
                evidence: evidence,
                confidence: invalid ? .low : value.confidence
            )
        }

        let summary = MeetingSummary(
            schemaVersion: 2,
            tldr: decoded.tldr.map(point),
            decisions: decoded.decisions.map(point),
            actionItems: decoded.actionItems.map { value in
                let (evidence, invalid) = resolve(value.evidenceRefs)
                return SummaryActionItem(
                    text: value.text,
                    owner: value.owner,
                    deadline: value.deadline,
                    explicitness: value.explicitness,
                    evidence: evidence,
                    confidence: invalid ? .low : value.confidence
                )
            },
            nextSteps: decoded.nextSteps.map(point),
            openQuestions: decoded.openQuestions.map(point),
            risks: decoded.risks.map(point),
            sections: decoded.sections.map { section in
                SummarySection(title: section.title, bullets: section.bullets.map(point))
            },
            sourceWarnings: decoded.sourceWarnings
        )

        guard invalidReferenceCount > 0 else { return summary }
        return MeetingSummary(
            schemaVersion: summary.schemaVersion,
            tldr: summary.tldr,
            decisions: summary.decisions,
            actionItems: summary.actionItems,
            nextSteps: summary.nextSteps,
            openQuestions: summary.openQuestions,
            risks: summary.risks,
            sections: summary.sections,
            sourceWarnings: summary.sourceWarnings + [
                "Morrow Scribe ignored \(invalidReferenceCount) model evidence reference(s) that were not present in the transcript chunk."
            ]
        )
    }

    private struct ModelSummaryPoint: Decodable {
        let text: String
        let evidenceRefs: [String]
        let confidence: SummaryConfidence
    }

    private struct ModelSummaryAction: Decodable {
        let text: String
        let owner: String?
        let deadline: String?
        let explicitness: SummaryActionExplicitness
        let evidenceRefs: [String]
        let confidence: SummaryConfidence
    }

    private struct ModelSummarySection: Decodable {
        let title: String
        let bullets: [ModelSummaryPoint]
    }

    private struct ModelMeetingSummary: Decodable {
        let schemaVersion: Int
        let tldr: [ModelSummaryPoint]
        let decisions: [ModelSummaryPoint]
        let actionItems: [ModelSummaryAction]
        let nextSteps: [ModelSummaryPoint]
        let openQuestions: [ModelSummaryPoint]
        let risks: [ModelSummaryPoint]
        let sections: [ModelSummarySection]
        let sourceWarnings: [String]
    }

    public var markdown: String { markdown(mode: .detailed) }
    public var conciseMarkdown: String { markdown(mode: .concise) }

    public func markdown(mode: SummaryPresentationMode) -> String {
        var out = "# Meeting Summary\n\n"
        let includeEvidence = mode == .detailed
        Self.appendPoints(&out, title: "TL;DR", points: tldr, includeEvidence: includeEvidence)
        Self.appendPoints(&out, title: "Decisions", points: decisions, includeEvidence: includeEvidence)

        if !actionItems.isEmpty {
            out += "## Action Items\n\n"
            for item in actionItems {
                var suffix: [String] = []
                if let owner = item.owner { suffix.append("Owner: \(owner)") }
                if let deadline = item.deadline { suffix.append("Deadline: \(deadline)") }
                if item.explicitness == .inferred { suffix.append("inferred") }
                let metadata = suffix.isEmpty ? "" : " — \(suffix.joined(separator: "; "))"
                out += "- [ ] \(item.text)\(metadata)\n"
                if includeEvidence {
                    Self.appendEvidence(&out, evidence: item.evidence, confidence: item.confidence)
                }
            }
            out += "\n"
        }

        Self.appendPoints(&out, title: "Open Questions", points: openQuestions, includeEvidence: includeEvidence)

        if mode == .detailed {
            Self.appendPoints(&out, title: "Next Steps", points: nextSteps, includeEvidence: true)
            Self.appendPoints(&out, title: "Risks / Blockers", points: risks, includeEvidence: true)

            for section in sections {
                Self.appendPoints(&out, title: section.title, points: section.bullets, includeEvidence: true)
            }

            if !sourceWarnings.isEmpty {
                out += "## Source Quality\n\n"
                for warning in sourceWarnings { out += "- \(warning)\n" }
                out += "\n"
            }
        }
        return out
    }

    public var isEmpty: Bool {
        tldr.isEmpty && decisions.isEmpty && actionItems.isEmpty && nextSteps.isEmpty &&
            openQuestions.isEmpty && risks.isEmpty && sections.isEmpty
    }

    public func grounded(
        against entries: [TranscriptEntry],
        timelineOrigin: Date? = nil
    ) -> MeetingSummary {
        guard !entries.isEmpty else { return self }
        let origin = timelineOrigin ?? entries[0].observedAt
        var rejectedEvidenceCount = 0

        func groundedEvidence(_ evidence: [SummaryEvidence]) -> (values: [SummaryEvidence], rejected: Bool) {
            var values: [SummaryEvidence] = []
            var rejected = false
            for item in evidence {
                if let validated = Self.validatedEvidence(item, against: entries, timelineOrigin: origin) {
                    if !values.contains(validated) { values.append(validated) }
                } else {
                    rejectedEvidenceCount += 1
                    rejected = true
                }
            }
            return (Array(values.prefix(4)), rejected)
        }

        func groundedPoint(_ point: SummaryPoint) -> SummaryPoint {
            let result = groundedEvidence(point.evidence)
            return SummaryPoint(
                text: point.text,
                evidence: result.values,
                confidence: result.rejected ? .low : point.confidence
            )
        }

        func groundedAction(_ item: SummaryActionItem) -> SummaryActionItem {
            let result = groundedEvidence(item.evidence)
            return SummaryActionItem(
                text: item.text,
                owner: item.owner,
                deadline: item.deadline,
                explicitness: item.explicitness,
                evidence: result.values,
                confidence: result.rejected ? .low : item.confidence
            )
        }

        var warnings = sourceWarnings
        let groundedSummary = MeetingSummary(
            schemaVersion: max(2, schemaVersion),
            tldr: tldr.map(groundedPoint),
            decisions: decisions.map(groundedPoint),
            actionItems: actionItems.map(groundedAction),
            nextSteps: nextSteps.map(groundedPoint),
            openQuestions: openQuestions.map(groundedPoint),
            risks: risks.map(groundedPoint),
            sections: sections.map { SummarySection(title: $0.title, bullets: $0.bullets.map(groundedPoint)) },
            sourceWarnings: []
        )
        if rejectedEvidenceCount > 0 {
            warnings.append(
                "Morrow Scribe removed \(rejectedEvidenceCount) model evidence citation(s) that could not be matched to the transcript."
            )
        }
        return MeetingSummary(
            schemaVersion: groundedSummary.schemaVersion,
            tldr: groundedSummary.tldr,
            decisions: groundedSummary.decisions,
            actionItems: groundedSummary.actionItems,
            nextSteps: groundedSummary.nextSteps,
            openQuestions: groundedSummary.openQuestions,
            risks: groundedSummary.risks,
            sections: groundedSummary.sections,
            sourceWarnings: warnings
        )
    }

    private static func appendPoints(
        _ out: inout String,
        title: String,
        points: [SummaryPoint],
        includeEvidence: Bool
    ) {
        guard !points.isEmpty else { return }
        out += "## \(title)\n\n"
        for point in points {
            out += "- \(point.text)\n"
            if includeEvidence {
                appendEvidence(&out, evidence: point.evidence, confidence: point.confidence)
            }
        }
        out += "\n"
    }

    private static func appendEvidence(
        _ out: inout String,
        evidence: [SummaryEvidence],
        confidence: SummaryConfidence
    ) {
        if evidence.isEmpty, confidence != .high {
            out += "  - \(confidence.rawValue.capitalized) confidence\n"
            return
        }
        for item in evidence {
            var metadata: [String] = []
            if let timestamp = item.timestamp { metadata.append(timestamp) }
            if let speaker = item.speaker { metadata.append(speaker) }
            if confidence != .high { metadata.append("\(confidence.rawValue) confidence") }
            if let quote = item.quote {
                let prefix = metadata.isEmpty ? "" : "\(metadata.joined(separator: " · ")) — "
                out += "  - Evidence: \(prefix)“\(quote)”\n"
            } else if !metadata.isEmpty {
                out += "  - Evidence: \(metadata.joined(separator: " · "))\n"
            }
        }
    }

    private static func extractJSONObject(from output: String) throws -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last else {
            throw SummaryError.invalidStructuredResponse("response did not contain a JSON object")
        }
        return String(trimmed[first...last])
    }

    private static func validatedEvidence(
        _ evidence: SummaryEvidence,
        against entries: [TranscriptEntry],
        timelineOrigin: Date
    ) -> SummaryEvidence? {
        guard let quote = evidence.quote else { return nil }
        let normalizedQuote = normalizeEvidenceText(quote)
        guard !normalizedQuote.isEmpty else { return nil }

        let matching = entries.filter { normalizeEvidenceText($0.text).contains(normalizedQuote) }
        guard !matching.isEmpty else { return nil }

        let selected: TranscriptEntry
        if let requestedSpeaker = evidence.speaker,
           let speakerMatch = matching.first(where: {
               ($0.speaker ?? "").caseInsensitiveCompare(requestedSpeaker) == .orderedSame
           }) {
            selected = speakerMatch
        } else if let requestedTimestamp = evidence.timestamp,
                  let timestampMatch = matching.first(where: {
                      MeetingSummaryPrompt.formatElapsed(max(0, $0.observedAt.timeIntervalSince(timelineOrigin))) == requestedTimestamp
                  }) {
            selected = timestampMatch
        } else {
            selected = matching[0]
        }

        return SummaryEvidence(
            speaker: selected.speaker,
            timestamp: MeetingSummaryPrompt.formatElapsed(max(0, selected.observedAt.timeIntervalSince(timelineOrigin))),
            quote: quote.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func normalizeEvidenceText(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum MeetingSummaryReducer {
    public static func reduce(_ summaries: [MeetingSummary]) -> MeetingSummary {
        guard !summaries.isEmpty else { return MeetingSummary(tldr: []) }

        let tldr = mergePoints(summaries.flatMap(\.tldr), limit: 5)
        let decisions = mergePoints(summaries.flatMap(\.decisions), limit: 10)
        let actions = mergeActions(summaries.flatMap(\.actionItems), limit: 14)
        let actionTexts = actions.map(\.text)
        let decisionTexts = decisions.map(\.text)
        let nextSteps = mergePoints(summaries.flatMap(\.nextSteps), limit: 8).filter { point in
            !actionTexts.contains(where: { similar($0, point.text) }) &&
                !decisionTexts.contains(where: { similar($0, point.text) })
        }
        let questions = mergePoints(summaries.flatMap(\.openQuestions), limit: 8)
        let risks = mergePoints(summaries.flatMap(\.risks), limit: 8)
        let coreTexts = decisionTexts + actionTexts + questions.map(\.text) + risks.map(\.text)
        let sections = mergeSections(summaries.flatMap(\.sections), excluding: coreTexts)
        let warnings = dedupeStrings(summaries.flatMap(\.sourceWarnings))

        return MeetingSummary(
            schemaVersion: 2,
            tldr: tldr,
            decisions: decisions,
            actionItems: actions,
            nextSteps: nextSteps,
            openQuestions: questions,
            risks: risks,
            sections: sections,
            sourceWarnings: warnings
        )
    }

    public static func similar(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalize(lhs)
        let b = normalize(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let shorter = min(a.count, b.count)
        let longer = max(a.count, b.count)
        if shorter >= 12, (a.contains(b) || b.contains(a)), Double(shorter) / Double(longer) >= 0.58 {
            return true
        }

        let af = features(lhs)
        let bf = features(rhs)
        guard !af.isEmpty, !bf.isEmpty else { return false }
        let shared = af.intersection(bf).count
        let smaller = min(af.count, bf.count)
        return smaller > 0 && Double(shared) / Double(smaller) >= 0.76
    }

    private static func mergePoints(_ points: [SummaryPoint], limit: Int) -> [SummaryPoint] {
        var merged: [SummaryPoint] = []
        for point in points where !point.text.isEmpty {
            if let index = merged.firstIndex(where: { similar($0.text, point.text) }) {
                let existing = merged[index]
                merged[index] = SummaryPoint(
                    text: preferredText(existing.text, point.text),
                    evidence: mergeEvidence(existing.evidence + point.evidence),
                    confidence: existing.confidence.rank >= point.confidence.rank ? existing.confidence : point.confidence
                )
            } else {
                merged.append(point)
            }
        }
        return Array(merged.prefix(limit))
    }

    private static func mergeActions(_ actions: [SummaryActionItem], limit: Int) -> [SummaryActionItem] {
        var merged: [SummaryActionItem] = []
        for action in actions where !action.text.isEmpty {
            if let index = merged.firstIndex(where: { similar($0.text, action.text) }) {
                let existing = merged[index]
                let explicitness: SummaryActionExplicitness =
                    (existing.explicitness == .explicit || action.explicitness == .explicit) ? .explicit : .inferred
                merged[index] = SummaryActionItem(
                    text: preferredText(existing.text, action.text),
                    owner: existing.owner ?? action.owner,
                    deadline: existing.deadline ?? action.deadline,
                    explicitness: explicitness,
                    evidence: mergeEvidence(existing.evidence + action.evidence),
                    confidence: existing.confidence.rank >= action.confidence.rank ? existing.confidence : action.confidence
                )
            } else {
                merged.append(action)
            }
        }
        return Array(merged.prefix(limit))
    }

    private static func mergeSections(_ sections: [SummarySection], excluding coreTexts: [String]) -> [SummarySection] {
        var order: [String] = []
        var byTitle: [String: [SummaryPoint]] = [:]
        for section in sections {
            let key = normalize(section.title)
            guard !key.isEmpty else { continue }
            if byTitle[key] == nil { order.append(key) }
            byTitle[key, default: []].append(contentsOf: section.bullets)
        }

        var result: [SummarySection] = []
        for key in order {
            guard let raw = byTitle[key], let title = sections.first(where: { normalize($0.title) == key })?.title else { continue }
            let reduced = mergePoints(raw, limit: 12).filter { bullet in
                !coreTexts.contains(where: { similar($0, bullet.text) })
            }
            if !reduced.isEmpty { result.append(SummarySection(title: title, bullets: reduced)) }
            if result.count == 4 { break }
        }
        return result
    }

    private static func mergeEvidence(_ evidence: [SummaryEvidence]) -> [SummaryEvidence] {
        var seen = Set<SummaryEvidence>()
        return evidence.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(4).map { $0 }
    }

    private static func preferredText(_ a: String, _ b: String) -> String {
        // Near-duplicate atoms should stay compact. Prefer the shorter wording unless it is
        // suspiciously terse compared with the other candidate.
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        return Double(shorter.count) / Double(max(1, longer.count)) >= 0.62 ? shorter : longer
    }

    private static func dedupeStrings(_ strings: [String]) -> [String] {
        var out: [String] = []
        for value in strings where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !out.contains(where: { similar($0, value) }) { out.append(value) }
        }
        return out
    }

    private static func normalize(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || isHan(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func features(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let words = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !englishStopwords.contains($0) }
        var out = Set(words.map { "w:\($0)" })

        var hanRun: [Unicode.Scalar] = []
        func flushHan() {
            guard !hanRun.isEmpty else { return }
            if hanRun.count == 1 {
                out.insert("h:\(String(hanRun[0]))")
            } else {
                for index in 0..<(hanRun.count - 1) {
                    out.insert("h:\(String(hanRun[index]))\(String(hanRun[index + 1]))")
                }
            }
            hanRun.removeAll(keepingCapacity: true)
        }

        for scalar in lowered.unicodeScalars {
            if isHan(scalar) {
                hanRun.append(scalar)
            } else {
                flushHan()
            }
        }
        flushHan()
        return out
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            true
        default:
            false
        }
    }

    private static let englishStopwords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "that", "this", "will", "would", "should",
        "about", "after", "before", "meeting", "team", "task", "item", "items", "next"
    ]
}

public enum MeetingSummaryPrompt {
    public static func build(entries: [TranscriptEntry], timelineOrigin: Date? = nil) -> String {
        let firstDate = timelineOrigin ?? entries.first?.observedAt ?? Date()
        let transcript = entries.enumerated().map { index, entry -> String in
            let elapsed = max(0, entry.observedAt.timeIntervalSince(firstDate))
            let timestamp = formatElapsed(elapsed)
            let speaker = entry.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? entry.speaker!.trimmingCharacters(in: .whitespacesAndNewlines)
                : "Unknown"
            return "[E\(index + 1)] [\(timestamp)] [\(speaker)] [\(entry.source)] \(entry.text)"
        }.joined(separator: "\n")

        return """
        You are Morrow Scribe, a meticulous meeting fact extractor. Extract grounded meeting atoms from the transcript. Do not optimize for final prose; a deterministic reducer will deduplicate and present the atoms later.

        GROUNDING RULES (non-negotiable):
        - Use only information stated in this transcript. Never add outside knowledge or typical-meeting assumptions.
        - Empty is better than guessed. Do not invent names, decisions, owners, deadlines, dates, numbers, risks, or conclusions.
        - A decision is something actually agreed/decided, not merely discussed, proposed, or considered. If one speaker proposes something and another later accepts it, include BOTH the proposal and acceptance as evidence.
        - An action item is a concrete task or commitment. Set explicitness="explicit" only when the transcript clearly commits someone to it. A suggestion such as “you can”, “could”, “maybe”, or a proposed measurement is NOT an action item unless someone accepts/commits to it.
        - Prefer one complete action item per deliverable. If one speaker makes a compound commitment in one turn (for example task pool + experiment run + failure matrix under the same deadline), keep it together rather than fragmenting it into several overlapping actions. If a later turn adds details to the same deliverable, combine them into the same action when possible.
        - Before returning JSON, scan the transcript once more for explicit first-person commitments such as “我会…”, “我来…”, “I will…”, or “I'll…”. Preserve every materially distinct commitment as an action item even when it has no deadline; do not drop a real commitment merely because it is lower priority than the main deliverable.
        - owner and deadline must be null unless directly supported by evidence for that action. Do not inherit a nearby deadline just because it appears in the same discussion. A deadline may be carried across turns only when an explicit referent clearly applies it to that same action/deliverable.
        - Preserve technical terms and proper nouns when the transcript supports them. Correct obvious caption errors only when context makes the correction unambiguous.
        - Every transcript turn has an immutable evidence ID such as E14. Return evidenceRefs containing 0-3 of those exact IDs. Never copy or rewrite transcript quotes yourself; Morrow Scribe resolves IDs back to exact quotes after generation.
        - Use multiple evidenceRefs whenever a claim combines facts from different turns or needs proposal + confirmation to establish a decision. The cited turns together must directly support the whole claim.
        - Use confidence="low" when captions are ambiguous, speaker attribution is uncertain, or the conclusion requires interpretation.
        - Avoid filler such as “the meeting discussed”, “various topics”, or generic restatements.
        - Write extracted text in the dominant language of the transcript, while preserving technical terms in their natural form.
        - Avoid duplicating the same fact across decisions, actionItems, nextSteps, risks, and sections. TL;DR may intentionally summarize the most important core facts.

        CONTENT RULES:
        - tldr: 2-5 compact candidate takeaways covering the most important outcomes or state changes.
        - decisions: only actual decisions/agreement.
        - actionItems: tasks/commitments, with owner/deadline only when directly supported.
        - nextSteps: future directions or intended follow-ups that are useful but are not assigned action items.
        - openQuestions: only questions that remain unresolved at the END of the transcript. Read later turns before classifying: if a later speaker gives a concrete answer, policy, conditional permission, or decision (for example “可以做 X，但要 Y”), the earlier question is answered and must NOT remain in openQuestions; put any resulting conditional work in nextSteps instead.
        - Explicit research questions that the group says the experiments/paper should ultimately answer ARE openQuestions when the meeting does not answer them, even if they are phrased as “we want to answer…” rather than with a question mark.
        - risks: explicit blockers, risks, concerns, or uncertainties that could materially affect the work. Do not turn every hypothetical downside into a risk.
        - sections: 0-4 topic-specific sections only when they add detail not already captured by core atoms.
        - sourceWarnings: only concrete limitations visible in the transcript, such as missing speaker identity or clearly incomplete captions. Otherwise return [].

        Return ONLY one valid JSON object matching this exact shape. No Markdown fences and no prose outside JSON:
        {
          "schemaVersion": 2,
          "tldr": [
            {"text":"concrete takeaway","evidenceRefs":["E14","E20"],"confidence":"high|medium|low"}
          ],
          "decisions": [],
          "actionItems": [
            {"text":"task","owner":null,"deadline":null,"explicitness":"explicit|inferred","evidenceRefs":[],"confidence":"high|medium|low"}
          ],
          "nextSteps": [],
          "openQuestions": [],
          "risks": [],
          "sections": [
            {"title":"Topic-specific title","bullets":[{"text":"grounded note","evidenceRefs":[],"confidence":"high|medium|low"}]}
          ],
          "sourceWarnings": []
        }

        Transcript:
        ---
        \(transcript)
        ---
        """
    }

    static func evidenceCatalog(
        entries: [TranscriptEntry],
        timelineOrigin: Date
    ) -> [String: SummaryEvidence] {
        Dictionary(uniqueKeysWithValues: entries.enumerated().map { index, entry in
            let timestamp = formatElapsed(max(0, entry.observedAt.timeIntervalSince(timelineOrigin)))
            return (
                "E\(index + 1)",
                SummaryEvidence(speaker: entry.speaker, timestamp: timestamp, quote: entry.text)
            )
        })
    }

    static func formatElapsed(_ interval: TimeInterval) -> String {
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
