import Foundation
import Security

public enum SummaryError: Error, CustomStringConvertible {
    case missingConfiguration
    case invalidResponse
    case invalidStructuredResponse(String)
    case http(Int, String)
    case codexUnavailable
    case codexFailed(Int32, String)
    case codexTimedOut

    public var description: String {
        switch self {
        case .missingConfiguration:
            return "configure Codex CLI or an OpenAI-compatible summary provider in Morrow Scribe"
        case .invalidResponse:
            return "invalid OpenAI-compatible chat-completions response"
        case let .invalidStructuredResponse(reason):
            return "LLM returned an invalid structured meeting summary: \(reason)"
        case let .http(code, body):
            return "LLM endpoint returned HTTP \(code): \(body.prefix(300))"
        case .codexUnavailable:
            return "Codex CLI was not found. Install Codex or set its executable path in Summary Settings."
        case let .codexFailed(code, output):
            return "Codex CLI exited with status \(code): \(output.prefix(500))"
        case .codexTimedOut:
            return "Codex CLI summary timed out"
        }
    }
}

public enum SummaryProvider: String, CaseIterable, Hashable, Sendable {
    case openAICompatible = "openai-compatible"
    case codexCLI = "codex-cli"

    public var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible API"
        case .codexCLI: return "Codex CLI"
        }
    }
}

public enum SummaryDefaults {
    public static let provider: SummaryProvider = .codexCLI
    public static let codexModel = "gpt-5.6-luna"
    public static let codexReasoningEffort = "xhigh"
}

public struct SummaryConfiguration: Hashable, Sendable {
    public var provider: SummaryProvider
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var codexPath: String
    public var codexModel: String
    public var codexReasoningEffort: String

    public init(
        provider: SummaryProvider = SummaryDefaults.provider,
        baseURL: String = "",
        model: String = "",
        apiKey: String = "",
        codexPath: String = "",
        codexModel: String = SummaryDefaults.codexModel,
        codexReasoningEffort: String = SummaryDefaults.codexReasoningEffort
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.codexPath = codexPath
        self.codexModel = codexModel
        self.codexReasoningEffort = codexReasoningEffort
    }

    public var isConfigured: Bool {
        switch provider {
        case .openAICompatible:
            return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .codexCLI:
            return CodexCLI.resolveExecutable(configuredPath: codexPath) != nil
        }
    }
}

public enum SummaryConfigurationStore {
    private static let defaultsProviderKey = "llm.provider"
    private static let defaultsBaseURLKey = "llm.baseURL"
    private static let defaultsModelKey = "llm.model"
    private static let defaultsCodexPathKey = "llm.codexPath"
    private static let defaultsCodexModelKey = "llm.codexModel"
    private static let defaultsCodexReasoningEffortKey = "llm.codexReasoningEffort"
    private static let keychainService = "com.morrow.scribe.llm"
    private static let keychainAccount = "api-key"

    public static func load() -> SummaryConfiguration {
        let defaults = UserDefaults.standard
        let storedProviderRaw = defaults.string(forKey: defaultsProviderKey)
        let storedProvider = storedProviderRaw.flatMap(SummaryProvider.init(rawValue:)) ?? .openAICompatible
        let storedBase = defaults.string(forKey: defaultsBaseURLKey) ?? ""
        let storedModel = defaults.string(forKey: defaultsModelKey) ?? ""
        let storedKey = loadAPIKey() ?? ""
        let storedCodexPath = defaults.string(forKey: defaultsCodexPathKey) ?? ""
        let storedCodexModel = normalizedCodexModel(defaults.string(forKey: defaultsCodexModelKey))
        let storedCodexReasoningEffort = normalizedCodexReasoningEffort(
            defaults.string(forKey: defaultsCodexReasoningEffortKey)
        )
        let stored = SummaryConfiguration(
            provider: storedProvider,
            baseURL: storedBase,
            model: storedModel,
            apiKey: storedKey,
            codexPath: storedCodexPath,
            codexModel: storedCodexModel,
            codexReasoningEffort: storedCodexReasoningEffort
        )
        if storedProviderRaw != nil { return stored }
        if stored.isConfigured { return stored }
        return environmentConfiguration()
    }

    public static func save(_ configuration: SummaryConfiguration) throws {
        let defaults = UserDefaults.standard
        defaults.set(configuration.provider.rawValue, forKey: defaultsProviderKey)
        defaults.set(configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsBaseURLKey)
        defaults.set(configuration.model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsModelKey)
        defaults.set(configuration.codexPath.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsCodexPathKey)
        defaults.set(configuration.codexModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsCodexModelKey)
        defaults.set(configuration.codexReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsCodexReasoningEffortKey)
        try saveAPIKey(configuration.apiKey)
    }

