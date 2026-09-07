import SQLite3
import XCTest
@testable import Codenotch

/// Pinned to a response recorded from a live free account. `/api/usage-summary`
/// is not a documented API, so this is what fails first if it changes.
final class CursorUsageTests: XCTestCase {
    /// Verbatim, from the account the editor is signed into.
    private let recorded = """
    {"billingCycleStart":"2026-08-24T03:32:15.933Z",
     "billingCycleEnd":"2026-09-24T03:32:15.933Z",
     "membershipType":"free","limitType":"user","isUnlimited":false,
     "autoModelSelectedDisplayMessage":"You've used 10% of your included total usage",
     "namedModelSelectedDisplayMessage":"You've used 19% of your included API usage",
     "individualUsage":{
       "plan":{"enabled":true,"used":0,"limit":0,"remaining":0,
               "breakdown":{"included":0,"bonus":19,"total":19},
               "autoPercentUsed":0,"apiPercentUsed":19,"totalPercentUsed":9.5},
       "onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}},
     "teamUsage":{}}
    """

    private func windows(_ json: String) throws -> [LimitWindow] {
        try CursorUsage.windows(fromJSON: json)
    }

    /// The bug this replaced: `used`/`limit` are both zero on a free plan even
    /// while real usage is happening, because the allowance arrives as
    /// `breakdown.bonus`. Reading them reported 0% for an account 10% through
    /// its month. `totalPercentUsed` is what the dashboard actually shows.
    func testReadsThePercentageTheDashboardShows() throws {
        let w = try windows(recorded)
        XCTAssertEqual(w[0].id, "included")
        XCTAssertEqual(w[0].label, "Included usage")
        XCTAssertEqual(w[0].usedFraction ?? -1, 0.095, accuracy: 0.0001)
        XCTAssertEqual(w[0].summary, "10% Used · 90% left",
                       "should round the way Cursor does, and show both ends")
    }

    func testApiUsageIsReportedSeparately() throws {
        let w = try windows(recorded)
        XCTAssertEqual(w.map(\.id), ["included", "api"])
        XCTAssertEqual(w[1].usedFraction ?? -1, 0.19, accuracy: 0.0001)
    }

    /// It is only worth a row when it has actually been touched.
    func testZeroApiUsageIsOmitted() throws {
        let json = """
        {"individualUsage":{"plan":{"totalPercentUsed":4,"apiPercentUsed":0}}}
        """
        XCTAssertEqual(try windows(json).map(\.id), ["included"])
    }

    /// The reset is Cursor's own `billingCycleEnd` — Sep 24 here, which is what
    /// the dashboard prints, and is *not* a month after `billingCycleStart`.
    func testResetComesFromTheBillingCycleEnd() throws {
        let reset = try XCTUnwrap(windows(recorded)[0].resetsAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.component(.month, from: reset), 9)
        XCTAssertEqual(calendar.component(.day, from: reset), 24)
    }

    func testOnDemandOnlyCountsWhenSwitchedOnWithACeiling() throws {
        let on = """
        {"individualUsage":{"plan":{"totalPercentUsed":5},
                            "onDemand":{"enabled":true,"used":3,"limit":50}}}
        """
        XCTAssertEqual(try windows(on).map(\.id), ["included", "on_demand"])

        let off = """
        {"individualUsage":{"plan":{"totalPercentUsed":5},
                            "onDemand":{"enabled":false,"used":0,"limit":null}}}
        """
        XCTAssertEqual(try windows(off).map(\.id), ["included"])
    }

