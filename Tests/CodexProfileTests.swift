import SQLite3
import XCTest
@testable import Codenotch

final class CodexProfileTests: XCTestCase {
    private func home(_ layout: [String: [String]] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexProfileTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (directory, files) in layout {
            let url = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for file in files {
                let path = url.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data().write(to: path)
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func archive() -> UsageArchive {
        let name = "CodexProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return UsageArchive(defaults: defaults)
    }

    private func writeAuth(_ profile: CodexProfile, account: String, token: String = "fake") throws {
        let claims: [String: Any] = ["email": "\(account)@example.test",
                                   "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
        let auth = ["tokens": ["access_token": token, "account_id": account,
                               "id_token": "header.\(payload).signature"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: profile.authURL)
    }

    func testDefaultIdentityAndPathsStayCompatible() {
        let profile = CodexProfile.default(home: URL(fileURLWithPath: "/Users/test"))
        XCTAssertEqual(profile.id, "codex")
        XCTAssertEqual(profile.displayName, "Codex")
        XCTAssertEqual(profile.authURL.path, "/Users/test/.codex/auth.json")
        XCTAssertEqual(profile.stateURL.path, "/Users/test/.codex/state_5.sqlite")
        XCTAssertEqual(profile.desktopStoreURL.path, "/Users/test/.codex/sqlite/codex-dev.db")
        XCTAssertEqual(CodexLocalProvider(profile: profile).signInRoute,
                       .openApp(bundleID: "com.openai.codex", name: "Codex"))
    }

    func testDiscoveryIsStableAndIgnoresUnrelatedFiles() throws {
        let root = try home([".codex-work": ["auth.json"], ".codex-alpha": ["config.toml"],
                             ".codex-empty": [], ".codex-notes": ["README.md"],
                             ".codex-": ["auth.json"], "codex-other": ["auth.json"]])
        try Data().write(to: root.appendingPathComponent(".codex-file"))
        let found = CodexProfile.discover(home: root)
        XCTAssertEqual(found.map(\.id), ["codex", "codex-alpha", "codex-work"])
        XCTAssertEqual(found.map(\.displayName), ["Codex", "Codex (alpha)", "Codex (work)"])
        XCTAssertEqual(found[2].authURL, root.appendingPathComponent(".codex-work/auth.json"))
    }

    func testSignedOutProfilesAndMissingHomeAreSupported() throws {
        let root = try home([".codex-a": ["sessions"], ".codex-b": ["history.jsonl"],
                             ".codex-c": ["state_5.sqlite"], ".codex-d": ["sqlite/codex-dev.db"]])
        XCTAssertEqual(CodexProfile.discover(home: root).map(\.id),
                       ["codex", "codex-a", "codex-b", "codex-c", "codex-d"])
        XCTAssertEqual(CodexProfile.discover(home: root.appendingPathComponent("missing")).map(\.id),
                       ["codex"])
    }

    func testSignInNamesAndQuotesTheCorrectProfile() {
        let profile = CodexProfile(slug: "work", configDirectory: URL(fileURLWithPath: "/Users/O'Brien/.codex-work"))
        XCTAssertEqual(profile.signInCommand,
                       "CODEX_HOME='/Users/O'\"'\"'Brien/.codex-work' codex -c 'cli_auth_credentials_store=\"file\"' login")
        let provider = CodexLocalProvider(profile: profile)
        XCTAssertEqual(provider.signInRoute,
                       .command(profile.signInCommand, name: "Codex (work)",
                                install: URL(string: "https://developers.openai.com/codex/cli")))
        let snapshot = ProviderSnapshot(id: profile.id, displayName: profile.displayName,
                                        glyph: .openai, fidelity: .official, status: .needsAuth, windows: [])
        XCTAssertEqual(snapshot.statusMessage, "Sign in to Codex in ~/.codex-work to read your usage")
        XCTAssertNil(CodexProfile.slug(fromProviderID: "codex-"))
        XCTAssertNil(CodexProfile.slug(fromProviderID: "codextra"))
    }

    func testAccountLabelsComeFromEachProfilesCredentials() throws {
        let root = try home([".codex": [], ".codex-work": []])
        let personal = CodexProfile.default(home: root)
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        try writeAuth(personal, account: "personal")
        try writeAuth(work, account: "work")
        XCTAssertEqual(CodexLocalProvider(profile: personal).account()?.label, "personal@example.test")
        XCTAssertEqual(CodexLocalProvider(profile: work).account()?.label, "work@example.test")
        XCTAssertEqual(CodexLocalProvider(profile: work).account()?.source, "Codex in \(work.displayPath)")
        try FileManager.default.removeItem(at: work.authURL)
        XCTAssertNil(CodexLocalProvider(profile: work).account(), "must never fall back to the default account")
    }

    func testRequestsAndSnapshotsAreIsolatedAndTokensAreReread() async throws {
        let root = try home([".codex": [], ".codex-work": []])
        let personal = CodexProfile.default(home: root)
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        try writeAuth(personal, account: "personal", token: "personal-token")
        try writeAuth(work, account: "work", token: "work-token")
        let session = CodexProfileEndpoint.session()
        defer { session.invalidateAndCancel() }
        let archive = archive()
        let p = CodexLocalProvider(profile: personal, session: session, archive: archive)
        let w = CodexLocalProvider(profile: work, session: session, archive: archive)
        let personalReading = try await p.fetchSnapshot()
        let workReading = try await w.fetchSnapshot()
        XCTAssertEqual(personalReading.id, "codex")
        XCTAssertEqual(personalReading.usedFraction, 0.10)
        XCTAssertEqual(workReading.id, "codex-work")
        XCTAssertEqual(workReading.usedFraction, 0.75)

        try writeAuth(work, account: "work", token: "rotated-token")
        let rotated = try await w.fetchSnapshot()
        XCTAssertEqual(rotated.usedFraction, 0.80)
        let unchanged = try CodexCredentials.load(from: personal.authURL)
        XCTAssertEqual(unchanged.accessToken, "personal-token")
    }

    func testMissingProfileCredentialsNeverUseAnotherAccount() async throws {
        let root = try home([".codex": [], ".codex-work": []])
        try writeAuth(.default(home: root), account: "personal", token: "personal-token")
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        let session = CodexProfileEndpoint.session()
        defer { session.invalidateAndCancel() }
        let provider = CodexLocalProvider(profile: work, session: session, archive: archive())
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("A missing work login must not return the personal reading")
        } catch UsageProviderError.needsAuth {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRateLimitSurvivesRecreationWithoutBlockingTheDefault() async throws {
        let root = try home([".codex": [], ".codex-work": []])
        let personal = CodexProfile.default(home: root)
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        try writeAuth(personal, account: "personal", token: "personal-token")
        try writeAuth(work, account: "work", token: "limited-token")
        let archive = archive()
        let session = CodexProfileEndpoint.session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await CodexLocalProvider(profile: work, session: session, archive: archive).fetchSnapshot()
            XCTFail("Expected the work account's rate limit")
        } catch UsageProviderError.rateLimited {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNotNil(archive.loadBackoffUntil(providerID: work.id))
        XCTAssertNil(archive.loadBackoffUntil(providerID: personal.id))
        // A fresh token would succeed on the stub; the persisted deadline must prevent that request.
        try writeAuth(work, account: "work", token: "work-token")
        do {
            _ = try await CodexLocalProvider(profile: work, session: session, archive: archive).fetchSnapshot()
            XCTFail("Recreating the provider bypassed the persisted deadline")
        } catch UsageProviderError.rateLimited {} catch { XCTFail("Unexpected error: \(error)") }
        let reading = try await CodexLocalProvider(profile: personal, session: session, archive: archive).fetchSnapshot()
        XCTAssertEqual(reading.usedFraction, 0.10)
        XCTAssertNotNil(archive.loadBackoffUntil(providerID: work.id), "success for personal must not clear work backoff")
    }

    @MainActor
    func testTwoProfilesKeepTheirOrderAndDisconnectIndependently() async throws {
        let root = try home([".codex": [], ".codex-work": []])
        let personal = CodexProfile.default(home: root)
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        try writeAuth(personal, account: "personal", token: "personal-token")
        try writeAuth(work, account: "work", token: "work-token")
        let originalAuth = try Data(contentsOf: work.authURL)
        let archive = archive()
        let session = CodexProfileEndpoint.session()
        defer { session.invalidateAndCancel() }
        let providers: [UsageProvider] = [personal, work].map {
            CodexLocalProvider(profile: $0, session: session, archive: archive)
        }
        let store = UsageStore(providers: providers, archive: archive, order: [work.id, personal.id])
        await store.refresh()
        XCTAssertEqual(store.snapshots.map(\.id), [work.id, personal.id])
        XCTAssertEqual(store.providerSummaries.map(\.account?.label), ["work@example.test", "personal@example.test"])
        XCTAssertEqual(Set(archive.load().keys), Set([work.id, personal.id]))
        // Rebuilding with a disconnected profile exercises the same startup path as the app.
        let restarted = UsageStore(providers: providers, archive: archive, disconnected: [work.id])
        await restarted.refresh()
        XCTAssertEqual(restarted.snapshots.map(\.id), [personal.id])
        XCTAssertNil(archive.load()[work.id])
        XCTAssertNotNil(archive.load()[personal.id])
        XCTAssertEqual(try Data(contentsOf: work.authURL), originalAuth)
    }

    @MainActor
    func testActivityUsesEachProfilesStoreAndDistinctSessionIDs() throws {
        let root = try home([".codex": [], ".codex-work": []])
        let personal = CodexProfile.default(home: root)
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        try catalogue(profile: personal, title: "Personal task")
        try catalogue(profile: work, title: "Work task")
        let p = CodexActivityMonitor(profile: personal)
        let w = CodexActivityMonitor(profile: work)
        p.start(); w.start()
        defer { p.stop(); w.stop() }
        XCTAssertEqual(p.sessions.map(\.id), ["codex.desktop"])
        XCTAssertEqual(w.sessions.map(\.id), ["codex-work.desktop"])
        XCTAssertEqual(p.sessions.map(\.name), ["Personal task"])
        XCTAssertEqual(w.sessions.map(\.name), ["Work task"])
    }

    private func catalogue(profile: CodexProfile, title: String) throws {
        try FileManager.default.createDirectory(at: profile.desktopStoreURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(profile.desktopStoreURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE local_thread_catalog (source_updated_at REAL, display_title TEXT, thread_id TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO local_thread_catalog VALUES (\(Date().timeIntervalSince1970), '\(title)', 'test')", nil, nil, nil), SQLITE_OK)
    }

    @MainActor
    func testCLIActivityWithTheSameRolloutFilenameDoesNotCollide() throws {
        let root = try home([".codex": [], ".codex-work": []])
        let personal = CodexProfile.default(home: root)
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        for profile in [personal, work] {
            let rollout = profile.configDirectory.appendingPathComponent("rollout.jsonl")
            try Data().write(to: rollout)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(profile.stateURL.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (rollout_path TEXT, archived INTEGER, updated_at_ms INTEGER)", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('\(rollout.path)', 0, 1)", nil, nil, nil), SQLITE_OK)
        }
        let p = CodexActivityMonitor(profile: personal)
        let w = CodexActivityMonitor(profile: work)
        p.start(); w.start()
        defer { p.stop(); w.stop() }
        XCTAssertEqual(p.sessions.map(\.id), ["codex.rollout.jsonl"])
        XCTAssertEqual(w.sessions.map(\.id), ["codex-work.rollout.jsonl"])
        XCTAssertEqual(w.sessions.map(\.name), ["Codex (work)"])
    }

    func testCodexAuthRegistryParsingAndPreferredSlugs() throws {
        let json = """
        {
          "schema_version": 1,
          "command": "list",
          "accounts": [
            {
              "number": 1,
              "account_key": "user-abc::account-123",
              "email": "work@example.com",
              "alias": "work",
              "account_name": "Work Account",
              "plan": "business",
              "auth_mode": "chatgpt",
              "access_token_expires_at": 1711900000,
              "plan_expires_at": 1743400000,
              "active": true
            },
            {
              "number": 2,
              "account_key": "user-def::account-456",
              "email": "personal@example.com",
              "alias": null,
              "account_name": null,
              "plan": "plus",
              "auth_mode": "chatgpt",
              "access_token_expires_at": null,
              "plan_expires_at": null,
              "active": false
            }
          ]
        }
        """.data(using: .utf8)!

        let registry = try JSONDecoder().decode(CodexAuthRegistry.self, from: json)
        XCTAssertEqual(registry.schemaVersion, 1)
        XCTAssertEqual(registry.command, "list")
        XCTAssertEqual(registry.accounts.count, 2)
        XCTAssertEqual(registry.accounts[0].alias, "work")
        XCTAssertEqual(registry.accounts[0].plan, "business")
        XCTAssertTrue(registry.accounts[0].active)
        XCTAssertFalse(registry.accounts[1].active)

        let slug0 = CodexAuthRegistry.preferredSlug(for: registry.accounts[0])
        XCTAssertEqual(slug0, "work")
        let slug1 = CodexAuthRegistry.preferredSlug(for: registry.accounts[1], existingSlugs: [slug0])
        XCTAssertEqual(slug1, "personal")
    }

    func testCodexAuthProfileDiscoveryAndRoutes() throws {
        let root = try home([".codex": []])
        let registryData = """
        {
          "schema_version": 1,
          "accounts": [
            {
              "account_key": "acc-1",
              "email": "work@example.test",
              "alias": "work",
              "plan": "business",
              "active": true
            },
            {
              "account_key": "acc-2",
              "email": "personal@example.test",
              "alias": "personal",
              "plan": "plus",
              "active": false
            }
          ]
        }
        """.data(using: .utf8)!

        let registryURL = root.appendingPathComponent(".codex/registry.json")
        try registryData.write(to: registryURL)

        let found = CodexProfile.discover(home: root)
        XCTAssertEqual(found.map(\.id), ["codex-personal", "codex-work"])
        XCTAssertEqual(found.map(\.displayName), ["Codex (personal)", "Codex (work)"])
        XCTAssertTrue(found.allSatisfy(\.isCodexAuth))

        let personal = found[0]
        let work = found[1]

        XCTAssertEqual(personal.signInCommand, "codex-auth switch 'personal'")
        XCTAssertEqual(work.signInCommand, "codex-auth switch 'work'")

        let personalProvider = CodexLocalProvider(profile: personal)
        XCTAssertEqual(personalProvider.signInRoute.actionTitle, "Switch to Codex (personal)")
        if TerminalCommand.isInstalled(command: personal.signInCommand) {
            XCTAssertEqual(personalProvider.signInRoute.explanation,
                           "Runs codex-auth switch 'personal' in your terminal to switch the active account.")
        } else {
            XCTAssertEqual(personalProvider.signInRoute.explanation,
                           "Install the Codex (personal) CLI first; Sign in opens its install page.")
        }
    }

    func testCodexAuthLocalProviderActiveVsInactiveIsolation() async throws {
        let root = try home([".codex": []])
        let registryURL = root.appendingPathComponent(".codex/registry.json")

        func writeRegistry(workActive: Bool) throws {
            let json = """
            {
              "schema_version": 1,
              "accounts": [
                {
                  "account_key": "work-key",
                  "email": "work@example.test",
                  "alias": "work",
                  "plan": "business",
                  "active": \(workActive)
                },
                {
                  "account_key": "personal-key",
                  "email": "personal@example.test",
                  "alias": "personal",
                  "plan": "plus",
                  "active": \(!workActive)
                }
              ]
            }
            """.data(using: .utf8)!
            try json.write(to: registryURL)
        }

        try writeRegistry(workActive: true)
        let found = CodexProfile.discover(home: root)
        let personal = found.first(where: { $0.slug == "personal" })!
        let work = found.first(where: { $0.slug == "work" })!

        // Currently work is active; write work's tokens to auth.json
        try writeAuth(work, account: "work", token: "work-token")

        let session = CodexProfileEndpoint.session()
        defer { session.invalidateAndCancel() }
        let archive = archive()

        let workProvider = CodexLocalProvider(profile: work, session: session, archive: archive)
        let personalProvider = CodexLocalProvider(profile: personal, session: session, archive: archive)

        // Work provider is active: fetchSnapshot succeeds with live usage
        let workSnapshot = try await workProvider.fetchSnapshot()
        XCTAssertEqual(workSnapshot.id, "codex-work")
        XCTAssertEqual(workSnapshot.usedFraction, 0.75)
        XCTAssertEqual(workProvider.account()?.label, "work@example.test")
        XCTAssertEqual(workProvider.account()?.plan, "plus")

        // Personal provider is inactive: fetchSnapshot throws needsAuth and does NOT leak work credentials
        do {
            _ = try await personalProvider.fetchSnapshot()
            XCTFail("Inactive codex-auth account must not read the active account's credentials")
        } catch UsageProviderError.needsAuth {} catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Even though inactive, personal provider still surfaces its plan and email metadata from registry
        let personalAccount = personalProvider.account()
        XCTAssertEqual(personalAccount?.label, "personal@example.test")
        XCTAssertEqual(personalAccount?.plan, "plus")

        // Status message indicates switching via codex-auth
        let inactiveSnapshot = ProviderSnapshot(id: personal.id, displayName: personal.displayName,
                                                glyph: .openai, fidelity: .official, status: .needsAuth, windows: [],
                                                customStatusMessage: "Switch to this account with codex-auth to read your usage")
        XCTAssertEqual(inactiveSnapshot.statusMessage, "Switch to this account with codex-auth to read your usage")

        // Now simulate switching active account in registry.json (e.g. via `codex-auth switch personal`)
        try writeRegistry(workActive: false)
        try writeAuth(personal, account: "personal", token: "personal-token")

        // Personal is now active: fetchSnapshot succeeds
        let personalSnapshot = try await personalProvider.fetchSnapshot()
        XCTAssertEqual(personalSnapshot.id, "codex-personal")
        XCTAssertEqual(personalSnapshot.usedFraction, 0.10)

        // Work is now inactive: fetchSnapshot throws needsAuth
        do {
            _ = try await workProvider.fetchSnapshot()
            XCTFail("Demoted work account must not read personal credentials")
        } catch UsageProviderError.needsAuth {} catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCodexAuthActivityMonitorIgnoresInactiveAccount() throws {
        let root = try home([".codex": []])
        let registryURL = root.appendingPathComponent(".codex/registry.json")
        let json = """
        {
          "schema_version": 1,
          "accounts": [
            {
              "account_key": "work-key",
              "alias": "work",
              "active": true
            },
            {
              "account_key": "personal-key",
              "alias": "personal",
              "active": false
            }
          ]
        }
        """.data(using: .utf8)!
        try json.write(to: registryURL)

        let found = CodexProfile.discover(home: root)
        let personal = found.first(where: { $0.slug == "personal" })!
        let work = found.first(where: { $0.slug == "work" })!

        try catalogue(profile: work, title: "Active work conversation")

        let workMonitor = CodexActivityMonitor(profile: work)
        let personalMonitor = CodexActivityMonitor(profile: personal)

        workMonitor.start(); personalMonitor.start()
        defer { workMonitor.stop(); personalMonitor.stop() }

        // Active account sees the sessions
        XCTAssertEqual(workMonitor.sessions.map(\.name), ["Active work conversation"])
        // Inactive account does not mirror sessions
        XCTAssertEqual(personalMonitor.sessions, [])
    }
}

/// Stateless: tests can run concurrently without a shared request queue.
private final class CodexProfileEndpoint: URLProtocol {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexProfileEndpoint.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let account = request.value(forHTTPHeaderField: "ChatGPT-Account-Id")
        let token = request.value(forHTTPHeaderField: "Authorization")
        let percent: Int
        let status: Int
        switch (account, token) {
        case ("personal", "Bearer personal-token"): percent = 10; status = 200
        case ("work", "Bearer work-token"): percent = 75; status = 200
        case ("work", "Bearer rotated-token"): percent = 80; status = 200
        case ("work", "Bearer limited-token"): percent = 0; status = 429
        default: percent = 0; status = 401
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: ["Retry-After": "300"])!
        let body = Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(percent),\"limit_window_seconds\":18000}}}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
