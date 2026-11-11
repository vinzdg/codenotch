import XCTest
import SQLite3
@testable import Codenotch

/// The Go plan windows, pinned to the live response (secret redacted) — the
/// same figures the OpenCode dashboard shows.
final class OpenCodeUsageTests: XCTestCase {
    /// Verbatim from `GET /zen/go/v1/usage`, 2026-09-06.
    private let payload = """
    {"usage":{\
    "rolling":{"status":"ok","percent":0,"resetsAt":"2026-09-06T12:31:06.611Z"},\
    "weekly":{"status":"ok","percent":0,"resetsAt":"2026-09-07T00:00:00.611Z"},\
    "monthly":{"status":"ok","percent":0,"resetsAt":"2026-10-03T13:09:45.611Z"}}}
    """

    func testReadsAllThreeWindows() throws {
        let w = try OpenCodeUsage.windows(fromJSON: payload)
        XCTAssertEqual(w.map(\.duration), [18000, 604800, 30 * 86400])
        XCTAssertEqual(w.map(\.id), ["rolling", "weekly", "monthly"])
        XCTAssertEqual(w.map(\.label), ["5h limit", "Weekly limit", "Monthly limit"])
        XCTAssertTrue(w.allSatisfy { ($0.usedFraction ?? -1) == 0 })
    }

    /// `percent` is used, matching the dashboard's "X% used" — the ring must
    /// not invert it.
    func testPercentIsUsedNotRemaining() throws {
        let json = """
        {"usage":{"rolling":{"status":"ok","percent":65,"resetsAt":"2026-09-06T12:31:06.611Z"}}}
        """
        let w = try OpenCodeUsage.windows(fromJSON: json)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].usedFraction ?? -1, 0.65, accuracy: 0.0001)
    }

    /// The reset carries milliseconds, which the plain ISO8601 formatter
    /// refuses — reading only that form silently loses every reset time.
    func testReadsAMillisecondResetTime() throws {
        let w = try OpenCodeUsage.windows(fromJSON: payload)
        let rolling = try XCTUnwrap(w.first { $0.id == "rolling" })
        let at = try XCTUnwrap(rolling.resetsAt)
        let plain = ISO8601DateFormatter().date(from: "2026-09-06T12:31:06Z")!
        XCTAssertEqual(at.timeIntervalSince1970, plain.timeIntervalSince1970, accuracy: 1)
    }

    /// A window without a percent is dropped rather than invented; with none
    /// left at all that is a bad response, not zeros.
    func testWindowsWithoutAPercentAreDropped() throws {
        let json = """
        {"usage":{"rolling":{"status":"ok"},"weekly":{"status":"ok","percent":3}}}
        """
        let w = try OpenCodeUsage.windows(fromJSON: json)
        XCTAssertEqual(w.map(\.id), ["weekly"])
    }

    func testAnEmptyUsageIsNotAReading() {
        for json in ["{}", #"{"usage":{}}"#,
                     #"{"usage":{"rolling":{"status":"ok"}}}"#] {
            XCTAssertThrowsError(try OpenCodeUsage.windows(fromJSON: json)) { error in
                guard case UsageProviderError.badResponse = error else {
                    return XCTFail("expected badResponse, got \(error)")
                }
            }
        }
    }
}