    func testNothingMeteredRatherThanAFalseZero() {
        let json = #"{"membershipType":"free","individualUsage":{"plan":{}}}"#
        XCTAssertThrowsError(try windows(json)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testRejectsRubbish() {
        XCTAssertThrowsError(try windows("not json"))
    }
}

/// Borrowing the editor's session is what stops the notch reporting a different
/// account's usage — signing into cursor.com separately made a second, empty one.
/// The CLI session is the same cookie, reached only when the editor has none.
final class CursorCredentialsTests: XCTestCase {
    func testCookieIsTheAccountAndTokenPair() {
        let credentials = CursorCredentials(accountID: "google-oauth2|user_ABC", accessToken: "tok")
        XCTAssertEqual(credentials.sessionCookie, "WorkosCursorSessionToken=google-oauth2|user_ABC::tok")
    }

    func testAMissingStoreMeansSignedOutRatherThanAnError() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).vscdb")
        XCTAssertThrowsError(try CursorCredentials.load(from: missing)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    /// The editor path must not become a live keychain read. A missing store
    /// with no agent token is still signed out, even on a machine that has
    /// `cursor-agent` installed.
    func testAMissingEditorAndNoAgentTokenIsSignedOut() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).vscdb")
        let config = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).json")
        XCTAssertThrowsError(
            try CursorCredentials.load(editorStore: missing, agentToken: nil, agentConfig: config)
        ) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testAgentCookieUsesAuthIdFromCliConfig() throws {
        let token = Self.jwt(sub: "auth0|user_JWT", exp: Date().timeIntervalSince1970 + 3600)
        let config = try writeAgentConfig(authId: "auth0|user_CLI", userId: 42, email: "cli@example.com")
        defer { try? FileManager.default.removeItem(at: config) }

        let credentials = try CursorCredentials.session(fromAgentToken: token, configURL: config)
        XCTAssertEqual(credentials.accountID, "auth0|user_CLI")
        XCTAssertEqual(credentials.sessionCookie,
                       "WorkosCursorSessionToken=auth0|user_CLI::\(token)")
    }

