import Foundation
import SQLite3

/// Which OpenCode wrote `opencode.db`.
///
/// 2.x renamed `message` to `session_message` and `session` to `session_v2`, and
/// moved the message's role out of `data` and into the row's own `type` column.
/// Neither shape can be read with the other's SQL — a query naming a table that
/// does not exist does not return nothing, it fails to prepare, and
/// `SQLiteStore.rows` answers an empty set for that. So a reader written for 2.x
/// applied to a 1.x database reads as "spent nothing" rather than as "cannot
/// read", which is the same silent-zero bug as the one the rename caused.
///
/// Probed rather than assumed, because both are in the wild and there is no
/// version string in the store to ask.
enum OpenCodeSchema {
    case v1, v2

    /// Which shape the database is, or nil for one that is neither.
    ///
    /// **`session_message` alone does not say 2.x.** 1.18 already ships that
    /// table, beside `message` and `session`, which it still reads and writes
    /// (upstream `packages/core/schema.json` at v1.18.0 and v1.18.34: all three,
    /// and no `session_v2`). Asked for first, it sent every current 1.x store
    /// down the 2.x path: usage read from a table 1.x does not keep its
    /// messages in, and the activity query failed to prepare on `session_v2`
    /// and answered nothing. What only 2.x has is `session_v2`, and what every
    /// 1.x has is `message`; `session_message` on its own is a 2.x store seen
    /// through one table.
    static func of(_ db: OpaquePointer?) -> OpenCodeSchema? {
        if hasTable("session_v2", in: db) { return .v2 }
        if hasTable("message", in: db) { return .v1 }
        if hasTable("session_message", in: db) { return .v2 }
        return nil
    }

    private static func hasTable(_ name: String, in db: OpaquePointer?) -> Bool {
        SQLiteStore.rows(
            in: db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\(name)'"
        ).first != nil
    }

    /// The provider id, which moved into the model object in 2.x. Matched in
    /// both places rather than branching, since one predicate covers the pair
    /// and a 1.x row has no `model` key to miss on.
    static let providerPredicate = """
    COALESCE(json_extract(data, '$.model.providerID'),
              json_extract(data, '$.providerID')) = 'google'
    """

    /// The role, which is a column in 2.x and a JSON key in 1.x. This one has to
    /// branch: `type` does not exist as a column in 1.x, so naming it there
    /// fails to prepare.
    static func assistantPredicate(for schema: OpenCodeSchema) -> String {
        switch schema {
        case .v2: "type = 'assistant'"
        case .v1: "json_extract(data, '$.role') = 'assistant'"
        }
    }

    /// `$.tokens.total` is still selected, and still preferred.
    ///
    /// 2.x dropped it, so it reads as NULL there and the component sum below is
    /// the whole figure. But 1.x can record a total without the components — a
    /// message OpenCode summarised keeps the figure and loses the breakdown —
    /// so dropping the column would turn those rows into a zero, which is
    /// worse than the rename this reader was fixed for.
    func geminiUsageSQL(startOfMonth: Int) -> String {
        let table = self == .v2 ? "session_message" : "message"
        return """
        SELECT time_created,
               json_extract(data, '$.tokens.total'),
               json_extract(data, '$.tokens.input'),
               json_extract(data, '$.tokens.output'),
               json_extract(data, '$.tokens.reasoning'),
               json_extract(data, '$.tokens.cache.read'),
               json_extract(data, '$.tokens.cache.write')
        FROM \(table)
        WHERE \(OpenCodeSchema.assistantPredicate(for: self))
          AND \(OpenCodeSchema.providerPredicate)
          AND time_created >= \(startOfMonth)
        """
    }

    func activitySQL(cutoffMillis: Int) -> String {
        switch self {
        case .v2:
            // `seq` orders a session's messages in 2.x, and does not go
            // backwards when two land in the same millisecond.
            return """
            SELECT r.id, r.title, r.directory, m.time_created, m.time_updated, m.data, m.type
            FROM session_v2 s
            JOIN session_v2 r ON r.id = COALESCE(s.parent_id, s.id)
            JOIN session_message m ON m.id = (SELECT id FROM session_message WHERE session_id = s.id
                                             ORDER BY seq DESC LIMIT 1)
            WHERE s.time_updated >= \(cutoffMillis)
            ORDER BY m.time_updated DESC
            """
        case .v1:
            return """
            SELECT r.id, r.title, r.directory, m.time_created, m.time_updated, m.data, ''
            FROM session s
            JOIN session r ON r.id = COALESCE(s.parent_id, s.id)
            JOIN message m ON m.id = (SELECT id FROM message WHERE session_id = s.id
                                      ORDER BY time_created DESC LIMIT 1)
            WHERE s.time_updated >= \(cutoffMillis)
            ORDER BY m.time_updated DESC
            """
        }
    }
}
