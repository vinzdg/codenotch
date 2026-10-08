import SQLite3
import SwiftUI
import XCTest
@testable import Codenotch

final class DevinUsageTests: XCTestCase {
    /// GetUserStatus quota shape, with synthetic values and no account data.
    private let recorded = """
    {"userStatus":{"planStatus":{
     "dailyQuotaRemainingPercent":99,"weeklyQuotaRemainingPercent":50,
     "dailyQuotaResetAtUnix":"1789113600","weeklyQuotaResetAtUnix":"1789286400",
     "overageBalanceMicros":"14277951"}}}
    """

    private func windows(_ json: String) throws -> [LimitWindow] {
        try DevinUsage.windows(fromJSON: json)
    }

    @MainActor
    func testDevinLogoIsBundledAndRendersAsAMark() throws {
        let glyph = DevinLocalProvider().glyph
        XCTAssertEqual(glyph, .devin)
        XCTAssertEqual(glyph.assetName, "glyph-devin")
        let image = try XCTUnwrap(NSImage(named: glyph.assetName))
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        let renderer = ImageRenderer(content: ProviderGlyphView(glyph: glyph, size: 32)
            .foregroundStyle(.white))
        let data = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var inkPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { inkPixels += 1 }
            }
        }
        let coverage = Double(inkPixels) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
        XCTAssertGreaterThan(coverage, 0.05)
        XCTAssertLessThan(coverage, 0.85)
        XCTAssertNotNil(Bundle.main.url(forResource: "LobeIcons-LICENSE", withExtension: "txt"))
    }

    func testFormattedBalanceSurvivesArchivingWithoutChangingPlainCounts() throws {
        let old = try JSONDecoder().decode(LimitWindow.self,
            from: Data(#"{"id":"requests","label":"Requests","used":3}"#.utf8))
        XCTAssertNil(old.usedText)
        XCTAssertEqual(old.summary, "3 used")
        let balance = try XCTUnwrap(windows(recorded).last)
        let restored = try JSONDecoder().decode(LimitWindow.self,
            from: JSONEncoder().encode(balance))
        XCTAssertEqual(restored.summary, "$14.28")
    }

    func testLegacyDevinArchiveGetsNewLogoWithoutChangingReadings() throws {
        let suite = "DevinArchiveTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = UsageArchive(defaults: defaults)
        let captured = Date(timeIntervalSince1970: 100)
        let windows = try windows(recorded)
        let old = ProviderSnapshot(id: "devin", displayName: "Devin", glyph: .third,
                                   fidelity: .official, status: .ok, windows: windows)
        let other = ProviderSnapshot(id: "other", displayName: "Other", glyph: .third,
                                     fidelity: .official, status: .ok, windows: [])
        archive.save(["devin": (old, captured), "other": (other, captured)])
        let restored = archive.load()
        XCTAssertEqual(restored["devin"]?.snapshot.glyph, .devin)
        XCTAssertEqual(restored["devin"]?.snapshot.windows, windows)
        XCTAssertEqual(restored["devin"]?.fetchedAt, captured)
        XCTAssertEqual(restored["devin"]?.snapshot.status, .stale(since: captured))
        XCTAssertEqual(restored["other"]?.snapshot.glyph, .third)
    }

    func testReadsLiveResponseAndFormatsBalance() throws {
        let w = try windows(recorded)
        XCTAssertEqual(w.map(\.id), ["daily", "weekly", "overage"])
        XCTAssertEqual(try XCTUnwrap(w[0].usedFraction), 0.01, accuracy: 0.00001)
        XCTAssertEqual(w[1].usedFraction, 0.50)
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1789113600))
        XCTAssertEqual(w[2].usedText, "$14.28")
        XCTAssertEqual(w[2].summary, "$14.28")
    }

    func testPastResetIsNotRolledForward() throws {
        // An expired timestamp must remain expired, not disguise an old reading.
        let json = recorded.replacingOccurrences(of: "1789113600", with: "100")
        let w = try windows(json)
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try XCTUnwrap(w[0].usedFraction), 0.01, accuracy: 0.00001)
    }

    func testFractionalPercentAndNumericTimestamps() throws {
        let json = #"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":99.5,"dailyQuotaResetAtUnix":1789113600}}}"#
        let w = try windows(json)
        XCTAssertEqual(try XCTUnwrap(w[0].usedFraction), 0.005, accuracy: 0.00001)
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1789113600))
    }

    func testZeroBalanceIsAReading() throws {
        let w = try windows(recorded.replacingOccurrences(of: "14277951", with: "0"))
        XCTAssertEqual(w.last?.usedText, "$0.00")
    }

    func testHiddenQuotaAndMissingReset() throws {
        let json = #"{"userStatus":{"planStatus":{"hideDailyQuota":true,"dailyQuotaRemainingPercent":99,"weeklyQuotaRemainingPercent":50}}}"#
        let w = try windows(json)
        XCTAssertEqual(w.map(\.id), ["weekly"])
        XCTAssertNil(w[0].resetsAt)
    }

    func testRejectsMissingOrInvalidQuotaInsteadOfInventingZero() {
        for value in ["null", "true", "-1", "101", #""NaN""#, #""Infinity""#] {
            XCTAssertThrowsError(try windows("{\"userStatus\":{\"planStatus\":{\"dailyQuotaRemainingPercent\":\(value)}}}"))
        }
        XCTAssertThrowsError(try windows(#"{"dailyRemainingPercent":100}"#))
        XCTAssertThrowsError(try windows(#"{"userStatus":{"planStatus":{}}}"#))
        XCTAssertThrowsError(try windows("not json"))
    }

    func testInvalidBalanceDoesNotDiscardQuotaOrTrap() throws {
        for value in ["-1", "true", "1e100", #""Infinity""#] {
            let json = recorded.replacingOccurrences(of: #""14277951""#, with: value)
            XCTAssertEqual(try windows(json).map(\.id), ["daily", "weekly"])
        }
    }

    /// The service drops *QuotaRemainingPercent at 0 (fully used) but keeps the
    /// reset timestamp. A missing percent with a reset is 100% used, not absent.
    func testMissingRemainingWithResetMeansFullyUsed() throws {
        let json = #"{"userStatus":{"planStatus":{"dailyQuotaResetAtUnix":"1789113600","weeklyQuotaResetAtUnix":"1789286400","overageBalanceMicros":"4632524"}}}"#
        let w = try windows(json)
        XCTAssertEqual(w.map(\.id), ["daily", "weekly", "overage"])
        XCTAssertEqual(try XCTUnwrap(w[0].usedFraction), 1.0)    // daily 100% used
        XCTAssertEqual(try XCTUnwrap(w[1].usedFraction), 1.0)    // weekly 100% used
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1789113600))
        XCTAssertEqual(w[2].usedText, "$4.63")
    }

    func testRefreshFetchesChangedUsageInsteadOfLocalCache() async throws {
        let database = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: database) }
        DevinEndpoint.reset([(200, recorded), (200, recorded.replacingOccurrences(of: ":99", with: ":98"))])
        let provider = makeProvider(database: database)
        let first = try await provider.fetchSnapshot()
        let second = try await provider.fetchSnapshot()
        XCTAssertEqual(try XCTUnwrap(first.usedFraction), 0.01, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(second.usedFraction), 0.02, accuracy: 0.00001)
        XCTAssertEqual(second.status, .ok)
        XCTAssertEqual(DevinEndpoint.requestCount, 2)
    }

    func testNetworkFailureDoesNotReturnStaleSQLiteQuotaAsOK() async throws {
        let database = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: database) }
        DevinEndpoint.reset([(200, recorded), (503, "")])
        let provider = makeProvider(database: database)
        _ = try await provider.fetchSnapshot()
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("An HTTP failure must reach UsageStore's stale-reading handling")
        } catch UsageProviderError.badResponse(let status) {
            XCTAssertEqual(status, 503)
        }
    }

    func testAuthenticationErrorsAndRateLimit() async throws {
        let database = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: database) }
        for (code, expected) in [(401, ProviderStatus.needsAuth), (403, .accessDenied)] {
            DevinEndpoint.reset([(code, "")])
            do {
                _ = try await makeProvider(database: database).fetchSnapshot()
                XCTFail("Expected authentication failure")
            } catch {
                let status = await UsageStore.statusForTesting(error)
                XCTAssertEqual(status, expected)
            }
        }
        DevinEndpoint.reset([(429, "")])
        let provider = makeProvider(database: database)
        for _ in 0..<2 {
            do {
                _ = try await provider.fetchSnapshot()
                XCTFail("Expected rate limit")
            } catch UsageProviderError.rateLimited(let delay) {
                XCTAssertGreaterThan(delay, 0)
            }
        }
        XCTAssertEqual(DevinEndpoint.requestCount, 1)
    }

    func testMissingAuthenticationDoesNotMakeNetworkRequest() async throws {
        DevinEndpoint.reset([])
        do {
            _ = try await makeProvider(database: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)).fetchSnapshot()
            XCTFail("Expected needsAuth")
        } catch UsageProviderError.needsAuth {}
        XCTAssertEqual(DevinEndpoint.requestCount, 0)
    }

    /// When the Desktop database is absent, the CLI credentials file is the
    /// fallback. A valid key there must produce a snapshot, not needsAuth.
    func testCLICredentialsAreUsedWhenDesktopDatabaseIsAbsent() async throws {
        let cli = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString).toml")
        try #"windsurf_api_key = "devin-session-token$test-key""#.write(to: cli, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cli) }
        DevinEndpoint.reset([(200, recorded)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DevinEndpoint.self]
        let provider = DevinLocalProvider(
            database: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            cliCredentials: cli, session: URLSession(configuration: configuration))
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(DevinEndpoint.requestCount, 1)
    }

    func testLiveDevinUsageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODENOTCH_TEST_DEVIN_LIVE"] == "1" else {
            throw XCTSkip("Opt-in live check requires a signed-in Devin Desktop")
        }
        let snapshot = try await DevinLocalProvider().fetchSnapshot()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNotNil(snapshot.usedFraction)
        XCTAssertNotNil(snapshot.weeklyFraction)
        print("Devin live quota: daily \(snapshot.headlineText), weekly \(snapshot.weeklyFraction.map { Percent.text(for: $0) } ?? "missing")% used")
        for window in snapshot.windows {
            print("Devin live \(window.id): \(window.summary), reset \(window.resetsAt?.description ?? "none")")
        }
    }

    private func makeProvider(database: URL) -> DevinLocalProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DevinEndpoint.self]
        // A non-existent CLI path so the fallback is not triggered by the
        // developer's own credentials file during tests.
        let cli = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString).toml")
        return DevinLocalProvider(database: database, cliCredentials: cli,
                                  session: URLSession(configuration: configuration))
    }

    private func makeDatabase() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("devin-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO ItemTable VALUES ('windsurfAuthStatus', '{"apiKey":"test-only-key","email":"user@example.com"}');
        INSERT INTO ItemTable VALUES ('windsurf.reactSettings.cachedPlanInfoData:test',
            '{"dailyRemainingPercent":100,"dailyResetAtUnix":100,"weeklyRemainingPercent":50,"weeklyResetAtUnix":100}');
        """, nil, nil, nil), SQLITE_OK)
        return url
    }
}

private final class DevinEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var answers: [(Int, String)] = []
    private static var count = 0

    static var requestCount: Int { lock.withLock { count } }

    static func reset(_ values: [(Int, String)]) {
        lock.withLock { answers = values; count = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        XCTAssertEqual(request.url?.absoluteString, "https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
        let answer = Self.lock.withLock {
            Self.count += 1
            return Self.answers.isEmpty ? (500, "") : Self.answers.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
