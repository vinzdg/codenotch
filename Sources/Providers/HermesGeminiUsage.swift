import Foundation
import SQLite3

/// Tokens Hermes billed to a `GEMINI_API_KEY`, read out of its own usage table.
///
/// Hermes keeps a running total per session and model in `~/.hermes/state.db`:
///
/// ```
/// session_model_usage(session_id, model, billing_provider, billing_base_url,
///                     billing_mode, task, api_call_count, input_tokens,
///                     output_tokens, cache_read_tokens, cache_write_tokens,
///                     reasoning_tokens, estimated_cost_usd, actual_cost_usd,
///                     cost_status, cost_source, first_seen REAL, last_seen REAL)
/// ```
///
/// `billing_provider == "gemini"` is Hermes's id for "Google AI Studio", which
/// is the bare API key against `generativelanguage.googleapis.com/v1beta`. The
/// id survives a `GEMINI_BASE_URL` override — the base url moves to its own
/// column — so matching on it and not on the url is what keeps a proxied setup
/// counted.
///
/// `reasoning_tokens` is left out of the sum on purpose. Hermes's own
/// `CanonicalUsage.total_tokens` treats reasoning as part of `output_tokens`,
/// so adding it back would bill every thinking model twice. That is the
/// opposite of OpenCode next door, where `reasoning` is a separate component.
///
/// A row is an aggregate over a whole session, not a single call, so there is
/// no per-call timestamp to bucket by: `last_seen` is the closest thing, and a
/// session straddling midnight or month end lands wholly in the bucket of its
/// last call. Hermes's own `/usage` report has exactly the same granularity.
enum HermesGeminiUsage {
    static var database: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/state.db")
    }

    /// `nil` means Hermes has no database on disk, which is a different answer
    /// from "it ran and spent nothing" — the provider drops the row entirely
    /// rather than showing a zero for a tool that was never installed.
    static func read(
        database: URL = HermesGeminiUsage.database,
        now: Date = Date()
    ) -> GeminiTokenUsage? {
        guard let db = SQLiteStore.open(database) else { return nil }
        defer { sqlite3_close(db) }

        // `last_seen` is epoch seconds as a REAL. Filtering in SQL keeps the
        // read to this month's sessions however long the user has run Hermes.
        let startOfMonth = Int(GeminiTokenUsage.startOfMonth(now: now).timeIntervalSince1970)
        let rows = SQLiteStore.rows(
            in: db,
            sql: """
            SELECT last_seen,
                   input_tokens + cache_read_tokens + cache_write_tokens + output_tokens,
                   api_call_count
            FROM session_model_usage
            WHERE billing_provider = 'gemini'
              AND last_seen >= \(startOfMonth)
            """,
            columns: 3
        )

        let entries: [(at: Date, tokens: Int, calls: Int)] = rows.compactMap { row in
            guard let seconds = Double(row[0]) else { return nil }
            return (
                at: Date(timeIntervalSince1970: seconds),
                tokens: Int(row[1]) ?? 0,
                calls: Int(row[2]) ?? 0
            )
        }
        return GeminiTokenUsage.bucket(entries, now: now)
    }
}
