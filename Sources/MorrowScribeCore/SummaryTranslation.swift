import Foundation

public enum SummaryTranslationError: Error, CustomStringConvertible {
    case invalidResponse(String)

    public var description: String {
        switch self {
        case let .invalidResponse(reason):
            return "LLM returned an invalid summary translation: \(reason)"
        }
    }
}

public enum SummaryTranslator {
    private struct TranslationField: Codable, Hashable {
        let id: String
        let text: String
    }

    private struct TranslationResponse: Decodable {
        let translations: [String: String]
    }

    public static func translateToSimplifiedChinese(
        _ summary: MeetingSummary,
        configuration: SummaryConfiguration? = nil
    ) async throws -> MeetingSummary {
        let fields = translationFields(from: summary)
        guard !fields.isEmpty else { return summary }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = String(decoding: try encoder.encode(fields), as: UTF8.self)
        let prompt = """
        You are Morrow Scribe's translation engine.

        Translate every `text` value in INPUT into concise, natural Simplified Chinese.

        STRICT RULES:
        - Translate only the supplied text. Do not add, remove, merge, split, reinterpret, or summarize facts.
        - Preserve every field ID exactly and return exactly one translation for every input ID.
        - Preserve personal names, product names, repository names, code identifiers, commands, filenames, paths, URLs, acronyms, and technical terms when translating them would reduce precision.
        - Preserve numbers, dates, quantities, negation, modality, uncertainty, and commitment strength exactly.
        - Do not translate evidence quotes or speakers; they are intentionally absent from INPUT.
        - Use Simplified Chinese, not Traditional Chinese.
        - Return ONLY one valid JSON object with this shape and no Markdown fences or prose:
          {"translations":{"T1":"中文翻译","D1":"中文翻译"}}

        INPUT:
        \(payload)
        """

        let output = try await SummaryClient.complete(
            prompt: prompt,
            configuration: configuration ?? SummaryConfigurationStore.load(),
            structuredOutput: false
        )
        let response = try decodeResponse(output)
        return try applying(response.translations, to: summary)
    }

    static func applying(
        _ translations: [String: String],
        to summary: MeetingSummary
    ) throws -> MeetingSummary {
        let fields = translationFields(from: summary)
        let expected = Set(fields.map(\.id))
        let returned = Set(translations.keys)
        guard expected == returned else {
            let missing = expected.subtracting(returned).sorted()
            let extra = returned.subtracting(expected).sorted()
            throw SummaryTranslationError.invalidResponse(
                "translation IDs did not match input (missing: \(missing.joined(separator: ", ")); extra: \(extra.joined(separator: ", ")))"
            )
        }

        func value(_ id: String) throws -> String {
            guard let raw = translations[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                throw SummaryTranslationError.invalidResponse("translation for \(id) was empty")
            }
            return raw
        }

        func point(_ source: SummaryPoint, id: String) throws -> SummaryPoint {
            SummaryPoint(
                text: try value(id),
                evidence: source.evidence,
                confidence: source.confidence
            )
        }

        let tldr = try summary.tldr.enumerated().map { try point($0.element, id: "T\($0.offset + 1)") }
        let decisions = try summary.decisions.enumerated().map { try point($0.element, id: "D\($0.offset + 1)") }
        let actionItems = try summary.actionItems.enumerated().map { index, item in
            let number = index + 1
            return SummaryActionItem(
                text: try value("A\(number)"),
                owner: item.owner,
                deadline: item.deadline == nil ? nil : try value("AD\(number)"),
                explicitness: item.explicitness,
                evidence: item.evidence,
                confidence: item.confidence
            )
        }
        let nextSteps = try summary.nextSteps.enumerated().map { try point($0.element, id: "N\($0.offset + 1)") }
        let openQuestions = try summary.openQuestions.enumerated().map { try point($0.element, id: "Q\($0.offset + 1)") }
        let risks = try summary.risks.enumerated().map { try point($0.element, id: "R\($0.offset + 1)") }
        let sections = try summary.sections.enumerated().map { sectionIndex, section in
            let sectionNumber = sectionIndex + 1
            return SummarySection(
                title: try value("S\(sectionNumber)T"),
                bullets: try section.bullets.enumerated().map { bulletIndex, bullet in
                    try point(bullet, id: "S\(sectionNumber)B\(bulletIndex + 1)")
                }
            )
        }
        let sourceWarnings = try summary.sourceWarnings.enumerated().map { try value("W\($0.offset + 1)") }

        return MeetingSummary(
            schemaVersion: summary.schemaVersion,
            tldr: tldr,
            decisions: decisions,
            actionItems: actionItems,
            nextSteps: nextSteps,
            openQuestions: openQuestions,
            risks: risks,
            sections: sections,
            sourceWarnings: sourceWarnings
        )
    }

    private static func translationFields(from summary: MeetingSummary) -> [TranslationField] {
        var fields: [TranslationField] = []
        for (index, point) in summary.tldr.enumerated() {
            fields.append(TranslationField(id: "T\(index + 1)", text: point.text))
        }
        for (index, point) in summary.decisions.enumerated() {
            fields.append(TranslationField(id: "D\(index + 1)", text: point.text))
        }
        for (index, item) in summary.actionItems.enumerated() {
            let number = index + 1
            fields.append(TranslationField(id: "A\(number)", text: item.text))
            if let deadline = item.deadline {
                fields.append(TranslationField(id: "AD\(number)", text: deadline))
            }
        }
        for (index, point) in summary.nextSteps.enumerated() {
            fields.append(TranslationField(id: "N\(index + 1)", text: point.text))
        }
        for (index, point) in summary.openQuestions.enumerated() {
            fields.append(TranslationField(id: "Q\(index + 1)", text: point.text))
        }
        for (index, point) in summary.risks.enumerated() {
            fields.append(TranslationField(id: "R\(index + 1)", text: point.text))
        }
        for (sectionIndex, section) in summary.sections.enumerated() {
            let sectionNumber = sectionIndex + 1
            fields.append(TranslationField(id: "S\(sectionNumber)T", text: section.title))
            for (bulletIndex, bullet) in section.bullets.enumerated() {
                fields.append(TranslationField(id: "S\(sectionNumber)B\(bulletIndex + 1)", text: bullet.text))
            }
        }
        for (index, warning) in summary.sourceWarnings.enumerated() {
            fields.append(TranslationField(id: "W\(index + 1)", text: warning))
        }
        return fields
    }

    private static func decodeResponse(_ output: String) throws -> TranslationResponse {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"),
              let last = trimmed.lastIndex(of: "}"),
              first <= last else {
            throw SummaryTranslationError.invalidResponse("response did not contain a JSON object")
        }
        do {
            return try JSONDecoder().decode(
                TranslationResponse.self,
                from: Data(trimmed[first...last].utf8)
            )
        } catch {
            throw SummaryTranslationError.invalidResponse(String(describing: error))
        }
    }
}