/// The credential is borrowed from OpenCode's own sign-in, so only OpenCode's
/// two ids may ever be claimed — any other entry is somebody else's account.
final class OpenCodeCredentialsTests: XCTestCase {
    private func file(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-auth-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testReadsTheGoKey() throws {
        let url = try file(#"{"opencode-go":{"type":"api","key":"sk-go-live"}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(OpenCodeCredentials.loadGoKey(from: url)?.token, "sk-go-live")
    }

    func testReadsABareStringEntry() throws {
        let url = try file(#"{"opencode-go":"sk-go-live"}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(OpenCodeCredentials.loadGoKey(from: url)?.token, "sk-go-live")
    }

    func testNeverClaimsAnotherVendorsKey() throws {
        let url = try file(
            #"{"openai":{"type":"api","key":"sk-openai"},"google":{"type":"api","key":"g-key"}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(OpenCodeCredentials.loadGoKey(from: url))
    }

    func testAnEmptyKeyIsMissing() throws {
        let url = try file(#"{"opencode-go":{"type":"api","key":""}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(OpenCodeCredentials.loadGoKey(from: url))
    }

    // MARK: - The OAuth sign-in OpenCode 1.18 moved into SQLite

    /// An OAuth sign-in carries an org and a console, and no Go key — which is
    /// the whole reason it needs a different endpoint.
    func testOAuthCarriesOrgConsoleAndExpiry() throws {
        let entry = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(#"""
        {"type":"oauth","methodID":"device","refresh":"rt_x","access":"st_abc",
         "expires":1792854570201,
         "metadata":{"server":"https://opencode.ai/console","orgID":"org_1",
                     "orgName":"Personal"}}
        """#.utf8)))
        let c = try XCTUnwrap(OpenCodeCredentials.credential(from: entry, source: "OpenCode"))
        XCTAssertEqual(c.token, "st_abc")
        XCTAssertTrue(c.oauth)
        XCTAssertEqual(c.org, "org_1")
        XCTAssertEqual(c.console?.absoluteString, "https://opencode.ai/console")
        XCTAssertEqual(c.expires?.timeIntervalSince1970 ?? 0, 1_792_854_570.201, accuracy: 0.001)
    }

    /// `expires` is a number in auth.json and a string in opencode.db; a reader
    /// that takes one shape silently loses the expiry hint on the other.
    func testTheDatabaseWritesExpiresAsAString() throws {
        let entry = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(#"{"type":"oauth","access":"st_abc","expires":"1792877970039"}"#.utf8)))
        let c = try XCTUnwrap(OpenCodeCredentials.credential(from: entry, source: "OpenCode"))
        XCTAssertEqual(c.expires?.timeIntervalSince1970 ?? 0, 1_792_877_970.039, accuracy: 0.001)
    }

    /// An OAuth entry with no access token is not a credential.
    func testAnOAuthEntryWithoutATokenIsMissing() {
        XCTAssertNil(OpenCodeCredentials.credential(
            from: ["type": "oauth", "access": ""], source: "OpenCode"))
    }

    /// The credential decides the route and each route refuses the other's, so
    /// this pairing is the fix rather than a detail.
    func testEachCredentialGoesToTheRouteThatAcceptsIt() {
        let oauth = OpenCodeCredentials.Credential(
            token: "st_x", oauth: true, console: nil, org: nil, expires: nil, source: "OpenCode")
        let key = OpenCodeCredentials.Credential(
            token: "sk-go", oauth: false, console: nil, org: nil, expires: nil, source: "OpenCode")
        XCTAssertEqual(OpenCodeProvider.endpoint(for: oauth).absoluteString,
                       "https://opencode.ai/inference/go/v1/usage")
        XCTAssertEqual(OpenCodeProvider.endpoint(for: key).absoluteString,
                       "https://opencode.ai/zen/go/v1/usage")
    }

    // MARK: - The database

    /// A `credential` table shaped as OpenCode writes it: values are JSON
    /// strings, and `active` is present on some rows and absent on others.
    private func database(
        _ rows: [(id: String, value: String, active: Int?, updated: Int)]
    ) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-\(UUID().uuidString).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE credential (id text PRIMARY KEY, integration_id text, label text NOT NULL,
         value text NOT NULL, connector_id text, method_id text, active integer,
         time_created integer NOT NULL, time_updated integer NOT NULL)
        """, nil, nil, nil), SQLITE_OK)
        for (index, row) in rows.enumerated() {
            let escaped = row.value.replacingOccurrences(of: "'", with: "''")
            let active = row.active.map(String.init) ?? "NULL"
            XCTAssertEqual(sqlite3_exec(db, """
            INSERT INTO credential VALUES ('cred_\(index)', '\(row.id)', 'x', '\(escaped)',
             NULL, NULL, \(active), 0, \(row.updated))
            """, nil, nil, nil), SQLITE_OK)
        }
        return url
    }

    /// The case that broke the ring: no `auth.json` at all, only the database
    /// OpenCode 1.18+ writes.
    func testReadsTheSignInFromTheDatabaseAlone() throws {
        let db = try database([("opencode",
            #"{"type":"oauth","access":"st_new","metadata":{"orgID":"org_1"}}"#, 1, 3)])
        defer { try? FileManager.default.removeItem(at: db) }

        let c = try XCTUnwrap(OpenCodeCredentials.loadFromDatabase(db))
        XCTAssertEqual(c.token, "st_new")
        XCTAssertTrue(c.oauth)
        XCTAssertEqual(c.org, "org_1")
    }

    /// The combined loader, on a directory holding the database and nothing
    /// else — no `auth.json` anywhere.
    func testTheCombinedLoaderFindsTheDatabaseAlone() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let db = try database([("opencode", #"{"type":"oauth","access":"st_new"}"#, 1, 3)])
        defer { try? FileManager.default.removeItem(at: db) }
        try FileManager.default.copyItem(at: db, to: directory.appendingPathComponent("opencode.db"))

        XCTAssertEqual(OpenCodeCredentials.load(in: directory)?.token, "st_new")
    }

    // MARK: - Which source wins

    /// The case OpenCode 2.x made common: a key left in `auth.json` by a
    /// pre-rotation OpenCode, and a fresh one in the database. The file's key
    /// answers 401 once OpenCode rotates past it, while the database's answers
    /// 200 — so the file must never shadow a database that has a row, however
    /// much older the file's habit of being read first is.
    func testTheDatabaseBeatsAStaleFileKey() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try #"{"opencode-go":{"type":"api","key":"sk-stale"}}"#
            .write(to: directory.appendingPathComponent("auth.json"), atomically: true,
                   encoding: .utf8)
        let db = try database([("opencode-go", #"{"type":"api","key":"oc_sk_live"}"#, 1, 3)])
        defer { try? FileManager.default.removeItem(at: db) }
        try FileManager.default.copyItem(at: db, to: directory.appendingPathComponent("opencode.db"))

        XCTAssertEqual(OpenCodeCredentials.load(in: directory)?.token, "oc_sk_live")
    }

    /// A file with no database behind it — the pre-1.18 machine, or one whose
    /// database cannot be opened — still reads. The reorder must not trade the
    /// 2.x fix for this one.
    func testTheFileStillServesWhenTheDatabaseIsMissing() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try #"{"opencode-go":{"type":"api","key":"sk-file-only"}}"#
            .write(to: directory.appendingPathComponent("auth.json"), atomically: true,
                   encoding: .utf8)

        XCTAssertEqual(OpenCodeCredentials.load(in: directory)?.token, "sk-file-only")
    }

    /// A database carrying no OpenCode row — signed out in the app, say — does
    /// not hide a legacy sign-in the file still holds: with no answer of its
    /// own, the database is only ever allowed to pass the question to the file.
    func testADatabaseWithoutASignInFallsBackToTheFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try #"{"opencode-go":{"type":"api","key":"sk-legacy"}}"#
            .write(to: directory.appendingPathComponent("auth.json"), atomically: true,
                   encoding: .utf8)
        let db = try database([("openrouter", #"{"type":"api","key":"sk-or"}"#, 1, 3)])
        defer { try? FileManager.default.removeItem(at: db) }
        try FileManager.default.copyItem(at: db, to: directory.appendingPathComponent("opencode.db"))

        XCTAssertEqual(OpenCodeCredentials.load(in: directory)?.token, "sk-legacy")
    }

    func testTheDatabaseNeverClaimsAnotherVendorsRow() throws {
        let db = try database([("openrouter", #"{"type":"api","key":"sk-or"}"#, nil, 5)])
        defer { try? FileManager.default.removeItem(at: db) }
        XCTAssertNil(OpenCodeCredentials.loadFromDatabase(db))
    }

    /// A Go key beats an OAuth sign-in even when the OAuth row is newer, so a
    /// machine holding both reads the same account whichever file is consulted.
    func testTheDatabasePrefersAGoKey() throws {
        let db = try database([
            ("opencode", #"{"type":"oauth","access":"st_oauth"}"#, 1, 9),
            ("opencode-go", #"{"type":"api","key":"sk-go"}"#, nil, 1),
        ])
        defer { try? FileManager.default.removeItem(at: db) }
        let c = try XCTUnwrap(OpenCodeCredentials.loadFromDatabase(db))
        XCTAssertEqual(c.token, "sk-go")
        XCTAssertFalse(c.oauth)
    }

    /// A row OpenCode has retired is not a sign-in. A row that omits `active`
    /// entirely still is — both shapes have shipped.
    func testTheDatabaseSkipsRetiredRows() throws {
        let db = try database([
            ("opencode", #"{"type":"oauth","access":"st_old"}"#, 0, 9),
            ("opencode", #"{"type":"oauth","access":"st_live"}"#, nil, 1),
        ])
        defer { try? FileManager.default.removeItem(at: db) }
        XCTAssertEqual(OpenCodeCredentials.loadFromDatabase(db)?.token, "st_live")
    }

    // MARK: - Presence

    /// Installed-but-signed-out and never-installed are different answers, so
    /// presence is asked of the files rather than of the credential.
    func testPresenceNeedsEitherFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(OpenCodeCredentials.present(in: directory))

        try Data().write(to: directory.appendingPathComponent("opencode.db"))
        XCTAssertTrue(OpenCodeCredentials.present(in: directory))
    }
}
