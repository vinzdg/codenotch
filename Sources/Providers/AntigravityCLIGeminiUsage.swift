import Foundation

/// Tokens Antigravity CLI recorded for itself while running on a bare
/// `GEMINI_API_KEY`, read out of its conversation transcripts.
///
/// Two stores exist, one per entry point: `~/.gemini/antigravity-cli` (`agy`)
/// and `~/.gemini/antigravity-acp` (`agy acp`). An ACP server started by an IDE
/// was seen writing to `~/.gemini/antigravity-cli` instead (IntelliJ IDEA,
/// `agy` 1.5.18), which is harmless because both stores are read. Each holds a `settings.json`
/// and, per conversation,
/// `brain/<conversation-uuid>/.system_generated/logs/transcript.jsonl`. Every
/// model call is one `PLANNER_RESPONSE` record; this is a real one with
/// `content`, `thinking` and `tool_calls` removed:
///
/// ```
/// {"step_index":56,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE",
///  "created_at":"2026-11-23T22:05:25Z","model":"gemini-4-carbon-high",
///  "input_tokens":3617,"cache_read_tokens":145480,"output_tokens":1053}
/// ```
///
/// `input_tokens` excludes the cache, so the cache is added back; and
/// `output_tokens` already contains the thinking, so no thinking figure is
/// added on top. That call is 3617 + 145480 + 1053 = 150150 tokens. Records of
/// other types (`USER_INPUT`, `SYSTEM_MESSAGE`, tool responses) carry no token
/// keys, and a call cut off before the answer has none either, so it adds
/// nothing.
///
/// Whether a store is on an API key is written in its `settings.json`:
/// top-level `"modelProvider": "gemini"` for the CLI,
/// `{"auth":{"type":"gemini-api-key"}}` for ACP. Neither file holds the key,
/// and the key is never read. A store on Google sign-in is somebody else's
/// quota and is not counted here.
///
/// The same counters exist as protobuf in `conversations/<uuid>.db`, table
/// `gen_metadata`; over 50 real calls the transcript sums and the database sums
/// were identical and no `step_index` repeated. The transcript is read because
/// it is plain JSON; the database was only the evidence. Verified against `agy`
/// 1.5.15.
enum AntigravityCLIGeminiUsage {
    static var stores: [URL] {
        let gemini = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini")
        return [
            gemini.appendingPathComponent("antigravity-cli"),
            gemini.appendingPathComponent("antigravity-acp")
        ]
    }

    static func usesAPIKey(store: URL) -> Bool {
        guard let data = try? Data(contentsOf: store.appendingPathComponent("settings.json")),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        if settings["modelProvider"] as? String == "gemini" { return true }
        let auth = settings["auth"] as? [String: Any]
        return auth?["type"] as? String == "gemini-api-key"
    }

    /// `nil` means no API-key store with a `brain` directory exists, which is a
    /// different answer from "it ran and spent nothing" — the provider drops the
    /// row rather than showing a zero for a tool that was never set up.
    static func read(
        stores: [URL] = AntigravityCLIGeminiUsage.stores,
        now: Date = Date()
    ) -> GeminiTokenUsage? {
        let manager = FileManager.default
        // shortcut: the store's current settings decide for its whole history, so calls made before a switch between Google sign-in and an API key are attributed by today's mode; upgrade to the per-call api_provider (24 = API_PROVIDER_GOOGLE_GEMINI) in conversations/<id>.db gen_metadata if that ever matters.
        let brains = stores.filter { usesAPIKey(store: $0) }.compactMap { store -> [URL]? in
            try? manager.contentsOfDirectory(
                at: store.appendingPathComponent("brain"), includingPropertiesForKeys: nil)
        }
        guard !brains.isEmpty else { return nil }

        let startOfMonth = GeminiTokenUsage.startOfMonth(now: now)
        var entries: [(at: Date, tokens: Int, calls: Int)] = []

        for conversation in brains.joined() {
            let transcript = conversation.appendingPathComponent(
                ".system_generated/logs/transcript.jsonl")
            // Append-only: a transcript last written before this month cannot
            // hold a record from it, so it is not worth parsing.
            let modified = try? transcript.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if let modified, modified < startOfMonth { continue }

            guard let text = try? String(contentsOf: transcript, encoding: .utf8) else { continue }
            entries.append(contentsOf: calls(in: text))
        }
        return GeminiTokenUsage.bucket(entries, now: now)
    }

    private static func calls(in text: String) -> [(at: Date, tokens: Int, calls: Int)] {
        var answered: [Int: (at: Date, tokens: Int, calls: Int)] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  let step = record.step_index,
                  record.input_tokens != nil || record.cache_read_tokens != nil
                    || record.output_tokens != nil,
                  let stamp = record.created_at, let at = GeminiCLIUsage.parse(stamp)
            else { continue }
            // Later line wins, as in `GeminiCLIUsage`; a line with an unreadable
            // date is not a later version of the call, so it is skipped above.
            let tokens = (record.input_tokens ?? 0) + (record.cache_read_tokens ?? 0)
                + (record.output_tokens ?? 0)
            answered[step] = (at: at, tokens: tokens, calls: 1)
        }
        return Array(answered.values)
    }

    /// Everything is optional because the transcript mixes user input, system
    /// messages and tool responses with the model calls; those decode into a
    /// record without token keys and are dropped by the filter.
    private struct Record: Decodable {
        let step_index: Int?
        let created_at: String?
        let input_tokens: Int?
        let cache_read_tokens: Int?
        let output_tokens: Int?
    }
}
