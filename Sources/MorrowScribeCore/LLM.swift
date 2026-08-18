import Foundation
import Security

public enum SummaryError: Error, CustomStringConvertible {
    case missingConfiguration
    case invalidResponse
    case invalidStructuredResponse(String)
    case http(Int, String)

    public var description: String {
        switch self {
        case .missingConfiguration:
            return "configure an OpenAI-compatible LLM endpoint and model in Morrow Scribe"
        case .invalidResponse:
            return "invalid OpenAI-compatible chat-completions response"
        case let .invalidStructuredResponse(reason):
            return "LLM returned an invalid structured meeting summary: \(reason)"
        case let .http(code, body):
            return "LLM endpoint returned HTTP \(code): \(body.prefix(300))"
        }
    }
}

public struct SummaryConfiguration: Hashable, Sendable {
    public var baseURL: String
    public var model: String
    public var apiKey: String

    public init(baseURL: String = "", model: String = "", apiKey: String = "") {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum SummaryConfigurationStore {
    private static let defaultsBaseURLKey = "llm.baseURL"
    private static let defaultsModelKey = "llm.model"
    private static let keychainService = "com.morrow.scribe.llm"
    private static let keychainAccount = "api-key"

    public static func load() -> SummaryConfiguration {
        let defaults = UserDefaults.standard
        let storedBase = defaults.string(forKey: defaultsBaseURLKey) ?? ""
        let storedModel = defaults.string(forKey: defaultsModelKey) ?? ""
        let storedKey = loadAPIKey() ?? ""
        let stored = SummaryConfiguration(baseURL: storedBase, model: storedModel, apiKey: storedKey)
        if stored.isConfigured { return stored }
        return environmentConfiguration()
    }

    public static func save(_ configuration: SummaryConfiguration) throws {
        let defaults = UserDefaults.standard
        defaults.set(configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsBaseURLKey)
        defaults.set(configuration.model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsModelKey)
        try saveAPIKey(configuration.apiKey)
    }

    public static func environmentConfiguration() -> SummaryConfiguration {
        let env = ProcessInfo.processInfo.environment
        return SummaryConfiguration(
            baseURL: env["MORROW_SCRIBE_LLM_BASE_URL"] ?? "",
            model: env["MORROW_SCRIBE_LLM_MODEL"] ?? "",
            apiKey: env["MORROW_SCRIBE_LLM_API_KEY"] ?? ""
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
    public static var isConfigured: Bool {
        SummaryConfigurationStore.load().isConfigured
    }

    public static func summarize(
        entries: [TranscriptEntry],
        configuration: SummaryConfiguration? = nil
    ) async throws -> MeetingSummary {
        let config = configuration ?? SummaryConfigurationStore.load()
        let output = try await complete(prompt: MeetingSummaryPrompt.build(entries: entries), configuration: config)
        let summary = try MeetingSummary.decodeModelOutput(output)
        guard !summary.isEmpty else {
            throw SummaryError.invalidStructuredResponse("summary contained no useful content")
        }
        return summary
    }

    public static func summarize(prompt: String) async throws -> String {
        try await complete(prompt: prompt, configuration: SummaryConfigurationStore.load())
    }

    public static func complete(prompt: String, configuration: SummaryConfiguration) async throws -> String {
        guard configuration.isConfigured else { throw SummaryError.missingConfiguration }

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
            "temperature": 0.1,
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
}
