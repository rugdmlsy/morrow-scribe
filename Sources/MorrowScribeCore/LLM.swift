import Foundation

public enum SummaryError: Error, CustomStringConvertible {
    case missingConfiguration
    case invalidResponse
    case http(Int, String)

    public var description: String {
        switch self {
        case .missingConfiguration:
            return "set MORROW_SCRIBE_LLM_BASE_URL and MORROW_SCRIBE_LLM_MODEL (plus MORROW_SCRIBE_LLM_API_KEY when required)"
        case .invalidResponse:
            return "invalid OpenAI-compatible chat-completions response"
        case let .http(code, body):
            return "LLM endpoint returned HTTP \(code): \(body.prefix(300))"
        }
    }
}

public enum SummaryClient {
    public static func summarize(prompt: String) async throws -> String {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["MORROW_SCRIBE_LLM_BASE_URL"],
              let model = env["MORROW_SCRIBE_LLM_MODEL"],
              !base.isEmpty, !model.isEmpty else {
            throw SummaryError.missingConfiguration
        }

        let endpoint = base.hasSuffix("/") ? "\(base)chat/completions" : "\(base)/chat/completions"
        guard let url = URL(string: endpoint) else { throw SummaryError.missingConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = env["MORROW_SCRIBE_LLM_API_KEY"], !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.2,
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
        return content
    }
}
