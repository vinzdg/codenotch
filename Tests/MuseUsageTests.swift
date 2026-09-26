import XCTest
@testable import Codenotch

/// One model_completed line in muse's session logs. `recorded_at` is
/// microseconds since the epoch; the tests below pin that unit.
private func museRecord(at date: Date,
                        input: Int = 100, output: Int = 10,
                        reasoning: Int = 2, cached: Int = 0,
                        durationMs: Int? = 1000,
                        model: String? = "muse-spark-1.3-contributor") -> String {
    let micro = Int(date.timeIntervalSince1970 * 1_000_000)
    let duration = durationMs.map { ",\"duration_ms\":\($0)" } ?? ""
    let modelField = model.map { ",\"model\":\"\($0)\"" } ?? ""
    return #"{"recorded_at":\#(micro),"payload_type":"runtime.session","payload":{"kind":"run","event":{"kind":"model_completed","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cached_tokens":\#(cached),"reasoning_tokens":\#(reasoning)}\#(duration)\#(modelField)}}}"#
}

private func museUTC() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

/// Parsing muse's session logs: one model_completed event per billed request,
/// counts and timestamps only — no prompt or reply text ever enters a sample.
final class MuseUsageParsingTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    func testParsesACompletedModelCall() throws {
        let samples = MuseUsage.samples(from: museRecord(at: at) + "\n")
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(sample.at, at)
        XCTAssertEqual(sample.inputTokens, 100)
        XCTAssertEqual(sample.outputTokens, 10)
        XCTAssertEqual(sample.reasoningTokens, 2)
        XCTAssertEqual(sample.cachedTokens, 0)
        XCTAssertEqual(sample.totalTokens, 110)
        XCTAssertEqual(try XCTUnwrap(sample.duration), 1, accuracy: 1e-9)
    }

    func testSkipsAnythingThatIsNotACompletedCall() {
        let lines = [
            museRecord(at: at),
            #"{"recorded_at":1800000000000000,"payload_type":"runtime.session","payload":{"kind":"run","event":{"kind":"model_started"}}}"#,
            #"{"kind":"goal_usage_attribution","record":{"usage_id":"usage-1"}}"#,
            "not json at all",
            "",
            // A usage-shaped object outside a model_completed event is not a request.
            #"{"recorded_at":1800000000000000,"payload":{"event":{"kind":"status","usage":{"input_tokens":5,"output_tokens":5}}}}"#,
        ]
        XCTAssertEqual(MuseUsage.samples(from: lines.joined(separator: "\n")).count, 1)
    }

    func testSkipsRecordsWithoutATimestamp() {
        let line = #"{"payload_type":"runtime.session","payload":{"kind":"run","event":{"kind":"model_completed","usage":{"input_tokens":5,"output_tokens":5}}}}"#
        XCTAssertTrue(MuseUsage.samples(from: line).isEmpty)
    }

    func testMissingCountsReadAsZero() throws {
        let line = #"{"recorded_at":1800000000000000,"payload_type":"runtime.session","payload":{"kind":"run","event":{"kind":"model_completed","usage":{"input_tokens":5}}}}"#
        let sample = try XCTUnwrap(MuseUsage.samples(from: line).first)
        XCTAssertEqual(sample.totalTokens, 5)
        XCTAssertEqual(sample.outputTokens, 0)
        XCTAssertNil(sample.duration)
    }

    func testMentionsOfTheEventElsewhereAreNotRequests() {
        // The prefilter looks for the event name; only a real event decodes.
        let line = #"{"recorded_at":1800000000000000,"payload_type":"transcript","payload":{"text":"the model_completed event fired twice"}}"#
        XCTAssertTrue(MuseUsage.samples(from: line).isEmpty)
    }
}

