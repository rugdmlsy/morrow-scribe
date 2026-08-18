import Foundation

public enum CodexCLI {
    private static let timeout: TimeInterval = 180

    public static func resolveExecutable(configuredPath: String = "") -> String? {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var candidates: [String] = []
        if !trimmed.isEmpty {
            if trimmed.contains("/") {
                candidates.append((trimmed as NSString).expandingTildeInPath)
            } else {
                candidates.append(contentsOf: executableCandidates(named: trimmed))
            }
        }
        if let environmentPath = environment["MORROW_SCRIBE_CODEX_PATH"], !environmentPath.isEmpty {
            candidates.append((environmentPath as NSString).expandingTildeInPath)
        }
        candidates.append(contentsOf: [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ])
        candidates.append(contentsOf: executableCandidates(named: "codex"))

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public static func complete(
        prompt: String,
        configuration: SummaryConfiguration,
        structuredOutput: Bool
    ) throws -> String {
        guard let executable = resolveExecutable(configuredPath: configuration.codexPath) else {
            throw SummaryError.codexUnavailable
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("morrow-scribe-codex-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("last-message.txt")
        let stdoutURL = directory.appendingPathComponent("stdout.txt")
        let stderrURL = directory.appendingPathComponent("stderr.txt")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        var arguments = [
            "-a", "never",
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--ignore-user-config",
            "--ignore-rules",
            "-C", directory.path,
        ]

        let model = configuration.codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }

        if structuredOutput {
            let schemaURL = directory.appendingPathComponent("meeting-summary.schema.json")
            try Self.summarySchema.write(to: schemaURL, atomically: true, encoding: .utf8)
            arguments.append(contentsOf: ["--output-schema", schemaURL.path])
        }

        arguments.append(contentsOf: ["--output-last-message", outputURL.path, "-"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdin = Pipe()
        process.standardInput = stdin
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdout
        process.standardError = stderr
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        do {
            try process.run()
        } catch {
            throw SummaryError.codexFailed(-1, String(describing: error))
        }

        let promptData = Data((prompt + "\n").utf8)
        try stdin.fileHandleForWriting.write(contentsOf: promptData)
        try stdin.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.25)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw SummaryError.codexTimedOut
        }

        try? stdout.synchronize()
        try? stderr.synchronize()
        if process.terminationStatus != 0 {
            let diagnostic = (try? String(contentsOf: stderrURL, encoding: .utf8)) ??
                (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
            throw SummaryError.codexFailed(process.terminationStatus, diagnostic)
        }

        guard fileManager.fileExists(atPath: outputURL.path) else {
            let diagnostic = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            throw SummaryError.codexFailed(process.terminationStatus, diagnostic.isEmpty ? "no final response" : diagnostic)
        }
        let output = try String(contentsOf: outputURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw SummaryError.invalidResponse }
        return output
    }

    private static func executableCandidates(named name: String) -> [String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path
            .split(separator: ":")
            .map { String($0) + "/" + name }
    }

    private static let summarySchema = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["schemaVersion", "tldr", "decisions", "actionItems", "nextSteps", "openQuestions", "risks", "sections", "sourceWarnings"],
      "properties": {
        "schemaVersion": {"type": "integer"},
        "tldr": {"type": "array", "items": {"$ref": "#/$defs/point"}},
        "decisions": {"type": "array", "items": {"$ref": "#/$defs/point"}},
        "actionItems": {"type": "array", "items": {"$ref": "#/$defs/action"}},
        "nextSteps": {"type": "array", "items": {"$ref": "#/$defs/point"}},
        "openQuestions": {"type": "array", "items": {"$ref": "#/$defs/point"}},
        "risks": {"type": "array", "items": {"$ref": "#/$defs/point"}},
        "sections": {"type": "array", "items": {"$ref": "#/$defs/section"}},
        "sourceWarnings": {"type": "array", "items": {"type": "string"}}
      },
      "$defs": {
        "evidence": {
          "type": "object",
          "additionalProperties": false,
          "required": ["speaker", "timestamp", "quote"],
          "properties": {
            "speaker": {"type": ["string", "null"]},
            "timestamp": {"type": ["string", "null"]},
            "quote": {"type": ["string", "null"]}
          }
        },
        "point": {
          "type": "object",
          "additionalProperties": false,
          "required": ["text", "evidence", "confidence"],
          "properties": {
            "text": {"type": "string"},
            "evidence": {"anyOf": [{"$ref": "#/$defs/evidence"}, {"type": "null"}]},
            "confidence": {"type": "string", "enum": ["high", "medium", "low"]}
          }
        },
        "action": {
          "type": "object",
          "additionalProperties": false,
          "required": ["text", "owner", "deadline", "explicitness", "evidence", "confidence"],
          "properties": {
            "text": {"type": "string"},
            "owner": {"type": ["string", "null"]},
            "deadline": {"type": ["string", "null"]},
            "explicitness": {"type": "string", "enum": ["explicit", "inferred"]},
            "evidence": {"anyOf": [{"$ref": "#/$defs/evidence"}, {"type": "null"}]},
            "confidence": {"type": "string", "enum": ["high", "medium", "low"]}
          }
        },
        "section": {
          "type": "object",
          "additionalProperties": false,
          "required": ["title", "bullets"],
          "properties": {
            "title": {"type": "string"},
            "bullets": {"type": "array", "items": {"$ref": "#/$defs/point"}}
          }
        }
      }
    }
    """#
}
