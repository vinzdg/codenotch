import XCTest
@testable import Codenotch

/// The fixture is a live response (2026-09-27) cut to two days. The per-model
/// key is `credits`, but the values are percent: models and surfaces sum alike.
final class CodexLimitUsageTests: XCTestCase {
    static let fixture = Data("""
    {"units":"percent","group_by":"day","data":[
      {"date":"2026-09-25",
       "product_surface_usage_values":{"cli":0.0,"work_mobile":0.16031485957534297,"unknown":1.166405589631179},
       "models":[{"model":"gpt-5.6-sol","speed":"standard","credits":0.26155736278774117},
                 {"model":"gpt-6-astra","speed":"standard","credits":1.0651630864187809},
                 {"model":"gpt-5.6-luna","speed":"standard","credits":0.0}],
       "attribution":[]},
      {"date":"2026-09-26",
       "product_surface_usage_values":{"cli":0.0,"unknown":1.9967171779122894},
       "models":[{"model":"gpt-5.6-sol","speed":"standard","credits":0.6808702966834033},
                 {"model":"gpt-6-astra","speed":"standard","credits":1.3158468812288866},
                 {"model":"gpt-5.6-luna","speed":"standard","credits":0.0}],
       "attribution":[]}]}
    """.utf8)

    func testParsesDaysOldestFirstAndDropsEmptyModels() throws {
        let usage = try CodexLimitUsage.parse(Self.fixture)
        XCTAssertEqual(usage.days.map(\.date), ["2026-09-25", "2026-09-26"])
        XCTAssertEqual(usage.days[1].models.map(\.model), ["gpt-6-astra", "gpt-5.6-sol"])
        XCTAssertEqual(usage.days[1].total, 1.99671718, accuracy: 0.000001)
    }

    func testMergesSpeedsOfOneModel() throws {
        let body = Data("""
        {"units":"percent","data":[{"date":"2026-09-26","models":[
          {"model":"gpt-6-astra","speed":"standard","credits":1.0},
          {"model":"gpt-6-astra","speed":"fast","credits":0.5}]}]}
        """.utf8)
        XCTAssertEqual(try CodexLimitUsage.parse(body).days[0].models,
                       [.init(model: "gpt-6-astra", percent: 1.5)])
    }