final class MuseUsageLogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseUsageLogTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ text: String, at relative: String, mtime: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime],
                                                  ofItemAtPath: url.path)
        }
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testCollectsSessionsAndSubagentsSkippingViewsAndStrays() throws {
        let now = Date()
        try write(museRecord(at: now) + "\n", at: "sessions/2026/09/25/aaa/session.jsonl")
        try write(museRecord(at: now, input: 50) + "\n",
                  at: "sessions/2026/09/25/aaa/subagent/bbb/session.jsonl")
        // The materialised views are binary projections, not logs.
        try write(museRecord(at: now, input: 999) + "\n",
                  at: "sessions/.msp-view-v1/aaa/session.jsonl")
        // Only session logs count, whatever else lands beside them.
        try write(museRecord(at: now, input: 999) + "\n", at: "sessions/2026/09/25/aaa/cli-x.log")

        var log = MuseUsageLog()
        let samples = log.scan(at: root.appendingPathComponent("sessions"), now: now)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.map(\.inputTokens).sorted(), [50, 100])
    }

    func testReadsOnlyAppendsAndHoldsPartialLines() throws {
        let now = Date()
        let url = try write(museRecord(at: now) + "\n",
                            at: "sessions/2026/09/25/aaa/session.jsonl")
        var log = MuseUsageLog()
        let sessions = root.appendingPathComponent("sessions")
        XCTAssertEqual(log.scan(at: sessions, now: now).count, 1)

        // An unterminated line is still being written: hold it, don't parse it.
        try append(String(museRecord(at: now, input: 50).prefix(60)), to: url)
        XCTAssertEqual(log.scan(at: sessions, now: now).count, 1)

        try append(String(museRecord(at: now, input: 50).dropFirst(60)) + "\n", to: url)
        let samples = log.scan(at: sessions, now: now)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.map(\.inputTokens).sorted(), [50, 100])
    }

    func testRescansFilesThatShrank() throws {
        let now = Date()
        let url = try write(museRecord(at: now) + "\n" + museRecord(at: now, input: 50) + "\n",
                            at: "sessions/2026/09/25/aaa/session.jsonl")
        var log = MuseUsageLog()
        let sessions = root.appendingPathComponent("sessions")
        XCTAssertEqual(log.scan(at: sessions, now: now).count, 2)

        try (museRecord(at: now, input: 7) + "\n").write(to: url, atomically: true, encoding: .utf8)
        let samples = log.scan(at: sessions, now: now)
        XCTAssertEqual(samples.map(\.inputTokens), [7])
    }

    func testSkipsFilesUntouchedPastTheWindow() throws {
        let now = Date()
        try write(museRecord(at: now) + "\n",
                  at: "sessions/2026/09/25/aaa/session.jsonl",
                  mtime: now.addingTimeInterval(-40 * 86400))
        var log = MuseUsageLog()
        XCTAssertTrue(log.scan(at: root.appendingPathComponent("sessions"), now: now).isEmpty)
    }

    func testPrunesSamplesPastTheWindow() throws {
        let now = Date()
        try write(museRecord(at: now.addingTimeInterval(-50 * 86400), input: 999) + "\n"
            + museRecord(at: now) + "\n",
                  at: "sessions/2026/09/25/aaa/session.jsonl")
        var log = MuseUsageLog()
        let samples = log.scan(at: root.appendingPathComponent("sessions"), now: now)
        XCTAssertEqual(samples.map(\.inputTokens), [100])
    }
}

final class MuseAggregationTests: XCTestCase {
    private let calendar = museUTC()
    private let today = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(daysAgo: Int, input: Int, output: Int = 10,
                        reasoning: Int = 0, duration: TimeInterval? = nil) -> MuseUsage.Sample {
        let at = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
            .addingTimeInterval(3600)
        return MuseUsage.Sample(at: at, inputTokens: input, outputTokens: output,
                                reasoningTokens: reasoning, duration: duration)
    }

    func testDailyBucketsFileUnderLocalDays() {
        let buckets = MuseUsage.dailyBuckets(
            from: [sample(daysAgo: 1, input: 100), sample(daysAgo: 1, input: 50),
                   sample(daysAgo: 0, input: 200)],
            now: today, calendar: calendar)
        let keyed = Dictionary(uniqueKeysWithValues: buckets.map { ($0.startDate, $0.tokens) })
        XCTAssertEqual(keyed[MuseUsage.dayKey(for: today, calendar: calendar)], 210)
        XCTAssertEqual(keyed[MuseUsage.dayKey(
            for: calendar.date(byAdding: .day, value: -1, to: today)!, calendar: calendar)], 170)
    }