    public static func environmentConfiguration() -> SummaryConfiguration {
        let env = ProcessInfo.processInfo.environment
        let provider: SummaryProvider
        switch (env["MORROW_SCRIBE_SUMMARY_PROVIDER"] ?? "").lowercased() {
        case "openai", "openai-compatible":
            provider = .openAICompatible
        case "codex", "codex-cli":
            provider = .codexCLI
        default:
            let hasExplicitAPI = !(env["MORROW_SCRIBE_LLM_BASE_URL"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !(env["MORROW_SCRIBE_LLM_MODEL"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            provider = hasExplicitAPI ? .openAICompatible : SummaryDefaults.provider
        }
        return SummaryConfiguration(
            provider: provider,
            baseURL: env["MORROW_SCRIBE_LLM_BASE_URL"] ?? "",
            model: env["MORROW_SCRIBE_LLM_MODEL"] ?? "",
            apiKey: env["MORROW_SCRIBE_LLM_API_KEY"] ?? "",
            codexPath: env["MORROW_SCRIBE_CODEX_PATH"] ?? "",
            codexModel: normalizedCodexModel(env["MORROW_SCRIBE_CODEX_MODEL"]),
            codexReasoningEffort: normalizedCodexReasoningEffort(
                env["MORROW_SCRIBE_CODEX_REASONING_EFFORT"]
            )
        )
    }

    private static func normalizedCodexModel(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? SummaryDefaults.codexModel : trimmed
    }

    private static func normalizedCodexReasoningEffort(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? SummaryDefaults.codexReasoningEffort : trimmed
    }

    private static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveAPIKey(_ apiKey: String) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: Data(trimmed.utf8),
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not save LLM API key in Keychain (OSStatus \(status))"]
            )
        }
    }
}

public enum SummaryClient {
    static let maxTranscriptCharactersPerRequest = 24_000

    public static var isConfigured: Bool {
        SummaryConfigurationStore.load().isConfigured
    }

    public static func test(configuration: SummaryConfiguration) async throws {
        let marker = "MORROW_SCRIBE_OK"
        let output = try await complete(
            prompt: "Connection test. Reply with exactly \(marker) and nothing else.",
            configuration: configuration,
            structuredOutput: false
        )
        guard output.contains(marker) else {
            throw SummaryError.invalidResponse
        }
    }

    public static func summarize(
        entries: [TranscriptEntry],
        configuration: SummaryConfiguration? = nil
    ) async throws -> MeetingSummary {
        let config = configuration ?? SummaryConfigurationStore.load()
        guard let timelineOrigin = entries.first?.observedAt else {
            throw SummaryError.invalidStructuredResponse("meeting has no transcript entries")
        }

        let chunks = transcriptChunks(entries: entries)
        var partials: [MeetingSummary] = []
        partials.reserveCapacity(chunks.count)
        for chunk in chunks {
            try Task.checkCancellation()
            let basePrompt = MeetingSummaryPrompt.build(entries: chunk, timelineOrigin: timelineOrigin)
            var output = try await complete(
                prompt: basePrompt,
                configuration: config,
                structuredOutput: true
            )
            var partial = try MeetingSummary.decodeModelOutput(
                output,
                entries: chunk,
                timelineOrigin: timelineOrigin
            )
                .grounded(against: chunk, timelineOrigin: timelineOrigin)

            // Invalid evidence IDs are usually a transcription-reference typo, not a factual
            // extraction failure. Retry exactly once with the previous atoms visible so the
            // model can repair IDs without silently dropping content to avoid citation work.
            if partial.hasInvalidEvidenceReferences {
                try Task.checkCancellation()
                output = try await complete(
                    prompt: MeetingSummaryPrompt.repairEvidenceReferences(
                        basePrompt: basePrompt,
                        previousOutput: output,
                        validEvidenceCount: chunk.count
                    ),
                    configuration: config,
                    structuredOutput: true
                )
                partial = try MeetingSummary.decodeModelOutput(
                    output,
                    entries: chunk,
                    timelineOrigin: timelineOrigin
                )
                    .grounded(against: chunk, timelineOrigin: timelineOrigin)
            }
            if !partial.isEmpty { partials.append(partial) }
        }

        guard !partials.isEmpty else {
            throw SummaryError.invalidStructuredResponse("summary contained no useful content")
        }

        // Chunk extraction is the only LLM pass allowed to create factual atoms. Cross-chunk
        // consolidation is deterministic so a second model pass cannot promote a proposal to
        // a decision, invent an owner/deadline, or discard evidence while re-summarizing.
        let reduced = MeetingSummaryReducer.reduce(partials)
        let grounded = reduced.grounded(against: entries, timelineOrigin: timelineOrigin)
        guard !grounded.isEmpty else {
            throw SummaryError.invalidStructuredResponse("summary contained no useful content")
        }

        // A single extraction already saw the complete transcript and can write a coherent
        // TL;DR directly. Reserve the extra polish call for true multi-chunk meetings, where
        // the deterministic reducer intentionally does not synthesize new prose.
        try Task.checkCancellation()
        guard partials.count > 1 else { return grounded }

        // Readability polish is deliberately narrow and non-critical. It can rewrite only
        // the TL;DR, must cite immutable source atom IDs, passes a no-new-fact-token gate, and
        // falls back to the deterministic summary on any provider/validation failure.
        do {
            return try await polishTLDR(grounded, configuration: config)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return grounded
        }
    }

