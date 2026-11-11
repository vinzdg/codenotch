import XCTest
@testable import Codenotch

/// Guards the shape of MiniMax Coding Plan / Token Plan remains JSON. It is
/// not a published schema, so these are the tests that fail first if the
/// counts keep meaning remaining, or if a video placeholder starts reading
/// as a full bar.
final class MiniMaxUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let start = 1_700_000_000_000
    private var end: Int { start + 5 * 60 * 60 * 1000 }
    private var weekEnd: Int { start + 7 * 24 * 60 * 60 * 1000 }

    private func parse(_ json: String) throws -> MiniMaxUsage.Reading {
        try MiniMaxUsage.parse(Data(json.utf8), now: now)
    }

    /// `current_interval_usage_count` is remaining. 1000 total with 250 left
    /// is 75% used, not 25%.
    func testCountBasedRemainsAreRemainingNotUsed() throws {
        let json = """
        { "base_resp": { "status_code": 0 },
          "current_subscribe_title": "Max",
          "model_remains": [
            { "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "start_time": \(start),
              "end_time": \(end),
              "remains_time": 240000 } ] }
        """
        let reading = try parse(json)
        XCTAssertEqual(reading.plan, "Max")
        XCTAssertEqual(reading.windows.map(\.id), ["session"])
        XCTAssertEqual(reading.windows.map(\.label), ["5h limit"])
        XCTAssertEqual(reading.windows.map(\.duration), [5 * 3600])
        let session = try XCTUnwrap(reading.windows.first)
        XCTAssertEqual(session.usedFraction ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(session.remaining, 250)
        XCTAssertEqual(session.used, 750)
        XCTAssertEqual(session.resetsAt?.timeIntervalSince1970 ?? -1,
                       TimeInterval(end) / 1000, accuracy: 0.001)
        XCTAssertEqual(try MiniMaxUsage.windows(fromJSON: json, now: now).map(\.id), ["session"])
    }

    /// Token Plan leaves the counts at 0 and answers remaining percent.
    /// Used is `100 - remaining`, not a fraction invented from 0/0.
    func testPercentBasedTokenPlanUsesRemainingPercent() throws {
        let json = """
        { "base_resp": { "status_code": 0 },
          "plan_name": "Plus",
          "model_remains": [
            { "model_name": "general",
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "current_interval_remaining_percent": 96,
              "start_time": \(start),
              "end_time": \(end),
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "current_weekly_remaining_percent": 99,
              "weekly_start_time": \(start),
              "weekly_end_time": \(weekEnd) } ] }
        """
        let reading = try parse(json)
        XCTAssertEqual(reading.plan, "Plus")
        XCTAssertEqual(reading.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(reading.windows.map(\.label), ["5h limit", "Weekly limit"])
        XCTAssertEqual(reading.windows.map(\.duration), [5 * 3600, 7 * 86400])
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.04, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[1].usedFraction ?? -1, 0.01, accuracy: 0.0001)
        XCTAssertNil(reading.windows[0].used)
        XCTAssertNil(reading.windows[0].remaining)
    }

    /// `interval_boost_permill` 2000 is a 200-unit bar. 99% remaining is 2
    /// used, not 198 — 50% would hide an inversion. Status 3 on the general
    /// weekly lane with 100% remaining is unlimited, not a placeholder to drop.
    func testBoostedIntervalAndUnlimitedWeekly() throws {
        let json = """
        { "base_resp": { "status_code": 0 },
          "combo_title": "Ultra",
          "model_remains": [
            { "model_name": "general",
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "current_interval_remaining_percent": 99,
              "interval_boost_permill": 2000,
              "start_time": \(start),
              "end_time": \(end),
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "current_weekly_status": 3,
              "current_weekly_remaining_percent": 100,
              "weekly_start_time": \(start),
              "weekly_end_time": \(weekEnd) } ] }
        """
        let reading = try parse(json)
        XCTAssertEqual(reading.plan, "Ultra")
        XCTAssertEqual(reading.windows.map(\.id), ["session", "weekly"])
        let session = reading.windows[0]
        XCTAssertEqual(session.usedFraction ?? -1, 0.01, accuracy: 0.0001)
        XCTAssertEqual(session.used, 2)
        XCTAssertEqual(session.remaining, 198)
        let weekly = reading.windows[1]
        XCTAssertEqual(weekly.usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertNil(weekly.resetsAt)
        XCTAssertEqual(weekly.duration, 7 * 86400)
    }

    /// Remaining percent above 100 is leftover boost, not a negative ring.
    func testRemainingPercentAboveOneHundredIsZeroUsed() throws {
        let json = """
        { "model_remains": [
            { "model_name": "general",
              "current_interval_remaining_percent": 150,
              "interval_boost_permill": 2000 } ] }
        """
        let session = try XCTUnwrap(try parse(json).windows.first)
        XCTAssertEqual(session.usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(session.used, 0)
        XCTAssertEqual(session.remaining, 200)
    }

    /// Video on Plus arrives as status 3, 0/0, 100% remaining. It is not a
    /// quota, and it must not hide the text lane's weekly window behind it.
    func testUnavailableVideoLaneIsDropped() throws {
        let json = """
        { "base_resp": { "status_code": 0 },
          "model_remains": [
            { "model_name": "video",
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "current_interval_status": 3,
              "current_interval_remaining_percent": 100,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "current_weekly_status": 3,
              "current_weekly_remaining_percent": 100 },
            { "model_name": "MiniMax-M2.7",
              "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "start_time": \(start),
              "end_time": \(end),
              "current_weekly_total_count": 6000,
              "current_weekly_usage_count": 5376,
              "weekly_start_time": \(start),
              "weekly_end_time": \(weekEnd) } ] }
        """
        let windows = try parse(json).windows
        XCTAssertEqual(windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(windows[0].used, 750)
        XCTAssertEqual(windows[0].remaining, 250)
        XCTAssertEqual(windows[1].used, 624)
        XCTAssertEqual(windows[1].remaining, 5376)
        XCTAssertEqual(windows[1].usedFraction ?? -1, 624.0 / 6000.0, accuracy: 0.0001)
    }

    /// Older coding-plan answers omit `model_name`. The weekly counts still
    /// belong to the text quota.
    func testUnnamedLaneKeepsWeeklyCounts() throws {
        let json = """
        { "model_remains": [
            { "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "current_weekly_total_count": 6000,
              "current_weekly_usage_count": 5376 } ] }
        """
        XCTAssertEqual(try parse(json).windows.map(\.id), ["session", "weekly"])
    }

    func testAnEmptyPayloadIsNothingMetered() {
        for json in ["{}", #"{"base_resp":{"status_code":0},"model_remains":[]}"#] {
            XCTAssertThrowsError(try parse(json)) { error in
                guard case UsageProviderError.nothingMetered = error else {
                    return XCTFail("expected nothingMetered, got \(error)")
                }
            }
        }
    }

    /// `1004` is a missing cookie, and it arrives under HTTP 200 — the
    /// envelope is the failure, not the transport. An inner `status_code: 0`
    /// must not hide the wrapper.
    func testStatus1004IsNeedsAuth() {
        let bodies = [
            #"{"base_resp":{"status_code":1004,"status_msg":"cookie is missing, log in again"}}"#,
            #"{"data":{"base_resp":{"status_code":"1004","status_msg":"unauthorized"}}}"#,
            #"{"base_resp":{"status_code":1004,"status_msg":"cookie is missing"},"data":{"base_resp":{"status_code":0},"model_remains":[]}}"#,
        ]
        for json in bodies {
            XCTAssertThrowsError(try parse(json)) { error in
                guard case UsageProviderError.needsAuth = error else {
                    return XCTFail("expected needsAuth, got \(error)")
                }
            }
        }
    }

    func testAnUnrecognisedBusinessCodeIsABadResponse() {
        XCTAssertThrowsError(try parse(#"{"base_resp":{"status_code":2045,"status_msg":"overloaded"}}"#)) { error in
            guard case UsageProviderError.badResponse(let status) = error, status == 2045 else {
                return XCTFail("expected badResponse(2045), got \(error)")
            }
        }
    }

    func testGarbageIsABadResponse() {
        XCTAssertThrowsError(try MiniMaxUsage.windows(fromJSON: "not json")) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    /// A percent nobody can read as a *number* is not a reading, whatever else
    /// the lane says. `Double("-inf")` parses, and `max(0, (100 - it) / 100)`
    /// is not a finiteness check: `max` answers its first argument when the
    /// comparison is false, so `-inf` escapes it as a `+inf` fraction while
    /// `NaN` is swallowed by that same ordering by accident. Either way the
    /// fraction that reaches `Percent.text`/`Percent.halves` is not one — and
    /// `Int(_: Double)` aborts the process on the non-finite one instead of
    /// printing a ring. Hence a failed read, not a window.
    func testNonFinitePercentsAreNotReadings() {
        for json in [
            // The string spelling `Double(_:)` accepts where the body named
            // neither infinity, and the one that gets past the clamp today.
            #"{"model_remains":[{"model_name":"general","current_interval_remaining_percent":"-inf"}]}"#,
            // `JSONSerialization` parses `-1e400` to an `NSNumber` carrying
            // -infinity rather than refusing it, where `1e400` parses to nil —
            // so the numeric spelling reaches the same fraction.
            #"{"model_remains":[{"model_name":"general","current_interval_remaining_percent":-1e400}]}"#,
            // The weekly lane reads its own field through the same helper.
            #"{"model_remains":[{"model_name":"general","current_weekly_remaining_percent":"nan"}]}"#,
        ] {
            XCTAssertThrowsError(try parse(json)) { error in
                guard case UsageProviderError.nothingMetered = error else {
                    return XCTFail("expected nothingMetered for \(json), got \(error)")
                }
            }
        }
    }

    /// The counts come through `int(_:)` instead, where a value a string can
    /// spell but an `Int` cannot hold is the same kind of trap: `Int("1e30")`
    /// fails, `Double("1e30")` succeeds, and `Int(_: Double)` then aborts the
    /// process rather than answering. A lane whose counts cannot be read
    /// meters nothing; the abort is reached from the payload, not from a test.
    func testACountTooLargeForAnIntIsNotAReading() {
        let json = """
        { "model_remains": [
            { "model_name": "general",
              "current_interval_total_count": "1e30",
              "current_interval_usage_count": "250" } ] }
        """
        XCTAssertThrowsError(try parse(json)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    /// The same trap by the other spelling, which the string bound does not
    /// cover. `JSONSerialization` hands `-1e400` back as an `NSNumber` carrying
    /// -infinity, and `NSNumber.intValue` saturates it to `Int.min` rather than
    /// aborting — so the read *succeeds* with a count nobody can represent, and
    /// `max(0, total - remaining)` then traps on the overflow instead. Verified
    /// against Foundation: `intValue` really is `Int.min` here.
    func testACountThatSaturatesAnIntIsNotAReading() {
        let json = """
        { "model_remains": [
            { "model_name": "general",
              "current_interval_total_count": 1000,
              "current_interval_usage_count": -1e400 } ] }
        """
        XCTAssertThrowsError(try parse(json)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    /// The other side of the guard, which no earlier test pins: every percent
    /// fixture above spells its number as a JSON number, so the *string* path
    /// is the one just narrowed and nothing else here would notice if it started
    /// refusing finite values too. A decimal string is still a reading.
    func testAFiniteStringSpellingIsStillAReading() throws {
        let json = """
        { "model_remains": [
            { "model_name": "general",
              "current_interval_remaining_percent": "12.5" } ] }
        """
        let session = try XCTUnwrap(try parse(json).windows.first)
        XCTAssertEqual(session.usedFraction ?? -1, 0.875, accuracy: 0.0001)
    }

    /// No `end_time` — the countdown is `now + remains_time / 1000`. Values
    /// under 1e6 are still milliseconds: 240000 ms is four minutes, not 66h.
    func testRemainsTimeIsMillisecondsEvenBelowOneMillion() throws {
        let json = """
        { "model_remains": [
            { "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "remains_time": 240000 } ] }
        """
        let session = try XCTUnwrap(try parse(json).windows.first)
        XCTAssertEqual(session.resetsAt?.timeIntervalSince(now) ?? -1, 240, accuracy: 0.001)
    }

    func testRemainsTimeIsMillisecondsPastOneMillion() throws {
        let json = """
        { "model_remains": [
            { "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "remains_time": 2400000 } ] }
        """
        let session = try XCTUnwrap(try parse(json).windows.first)
        XCTAssertEqual(session.resetsAt?.timeIntervalSince(now) ?? -1, 2400, accuracy: 0.001)
    }

    /// A 10-digit `end_time` is unix seconds. Dividing it as milliseconds
    /// lands the reset in 1970.
    func testSecondsPrecisionEndTimeIsNotTreatedAsMilliseconds() throws {
        let json = """
        { "model_remains": [
            { "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "start_time": 1700000000,
              "end_time": 1700001800 } ] }
        """
        let session = try XCTUnwrap(try parse(json).windows.first)
        XCTAssertEqual(session.duration, 1800)
        XCTAssertEqual(session.resetsAt?.timeIntervalSince1970 ?? -1, 1_700_001_800, accuracy: 0.001)
    }

    /// A past `end_time` is stale; the countdown follows `remains_time`.
    func testAPastEndTimeFallsBackToRemainsTime() throws {
        let json = """
        { "model_remains": [
            { "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "end_time": 1699990000,
              "remains_time": 240000 } ] }
        """
        let session = try XCTUnwrap(try parse(json).windows.first)
        XCTAssertEqual(session.resetsAt?.timeIntervalSince(now) ?? -1, 240, accuracy: 0.001)
    }

    // MARK: - Which key reaches the remains endpoint (#516)

    /// MiniMax China's Token Plan endpoint answered an `sk-api-` key with real
    /// remains. Skipping that key by its prefix left the notch on a dash and
    /// the log on `needsAuth`, with no request ever made.
    func testAChinaSkAPIKeyIsAskedOfTheTokenPlanEndpoint() async throws {
        let body = liveTokenPlanBody
        MiniMaxEndpoint.reset { _ in MiniMaxEndpoint.Reply(status: 200, body: body) }
        let snapshot = try await provider(region: .china, key: "sk-api-test-only").fetchSnapshot()

        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(snapshot.windows[0].usedFraction ?? -1, 0.04, accuracy: 0.0001)
        let requests = MiniMaxEndpoint.requests
        XCTAssertEqual(requests.map(\.url?.absoluteString), ["https://api.minimaxi.com/v1/token_plan/remains"])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-api-test-only")
    }

    /// An `sk-api-` key MiniMax will not meter is often a pay-as-you-go key
    /// exported as `MINIMAX_API_KEY` for other tools. Its refusal (1004 under
    /// HTTP 200, as api.minimaxi.com answers a key it does not take) must not
    /// hide the console session that used to be read in its place.
    func testARefusedChinaSkAPIKeyStillFallsBackToTheCookie() async throws {
        let body = liveCodingPlanBody
        MiniMaxEndpoint.reset { request in
            request.value(forHTTPHeaderField: "Cookie") == nil
                ? MiniMaxEndpoint.Reply(status: 200, body: Self.keyRefusedBody)
                : MiniMaxEndpoint.Reply(status: 200, body: body)
        }
        let snapshot = try await provider(region: .china, key: "sk-api-test-only",
                                          cookie: "session=test-only").fetchSnapshot()

        XCTAssertEqual(snapshot.fidelity, .derived)
        XCTAssertEqual(snapshot.windows[0].usedFraction ?? -1, 0.75, accuracy: 0.0001)
        let requests = MiniMaxEndpoint.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-api-test-only")
        let cookieRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(cookieRequest.url?.absoluteString,
                       "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains")
        XCTAssertEqual(cookieRequest.value(forHTTPHeaderField: "Cookie"), "session=test-only")
        XCTAssertNil(cookieRequest.value(forHTTPHeaderField: "Authorization"))
    }

    /// With nothing else to ask, a refused `sk-api-` key reads as it did when
    /// it was skipped: signed out, not a new error state.
    func testARefusedChinaSkAPIKeyWithNoSessionIsStillNeedsAuth() async {
        MiniMaxEndpoint.reset { _ in MiniMaxEndpoint.Reply(status: 200, body: Self.keyRefusedBody) }
        await assertNeedsAuth(provider(region: .china, key: "sk-api-test-only"))
        XCTAssertEqual(MiniMaxEndpoint.requests.count, 3)
    }

    /// Nothing has shown the international hosts metering an `sk-api-` key,
    /// so that path is unchanged: the key is skipped without a request.
    func testAnInternationalSkAPIKeyIsStillSkipped() async {
        MiniMaxEndpoint.reset { _ in nil }
        await assertNeedsAuth(provider(region: .international, key: "sk-api-test-only"))
        XCTAssertTrue(MiniMaxEndpoint.requests.isEmpty)
    }

    private static let keyRefusedBody = #"{"base_resp":{"status_code":1004,"status_msg":"login fail: Please carry the API secret key in the 'Authorization' field of the request header"}}"#

    /// Timestamps are relative to the real clock: the provider reads with `Date()`.
    private var liveTokenPlanBody: String {
        let start = Int(Date().timeIntervalSince1970 * 1000)
        return """
        { "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            { "model_name": "general",
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "current_interval_remaining_percent": 96,
              "start_time": \(start),
              "end_time": \(start + 5 * 60 * 60 * 1000),
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "current_weekly_remaining_percent": 99,
              "weekly_start_time": \(start),
              "weekly_end_time": \(start + 7 * 24 * 60 * 60 * 1000) } ] }
        """
    }

    private var liveCodingPlanBody: String {
        let start = Int(Date().timeIntervalSince1970 * 1000)
        return """
        { "base_resp": { "status_code": 0 },
          "model_remains": [
            { "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "start_time": \(start),
              "end_time": \(start + 5 * 60 * 60 * 1000) } ] }
        """
    }

    private func provider(region: MiniMaxRegion, key: String, cookie: String? = nil) -> MiniMaxProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MiniMaxEndpoint.self]
        let name = "MiniMaxUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return MiniMaxProvider(session: URLSession(configuration: configuration),
                               region: region,
                               archive: UsageArchive(defaults: defaults),
                               loadAPIKey: { key },
                               loadCookieHeader: { cookie })
    }

    private func assertNeedsAuth(_ provider: MiniMaxProvider,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth", file: file, line: line)
        } catch UsageProviderError.needsAuth {
        } catch {
            XCTFail("expected needsAuth, got \(error)", file: file, line: line)
        }
    }
}

private final class MiniMaxEndpoint: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
    }
    private static let lock = NSLock()
    private static var respond: (URLRequest) -> Reply? = { _ in nil }
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }

    /// Answers by request rather than by order, so a test reads the same
    /// whether or not the key is asked before the cookie.
    static func reset(_ responder: @escaping (URLRequest) -> Reply?) {
        lock.withLock { respond = responder; recorded = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { () -> Reply? in
            Self.recorded.append(request)
            return Self.respond(request)
        }
        guard let reply else {
            XCTFail("unexpected MiniMax request to \(request.url?.absoluteString ?? "")")
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
