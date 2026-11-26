import XCTest
@testable import Codenotch

final class MistralUsageTests: XCTestCase {
    func testParsesVibeAndAPIBudgetsHighestFirst() throws {
        let json = """
        {
          "vibe_budget": {
            "usage_percentage": 54.5,
            "initial_budget": 127.5,
            "currency": "EUR",
            "reset_at": "2026-12-01T00:00:00Z"
          },
          "api_budget": {
            "usage_percentage": 0.0,
            "initial_budget": 12.75,
            "currency": "EUR",
            "reset_at": "2026-12-01T00:00:00Z"
          }
        }
        """
        let windows = try MistralUsage.parseBudgets(Data(json.utf8))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].id, "vibe")
        XCTAssertEqual(windows[0].label, "Vibe Budget (€69.49 / €127.50)")
        XCTAssertEqual(try XCTUnwrap(windows[0].usedFraction), 0.545, accuracy: 1e-6)
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertEqual(windows[0].duration, 30 * 86_400)

        XCTAssertEqual(windows[1].id, "api")
        XCTAssertEqual(windows[1].label, "API Budget (€0.00 / €12.75)")
        XCTAssertEqual(try XCTUnwrap(windows[1].usedFraction), 0.0, accuracy: 1e-6)
    }

    func testSortsHigherAPIBudgetAheadOfVibeAndKeepsVibeFirstOnTie() throws {
        let apiHigher = """
        {
          "vibe_budget": { "usage_percentage": 10.0 },
          "api_budget": { "usage_percentage": 45.0 }
        }
        """
        XCTAssertEqual(try MistralUsage.parseBudgets(Data(apiHigher.utf8)).map(\.id), ["api", "vibe"])

        let tied = """
        {
          "vibe_budget": { "usage_percentage": 20.0 },
          "api_budget": { "usage_percentage": 20.0 }
        }
        """
        XCTAssertEqual(try MistralUsage.parseBudgets(Data(tied.utf8)).map(\.id), ["vibe", "api"])
    }

    func testParsesFlatBudgetClampsOver100AndRejectsNegative() throws {
        let flat = """
        {"usage_percentage": 125.0, "initial_budget": 20.0, "currency": "USD"}
        """
        let windows = try MistralUsage.parseBudgets(Data(flat.utf8))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].id, "api")
        XCTAssertEqual(try XCTUnwrap(windows[0].usedFraction), 1.0, accuracy: 1e-6)
        XCTAssertEqual(windows[0].label, "API Budget ($20.00 / $20.00)")

        let negative = #"{"usage_percentage": -5.0}"#
        XCTAssertTrue(try MistralUsage.parseBudgets(Data(negative.utf8)).isEmpty)
    }

    func testFormatsCurrencies() {
        XCTAssertEqual(MistralUsage.formatCurrency(12.5, code: nil), "$12.50")
        XCTAssertEqual(MistralUsage.formatCurrency(12.5, code: "USD"), "$12.50")
        XCTAssertEqual(MistralUsage.formatCurrency(12.5, code: "eur"), "€12.50")
        XCTAssertEqual(MistralUsage.formatCurrency(12.5, code: "GBP"), "£12.50")
        XCTAssertEqual(MistralUsage.formatCurrency(12.5, code: "CAD"), "CAD 12.50")
    }

    func testParsesSubscriptionPlanAndPAYG() {
        let edu = Data(#"{"plan_name":"EDU","payg_enabled":false,"vibe_payg_enabled":false}"#.utf8)
        XCTAssertEqual(MistralUsage.parseSubscriptionPlan(edu), "EDU")

        let pro = Data(#"{"plan_name":"Pro","payg_enabled":true}"#.utf8)
        XCTAssertEqual(MistralUsage.parseSubscriptionPlan(pro), "Pro · PAYG")

        let empty = Data(#"{"plan_name":"  "}"#.utf8)
        XCTAssertNil(MistralUsage.parseSubscriptionPlan(empty))
    }
}

final class MistralCredentialsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MistralCredentialsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ content: String, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func sources(
        environment: [String: String] = [:],
        settings: String? = nil,
        vibeEnv: URL? = nil,
        openCode: URL? = nil,
        configFile: URL? = nil
    ) -> MistralCredentialSources {
        MistralCredentialSources(
            environment: environment,
            settingsToken: { settings },
            settingsPresent: { settings != nil },
            deleteSettingsToken: {},
            vibeEnvURL: vibeEnv ?? directory.appendingPathComponent("missing.env"),
            openCodeAuthURL: openCode ?? directory.appendingPathComponent("missing-opencode.json"),
            configFileURL: configFile ?? directory.appendingPathComponent("missing-mistral.json"),
            forgetCached: {}
        )
    }

    func testParsesVibeDotEnvAndConfigJSON() {
        XCTAssertEqual(
            MistralCredentials.parseEnvKey("# comment\nexport MISTRAL_API_KEY=\"sk-test-123\"\n"),
            "sk-test-123"
        )
        XCTAssertEqual(
            MistralCredentials.parseEnvKey("MISTRAL_API_KEY='sk-single' # trailing\n"),
            "sk-single"
        )
        XCTAssertEqual(
            MistralCredentials.parseEnvKey("MISTRAL_API_KEY=sk-plain # comment\n"),
            "sk-plain"
        )
        XCTAssertEqual(MistralCredentials.parseKeyJSON(#"{"api_key":"  sk-json  "}"#), "sk-json")
        XCTAssertEqual(MistralCredentials.parseKeyJSON(#"{"apiKey":"sk-camel"}"#), "sk-camel")
    }

    func testCredentialPrecedence() throws {
        let vibe = try write("MISTRAL_API_KEY=sk-vibe\n", named: "vibe.env")
        let openCode = try write(#"{"mistral":{"key":"sk-opencode"}}"#, named: "opencode.json")
        let config = try write(#"{"api_key":"sk-config"}"#, named: "mistral.json")

        let envCred = try MistralCredentials.load(
            sources(environment: ["MISTRAL_API_KEY": " sk-env "], settings: "sk-settings",
                    vibeEnv: vibe, openCode: openCode, configFile: config)
        )
        XCTAssertEqual(envCred, MistralCredentials.Credential(token: "sk-env", source: .environment))

        let settingsCred = try MistralCredentials.load(
            sources(settings: "sk-settings", vibeEnv: vibe, openCode: openCode, configFile: config)
        )
        XCTAssertEqual(settingsCred, MistralCredentials.Credential(token: "sk-settings", source: .settings))

        let vibeCred = try MistralCredentials.load(
            sources(vibeEnv: vibe, openCode: openCode, configFile: config)
        )
        XCTAssertEqual(vibeCred, MistralCredentials.Credential(token: "sk-vibe", source: .vibeEnv))

        let openCodeCred = try MistralCredentials.load(
            sources(openCode: openCode, configFile: config)
        )
        XCTAssertEqual(openCodeCred, MistralCredentials.Credential(token: "sk-opencode", source: .openCode))

        let configCred = try MistralCredentials.load(
            sources(configFile: config)
        )
        XCTAssertEqual(configCred, MistralCredentials.Credential(token: "sk-config", source: .configFile))
    }

    func testMissingCredentialsThrowsNeedsAuth() {
        XCTAssertThrowsError(try MistralCredentials.load(sources())) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("Expected needsAuth, got \(error)")
            }
        }
    }

    func testRespectsVibeHomeAndXDGDataHome() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertEqual(
            MistralCredentials.vibeEnvURL(environment: ["VIBE_HOME": "/custom/vibe"], home: home).path,
            "/custom/vibe/.env"
        )
        XCTAssertEqual(
            MistralCredentials.vibeEnvURL(environment: [:], home: home).path,
            "/Users/test/.vibe/.env"
        )
        XCTAssertEqual(
            MistralCredentials.openCodeAuthURL(environment: ["XDG_DATA_HOME": "/custom/data"], home: home).path,
            "/custom/data/opencode/auth.json"
        )
        XCTAssertEqual(
            MistralCredentials.openCodeAuthURL(environment: [:], home: home).path,
            "/Users/test/.local/share/opencode/auth.json"
        )
    }
}

final class MistralProviderTests: XCTestCase {
    private final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeArchive() -> UsageArchive {
        let suite = "MistralProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return UsageArchive(defaults: defaults)
    }

    private func makeSources(token: String = "sk-mistral-test") -> MistralCredentialSources {
        MistralCredentialSources(
            environment: ["MISTRAL_API_KEY": token],
            settingsToken: { nil },
            settingsPresent: { false },
            deleteSettingsToken: {},
            vibeEnvURL: nil,
            openCodeAuthURL: URL(fileURLWithPath: "/nonexistent/opencode.json"),
            configFileURL: URL(fileURLWithPath: "/nonexistent/mistral.json"),
            forgetCached: {}
        )
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testFetchesBudgetAndSubscriptionPlan() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-mistral-test")
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path.hasSuffix("/billing/budget") {
                return (response, Data(#"{"vibe_budget":{"usage_percentage":42.0,"initial_budget":100.0,"currency":"EUR"}}"#.utf8))
            }
            return (response, Data(#"{"plan_name":"Pro","vibe_payg_enabled":true}"#.utf8))
        }

        let provider = MistralProvider(session: makeSession(), archive: makeArchive(), sources: makeSources())
        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.id, "mistral")
        XCTAssertEqual(snapshot.glyph, .mistral)
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.headlineID, "vibe")
        XCTAssertEqual(snapshot.plan, "Pro · PAYG")
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.windows.first?.usedFraction), 0.42, accuracy: 1e-6)
    }

    func testUnauthorizedReturnsNeedsAuth() async {
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let provider = MistralProvider(session: makeSession(), archive: makeArchive(), sources: makeSources())
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("Expected needsAuth")
        } catch UsageProviderError.needsAuth {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRateLimitPersistsBackoff() async {
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "120"]
            )!
            return (response, Data())
        }

        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let archive = makeArchive()
        let provider = MistralProvider(
            session: makeSession(),
            archive: archive,
            sources: makeSources(),
            now: { fixedNow }
        )
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("Expected rateLimited")
        } catch UsageProviderError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 120, accuracy: 0.1)
            XCTAssertNotNil(archive.loadBackoffUntil(providerID: "mistral"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