    public static func summarize(prompt: String) async throws -> String {
        try await complete(prompt: prompt, configuration: SummaryConfigurationStore.load(), structuredOutput: false)
    }

    public static func complete(
        prompt: String,
        configuration: SummaryConfiguration,
        structuredOutput: Bool = false
    ) async throws -> String {
        guard configuration.isConfigured else { throw SummaryError.missingConfiguration }

        switch configuration.provider {
        case .codexCLI:
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try CodexCLI.complete(
                    prompt: prompt,
                    configuration: configuration,
                    structuredOutput: structuredOutput
                )
            }
            return try await withTaskCancellationHandler(
                operation: { try await task.value },
                onCancel: { task.cancel() }
            )
        case .openAICompatible:
            return try await completeOpenAICompatible(prompt: prompt, configuration: configuration)
        }
    }

    private static func completeOpenAICompatible(
        prompt: String,
        configuration: SummaryConfiguration
    ) async throws -> String {

        let base = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint: String
        if base.hasSuffix("/chat/completions") {
            endpoint = base
        } else if base.hasSuffix("/") {
            endpoint = "\(base)chat/completions"
        } else {
            endpoint = "\(base)/chat/completions"
        }
        guard let url = URL(string: endpoint) else { throw SummaryError.missingConfiguration }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt],
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SummaryError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SummaryError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SummaryError.invalidResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func transcriptChunks(
        entries: [TranscriptEntry],
        maxCharacters: Int = maxTranscriptCharactersPerRequest
    ) -> [[TranscriptEntry]] {
        guard !entries.isEmpty else { return [] }
        let limit = max(1, maxCharacters)
        var result: [[TranscriptEntry]] = []
        var current: [TranscriptEntry] = []
        var currentCharacters = 0

        for entry in entries {
            let estimatedCharacters = entry.text.count + (entry.speaker?.count ?? 7) + entry.source.count + 32
            if !current.isEmpty, currentCharacters + estimatedCharacters > limit {
                result.append(current)
                current = []
                currentCharacters = 0
            }
            current.append(entry)
            currentCharacters += estimatedCharacters
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private struct PolishFact: Codable {
        let id: String
        let text: String
    }

    private struct PolishLine: Codable {
        let text: String
        let sourceIDs: [String]
    }

    private struct PolishResponse: Codable {
        let summary: [PolishLine]
    }

    private struct GroundedPolishSource {
        let fact: PolishFact
        let evidence: [SummaryEvidence]
        let confidence: SummaryConfidence
    }

    private static func polishTLDR(
        _ summary: MeetingSummary,
        configuration: SummaryConfiguration
    ) async throws -> MeetingSummary {
        let sources = polishSources(summary)
        guard sources.count >= 2 else { return summary }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sourcePayload = String(
            decoding: try encoder.encode(sources.map(\.fact)),
            as: UTF8.self
        )
        let prompt = """
        You are Morrow Scribe's final summary polisher. The FACTS below are immutable, already grounded meeting atoms.

        Rewrite them into 3-5 short, clear summary sentences in the same dominant language as the facts.
        Lead with the meeting's scope/outcome, then the most important decisions, then the most important committed next step.

        STRICT RULES:
        - Use ONLY information present in FACTS. Introduce no new fact, name, number, date, deadline, owner, system, or conclusion.
        - Every sentence must cite 1-3 sourceIDs whose facts fully support that sentence.
        - A sentence may combine facts only when all needed sourceIDs are listed.
        - Do not change the status of a proposal, decision, question, risk, or commitment.
        - Do not infer deadlines or owners.
        - No filler, headings, Markdown, or chronology narration.
        - Prefer fewer sentences when they cover the important outcome cleanly.

        Return ONLY JSON in this shape:
        {"summary":[{"text":"sentence","sourceIDs":["D1","A1"]}]}

        FACTS:
        \(sourcePayload)
        """

        let output = try await complete(
            prompt: prompt,
            configuration: configuration,
            structuredOutput: false
        )
        let object = try extractJSONObject(output)
        let response = try JSONDecoder().decode(PolishResponse.self, from: Data(object.utf8))
        guard (2...5).contains(response.summary.count) else { return summary }

        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.fact.id, $0) })
        let corpus = sources.map(\.fact.text).joined(separator: "\n")
        var polished: [SummaryPoint] = []
        for line in response.summary {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = Array(line.sourceIDs.prefix(3))
            guard !text.isEmpty, !ids.isEmpty, ids.allSatisfy({ byID[$0] != nil }) else { return summary }
            guard !hasUnsupportedPolishFacts(text, groundedCorpus: corpus) else { return summary }

            let cited = ids.compactMap { byID[$0] }
            let evidence = dedupeEvidence(cited.flatMap(\.evidence))
            let confidence = cited.map(\.confidence).min(by: { $0.rank < $1.rank }) ?? .medium
            polished.append(SummaryPoint(text: text, evidence: evidence, confidence: confidence))
        }

