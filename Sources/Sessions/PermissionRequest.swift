import Foundation

/// A question Claude Code is holding a tool call on, until someone answers it.
///
/// Arrives through Claude Code's `PermissionRequest` hook — see
/// `HookBridgeServer`. Two shapes are worth a card of their own: an ordinary
/// tool asking to run, and `AskUserQuestion`, which is Claude asking *you*
/// something and whose "permission" is really the answer.
struct PermissionRequest: Identifiable, Equatable {
    struct Question: Equatable {
        let question: String
        let header: String?
        let options: [String]
        let multiSelect: Bool
    }

    enum Kind: Equatable {
        /// A tool that wants to run: its name, what it would touch (a path, or
        /// Bash's own description of the command), and what to show of it.
        case tool(name: String, target: String, preview: Preview?)
        /// `AskUserQuestion` — answered with one label per question.
        case questions([Question])
    }

    /// The block under the tool line: removed and added lines for Edit /
    /// Write, the command itself for Bash — what the terminal prompt shows.
    struct Preview: Equatable {
        /// `context` is an unchanged line around an edit; `plain` is a line
        /// that is not a diff at all, like a Bash command.
        enum Mark: Equatable { case removed, added, context, plain }
        struct Line: Equatable {
            let mark: Mark
            let text: String
        }
        let lines: [Line]
    }

    /// One of the terminal's "Yes, and…" choices. Claude Code sends them as
    /// `permission_suggestions`; choosing one hands it back untouched as
    /// `updatedPermissions`, so what it means stays Claude Code's business.
    struct Suggestion: Equatable {
        let label: String
        let value: JSONValue
    }

    let id: UUID
    let sessionID: String
    /// The project folder name, which is what the session list calls it too.
    let project: String
    let kind: Kind
    /// Kept to echo back: an `AskUserQuestion` answer is the original input
    /// with `answers` added, and anything we drop would be dropped for Claude.
    let toolInput: [String: JSONValue]
    let receivedAt: Date
    var suggestions: [Suggestion] = []
    /// Where to look for the prompt being answered somewhere else — see
    /// `HookBridge.answeredElsewhere`. Nil in payloads that do not carry them.
    var transcriptPath: String? = nil
    var toolUseID: String? = nil
    /// The Claude Code process asking, and the app it runs in — for "Answer in
    /// <app>", which takes you to the full prompt. Filled in by `HookBridge`
    /// from the session registry; the hook itself names neither.
    var processID: pid_t? = nil
    var appName: String? = nil
}

extension PermissionRequest {
    /// Nil for anything that is not a `PermissionRequest` payload — the
    /// endpoint answers those by getting out of the way.
    static func decode(_ data: Data, id: UUID = UUID(), now: Date = Date()) -> PermissionRequest? {
        guard case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              root["hook_event_name"]?.string == "PermissionRequest",
              let tool = root["tool_name"]?.string,
              case .object(let input)? = root["tool_input"] else { return nil }
        let cwd = root["cwd"]?.string ?? ""
        var suggestions: [Suggestion] = []
        if case .array(let items)? = root["permission_suggestions"] {
            suggestions = items.map { Suggestion(label: label(for: $0), value: $0) }
        }
        if tool == planTool { suggestions = planChoices }
        return PermissionRequest(
            id: id,
            sessionID: root["session_id"]?.string ?? "",
            project: URL(fileURLWithPath: cwd).lastPathComponent,
            kind: kind(tool: tool, input: input, cwd: cwd),
            toolInput: input,
            receivedAt: now,
            suggestions: suggestions,
            transcriptPath: root["transcript_path"]?.string,
            toolUseID: root["tool_use_id"]?.string
        )
    }

    static let planTool = "ExitPlanMode"

    var isPlan: Bool {
        if case .tool(let name, _, _) = kind { return name == Self.planTool }
        return false
    }

    /// Leaving plan mode is answered with the mode to work in next, the way
    /// the terminal and Zed ask it. Each "Yes" is a `setMode` for the session;
    /// "clear context" has no hook equivalent, so it stays in the app.
    static let planChoices: [Suggestion] = [
        ("Yes, and auto-accept edits", "acceptEdits"),
        ("Yes, manually approve edits", "default"),
        ("Yes, and use auto mode", "auto"),
        ("Yes, and bypass permissions", "bypassPermissions"),
    ].map { label, mode in
        Suggestion(label: L10n.t(String.LocalizationValue(label)), value: .object([
            "type": .string("setMode"), "mode": .string(mode), "destination": .string("session"),
        ]))
    }

    /// Worded the way the terminal words the same choice.
    static func label(for suggestion: JSONValue) -> String {
        guard case .object(let s) = suggestion else { return L10n.t("Yes, and remember this") }
        switch s["type"]?.string {
        case "setMode":
            switch s["mode"]?.string {
            case "acceptEdits": return L10n.t("Yes, allow all edits this session")
            case "auto": return L10n.t("Yes, and switch to auto mode")
            case let mode?: return L10n.t("Yes, and switch to \(mode)")
            case nil: return L10n.t("Yes, and remember this")
            }
        case "addRules":
            var subjects: [String] = []
            if case .array(let rules)? = s["rules"] {
                for case .object(let rule) in rules {
                    if let subject = rule["ruleContent"]?.string ?? rule["toolName"]?.string {
                        subjects.append(subject)
                    }
                }
            }
            return subjects.isEmpty ? L10n.t("Yes, and don't ask again")
                : L10n.t("Yes, and don't ask again for: \(subjects.joined(separator: ", "))")
        case "addDirectories":
            var directories: [String] = []
            if case .array(let items)? = s["directories"] { directories = items.compactMap(\.string) }
            return L10n.t("Yes, and allow access to \(directories.joined(separator: ", "))")
        default:
            return L10n.t("Yes, and remember this")
        }
    }

