import Foundation
import SQLite3

/// The credential OpenCode itself signed in with, borrowed — never written.
///
/// OpenCode 1.18 moved its sign-in into SQLite, and with OpenCode 2.x on the
/// machine the `auth.json` this used to read is simply gone. Two files, the
/// database first — it is the store OpenCode itself consults, and the only one
/// it keeps current:
///
/// 1. `opencode.db` → the `credential` table — either the Go plan's own API key
///    (`{"type":"api","key":…}`, a fresh `oc_sk_…` one once 2.x starts rotating
///    keys) or an `opencode` sign-in (`{"type":"oauth","access":…,"expires":…,
///    "metadata":{"server":…,"orgID":…}}`, or 2.x's plain-key shape of it);
/// 2. `auth.json` → the same two entries, both fallbacks now. OpenCode stopped
///    writing the file once the database held the sign-in, and 2.x leaves the
///    Go key it wrote before that **dead** — it answers 401 while the database
///    row answers 200 — so the file must never shadow a database that has a
///    row. It only serves machines whose database cannot be opened or holds no
///    sign-in at all.
///
/// Which one is found decides the usage endpoint, because each route refuses the
/// other's credential — see `OpenCodeProvider`. Only OpenCode's own two ids are
/// ever claimed; another integration's row (`openrouter`, `openai`, …) is that
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

    /// The two files above, database first. The order is the fix for OpenCode
    /// 2.x: it rotates the Go key into the database and leaves the key the
    /// pre-rotation `auth.json` holds answering 401, so a file-first order
    /// would keep sending a credential OpenCode itself has retired — a signed-in
    /// app reading as signed out. The file is only asked when the database has
    /// no answer: missing, unreadable, or carrying no OpenCode row.
    static func load(in directory: URL = dataDirectory) -> Credential? {
        if let stored = loadFromDatabase(directory.appendingPathComponent("opencode.db")) {
            return stored
        }
        let auth = directory.appendingPathComponent("auth.json")
        if let go = loadGoKey(from: auth) { return go }
        return loadOAuth(from: auth)
    }

    // MARK: - Sources

    /// The `opencode-go` half of `auth.json`: the Go plan's own API key, what
    /// OpenCode wrote before 1.18. Kept as its own entry point because the
    /// tests pin it, and because "the key this account was given" is the one
    /// shape that has never moved.
    static func loadGoKey(from url: URL = authURL) -> Credential? {
        guard let root = readJSON(at: url), let entry = root["opencode-go"] else { return nil }
        return credential(from: entry, source: "OpenCode")
    }

    /// The `opencode` half of `auth.json`: the OAuth sign-in mirrored into the
    /// file. A fallback only — OpenCode stops writing it once the database
    /// holds the sign-in, so this covers a machine whose `opencode.db` cannot
    /// be opened, and nothing else.
    static func loadOAuth(from url: URL = authURL) -> Credential? {
        guard let root = readJSON(at: url),
              let entry = root["opencode"],
              (entry as? [String: Any])?["type"] as? String == "oauth"
        else { return nil }
        return credential(from: entry, source: "OpenCode")
    }

    /// The database. Read-only, and never `immutable` while OpenCode is
    /// running: that would ignore the write-ahead log and serve a token
    /// OpenCode has already rotated. `SQLiteStore` opens `mode=ro` first for
    /// that reason.
    static func loadFromDatabase(_ url: URL = databaseURL) -> Credential? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }

        // Newest first, so a rotated sign-in beats the one it replaced. The
        // active flag is honoured but a row that omits it counts as active:
        // OpenCode has shipped both.
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
        // Go key first, then the OAuth sign-in: same order as the file sources,
        // so a machine holding both reads the same account either way.
        for wanted in ["opencode-go", "opencode"] {
            for row in rows where row[0] == wanted {
                guard let value = try? JSONSerialization.jsonObject(with: Data(row[1].utf8)),
                      let found = credential(from: value, source: "OpenCode")
                else { continue }
                return found
            }
        }
        return nil
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
