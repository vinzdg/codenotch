import Foundation

/// The conversation so far, as the terminal shows it: what you typed, and
/// what Claude wrote back — its words, not its tool calls or their output.
enum ClaudeConversation {
    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case you, claude }
        let id: String
        let role: Role
        let text: String
    }

    static func read(tail data: Data, limit: Int = 40) -> [Message] {
        var messages: [Message] = []
        var index = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  json["isSidechain"] as? Bool != true,
                  json["isMeta"] as? Bool != true,
                  let type = json["type"] as? String, type == "user" || type == "assistant",
                  let message = json["message"] as? [String: Any] else { continue }
            index += 1
            let id = (json["uuid"] as? String) ?? "\(index)"
            var texts: [String] = []
            if let text = message["content"] as? String {
                texts = [text]
            } else if let blocks = message["content"] as? [[String: Any]] {
                // A tool's result coming back is not something anyone typed.
                if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { continue }
                texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            }
            let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isMachinery(text) else { continue }
            messages.append(Message(id: id, role: type == "user" ? .you : .claude, text: text))
        }
        return Array(messages.suffix(limit))
    }

    /// What Claude Code writes into the conversation for itself: command
    /// echoes, reminders, interruptions. Not shown.
    private static func isMachinery(_ text: String) -> Bool {
        let markers = ["<command-name>", "<local-command", "<system-reminder>", "<command-message>",
                       "[Request interrupted", "<task-notification>", "Caveat:"]
        return markers.contains { text.hasPrefix($0) }
    }
}