    func testRejectsOtherUnitsAndMalformedBodiesButAcceptsMissingUnits() throws {
        XCTAssertThrowsError(try CodexLimitUsage.parse(Data(#"{"units":"credits","data":[]}"#.utf8)))
        XCTAssertThrowsError(try CodexLimitUsage.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try CodexLimitUsage.parse(Data(#"{"detail":"Not Found"}"#.utf8)))
        XCTAssertEqual(try CodexLimitUsage.parse(Data(#"{"data":[{"date":"2026-09-26","models":[]}]}"#.utf8)).days.count, 1)
    }

    func testLeadersStackAndLegend() throws {
        let body = Data("""
        {"units":"percent","data":[
          {"date":"2026-09-25","models":[{"model":"a","credits":2.0},{"model":"b","credits":1.0},{"model":"c","credits":0.5}]},
          {"date":"2026-09-26","models":[{"model":"a","credits":1.0},{"model":"d","credits":0.5}]}]}
        """.utf8)
        let usage = try CodexLimitUsage.parse(body)
        XCTAssertEqual(usage.leaders, ["a", "b"])
        XCTAssertEqual(usage.stack(for: usage.days[1]), [1.0, 0.0, 0.5])
        XCTAssertEqual(usage.legend(hovering: nil).map(\.model), ["a", "b", nil])
        XCTAssertEqual(usage.legend(hovering: nil).map(\.amount), ["3.0", "1.0", "1.0"])
        XCTAssertEqual(usage.scale, 3.5, accuracy: 0.000001)
    }

    func testTheWeekIsTheLastSevenDaysReturned() throws {
        let days = (1...9).map { #"{"date":"2026-09-0\#($0)","models":[]}"# }.joined(separator: ",")
        let usage = try CodexLimitUsage.parse(Data(#"{"units":"percent","data":[\#(days)]}"#.utf8))
        XCTAssertEqual(usage.days.map(\.date).first, "2026-09-03")
        XCTAssertEqual(usage.days.count, 7)
        XCTAssertEqual(usage.scale, 1, "an empty week still has a scale")
    }

    func testWeekdayDoesNotShiftTheDate() {
        XCTAssertEqual(CodexLimitUsage.weekday("2026-09-26", locale: Locale(identifier: "en_US")), "Sat")
    }
}

final class CodexDailyLimitFetchTests: XCTestCase {
    private func profile() throws -> CodexProfile {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexDailyLimitFetchTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return CodexProfile.default(home: root)
    }

    /// Same shape as `CodexProfileTests.writeAuth`, which `CodexCredentials.load` accepts.
    private func writeAuth(_ profile: CodexProfile, token: String, account: String = "acct") throws {
        let claims: [String: Any] = ["email": "a@example.test",
                                     "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
        let auth = ["tokens": ["access_token": token, "account_id": account,
                               "id_token": "header.\(payload).signature"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: profile.authURL)
    }

    private func archive() -> UsageArchive {
        let name = "CodexDailyLimitFetchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return UsageArchive(defaults: defaults)
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    func testNoRequestWhileOff() async throws {
        let profile = try profile()
        let token = UUID().uuidString
        try writeAuth(profile, token: token)
        let provider = CodexLocalProvider(profile: profile, session: BreakdownEndpoint.session(),
                                          archive: archive(), showsDailyLimit: { false })
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertNil(snapshot.codexLimitUsage)
        XCTAssertEqual(BreakdownEndpoint.hits(token), 0)
    }

    func testFetchesAtMostOnceEveryFifteenMinutes() async throws {
        let profile = try profile()
        let token = UUID().uuidString
        try writeAuth(profile, token: token)
        let clock = Clock()
        let provider = CodexLocalProvider(profile: profile, session: BreakdownEndpoint.session(),
                                          archive: archive(), showsDailyLimit: { true },
                                          clock: { clock.now })
        let first = try await provider.fetchSnapshot()
        XCTAssertEqual(first.codexLimitUsage?.days.count, 2)
        clock.now += 10 * 60
        let cached = try await provider.fetchSnapshot()
        XCTAssertEqual(cached.codexLimitUsage, first.codexLimitUsage)
        XCTAssertEqual(BreakdownEndpoint.hits(token), 1)
        clock.now += 6 * 60
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(BreakdownEndpoint.hits(token), 2)
    }

    func testARefusedBreakdownLeavesTheReadingAlone() async throws {
        let profile = try profile()
        let token = "refused-\(UUID().uuidString)"
        try writeAuth(profile, token: token)
        let provider = CodexLocalProvider(profile: profile, session: BreakdownEndpoint.session(),
                                          archive: archive(), showsDailyLimit: { true })
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.usedFraction, 0.10)
        XCTAssertNil(snapshot.codexLimitUsage)
    }

    func testAnotherAccountIsNotServedTheCachedBreakdown() async throws {
        let profile = try profile()
        let clock = Clock()
        let first = UUID().uuidString
        try writeAuth(profile, token: first)
        let provider = CodexLocalProvider(profile: profile, session: BreakdownEndpoint.session(),
                                          archive: archive(), showsDailyLimit: { true },
                                          clock: { clock.now })
        _ = try await provider.fetchSnapshot()
        let second = UUID().uuidString
        try writeAuth(profile, token: second, account: "other")
        clock.now += 60
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(BreakdownEndpoint.hits(second), 1)
    }

    func testTheBreakdownIsNotArchived() throws {
        let store = archive()
        var snapshot = ProviderSnapshot(
            id: "codex", displayName: "Codex", glyph: .openai, fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "primary", label: "5h", usedFraction: 0.1)]
        )
        snapshot.codexLimitUsage = try CodexLimitUsage.parse(CodexLimitUsageTests.fixture)
        store.save(["codex": (snapshot, Date())])
        XCTAssertNil(store.load()["codex"]?.snapshot.codexLimitUsage)
    }

    @MainActor
    func testThePreferenceDefaultsOff() throws {
        let name = "CodexDailyLimitPreference.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(Preferences.storedShowCodexDailyLimit(defaults: defaults))
        XCTAssertFalse(Preferences(defaults: defaults).showCodexDailyLimit)
    }
}

/// Answers every Codex endpoint the provider calls, and counts breakdown hits
/// per bearer token so parallel tests never share a count.
private final class BreakdownEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]

    static func hits(_ token: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[token, default: 0]
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BreakdownEndpoint.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
            .replacingOccurrences(of: "Bearer ", with: "")
        let path = request.url?.path ?? ""
        let status: Int
        let body: Data
        if path.hasSuffix("/daily-token-usage-breakdown") {
            Self.lock.lock(); Self.counts[token, default: 0] += 1; Self.lock.unlock()
            status = token.hasPrefix("refused-") ? 401 : 200
            body = status == 200 ? CodexLimitUsageTests.fixture : Data()
        } else if path.hasSuffix("/wham/usage") {
            status = 200
            body = Data(#"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}}}"#.utf8)
        } else {
            status = 404
            body = Data()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class CodexLimitUsageLayoutTests: XCTestCase {
    func testTheSectionIsBudgetedAndOnlyShownWithDays() throws {
        var snapshot = ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai,
                                        fidelity: .official, status: .ok, windows: [])
        XCTAssertFalse(snapshot.showsCodexLimitUsage)
        snapshot.codexLimitUsage = CodexLimitUsage(days: [])
        XCTAssertFalse(snapshot.showsCodexLimitUsage)
        snapshot.codexLimitUsage = try CodexLimitUsage.parse(CodexLimitUsageTests.fixture)
        XCTAssertTrue(snapshot.showsCodexLimitUsage)

        let plain = NotchLayout.cardHeight(windowCount: 2)
        let with = NotchLayout.cardHeight(windowCount: 2, hasCodexLimitUsage: true)
        XCTAssertEqual(with - plain, NotchLayout.codexLimitBlockHeight, accuracy: 0.001)
        let budget = NotchLayout.cardHeight(windowCount: NotchLayout.maxWindowCount, groupCount: 2,
                                            sessionCount: 6, sessionCap: 5)
        XCTAssertLessThan(
            NotchLayout.sessionsFitting(cardBudget: budget, windowCount: NotchLayout.maxWindowCount, hasCodexLimitUsage: true),
            NotchLayout.sessionsFitting(cardBudget: budget, windowCount: NotchLayout.maxWindowCount)
        )
    }
}

@MainActor
final class CodexDailyLimitSwitchTests: XCTestCase {
    private final class Codex: UsageProvider, @unchecked Sendable {
        let id = "codex"
        let displayName = "Codex"
        let glyph = ProviderGlyph.openai
        var fails = false
        var signInRoute: SignInRoute { .guidance("") }
        func account() -> ProviderAccount? { nil }
        func presentSignIn() {}
        func fetchSnapshot() async throws -> ProviderSnapshot {
            if fails { throw UsageProviderError.badResponse(status: 500) }
            var snapshot = ProviderSnapshot(
                id: id, displayName: displayName, glyph: glyph, fidelity: .official, status: .ok,
                windows: [LimitWindow(id: "primary", label: "5h", usedFraction: 0.1)], headlineID: "primary"
            )
            snapshot.codexLimitUsage = try CodexLimitUsage.parse(CodexLimitUsageTests.fixture)
            return snapshot
        }
    }

    func testSwitchingOffHidesTheSectionEvenAfterAFailedFetch() async {
        let name = "CodexDailyLimitSwitchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let provider = Codex()
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: defaults),
                               history: UsageHistory(defaults: defaults))
        store.showsCodexDailyLimit = true
        await store.refresh()
        XCTAssertNotNil(store.snapshots.first?.codexLimitUsage)

        store.showsCodexDailyLimit = false
        XCTAssertNil(store.snapshots.first?.codexLimitUsage)
        provider.fails = true
        await store.refresh()
        XCTAssertNil(store.snapshots.first?.codexLimitUsage, "a failed fetch re-showed the section")
    }
}

final class CodexLimitUsageDetailTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private typealias Entry = CodexLimitUsage.LegendEntry

    func testWithoutHoverTheLinesGiveTheDaysInPercentOfTheWeeklyLimit() throws {
        let usage = try CodexLimitUsage.parse(CodexLimitUsageTests.fixture)
        XCTAssertEqual(usage.detail(hovering: nil, locale: en), "Last 2 days: 3.3% of your weekly limit")
        XCTAssertEqual(usage.legend(hovering: nil),
                       [Entry(model: "gpt-6-astra", amount: "2.4"), Entry(model: "gpt-5.6-sol", amount: "0.9")])
    }

    func testAHoveredDayGivesItsOwnAmounts() throws {
        let usage = try CodexLimitUsage.parse(CodexLimitUsageTests.fixture)
        XCTAssertEqual(usage.detail(hovering: 1, locale: en), "Sat 26: 2.0% of your weekly limit")
        XCTAssertEqual(usage.legend(hovering: 1),
                       [Entry(model: "gpt-6-astra", amount: "1.3"), Entry(model: "gpt-5.6-sol", amount: "0.7")])
    }

    func testOtherTakesTheRestAndAnEmptyDaySaysSo() throws {
        let usage = try CodexLimitUsage.parse(Data("""
        {"units":"percent","data":[
          {"date":"2026-09-01","models":[]},
          {"date":"2026-09-02","models":[{"model":"a","credits":2.0},{"model":"b","credits":1.0},{"model":"c","credits":0.5}]}]}
        """.utf8))
        XCTAssertEqual(usage.detail(hovering: 0, locale: en), "Tue 1: no use")
        XCTAssertEqual(usage.legend(hovering: 0), [])
        XCTAssertEqual(usage.legend(hovering: 1),
                       [Entry(model: "a", amount: "2.0"), Entry(model: "b", amount: "1.0"), Entry(model: nil, amount: "0.5")])
        XCTAssertEqual(usage.detail(hovering: 7, locale: en), usage.detail(hovering: nil, locale: en))
    }

    func testTheLongestLinesFitTheCard() throws {
        let usage = try CodexLimitUsage.parse(Data("""
        {"units":"percent","data":[{"date":"2026-09-30","models":[
          {"model":"gpt-5.1-codex-max","credits":10.3},{"model":"gpt-6-astra","credits":1.7},
          {"model":"gpt-image-2","credits":0.5}]}]}
        """.utf8))
        let legend = usage.legend(hovering: nil).map { "● \($0.model ?? "Other") \($0.amount)%" }.joined(separator: "   ")
        let detail = usage.detail(hovering: 0, locale: en)
        for (line, scale) in [(legend, 0.6), (detail, 0.8)] {
            let width = (line as NSString).size(withAttributes: [.font: NotchLayout.cardBodyFont]).width
            XCTAssertLessThanOrEqual(width, NotchLayout.cardTextWidth / scale, line)
        }
    }
}