    func testTodayBucketIsPresentEvenWhenIdle() {
        // Local logs are complete: a missing today is a real zero, not pending.
        let buckets = MuseUsage.dailyBuckets(from: [sample(daysAgo: 3, input: 100)],
                                             now: today, calendar: calendar)
        let keyed = Dictionary(uniqueKeysWithValues: buckets.map { ($0.startDate, $0.tokens) })
        XCTAssertEqual(keyed[MuseUsage.dayKey(for: today, calendar: calendar)], 0)
    }

    func testSummaryReportsPeakLongestTurnAndStreaks() {
        let samples = [sample(daysAgo: 0, input: 100, duration: 2),
                       sample(daysAgo: 1, input: 500, duration: 9),
                       sample(daysAgo: 2, input: 300),
                       sample(daysAgo: 5, input: 50)]
        let summary = MuseUsage.summary(from: samples, now: today, calendar: calendar)
        // Lifetime is unknowable from a bounded scan, so it stays blank.
        XCTAssertNil(summary.lifetimeTokens)
        XCTAssertEqual(summary.peakDailyTokens, 510)
        XCTAssertEqual(summary.longestRunningTurnSeconds, 9)
        XCTAssertEqual(summary.currentStreakDays, 3)
        XCTAssertEqual(summary.longestStreakDays, 3)
    }

    func testCurrentStreakSurvivesAnIdleToday() {
        let samples = [sample(daysAgo: 1, input: 100), sample(daysAgo: 2, input: 100)]
        let summary = MuseUsage.summary(from: samples, now: today, calendar: calendar)
        XCTAssertEqual(summary.currentStreakDays, 2)
    }

    func testWindowsCountToday() throws {
        let samples = [sample(daysAgo: 0, input: 12_400, output: 3_100, reasoning: 310),
                       sample(daysAgo: 0, input: 100, output: 10),
                       sample(daysAgo: 1, input: 999)]
        let windows = MuseUsage.windows(from: samples, now: today, calendar: calendar)
        let todayWindow = try XCTUnwrap(windows.first { $0.id == "today" })
        XCTAssertEqual(todayWindow.used, 15_610)
        XCTAssertEqual(todayWindow.detail, "12k in · 3110 out")
        let requests = try XCTUnwrap(windows.first { $0.id == "requests" })
        XCTAssertEqual(requests.used, 2)
        let reasoning = try XCTUnwrap(windows.first { $0.id == "reasoning" })
        XCTAssertEqual(reasoning.detail, "10%")

        let snapshot = ProviderSnapshot(
            id: "muse", displayName: "Muse", glyph: .meta, fidelity: .derived,
            status: .ok, windows: windows, headlineID: "today", plan: nil)
        XCTAssertEqual(snapshot.headlineText, "15k")
    }
}

