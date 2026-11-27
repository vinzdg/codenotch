import Foundation

/// The slash commands a Claude Code session answers to: its own, and the
/// ones written as files — commands and skills, for the person and for the
/// repository — read the way Claude Code reads them.
struct SlashCommand: Identifiable, Equatable {
    var id: String { name }
    /// Without the slash: "compact", "review", "frontend:lint".
    let name: String
    let summary: String
    /// Sends as soon as it is picked: no arguments to type after it.
    var runsAsIs = false

    /// Commands that open a picker on the terminal's own screen, which the
    /// pill cannot see: run from the pill, their terminal is brought forward.
    static let interactive: Set<String> = [
        "color", "config", "copy", "doctor", "effort", "export", "focus", "help", "hooks", "ide",
        "memory", "permissions", "plugin", "resume", "rewind", "skills", "status", "tasks",
        "theme", "usage",
    ]

    var opensInTerminal: Bool { Self.interactive.contains(name) }

    /// What a command takes after it, offered as a list in the pill instead
    /// of the terminal's picker. /model takes the model's name directly.
    var choices: [SlashCommand]? {
        func options(_ list: [(String, String)]) -> [SlashCommand] {
            list.map { SlashCommand(name: "\(name) \($0.0)", summary: $0.1, runsAsIs: true) }
        }
        switch name {
        case "model":
            return options([("default", "The recommended model for your plan"),
                            ("opus", "Most capable, for complex work"),
                            ("sonnet", "Fast and capable, for everyday work"),
                            ("haiku", "Fastest, for quick answers"),
                            ("opusplan", "Opus to plan, Sonnet to build")])
        case "fast":
            return options([("on", "Faster output"), ("off", "Back to normal speed")])
        case "voice":
            return options([("hold", "Hold a key to talk"), ("tap", "Tap to start and stop"),
                            ("off", "Turn voice off")])
        case "tui":
            return options([("classic", "The classic display"), ("fullscreen", "Fullscreen display")])
        case "output-style":
            return options([("default", "Claude's usual style"),
                            ("explanatory", "Explains its choices as it works"),
                            ("learning", "Leaves pieces for you to write")])
        case "autocompact":
            return options([("auto", "Let Claude Code decide")])
        default:
            return nil
        }
    }

    /// Claude Code's own commands, as its 2.1 release defines them: what
    /// each does, and whether it opens a screen of its own in the terminal.
    static let builtIn: [SlashCommand] = [
        .init(name: "add-dir", summary: "Add a working directory"),
        .init(name: "autocompact", summary: "How full the context gets before it is summarised"),
        .init(name: "background", summary: "Send this session to the background"),
        .init(name: "branch", summary: "Branch the conversation at this point"),
        .init(name: "btw", summary: "Ask a side question without interrupting Claude"),
        .init(name: "cd", summary: "Move this session to another directory"),
        .init(name: "clear", summary: "Start fresh with an empty context"),
        .init(name: "color", summary: "Set the prompt bar's colour"),
        .init(name: "compact", summary: "Summarise the conversation to free up context"),
        .init(name: "config", summary: "Open settings"),
        .init(name: "context", summary: "Show what is using the context window"),
        .init(name: "copy", summary: "Copy the last response to the clipboard"),
        .init(name: "doctor", summary: "Check the installation"),
        .init(name: "effort", summary: "Set the model's effort level"),
        .init(name: "export", summary: "Export this session to a file or the clipboard"),
        .init(name: "fast", summary: "Turn fast mode on or off"),
        .init(name: "focus", summary: "Just your prompt, the summary and the response"),
        .init(name: "goal", summary: "Set a goal Claude checks before stopping"),
        .init(name: "help", summary: "Help and the commands available"),
        .init(name: "hooks", summary: "View hooks for tool events"),
        .init(name: "ide", summary: "IDE integrations"),
        .init(name: "init", summary: "Write a CLAUDE.md for this project"),
        .init(name: "mcp", summary: "Manage MCP servers"),
        .init(name: "memory", summary: "Edit CLAUDE.md files and memory settings"),
        .init(name: "model", summary: "Set the model"),
        .init(name: "output-style", summary: "List output styles, or switch to one"),
        .init(name: "permissions", summary: "Allow and deny rules for tools"),
        .init(name: "plan", summary: "Turn on plan mode, or view the plan"),
        .init(name: "plugin", summary: "Manage plugins"),
        .init(name: "reload-plugins", summary: "Pick up plugin changes"),
        .init(name: "reload-skills", summary: "Pick up skills changed on disk"),
        .init(name: "rename", summary: "Rename this conversation"),
        .init(name: "resume", summary: "Resume an earlier conversation"),
        .init(name: "rewind", summary: "Go back to an earlier point"),
        .init(name: "skills", summary: "List available skills"),
        .init(name: "status", summary: "Version, account, model and MCP servers"),
        .init(name: "subtask", summary: "Send a subagent off with your full context"),
        .init(name: "tasks", summary: "This session's background work"),
        .init(name: "theme", summary: "Change the theme"),
        .init(name: "tui", summary: "Classic or fullscreen terminal display"),
        .init(name: "usage", summary: "Session cost, plan usage and activity"),
        .init(name: "voice", summary: "Voice mode"),
    ]

    /// Built-ins, then the person's and the repository's own, by name.
    static func available(cwd: String?) -> [SlashCommand] {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        var roots = [home]
        if let cwd { roots.append(URL(fileURLWithPath: cwd).appendingPathComponent(".claude")) }
        var found: [String: SlashCommand] = [:]
        for command in builtIn { found[command.name] = command }
        for root in roots {
            for command in files(in: root.appendingPathComponent("commands")) { found[command.name] = command }
            for command in skills(in: root.appendingPathComponent("skills")) { found[command.name] = command }
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// Commands, ranked for what has been typed after the slash: names that
    /// start with it first, then names that contain it.
    static func matching(_ query: String, in commands: [SlashCommand], limit: Int = 7) -> [SlashCommand] {
        let query = query.lowercased()
        guard !query.isEmpty else { return Array(commands.prefix(limit)) }
        let starts = commands.filter { $0.name.lowercased().hasPrefix(query) }
        let contains = commands.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
        return Array((starts + contains).prefix(limit))
    }

    /// `commands/review.md` is /review; `commands/frontend/lint.md` is
    /// /frontend:lint.
    private static func files(in folder: URL) -> [SlashCommand] {
        // Both sides resolved: the walker hands back paths through symlinks
        // resolved, and a prefix counted on the unresolved one cut names short.
        let base = folder.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var found: [SlashCommand] = []
        for case let url as URL in walker where url.pathExtension == "md" {
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = path.dropFirst(base.count + 1)
            let name = String(relative.dropLast(3)).replacingOccurrences(of: "/", with: ":")
            found.append(SlashCommand(name: name, summary: frontMatter(url)["description"] ?? ""))
        }
        return found
    }

    /// `skills/<name>/SKILL.md`, named by its front matter or its folder.
    private static func skills(in folder: URL) -> [SlashCommand] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { entry in
            let file = entry.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let fields = frontMatter(file)
            return SlashCommand(name: fields["name"] ?? entry.lastPathComponent,
                                summary: fields["description"] ?? "")
        }
    }

    /// The `key: value` lines between a file's opening `---` fences.
    private static func frontMatter(_ url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        return fields
    }
}
