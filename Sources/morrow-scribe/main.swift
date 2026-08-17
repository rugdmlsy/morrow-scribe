import Foundation
import MorrowScribeCore

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

@main
struct MorrowScribeCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "help"
        if !args.isEmpty { args.removeFirst() }

        switch command {
        case "help", "--help", "-h":
            printHelp()
        case "self-test":
            let passed = try MorrowScribeSelfTest.run()
            for item in passed { print("PASS \(item)") }
            print("\(passed.count) checks passed")
        case "status":
            try status()
        case "snapshot":
            try snapshot(args: args)
        case "collect":
            try collect(args: args)
        case "huddle":
            try huddle(args: args)
        case "export":
            try export(args: args)
        case "summarize":
            try await summarize(args: args)
        default:
            throw CLIError(description: "unknown command: \(command)")
        }
    }

    static func status() throws {
        let session = SlackAXSession()
        print("accessibility_trusted=\(session.accessibilityTrusted)")
        try session.bootstrap()
        let nodes = try session.snapshot()
        print("slack_pid=\(session.slackPID ?? 0)")
        print("window=\(try session.windowTitle())")
        print("ax_nodes=\(nodes.count)")
        let huddle = nodes.filter(CaptionHeuristics.isHuddleRelated)
        print("huddle_related_nodes=\(huddle.count)")
        let preferred = CaptionHeuristics.preferredSource(from: nodes)
        print("caption_source=\(preferred?.rawValue ?? "unavailable")")
        print("side_by_side_candidates=\(CaptionHeuristics.extractSideBySideCandidates(from: nodes).count)")
        print("overlay_candidates=\(CaptionHeuristics.extractOverlayCandidates(from: nodes).count)")
        print("caption_candidates=\(CaptionHeuristics.extractCandidates(from: nodes).count)")
    }

    static func snapshot(args: [String]) throws {
        let match = option("--match", in: args)
        let session = SlackAXSession()
        try session.bootstrap()
        let nodes = try session.snapshot()
        let filtered: [AXSnapshotNode]
        if let match, !match.isEmpty {
            filtered = nodes.filter { $0.visibleText.localizedCaseInsensitiveContains(match) }
        } else {
            filtered = nodes.filter { !$0.visibleText.isEmpty }
        }
        for node in filtered {
            print("\(node.path) d=\(node.depth) \(node.role) text=[\(node.visibleText)] id=[\(node.identifier)]")
        }
    }

    static func collect(args: [String]) throws {
        let title = option("--title", in: args) ?? "Slack Huddle"
        let duration = option("--duration", in: args).flatMap(Double.init)
        let interval = option("--poll", in: args).flatMap(Double.init) ?? 0.25
        let learn = args.contains("--learn")
        let output = option("--output", in: args).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let store = try MeetingStore(title: title, baseDirectory: output)
        print("meeting_dir=\(store.directory.path)")
        let collector = SlackCaptionCollector(
            session: SlackAXSession(),
            store: store,
            options: CollectorOptions(pollInterval: interval, learnMode: learn, duration: duration)
        )
        try collector.run { print("[scribe] \($0)") }
    }

    static func huddle(args: [String]) throws {
        let action = args.first ?? "status"
        let controller = SlackHuddleController()
        switch action {
        case "status":
            let state = try controller.status()
            print("active=\(state.active)")
            if let title = state.windowTitle { print("window=\(title)") }
            if let captions = state.captionsEnabled { print("captions_enabled=\(captions)") }
            if let mode = state.captionMode { print("caption_mode=\(mode.rawValue)") }
        case "side-by-side":
            print("side_by_side=\(try controller.preferSideBySideCaptions())")
        case "auto-captions-on":
            print("auto_captions_enabled=\(try controller.enableAutomaticCaptionsPreference())")
        case "leave":
            try controller.leave()
            print("left_huddle=true")
        default:
            throw CLIError(description: "unknown huddle action: \(action)")
        }
    }

    static func export(args: [String]) throws {
        guard let path = args.first else { throw CLIError(description: "export requires a meeting directory") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let entries = try MeetingExport.transcriptEntries(in: directory)
        let markdown = MeetingExport.markdown(entries: entries)
        let out = directory.appendingPathComponent("export.md")
        try markdown.write(to: out, atomically: true, encoding: .utf8)
        print(out.path)
    }

    static func summarize(args: [String]) async throws {
        guard let path = args.first else { throw CLIError(description: "summarize requires a meeting directory") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let entries = try MeetingExport.transcriptEntries(in: directory)
        guard !entries.isEmpty else { throw CLIError(description: "meeting has no finalized transcript entries") }
        let prompt = MeetingExport.summaryPrompt(entries: entries)
        let summary = try await SummaryClient.summarize(prompt: prompt)
        let out = directory.appendingPathComponent("summary.md")
        try summary.write(to: out, atomically: true, encoding: .utf8)
        print(out.path)
    }

    static func option(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    static func printHelp() {
        print("""
        Morrow Scribe — Slack-native meeting transcript collector

        Usage:
          morrow-scribe self-test
          morrow-scribe status
          morrow-scribe snapshot [--match TEXT]
          morrow-scribe collect [--title TITLE] [--duration SEC] [--poll SEC] [--learn] [--output DIR]
          morrow-scribe huddle [status|side-by-side|auto-captions-on|leave]
          morrow-scribe export MEETING_DIR
          morrow-scribe summarize MEETING_DIR

        collect briefly foregrounds Slack once to capture the AX window, restores the previous app,
        then continues reading the retained Accessibility window while Slack stays in the background.
        """)
    }
}