final class MuseLocalProviderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseLocalProviderTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testFetchesQuotaWithCountsUnderneath() async throws {
        let sessions = root.appendingPathComponent("sessions/2026/09/25/aaa")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try (museRecord(at: Date(), input: 12_400, output: 3_100) + "\n")
            .write(to: sessions.appendingPathComponent("session.jsonl"),
                   atomically: true, encoding: .utf8)
        MuseEndpoint.reset([(200, """
            event: response.subscription_usage
            data: {"subscription":{"tier":"t","weekly":{"resets_at":1790553600,"used_percent":12},"window":{"resets_at":1790370963,"used_percent":34,"window_duration_mins":300}},"type":"response.subscription_usage"}

            """)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MuseEndpoint.self]
        let provider = MuseLocalProvider(
            sessionsURL: root.appendingPathComponent("sessions"),
            authURL: root.appendingPathComponent("auth.json"),
            session: URLSession(configuration: configuration),
            keychain: MuseKeychain(reader: { _ in "test-key" }))
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.id, "muse")
        XCTAssertEqual(snapshot.headlineText, "34%")
        XCTAssertEqual(snapshot.tokenUsage?.usageToday(), 15_500)
    }

    func testRefreshesOnTheIdleTimer() {
        // Each quota poll spends one minimal metered request (~30 tokens),
        // accepted so the ring stays realtime.
        XCTAssertFalse(MuseLocalProvider().skipsIdleRefresh)
    }

    func testAccountReadsTheLoginEmail() throws {
        let auth = root.appendingPathComponent("auth.json")
        try #"{"schema_version":2,"providers":{"meta":{"mechanism":"oauth","user_full_name":"Ada","user_email":"ada@example.com"}}}"#
            .write(to: auth, atomically: true, encoding: .utf8)
        let account = MuseCredentials.account(from: auth)
        XCTAssertEqual(account?.label, "ada@example.com")
        XCTAssertTrue(MuseCredentials.anySourceExists(
            sessions: root.appendingPathComponent("sessions"), auth: auth))
        XCTAssertNil(MuseCredentials.account(from: root.appendingPathComponent("missing.json")))
        XCTAssertFalse(MuseCredentials.anySourceExists(
            sessions: root.appendingPathComponent("sessions"),
            auth: root.appendingPathComponent("missing.json")))
    }
}

/// The quota % arrives only inside a model response's SSE stream, as a
/// `response.subscription_usage` frame — there is no passive endpoint for it.
final class MuseQuotaParsingTests: XCTestCase {
    private let frame = #"data: {"subscription":{"tier":"t1","weekly":{"resets_at":1790553600,"used_percent":12},"window":{"resets_at":1790370963,"used_percent":34,"window_duration_mins":300}},"type":"response.subscription_usage"}"#

    func testExtractsTheSubscriptionFrame() throws {
        let sse = "event: response.created\ndata: {\"x\":1}\n\nevent: response.subscription_usage\n"
            + frame + "\n\nevent: response.completed\ndata: [DONE]\n\n"
        let payload = try XCTUnwrap(MuseUsage.subscriptionPayload(fromSSE: sse))
        XCTAssertTrue(String(data: payload, encoding: .utf8)?.contains("used_percent") ?? false)
    }

    func testMissingFrameYieldsNothing() {
        XCTAssertNil(MuseUsage.subscriptionPayload(fromSSE: "event: response.created\ndata: {}\n\n"))
    }