    /// Numeric userId is accepted by the same endpoint, and is what remains
    /// when an older config has no authId.
    func testAgentAccountIDFallsBackToUserIdThenJWTSub() throws {
        let token = Self.jwt(sub: "auth0|user_JWT", exp: Date().timeIntervalSince1970 + 3600)

        let withUser = try writeAgentConfig(authId: nil, userId: 99, email: "cli@example.com")
        defer { try? FileManager.default.removeItem(at: withUser) }
        XCTAssertEqual(CursorCredentials.agentAccountID(token: token, configURL: withUser), "99")

        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).json")
        XCTAssertEqual(CursorCredentials.agentAccountID(token: token, configURL: missing),
                       "auth0|user_JWT")
    }

    func testExpiredAgentTokenKeepsTheLastReading() {
        let token = Self.jwt(sub: "auth0|user_JWT", exp: 1)
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).json")
        XCTAssertThrowsError(
            try CursorCredentials.session(fromAgentToken: token, configURL: missing)
        ) { error in
            guard case UsageProviderError.credentialExpired = error else {
                return XCTFail("expected credentialExpired, got \(error)")
            }
        }
    }

    func testAgentAccountReadsEmailFromCliConfig() throws {
        let config = try writeAgentConfig(authId: "auth0|user_CLI", userId: 1, email: "cli@example.com")
        defer { try? FileManager.default.removeItem(at: config) }

        let account = try XCTUnwrap(CursorCredentials.agentAccount(from: config))
        XCTAssertEqual(account.label, "cli@example.com")
        XCTAssertEqual(account.source, "cursor-agent")
    }

    /// A signed-in editor wins so a laptop with both tools cannot flip
    /// accounts depending on which file we happened to read.
    func testTheEditorSessionIsPreferredOverTheAgent() throws {
        let store = try writeEditorStore(account: "auth0|user_EDITOR", token: "editor-tok")
        defer { try? FileManager.default.removeItem(at: store) }
        let token = Self.jwt(sub: "auth0|user_JWT", exp: Date().timeIntervalSince1970 + 3600)
        let config = try writeAgentConfig(authId: "auth0|user_CLI", userId: 1, email: "cli@example.com")
        defer { try? FileManager.default.removeItem(at: config) }

        let credentials = try CursorCredentials.load(editorStore: store, agentToken: token,
                                                     agentConfig: config)
        XCTAssertEqual(credentials.sessionCookie,
                       "WorkosCursorSessionToken=auth0|user_EDITOR::editor-tok")
    }

    func testAMissingEditorFallsThroughToTheAgent() throws {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).vscdb")
        let token = Self.jwt(sub: "auth0|user_JWT", exp: Date().timeIntervalSince1970 + 3600)
        let config = try writeAgentConfig(authId: "auth0|user_CLI", userId: 1, email: "cli@example.com")
        defer { try? FileManager.default.removeItem(at: config) }

        let credentials = try CursorCredentials.load(editorStore: missing, agentToken: token,
                                                     agentConfig: config)
        XCTAssertEqual(credentials.accountID, "auth0|user_CLI")
        XCTAssertEqual(credentials.accessToken, token)
    }

    func testSignInOpensTheEditorWhenItIsInstalled() {
        guard case .openApp(let bundleID, let name) =
                CursorCredentials.signInRoute(editorInstalled: true) else {
            return XCTFail("expected openApp")
        }
        XCTAssertEqual(bundleID, CursorCredentials.bundleID)
        XCTAssertEqual(name, "Cursor")
    }

    func testSignInNamesTheCLIWhenTheEditorIsMissing() {
        guard case .guidance(let text) =
                CursorCredentials.signInRoute(editorInstalled: false) else {
            return XCTFail("expected guidance")
        }
        XCTAssertTrue(text.contains("cursor-agent login"), text)
    }

    private func writeAgentConfig(authId: String?, userId: Int, email: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-cli-\(UUID().uuidString).json")
        var authInfo: [String: Any] = ["email": email, "userId": userId]
        if let authId { authInfo["authId"] = authId }
        try JSONSerialization.data(withJSONObject: ["authInfo": authInfo])
            .write(to: url)
        return url
    }

    private func writeEditorStore(account: String, token: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-\(UUID().uuidString).vscdb")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT, value TEXT);", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)');",
                     nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipAuthId', '\(account)');",
                     nil, nil, nil)
        sqlite3_close(db)
        return url
    }

    /// Unsigned, for tests only. The server never sees these; they exist so
    /// expiry and `sub` can be pinned without a live keychain item.
    private static func jwt(sub: String, exp: TimeInterval) -> String {
        func encode(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
        return encode(["alg": "none", "typ": "JWT"])
            + "." + encode(["sub": sub, "exp": exp])
            + ".sig"
    }
}

/// Confirmed against a real account switched mid-cycle: Cursor reports 0% and
/// means it. An earlier version suppressed this as "no allowance to be a
/// percentage of", which hid a correct reading — Cursor's own response says
/// "You've used 0% of your included total usage" in the same payload.
final class CursorZeroUsageTests: XCTestCase {
    /// Verbatim from a live free account, just after signing into a new one.
    private let freePlan = """
    {"billingCycleEnd":"2026-09-20T01:35:15.142Z","membershipType":"free","isUnlimited":false,
     "autoModelSelectedDisplayMessage":"You've used 0% of your included total usage",
     "individualUsage":{"plan":{"enabled":true,"used":0,"limit":0,"remaining":0,
       "breakdown":{"included":0,"bonus":0,"total":0},
       "autoPercentUsed":0,"apiPercentUsed":0,"totalPercentUsed":0},
      "onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}}}
    """

    func testZeroPercentIsShownRatherThanSuppressed() throws {
        let windows = try CursorUsage.windows(fromJSON: freePlan)
        XCTAssertEqual(windows.first?.id, "included")
        XCTAssertEqual(windows.first?.usedFraction, 0)
    }

    func testItStillReadsARealPercentage() throws {
        let used = freePlan.replacingOccurrences(of: "\"totalPercentUsed\":0",
                                                 with: "\"totalPercentUsed\":34")
        let windows = try CursorUsage.windows(fromJSON: used)
        XCTAssertEqual(windows.first?.usedFraction ?? 0, 0.34, accuracy: 0.0001)
    }
}