        return MeetingSummary(
            schemaVersion: 2,
            tldr: MeetingSummaryReducer.reduce([MeetingSummary(tldr: polished)]).tldr,
            decisions: summary.decisions,
            actionItems: summary.actionItems,
            nextSteps: summary.nextSteps,
            openQuestions: summary.openQuestions,
            risks: summary.risks,
            sections: summary.sections,
            sourceWarnings: summary.sourceWarnings
        )
    }

    private static func polishSources(_ summary: MeetingSummary) -> [GroundedPolishSource] {
        var out: [GroundedPolishSource] = []
        func append(prefix: String, point: SummaryPoint, index: Int) {
            out.append(GroundedPolishSource(
                fact: PolishFact(id: "\(prefix)\(index + 1)", text: point.text),
                evidence: point.evidence,
                confidence: point.confidence
            ))
        }

        for (index, point) in summary.tldr.enumerated() { append(prefix: "T", point: point, index: index) }
        for (index, point) in summary.decisions.enumerated() { append(prefix: "D", point: point, index: index) }
        for (index, item) in summary.actionItems.enumerated() {
            var text = item.text
            if let owner = item.owner { text += " | Owner: \(owner)" }
            if let deadline = item.deadline { text += " | Deadline: \(deadline)" }
            out.append(GroundedPolishSource(
                fact: PolishFact(id: "A\(index + 1)", text: text),
                evidence: item.evidence,
                confidence: item.confidence
            ))
        }
        for (index, point) in summary.openQuestions.enumerated() { append(prefix: "Q", point: point, index: index) }
        for (index, point) in summary.risks.prefix(3).enumerated() { append(prefix: "R", point: point, index: index) }
        return out
    }

    private static func dedupeEvidence(_ evidence: [SummaryEvidence]) -> [SummaryEvidence] {
        var seen = Set<SummaryEvidence>()
        return evidence.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(4).map { $0 }
    }

    static func hasUnsupportedPolishFacts(_ polished: String, groundedCorpus: String) -> Bool {
        let sourceTokens = factShapedTokens(groundedCorpus)
        return !factShapedTokens(polished).isSubset(of: sourceTokens)
    }

    private static func factShapedTokens(_ text: String) -> Set<String> {
        var tokens = Set<String>()
        let lower = text.lowercased()
        let latinParts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let allowedGeneric: Set<String> = [
            "the", "and", "for", "with", "from", "into", "only", "use", "using", "will", "while",
            "first", "phase", "meeting", "team", "summary", "key", "next", "step", "steps", "baseline"
        ]
        for part in latinParts where part.count >= 2 && !allowedGeneric.contains(part) {
            // ASCII technical terms, names and numeric expressions are fact-shaped here.
            if part.unicodeScalars.allSatisfy({ $0.value < 128 }) {
                tokens.insert(canonicalFactToken(part))
            }
        }

        let calendarTerms = [
            "今天", "明天", "后天", "本周", "下周", "月底", "年底",
            "周一", "周二", "周三", "周四", "周五", "周六", "周日", "周天",
            "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日", "星期天"
        ]
        for term in calendarTerms where text.contains(term) { tokens.insert(term) }

        let chineseNumerals = Set("零〇一二三四五六七八九十百千万亿两")
        var numeralRun = ""
        func flushNumerals() {
            if !numeralRun.isEmpty { tokens.insert("cn:\(numeralRun)") }
            numeralRun.removeAll(keepingCapacity: true)
        }
        for character in text {
            if chineseNumerals.contains(character) {
                numeralRun.append(character)
            } else {
                flushNumerals()
            }
        }
        flushNumerals()
        return tokens
    }

    private static func canonicalFactToken(_ token: String) -> String {
        if token.count > 4, token.hasSuffix("ies") {
            return String(token.dropLast(3)) + "y"
        }
        if token.count > 4, token.hasSuffix("s"), !token.hasSuffix("ss") {
            return String(token.dropLast())
        }
        return token
    }

    private static func extractJSONObject(_ output: String) throws -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last else {
            throw SummaryError.invalidStructuredResponse("polish response did not contain a JSON object")
        }
        return String(trimmed[first...last])
    }
}
