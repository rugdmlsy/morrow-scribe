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

public struct SummaryConfiguration: Hashable, Sendable {
    public var provider: SummaryProvider
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var codexPath: String
    public var codexModel: String

    public init(
        provider: SummaryProvider = .openAICompatible,
        baseURL: String = "",
        model: String = "",
        apiKey: String = "",
        codexPath: String = "",
        codexModel: String = ""
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.codexPath = codexPath
        self.codexModel = codexModel
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
        let storedCodexModel = defaults.string(forKey: defaultsCodexModelKey) ?? ""
        let stored = SummaryConfiguration(
            provider: storedProvider,
            baseURL: storedBase,
            model: storedModel,
            apiKey: storedKey,
            codexPath: storedCodexPath,
            codexModel: storedCodexModel
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
        try saveAPIKey(configuration.apiKey)
    }

    public static func environmentConfiguration() -> SummaryConfiguration {
        let env = ProcessInfo.processInfo.environment
        let provider: SummaryProvider
        switch (env["MORROW_SCRIBE_SUMMARY_PROVIDER"] ?? "").lowercased() {
        case "codex", "codex-cli": provider = .codexCLI
        default: provider = .openAICompatible
        }
        return SummaryConfiguration(
            provider: provider,
            baseURL: env["MORROW_SCRIBE_LLM_BASE_URL"] ?? "",
            model: env["MORROW_SCRIBE_LLM_MODEL"] ?? "",
            apiKey: env["MORROW_SCRIBE_LLM_API_KEY"] ?? "",
            codexPath: env["MORROW_SCRIBE_CODEX_PATH"] ?? "",
            codexModel: env["MORROW_SCRIBE_CODEX_MODEL"] ?? ""
        )
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
    static let maxSummariesPerMergeRequest = 6

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
            let output = try await complete(
                prompt: MeetingSummaryPrompt.build(entries: chunk, timelineOrigin: timelineOrigin),
                configuration: config,
                structuredOutput: true
            )
            let partial = try MeetingSummary.decodeModelOutput(output)
                .grounded(against: chunk, timelineOrigin: timelineOrigin)
            if !partial.isEmpty { partials.append(partial) }
        }

        guard !partials.isEmpty else {
            throw SummaryError.invalidStructuredResponse("summary contained no useful content")
        }

        let summary: MeetingSummary
        if partials.count == 1 {
            summary = partials[0]
        } else {
            summary = try await merge(
                summaries: partials,
                entries: entries,
                timelineOrigin: timelineOrigin,
                configuration: config
            )
        }
        let grounded = summary.grounded(against: entries, timelineOrigin: timelineOrigin)
        guard !grounded.isEmpty else {
            throw SummaryError.invalidStructuredResponse("summary contained no useful content")
        }
        return grounded
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
            return try await Task.detached(priority: .userInitiated) {
                try CodexCLI.complete(
                    prompt: prompt,
                    configuration: configuration,
                    structuredOutput: structuredOutput
                )
            }.value
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

    private static func merge(
        summaries: [MeetingSummary],
        entries: [TranscriptEntry],
        timelineOrigin: Date,
        configuration: SummaryConfiguration
    ) async throws -> MeetingSummary {
        var current = summaries
        while current.count > 1 {
            var mergedRound: [MeetingSummary] = []
            var index = 0
            while index < current.count {
                let end = min(index + maxSummariesPerMergeRequest, current.count)
                let batch = Array(current[index..<end])
                if batch.count == 1 {
                    mergedRound.append(batch[0])
                } else {
                    let output = try await complete(
                        prompt: try mergePrompt(summaries: batch),
                        configuration: configuration,
                        structuredOutput: true
                    )
                    let merged = try MeetingSummary.decodeModelOutput(output)
                        .grounded(against: entries, timelineOrigin: timelineOrigin)
                    guard !merged.isEmpty else {
                        throw SummaryError.invalidStructuredResponse("merge pass returned no useful content")
                    }
                    mergedRound.append(merged)
                }
                index = end
            }
            current = mergedRound
        }
        return current[0]
    }

    private static func mergePrompt(summaries: [MeetingSummary]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloads = try summaries.map { summary in
            String(decoding: try encoder.encode(summary), as: UTF8.self)
        }
        return """
        You are Morrow Scribe. Merge the partial meeting summaries below into one compact final summary.

        These partial summaries were generated from disjoint chunks of the same transcript. Treat them as your only source material.

        MERGE RULES (non-negotiable):
        - Do not add facts, names, owners, deadlines, decisions, risks, or conclusions that are absent from the partial summaries.
        - Deduplicate repeated or overlapping points while preserving distinct information.
        - A decision must remain a real decision; do not promote discussion, proposals, or next steps into decisions.
        - Preserve action-item owner/deadline only when already present in a partial summary.
        - Preserve evidence quotes verbatim. Never rewrite or invent an evidence quote, speaker, or timestamp.
        - Prefer 2-5 high-value TL;DR bullets for the whole meeting rather than one bullet per chunk.
        - Keep useful topic-specific sections, but merge redundant sections and omit empty sections.
        - Keep sourceWarnings that still matter; deduplicate equivalent warnings.
        - Write in the same dominant language as the partial summaries.

        Return ONLY one valid JSON object matching this shape and no Markdown fences:
        {
          "schemaVersion": 1,
          "tldr": [{"text":"takeaway","evidence":{"speaker":"name or null","timestamp":"MM:SS","quote":"verbatim quote or null"},"confidence":"high|medium|low"}],
          "decisions": [{"text":"decision","evidence":null,"confidence":"high|medium|low"}],
          "actionItems": [{"text":"task","owner":null,"deadline":null,"explicitness":"explicit|inferred","evidence":null,"confidence":"high|medium|low"}],
          "nextSteps": [{"text":"next step","evidence":null,"confidence":"high|medium|low"}],
          "openQuestions": [{"text":"question","evidence":null,"confidence":"high|medium|low"}],
          "risks": [{"text":"risk or blocker","evidence":null,"confidence":"high|medium|low"}],
          "sections": [{"title":"Topic-specific title","bullets":[{"text":"note","evidence":null,"confidence":"high|medium|low"}]}],
          "sourceWarnings": []
        }

        Partial summaries:
        ---
        \(payloads.joined(separator: "\n"))
        ---
        """
    }
}