    func testQuotaWindowsReadFiveHourAndWeekly() throws {
        let json = String(frame.dropFirst("data: ".count))
        let windows = try MuseUsage.quotaWindows(from: Data(json.utf8))
        let fiveHour = try XCTUnwrap(windows.first { $0.id == "window" })
        XCTAssertEqual(fiveHour.usedFraction, 0.34)
        XCTAssertEqual(fiveHour.resetsAt, Date(timeIntervalSince1970: 1790370963))
        XCTAssertEqual(fiveHour.duration, 300 * 60)
        XCTAssertTrue(fiveHour.isFiveHour)
        let weekly = try XCTUnwrap(windows.first { $0.id == "weekly" })
        XCTAssertEqual(weekly.usedFraction, 0.12)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1790553600))
        XCTAssertEqual(weekly.duration, 7 * 86400)
    }

    func testOverQuotaPercentsStayVerbatim() throws {
        let json = #"{"subscription":{"tier":"t","weekly":{"resets_at":1790553600,"used_percent":3},"window":{"resets_at":1790370963,"used_percent":128,"window_duration_mins":300}}}"#
        let windows = try MuseUsage.quotaWindows(from: Data(json.utf8))
        XCTAssertEqual(try XCTUnwrap(windows.first { $0.id == "window" }).usedFraction, 1.28)
    }

    func testMalformedQuotaThrows() {
        XCTAssertThrowsError(try MuseUsage.quotaWindows(from: Data("nope".utf8)))
    }

    func testSecretParsingReadsOnlyTheAPIKey() {
        XCTAssertEqual(MuseCredentials.parseAPIKey(
            from: #"{"access_token":"oauth-secret","api_key":"minted-key","secret_schema_version":1}"#),
            "minted-key")
        XCTAssertNil(MuseCredentials.parseAPIKey(from: #"{"access_token":"x"}"#))
        XCTAssertNil(MuseCredentials.parseAPIKey(from: "nope"))
    }
}

final class MuseKeychainTests: XCTestCase {
    func testLoadCachesUntilAskedAgain() throws {
        var reads = 0
        let keychain = MuseKeychain(reader: { _ in reads += 1; return "k" })
        XCTAssertEqual(try keychain.load(), "k")
        XCTAssertEqual(try keychain.load(), "k")
        XCTAssertEqual(reads, 1)
        keychain.forgetCached()
        XCTAssertEqual(try keychain.load(), "k")
        XCTAssertEqual(reads, 2)
    }

    func testDenyIsHonouredUntilAskAgain() throws {
        let keychain = MuseKeychain(reader: { _ in throw UsageProviderError.accessDenied })
        keychain.askAgain()
        XCTAssertThrowsError(try keychain.load()) { error in
            guard case UsageProviderError.accessDenied = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertTrue(keychain.isRefused)
        // The refusal stands without touching the reader again.
        var reads = 0
        let denying = MuseKeychain(reader: { _ in reads += 1; throw UsageProviderError.accessDenied })
        denying.askAgain()
        _ = try? denying.load()
        _ = try? denying.load()
        XCTAssertEqual(reads, 1)
    }
}

final class MuseQuotaFetchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseQuotaFetchTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        MuseEndpoint.reset()
    }

    private func makeProvider(status: Int = 200, body: String) -> MuseLocalProvider {
        MuseEndpoint.reset([(status, body)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MuseEndpoint.self]
        return MuseLocalProvider(
            sessionsURL: root.appendingPathComponent("sessions"),
            authURL: root.appendingPathComponent("auth.json"),
            session: URLSession(configuration: configuration),
            keychain: MuseKeychain(reader: { _ in "test-key" }))
    }

    private let quotaSSE = """
        event: response.created
        data: {"x":1}

        event: response.subscription_usage
        data: {"subscription":{"tier":"t1","weekly":{"resets_at":1790553600,"used_percent":12},"window":{"resets_at":1790370963,"used_percent":34,"window_duration_mins":300}},"type":"response.subscription_usage"}

        """

    func testFetchesPercentWindows() async throws {
        let snapshot = try await makeProvider(body: quotaSSE).fetchSnapshot()
        XCTAssertEqual(snapshot.headlineText, "34%")
        XCTAssertEqual(snapshot.weeklyFraction, 0.12)
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(MuseEndpoint.requestCount, 1)
        // The token activity stays underneath the quota, from the (empty) logs.
        XCTAssertEqual(snapshot.tokenUsage?.usageToday(), 0)
    }

    func testExhaustedWeeklyBlocksTheFiveHourRing() async throws {
        let spent = """
            event: response.subscription_usage
            data: {"subscription":{"tier":"t1","weekly":{"resets_at":1790553600,"used_percent":100},"window":{"resets_at":1790370963,"used_percent":20,"window_duration_mins":300}},"type":"response.subscription_usage"}

            """
        // The store attaches the block on publication; the fetch pins that the
        // parsed windows carry what the rule needs.
        let snapshot = try await makeProvider(body: spent).fetchSnapshot().blockingSpentWeek()
        // A spent week leaves the 5-hour allowance unusable: the ring must
        // not read green, while the headline keeps its own 5-hour figure.
        XCTAssertEqual(snapshot.headlineText, "20%")
        let block = try XCTUnwrap(snapshot.block)
        XCTAssertEqual(block.reason, "Weekly limit reached")
        XCTAssertEqual(block.resetsAt, Date(timeIntervalSince1970: 1790553600))
    }

    func testUnspentWeeklyLeavesTheRingUnblocked() async throws {
        let snapshot = try await makeProvider(body: quotaSSE).fetchSnapshot().blockingSpentWeek()
        XCTAssertNil(snapshot.block)
    }

    func testUnauthorizedForgetsAndReportsExpired() async throws {
        let provider = makeProvider(status: 401, body: "{}")
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected credentialExpired")
        } catch UsageProviderError.credentialExpired {
            // The CLI re-mints on next use; the held copy is dropped so the
            // next fetch re-reads.
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMissingCredentialNeedsAuth() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MuseEndpoint.self]
        let provider = MuseLocalProvider(
            sessionsURL: root.appendingPathComponent("sessions"),
            authURL: root.appendingPathComponent("auth.json"),
            session: URLSession(configuration: configuration),
            keychain: MuseKeychain(reader: { _ in throw UsageProviderError.needsAuth }))
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth")
        } catch UsageProviderError.needsAuth {
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(MuseEndpoint.requestCount, 0)
    }

    func testLiveQuotaWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODENOTCH_TEST_MUSE_LIVE"] == "1" else {
            throw XCTSkip("Opt-in live check requires a signed-in Muse CLI")
        }
        let snapshot = try await MuseLocalProvider().fetchSnapshot()
        XCTAssertNotNil(snapshot.usedFraction)
        XCTAssertNotNil(snapshot.weeklyFraction)
        print("Muse live quota: 5h \(snapshot.headlineText), weekly \(snapshot.weeklyFraction.map { Percent.text(for: $0) } ?? "missing")%")
    }
}

