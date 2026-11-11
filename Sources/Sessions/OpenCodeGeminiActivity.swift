import Foundation
import SQLite3

/// Notices when OpenCode is mid-turn against the Gemini API key.
///
/// OpenCode's database is written for reasons that have nothing to do with a
/// Gemini call, so its modification date says nothing this provider may claim.
/// Each message row, however, records who answered it and whether the answer
/// finished:
///
/// ```
/// message(id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)
/// {"role":"assistant","providerID":"google","modelID":"gemini-2.5-pro",
///  "time":{"created":1789000000000,"completed":1789000004120},"finish":"stop", …}
/// ```
///
/// `time.completed` is written only once the turn is over — while the model is
/// still answering the key is simply absent — so an assistant row with
/// `providerID == "google"` and no `completed` is a Gemini call in flight, and
/// that is the only thing here that is this provider's to report.
///
/// The query looks at one message per session, the newest, because `message`'s
/// only index is `(session_id, time_created, id)`: there is no way to ask "what
/// changed lately" across the whole table, and this poll runs on the main actor
/// every couple of seconds. `session.time_updated` is the cheap pre-filter, and
/// the last message of each recently touched session is then the only JSON that
/// has to be decoded.
///
/// Sub-agent sessions carry `parent_id`, and a sub-agent is the same piece of
/// work as the session that spawned it — folding it into its parent keeps one
/// row in the tooltip instead of two that mean the same thing.
///
/// `staleAfter` still applies on top of the unfinished-message marker: a server
/// that crashed mid-turn leaves `completed` missing forever, and without the
/// recency bound that dead row would spin the ring for the rest of the month.
enum OpenCodeGeminiActivity {
    static var database: URL { OpenCodeGeminiUsage.database }

    static func read(
        database: URL = OpenCodeGeminiActivity.database,
        staleAfter: TimeInterval,
        now: Date = Date()
    ) -> [AgentSession] {
        guard let db = SQLiteStore.open(database) else { return [] }
        defer { sqlite3_close(db) }

        let cutoffMillis = Int((now.timeIntervalSince1970 - staleAfter) * 1000)
        guard let schema = OpenCodeSchema.of(db) else { return [] }
        let rows = SQLiteStore.rows(
            in: db,
            sql: schema.activitySQL(cutoffMillis: cutoffMillis),
            // Seven for both shapes: the 1.x query ends in an empty string
            // where 2.x selects `m.type`, so the row layout does not depend on
            // which schema answered.
            columns: 7
        )

        var seen: Set<String> = []
        var out: [AgentSession] = []
        for row in rows {
            let root = row[0]
            guard !root.isEmpty, !seen.contains(root) else { continue }
            guard let updated = Double(row[4]), Int(updated) >= cutoffMillis else { continue }
            guard let created = Double(row[3]) else { continue }
            guard isUnfinishedGoogleTurn(row[5], type: row[6]) else { continue }

            seen.insert(root)
            let directory = row[2]
            let detail = directory.isEmpty
                ? row[1]
                : URL(fileURLWithPath: directory).lastPathComponent
            out.append(AgentSession(
                id: "gemini-api.opencode.\(root)",
                name: "OpenCode",
                detail: "Working in \(detail)",
                state: .busy,
                waitingFor: nil,
                since: Date(timeIntervalSince1970: created / 1000)
            ))
        }
        return out
    }

    /// A JSON `null` arrives as `NSNull` rather than as a missing key, and both
    /// shapes mean the same thing here: nobody has recorded an end yet.
    ///
    /// OpenCode 2.x moved the role out of `data` and into the row's own `type`
    /// column, so it is passed in rather than read, and moved the provider id
    /// under `$.model.providerID`. Before 2.x the role was `$.role` and the
    /// provider id was top-level, so both are still accepted.
    private static func isUnfinishedGoogleTurn(_ data: String, type: String) -> Bool {
        guard let bytes = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes),
              let message = object as? [String: Any]
        else { return false }
        let role = type.isEmpty ? (message["role"] as? String) : type
        guard role == "assistant" else { return false }
        let provider = (message["model"] as? [String: Any])?["providerID"] as? String
            ?? message["providerID"] as? String
        guard provider == "google" else { return false }
        guard let time = message["time"] as? [String: Any] else { return true }
        let completed = time["completed"]
        return completed == nil || completed is NSNull
    }
}
