import Foundation
import SQLite3

/// The credential OpenCode itself signed in with, borrowed — never written.
///
/// After the Console migration a live Go key is a console personal key. It is
/// stored in `auth.json` under `"opencode"` as `{"type":"api","key":"oc_sk_…"}`
/// — not under `"opencode-go"`, and not `type` `oauth`. The same shape can also
/// sit in `opencode.db`'s `credential` table. `auth.json` is still read; it is
/// not gone. The leftover `"opencode-go"` entry is the old `sk-` key, which the
/// usage endpoint now rejects.
///
/// A console key — a non-OAuth token with the `oc_sk_` prefix — wins wherever
/// it was written, so a database row cannot hide one that lives only in the
/// file. When more than one exists the order is:
///
/// 1. database `opencode`, then database `opencode-go` (active rows, newest
///    first, the same query as before);
/// 2. `auth.json` `"opencode"` when that entry is an API key (`type` `"api"`,
///    a bare string, or the usual key fields) and the token is `oc_sk_`;
/// 3. `auth.json` `"opencode-go"` when its token is `oc_sk_`.
///
/// With no console key the older order stands: database `opencode-go`, then
/// database `opencode`, then `auth.json` `opencode-go`, then `auth.json`
/// `opencode` only when `type` is `oauth`. The database still beats the file
/// when it holds the `oc_sk_` key itself, and when the file has no console key.
///
/// Which one is found decides the usage endpoint, because each route refuses the
/// other's credential — see `OpenCodeProvider`. A non-OAuth key, including
/// `oc_sk_`, stays on the zen route. Only OpenCode's own two ids are ever
/// claimed; another integration's row (`openrouter`, `openai`, …) is that
/// vendor's key, and reading it under OpenCode's name would meter the wrong
/// account.
enum OpenCodeCredentials {
    struct Credential {
        let token: String
        /// An OAuth sign-in rather than the Go API key. Decides the endpoint.
        let oauth: Bool
        /// The console that issued an OAuth token (`metadata.server`).
        let console: URL?
        /// Sent as `x-opencode-org-id`; only an OAuth sign-in carries one.
        let org: String?
        /// Local expiry hint. Only a hint: the server decides, and OpenCode
        /// refreshes the token whenever it runs.
        let expires: Date?
        /// Where it was read from, for the settings line. Never the token.
        let source: String
    }