private final class MuseEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var answers: [(Int, String)] = []
    private static var count = 0

    static var requestCount: Int { lock.withLock { count } }

    static func reset(_ values: [(Int, String)] = []) {
        lock.withLock { answers = values; count = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        XCTAssertEqual(request.url?.absoluteString, "https://api.meta.ai/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        // The quota poll stays minimal: a one-word prompt, the smallest
        // accepted output, streamed so the usage frame arrives.
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let capacity = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: capacity)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            bodyData = data
        }
        let body = try? JSONSerialization.jsonObject(with: bodyData ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "muse-spark-1.3")
        XCTAssertEqual(body?["max_output_tokens"] as? Int, 16)
        XCTAssertEqual(body?["stream"] as? Bool, true)
        let answer = Self.lock.withLock {
            Self.count += 1
            return Self.answers.isEmpty ? (500, "") : Self.answers.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Providers whose refresh costs something per call sit out the idle tick and
/// refresh on launch, on wake, on a rollover, and whenever asked.
@MainActor
final class MuseIdleRefreshTests: XCTestCase {
    private actor Stub: UsageProvider {
        nonisolated let id: String
        nonisolated let displayName: String
        nonisolated let glyph = ProviderGlyph.meta
        nonisolated let skipsIdleRefresh: Bool
        var fetches = 0

        init(id: String, skipsIdleRefresh: Bool) {
            self.id = id
            self.displayName = id
            self.skipsIdleRefresh = skipsIdleRefresh
        }

        func fetchSnapshot() async throws -> ProviderSnapshot {
            fetches += 1
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok, windows: [])
        }
    }

    private func makeStore(auto: Stub, manual: Stub) -> UsageStore {
        let name = "MuseIdleRefreshTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return UsageStore(providers: [auto, manual], archive: UsageArchive(defaults: defaults))
    }

    func testIdleTickSkipsManualProviders() async throws {
        let auto = Stub(id: "auto", skipsIdleRefresh: false)
        let manual = Stub(id: "manual", skipsIdleRefresh: true)
        await makeStore(auto: auto, manual: manual).refresh(includeIdleSkipped: false)
        let autoFetches = await auto.fetches
        let manualFetches = await manual.fetches
        XCTAssertEqual(autoFetches, 1)
        XCTAssertEqual(manualFetches, 0)
    }

    func testManualRefreshIncludesEveryone() async throws {
        let auto = Stub(id: "auto", skipsIdleRefresh: false)
        let manual = Stub(id: "manual", skipsIdleRefresh: true)
        await makeStore(auto: auto, manual: manual).refresh()
        let autoFetches = await auto.fetches
        let manualFetches = await manual.fetches
        XCTAssertEqual(autoFetches, 1)
        XCTAssertEqual(manualFetches, 1)
    }
}
