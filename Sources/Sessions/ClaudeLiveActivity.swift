import Foundation

/// What a Claude Code session is doing right now, read off the end of its
/// transcript: the tool it is running and on what, how much it has written
/// this turn, and when the turn began — the substance of the line its
/// terminal shows while it works.
struct ClaudeLiveActivity: Equatable {
    /// "Editing DockChatView.swift", "Running make build". Nil while it is
    /// thinking or writing, when the terminal has only its spinner word.
    let doing: String?
    /// Output tokens this turn — the terminal's "↓ 2.3k tokens".
    let tokens: Int
    /// When the prompt that started this turn was sent.
    let startedAt: Date?

    /// Read from the transcript's tail. Nil when the tail holds no turn.
    static func read(tail data: Data) -> ClaudeLiveActivity? {
        var records: [[String: Any]] = []
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  json["isSidechain"] as? Bool != true,
                  let type = json["type"] as? String, type == "user" || type == "assistant"
            else { continue }
            records.append(json)
        }
        // The turn starts at the last prompt a person typed — a user record
        // that is not a tool's result coming back.
        // A long turn with big records — screenshots, long files — can run
        // past the start of the tail; then what is in it is what there is:
        // the current tool still says itself; the tokens are left out.
        let start = records.lastIndex(where: { isPrompt($0) })
        guard start != nil || !records.isEmpty else { return nil }
        let turn = records[((start ?? -1) + 1)...]

        var counted = Set<String>()
        var tokens = 0
        for record in turn where record["type"] as? String == "assistant" {
            guard let message = record["message"] as? [String: Any] else { continue }
            // One reply is written as several records, one per block, each
            // carrying the whole reply's usage: counted once.
            let id = message["id"] as? String ?? UUID().uuidString
            guard counted.insert(id).inserted,
                  let usage = message["usage"] as? [String: Any] else { continue }
            tokens += (usage["output_tokens"] as? Int) ?? 0
        }

        var doing: String?
        if let last = turn.last, last["type"] as? String == "assistant",
           let message = last["message"] as? [String: Any],
           let blocks = message["content"] as? [[String: Any]],
           let tool = blocks.last(where: { $0["type"] as? String == "tool_use" }) {
            doing = describe(tool: tool["name"] as? String ?? "",
                             input: tool["input"] as? [String: Any] ?? [:])
        }
        // Without the turn's start the count is only of what the tail holds,
        // and it would fall as records scrolled out: better none than one
        // that goes backwards.
        return ClaudeLiveActivity(doing: doing, tokens: start == nil ? 0 : tokens,
                                  startedAt: start.flatMap { date(records[$0]["timestamp"]) })
    }

    private static func isPrompt(_ record: [String: Any]) -> Bool {
        guard record["type"] as? String == "user",
              let message = record["message"] as? [String: Any] else { return false }
        if message["content"] is String { return true }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        return !blocks.contains { $0["type"] as? String == "tool_result" }
    }

    /// A tool call the way the terminal sums it up.
    static func describe(tool: String, input: [String: Any]) -> String {
        func file(_ key: String = "file_path") -> String {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        }
        func text(_ key: String) -> String { (input[key] as? String) ?? "" }
        func short(_ value: String, _ limit: Int = 40) -> String {
            let line = value.split(separator: "\n").first.map(String.init) ?? value
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit": return "Editing \(file())"
        case "Write": return "Writing \(file())"
        case "Read": return "Reading \(file())"
        case "Bash":
            let description = text("description")
            return "Running " + short(description.isEmpty ? text("command") : description.lowercasedFirst)
        case "Grep": return "Searching for \(short(text("pattern"), 30))"
        case "Glob": return "Finding \(short(text("pattern"), 30))"
        case "WebFetch": return "Fetching \(URL(string: text("url"))?.host ?? "a page")"
        case "WebSearch": return "Searching the web"
        case "Task", "Agent": return "Agent: \(short(text("description"), 34))"
        case "TodoWrite": return "Updating the plan"
        default:
            // MCP tools arrive as mcp__server__tool_name.
            let name = tool.split(separator: "_").last.map(String.init) ?? tool
            return "Using \(name)"
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    /// "↓ 2.3k", as the terminal writes it.
    static func tokensText(_ tokens: Int) -> String {
        tokens >= 1000 ? String(format: "↓ %.1fk", Double(tokens) / 1000) : "↓ \(tokens)"
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