    /// OpenCode's data directory: `$XDG_DATA_HOME/opencode` when set, else
    /// `~/.local/share/opencode` — the same resolution OpenCode itself makes.
    static var dataDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"],
           !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/opencode")
    }

    static var authURL: URL { dataDirectory.appendingPathComponent("auth.json") }
    static var databaseURL: URL { dataDirectory.appendingPathComponent("opencode.db") }

    /// Is OpenCode on this machine at all? A machine that never had it shows no
    /// cell, which is a different answer from one that has it and is signed out.
    static func present(in directory: URL = dataDirectory) -> Bool {
        ["auth.json", "opencode.db"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Console key first, then the pre-console order. See the file comment for
    /// which source wins: a database `sk-` row must not hide an `oc_sk_` key
    /// that exists only in `auth.json`.
    static func load(in directory: URL = dataDirectory) -> Credential? {
        let auth = directory.appendingPathComponent("auth.json")
        let stored = databaseCredentials(directory.appendingPathComponent("opencode.db"))
        let fileGo = loadGoKey(from: auth)
        let fileAccount = authEntry("opencode", from: auth)

        if let console = consoleKey(in: stored, fileAccount: fileAccount, fileGo: fileGo) {
            return console
        }
        if let preferred = preferredDatabase(stored) { return preferred }
        if let fileGo { return fileGo }
        if let fileAccount, fileAccount.oauth { return fileAccount }
        return nil
    }

    // MARK: - Sources

    /// The `opencode-go` half of `auth.json`: the Go plan's own API key, what
    /// OpenCode wrote before 1.18. Kept as its own entry point because the
    /// tests pin it, and because "the key this account was given" is the one
    /// shape that has never moved.
    static func loadGoKey(from url: URL = authURL) -> Credential? {
        authEntry("opencode-go", from: url)
    }

    /// The `opencode` half of `auth.json` when it is still an OAuth sign-in.
    /// A non-console fallback only: an `oc_sk_` API key under the same id is
    /// chosen earlier, in `load`. OpenCode stops mirroring OAuth into the file
    /// once the database holds the sign-in, so this covers a machine whose
    /// `opencode.db` cannot be opened, and nothing else.
    static func loadOAuth(from url: URL = authURL) -> Credential? {
        guard let found = authEntry("opencode", from: url), found.oauth else { return nil }
        return found
    }

    /// The database. Read-only, and never `immutable` while OpenCode is
    /// running: that would ignore the write-ahead log and serve a token
    /// OpenCode has already rotated. `SQLiteStore` opens `mode=ro` first for
    /// that reason. Preference here is the pre-console order (Go key, then
    /// the other `opencode` row). `load` re-ranks these rows when one of them
    /// is a console key.
    static func loadFromDatabase(_ url: URL = databaseURL) -> Credential? {
        preferredDatabase(databaseCredentials(url))
    }

    private struct StoredCredential {
        let integrationID: String
        let credential: Credential
    }

    /// Active OpenCode rows, newest first. The active flag is honoured but a
    /// row that omits it counts as active: OpenCode has shipped both.
    /// Unreadable values are skipped, not fatal.
    private static func databaseCredentials(_ url: URL) -> [StoredCredential] {
        guard let db = SQLiteStore.open(url) else { return [] }
        defer { sqlite3_close(db) }

        let rows = SQLiteStore.rows(
            in: db,
            sql: """
            SELECT integration_id, value FROM credential
            WHERE integration_id IN ('opencode-go', 'opencode')
              AND COALESCE(active, 1) != 0
            ORDER BY time_updated DESC
            """,
            columns: 2
        )
        var stored: [StoredCredential] = []
        for row in rows {
            guard let value = try? JSONSerialization.jsonObject(with: Data(row[1].utf8)),
                  let found = credential(from: value, source: "OpenCode")
            else { continue }
            stored.append(StoredCredential(integrationID: row[0], credential: found))
        }
        return stored
    }

    /// Go key first, then the other `opencode` row — the same order the file
    /// sources use when neither is a console key. The first parseable row of
    /// that id wins, which is the newest because the query is
    /// `time_updated DESC`.
    private static func preferredDatabase(_ rows: [StoredCredential]) -> Credential? {
        for wanted in ["opencode-go", "opencode"] {
            if let found = rows.first(where: { $0.integrationID == wanted }) {
                return found.credential
            }
        }
        return nil
    }

    /// The first console key in source order. A newer non-console row of the
    /// same id does not hide an older `oc_sk_` row: any console key beats
    /// every credential that is not one.
    private static func consoleKey(
        in rows: [StoredCredential],
        fileAccount: Credential?,
        fileGo: Credential?
    ) -> Credential? {
        for wanted in ["opencode", "opencode-go"] {
            if let found = rows.first(where: {
                $0.integrationID == wanted && isConsoleKey($0.credential)
            }) {
                return found.credential
            }
        }
        if let fileAccount, isConsoleKey(fileAccount) { return fileAccount }
        if let fileGo, isConsoleKey(fileGo) { return fileGo }
        return nil
    }

    /// A console personal key: not OAuth, and issued with the `oc_sk_` prefix.
    /// An `sk-` token is the leftover Go key, whatever file it sits in.
    private static func isConsoleKey(_ credential: Credential) -> Bool {
        !credential.oauth && credential.token.hasPrefix("oc_sk_")
    }

    private static func authEntry(_ id: String, from url: URL) -> Credential? {
        guard let root = readJSON(at: url), let entry = root[id] else { return nil }
        return credential(from: entry, source: "OpenCode")
    }

    // MARK: - Shapes

    /// One stored credential value, in any of the shapes OpenCode has written:
    /// a bare string, `{"type":"api","key":…}`, or
    /// `{"type":"oauth","access":…,"expires":…,"metadata":{"orgID","server"}}`.
    static func credential(from entry: Any, source: String) -> Credential? {
        // A bare string is the key itself.
        if let token = nonEmpty(entry as? String) {
            return Credential(token: token, oauth: false, console: nil, org: nil,
                              expires: nil, source: source)
        }
        guard let object = entry as? [String: Any] else { return nil }

        if (object["type"] as? String) == "oauth" {
            guard let token = nonEmpty(object["access"] as? String) else { return nil }
            let metadata = object["metadata"] as? [String: Any]
            return Credential(
                token: token,
                oauth: true,
                console: nonEmpty(metadata?["server"] as? String).flatMap(URL.init(string:)),
                org: nonEmpty(metadata?["orgID"] as? String),
                // `expires` is a number in auth.json and a string in opencode.db.
                expires: milliseconds(object["expires"]),
                source: source
            )
        }

        let token = ["key", "apiKey", "api_key", "token", "accessToken"]
            .compactMap { nonEmpty(object[$0] as? String) }.first
        guard let token else { return nil }
        return Credential(token: token, oauth: false, console: nil, org: nil,
                          expires: nil, source: source)
    }

    // MARK: - Small helpers

    private static func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root
    }

    /// Non-empty, untrimmed-of-nothing: an empty key is worse than a missing
    /// one, it is a request that cannot succeed being sent all the same.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func milliseconds(_ value: Any?) -> Date? {
        let number: Double?
        if let text = value as? String {
            number = Double(text)
        } else {
            number = (value as? NSNumber)?.doubleValue
        }
        guard let number, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number / 1000)
    }
}
