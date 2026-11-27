import Foundation

/// What a Claude Code session is waiting on you for, read off the end of its
/// transcript: a question it asked with choices, or a tool it wants to run.
/// Its terminal shows either as a numbered list, and a number key picks.
struct ClaudePendingQuestion: Equatable {
    struct Choice: Equatable {
        let label: String
        let detail: String
        /// The key the terminal takes for it: "1", "2", …
        let key: String
    }

    /// The tool call it belongs to, so an answered one is not shown again.
    let id: String
    let title: String
    let choices: [Choice]

    /// The last tool call with no result yet, as a question. Nil when the
    /// session is not waiting on one.
    static func read(tail data: Data) -> ClaudePendingQuestion? {
        var answered = Set<String>()
        var pending: (id: String, name: String, input: [String: Any])?
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  json["isSidechain"] as? Bool != true,
                  let message = json["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    if let id = block["id"] as? String {
                        pending = (id, block["name"] as? String ?? "", block["input"] as? [String: Any] ?? [:])
                    }
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { answered.insert(id) }
                default: break
                }
            }
        }
        guard let pending, !answered.contains(pending.id) else { return nil }
        if pending.name == "AskUserQuestion",
           let question = (pending.input["questions"] as? [[String: Any]])?.first {
            let options = question["options"] as? [[String: Any]] ?? []
            let choices = options.enumerated().map { index, option in
                Choice(label: option["label"] as? String ?? "",
                       detail: option["description"] as? String ?? "",
                       key: "\(index + 1)")
            }
            guard !choices.isEmpty else { return nil }
            return ClaudePendingQuestion(id: pending.id,
                                         title: question["question"] as? String ?? "",
                                         choices: choices)
        }
        // Any other tool, waiting: the permission prompt.
        let what = ClaudeLiveActivity.describe(tool: pending.name, input: pending.input)
        return ClaudePendingQuestion(id: pending.id, title: "Allow: \(what)?", choices: [
            Choice(label: "Yes", detail: "", key: "1"),
            Choice(label: "Yes, and don't ask again", detail: "for this in this project", key: "2"),
            Choice(label: "No", detail: "and tell Claude what to do instead", key: "3"),
        ])
    }
}