    private static func kind(tool: String, input: [String: JSONValue], cwd: String) -> Kind {
        if tool == "AskUserQuestion", case .array(let items)? = input["questions"] {
            let questions: [Question] = items.compactMap {
                guard case .object(let q) = $0, let text = q["question"]?.string,
                      case .array(let options)? = q["options"] else { return nil }
                return Question(
                    question: text,
                    header: q["header"]?.string,
                    options: options.compactMap { option in
                        if case .object(let o) = option { return o["label"]?.string }
                        return option.string
                    },
                    multiSelect: q["multiSelect"]?.bool ?? false
                )
            }
            if !questions.isEmpty { return .questions(questions) }
        }
        if tool == planTool, let plan = input["plan"]?.string {
            // The plan's own title, then its opening lines, blank ones dropped.
            let body = lines(plan).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let title = body.first { $0.hasPrefix("#") }?.drop { $0 == "#" || $0 == " " }
            return .tool(name: tool, target: title.map(String.init) ?? "",
                         preview: Preview(lines: body.filter { !$0.hasPrefix("# ") }.map { .init(mark: .plain, text: $0) }))
        }
        let path = input["file_path"]?.string.map { relative($0, to: cwd) }
        let target = path ?? input["description"]?.string ?? input["url"]?.string
            ?? input["pattern"]?.string ?? ""
        var preview: [Preview.Line] = []
        if let new = input["new_string"]?.string {
            preview = diff(from: lines(input["old_string"]?.string), to: lines(new))
        } else if let content = input["content"]?.string {
            preview = lines(content).map { .init(mark: .added, text: $0) }
        } else if let command = input["command"]?.string {
            preview = lines(command).map { .init(mark: .plain, text: $0) }
        }
        return .tool(name: tool, target: target, preview: preview.isEmpty ? nil : Preview(lines: preview))
    }

    /// An Edit arrives as a whole old block and a whole new block, most of it
    /// the same. Shown as-is, every unchanged line appeared twice — once red,
    /// once green — for a one-line change. So: the real line diff, unchanged
    /// lines as context, starting one line above the first change.
    static func diff(from old: [String], to new: [String]) -> [Preview.Line] {
        let changes = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [Preview.Line] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                out.append(.init(mark: .removed, text: old[i])); i += 1
            } else if j < new.count, inserted.contains(j) {
                out.append(.init(mark: .added, text: new[j])); j += 1
            } else if i < old.count {
                out.append(.init(mark: .context, text: old[i])); i += 1; j += 1
            } else {
                break
            }
        }
        guard let first = out.firstIndex(where: { $0.mark != .context }) else { return out }
        return Array(out[max(0, first - 1)...])
    }

    private static func lines(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }

    private static func relative(_ path: String, to cwd: String) -> String {
        guard !cwd.isEmpty, path.hasPrefix(cwd + "/") else { return path }
        return String(path.dropFirst(cwd.count + 1))
    }
}

/// What the notch says back.
enum PermissionDecision: Equatable {
    case allow
    /// Allow, and apply one of the request's `suggestions` — the terminal's
    /// "Yes, and don't ask again…" rows.
    case allowRemembering(JSONValue)
    case deny
    /// Answers to `AskUserQuestion`, keyed by question text, in the shape the
    /// tool reads: several labels for a multi-select joined with ", ".
    case answer([String: String])
    /// No decision: Claude Code carries on with its own prompt in the terminal.
    case passThrough

    /// The hook's stdout / HTTP response body.
    func responseBody(for request: PermissionRequest) -> Data {
        let decision: JSONValue
        switch self {
        case .passThrough:
            return Data("{}".utf8)
        // The input echoed back on every allow: under the Agent SDK (Zed, VS
        // Code, Claude desktop) an ExitPlanMode allow without `updatedInput` is
        // ignored and the host's own prompt wins (checked against 2.1.280).
        case .allow:
            decision = .object(["behavior": .string("allow"),
                                "updatedInput": .object(request.toolInput)])
        case .allowRemembering(let suggestion):
            decision = .object(["behavior": .string("allow"),
                                "updatedInput": .object(request.toolInput),
                                "updatedPermissions": .array([suggestion])])
        case .deny:
            decision = .object(["behavior": .string("deny"),
                                "message": .string("Denied from Codenotch")])
        case .answer(let answers):
            var input = request.toolInput
            input["answers"] = .object(answers.mapValues { .string($0) })
            decision = .object(["behavior": .string("allow"), "updatedInput": .object(input)])
        }
        let body: JSONValue = .object(["hookSpecificOutput": .object([
            "hookEventName": .string("PermissionRequest"),
            "decision": decision,
        ])])
        return (try? JSONEncoder().encode(body)) ?? Data("{}".utf8)
    }
}

/// Just enough JSON to carry an arbitrary tool input through untouched.
indirect enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
