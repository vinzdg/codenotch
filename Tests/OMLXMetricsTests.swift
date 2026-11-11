import XCTest
import Combine
@testable import Codenotch

/// An activity endpoint that answers from a script, so the monitor's folding
/// of polls and log lines can be driven without oMLX.
@MainActor
final class OMLXLinkStub: OMLXCalling {
    var answer = OMLXActivity(models: [])
    var failure: Error?
    var calls = 0
    var closed = 0

    func activity() async throws -> OMLXActivity {
        calls += 1
        if let failure { throw failure }
        return answer
    }

    func close() async { closed += 1 }
}

private enum OMLXMetricsFixtures {
    static let zone = TimeZone(identifier: "Europe/Warsaw")!
    static let model = "Qwen3.8-27B-oQ8e-mtp"
    static let streamed = "2026-10-07 23:09:35,762 - omlx.server - INFO - [-] - Chat completion: model=Qwen3.8-27B-oQ8e-mtp, 430 tokens in 10.97s (42.8 tok/s), prompt: 68, finish_reason=stop, max_tokens=32768, request_max_tokens=None, stream_model_ttft=0.91s, stream_visible_ttft=0.97s\n"
    static let anthropic = "2026-10-08 09:00:00,000 - omlx.server - INFO - [-] - Anthropic message: model=Qwen3.8-27B-oQ8e-mtp, 1200 tokens in 40.00s (30.0 tok/s)\n"

    static func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int, _ millisecond: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute,
                                                  second: second, nanosecond: millisecond * 1_000_000))!
    }

    static func generating(tokens: Int = 10) -> OMLXActivity.Generating {
        OMLXActivity.Generating(generatedTokens: tokens, elapsedSeconds: 1, tokensPerSecond: 40, promptTokens: 68)
    }
}

@MainActor
final class OMLXMetricsTests: XCTestCase {
    private var logs: URL!
    private var cancellables = Set<AnyCancellable>()

    override func setUpWithError() throws {
        logs = FileManager.default.temporaryDirectory.appendingPathComponent("OMLXMetricsTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: logs)
    }

    private func metrics(link: OMLXLinkStub, now: @escaping () -> Date = Date.init) -> OMLXMetrics {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = OMLXMetricsFixtures.zone
        return OMLXMetrics(makeLink: { _ in link }, logsDirectory: logs,
                           pollInterval: 0.03, logInterval: 0.03, now: now, calendar: calendar)
    }

    private func wait<T: Equatable>(for publisher: Published<T>.Publisher, _ description: String,
                                    until condition: @escaping (T) -> Bool) async {
        let expectation = expectation(description: description)
        var done = false
        publisher.sink { value in
            guard !done, condition(value) else { return }
            done = true
            expectation.fulfill()
        }.store(in: &cancellables)
        await fulfillment(of: [expectation], timeout: 3)
    }

    func testTheCellIDIsNamespacedUnderTheProvider() {
        XCTAssertEqual(OMLXMetrics.providerID, "omlx")
        XCTAssertEqual(OMLXMetrics.cellID(instance: OMLXMetricsFixtures.model), "omlx:model:Qwen3.8-27B-oQ8e-mtp")
        XCTAssertEqual(OMLXMetrics.cellID(instance: "x"), OMLXIdentity.cellID(instance: "x"))
    }

    func testAPollBecomesActivityPhaseAndQueue() {
        let metrics = metrics(link: OMLXLinkStub())
        let t0 = Date(timeIntervalSince1970: 1_000)
        let qwen = OMLXMetricsFixtures.model
        let cell = OMLXMetrics.cellID(instance: qwen)

        metrics.observe(OMLXActivity(models: [
            .init(id: qwen, waiting: 2, prefilling: 1, generating: [OMLXMetricsFixtures.generating()]),
            .init(id: "idle-model"),
        ]), at: t0)
        XCTAssertEqual(metrics.activities, [cell: LocalModelActivity(phase: .processingPrompt, queued: 2, since: t0)],
                       "a prompt being read wins over another request generating, and an idle model is no activity")
        XCTAssertTrue(metrics.isBusy)

        metrics.observe(OMLXActivity(models: [.init(id: qwen, waiting: 1, prefilling: 1)]), at: t0.addingTimeInterval(1))
        XCTAssertEqual(metrics.activities[cell]?.since, t0, "the phase continues, so its start does")
        XCTAssertEqual(metrics.activities[cell]?.queued, 1)

        metrics.observe(OMLXActivity(models: [.init(id: qwen, generating: [OMLXMetricsFixtures.generating()])]),
                        at: t0.addingTimeInterval(2))
        XCTAssertEqual(metrics.activities[cell], LocalModelActivity(phase: .generating, queued: 0, since: t0.addingTimeInterval(2)))

        metrics.observe(OMLXActivity(models: [.init(id: qwen, activities: 1)]), at: t0.addingTimeInterval(3))
        XCTAssertEqual(metrics.activities[cell]?.phase, .generating, "a non-streaming engine's work is generating")
        XCTAssertEqual(metrics.activities[cell]?.since, t0.addingTimeInterval(2))

        metrics.observe(OMLXActivity(models: [.init(id: qwen)]), at: t0.addingTimeInterval(5))
        XCTAssertTrue(metrics.activities.isEmpty)
        XCTAssertFalse(metrics.isBusy)

        metrics.observe(OMLXActivity(models: [.init(id: qwen, waiting: 3)]), at: t0.addingTimeInterval(6))
        XCTAssertTrue(metrics.activities.isEmpty, "a queue with nothing in progress is not a phase")
        XCTAssertFalse(metrics.isBusy)
    }

    func testHistoryIsDatedByTheLogAndEveryLoggedSpeedIsExact() throws {
        let metrics = metrics(link: OMLXLinkStub())
        var parser = OMLXServerLog(timeZone: OMLXMetricsFixtures.zone)
        let events = parser.append(Data((OMLXMetricsFixtures.streamed + OMLXMetricsFixtures.anthropic).utf8))
        XCTAssertEqual(events.count, 2)
        metrics.absorb(events, live: false)

        let cell = OMLXMetrics.cellID(instance: OMLXMetricsFixtures.model)
        let speed = try XCTUnwrap(metrics.performances[cell])
        XCTAssertFalse(speed.isApproximate)
        XCTAssertEqual(speed.outputTokens, 1200, "the newer of the two responses")
        XCTAssertEqual(speed.tokensPerSecond, 30, accuracy: 0.001)
        XCTAssertEqual(speed.measuredAt, OMLXMetricsFixtures.date(8, 9, 0, 0))
        XCTAssertEqual(metrics.ledger.instances, [cell])
        let summary = try XCTUnwrap(metrics.ledger.summary(for: cell, now: OMLXMetricsFixtures.date(8, 12, 0, 0)))
        XCTAssertEqual(summary.today.requests, 1, "yesterday's line is filed under yesterday")
        XCTAssertEqual(summary.today.outputTokens, 1200)

        // An older line read later does not replace the newer speed.
        metrics.absorb(parser.append(Data(OMLXMetricsFixtures.streamed.utf8)), live: false)
        XCTAssertEqual(metrics.performances[cell], speed)
    }

    func testALiveLineIsDatedByWhenItWasRead() throws {
        let clock = OMLXMetricsFixtures.date(8, 10, 0, 0)
        let metrics = metrics(link: OMLXLinkStub(), now: { clock })
        var parser = OMLXServerLog(timeZone: OMLXMetricsFixtures.zone)
        metrics.absorb(parser.append(Data(OMLXMetricsFixtures.streamed.utf8)), live: true)
        let cell = OMLXMetrics.cellID(instance: OMLXMetricsFixtures.model)
        let speed = try XCTUnwrap(metrics.performances[cell])
        XCTAssertFalse(speed.isApproximate)
        XCTAssertEqual(speed.outputTokens, 430)
        XCTAssertEqual(speed.tokensPerSecond, 42.8, accuracy: 0.001)
        XCTAssertEqual(speed.measuredAt, clock)
        XCTAssertEqual(metrics.ledger.summary(for: cell, now: clock)?.last?.inputTokens, 68)
    }

    func testTheLinkIsPolledAndTheLogIsTailedWhileEnabled() async throws {
        let link = OMLXLinkStub()
        let qwen = OMLXMetricsFixtures.model
        link.answer = OMLXActivity(models: [.init(id: qwen, waiting: 1, generating: [OMLXMetricsFixtures.generating()])])
        let file = logs.appendingPathComponent("server.log")
        try Data(OMLXMetricsFixtures.streamed.utf8).write(to: file)
        let metrics = metrics(link: link)
        XCTAssertEqual(metrics.status, "Off")
        metrics.configure(enabled: true, endpoint: "http://127.0.0.1:8000")

        let cell = OMLXMetrics.cellID(instance: qwen)
        await wait(for: metrics.$activities, "generating") { $0[cell]?.phase == .generating && $0[cell]?.queued == 1 }
        XCTAssertTrue(metrics.linked)
        XCTAssertTrue(metrics.isBusy)
        XCTAssertEqual(metrics.status, "Connected · 1 loaded")
        await wait(for: metrics.$historyLoaded, "history") { $0 }
        XCTAssertEqual(metrics.ledger.instances, [cell])
        XCTAssertEqual(metrics.performances[cell]?.outputTokens, 430)

        // A line written now is read within a poll or two.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(OMLXMetricsFixtures.anthropic.utf8))
        try handle.close()
        await wait(for: metrics.$performances, "live speed") { $0[cell]?.outputTokens == 1200 }
        XCTAssertEqual(metrics.performances[cell]?.isApproximate, false)

        link.answer = OMLXActivity(models: [.init(id: qwen)])
        await wait(for: metrics.$activities, "idle") { $0.isEmpty }
        XCTAssertFalse(metrics.isBusy)

        // The server going away clears activity and says so, without dropping
        // the ledger that was read from disk.
        link.failure = OMLXError.unavailable
        await wait(for: metrics.$linked, "unlinked") { !$0 }
        XCTAssertEqual(metrics.status, OMLXError.unavailable.localizedDescription)
        XCTAssertFalse(metrics.ledger.isEmpty)

        metrics.configure(enabled: false, endpoint: "http://127.0.0.1:8000")
        XCTAssertEqual(metrics.status, "Off")
        XCTAssertFalse(metrics.linked)
        XCTAssertFalse(metrics.historyLoaded)
        XCTAssertTrue(metrics.activities.isEmpty)
        XCTAssertTrue(metrics.performances.isEmpty)
        XCTAssertTrue(metrics.ledger.isEmpty)
        // A poll already in flight may still land; after that, nothing more.
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertGreaterThan(link.closed, 0)
        let calls = link.calls
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(link.calls, calls, "switched off means no more polling")
    }

    func testARefusedKeySaysWhereTheKeyIsReadAndBacksOff() async throws {
        let link = OMLXLinkStub()
        link.answer = OMLXActivity(models: [.init(id: OMLXMetricsFixtures.model, prefilling: 1)])
        link.failure = OMLXError.needsKey
        let metrics = metrics(link: link)
        metrics.configure(enabled: true, endpoint: "http://127.0.0.1:8000")
        await wait(for: metrics.$status, "refused") { $0.contains("~/.omlx/settings.json") }
        XCTAssertFalse(metrics.linked)
        XCTAssertTrue(metrics.activities.isEmpty)
        XCTAssertFalse(metrics.isBusy)
        // Ten seconds before the key is tried again, not the poll rate.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(link.calls, 1)
        metrics.stop()
    }

    func testABadAddressNeverOpensALink() {
        let link = OMLXLinkStub()
        var made = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = OMLXMetricsFixtures.zone
        let metrics = OMLXMetrics(makeLink: { _ in made += 1; return link }, logsDirectory: logs,
                                  pollInterval: 0.03, logInterval: 0.03, calendar: calendar)
        metrics.configure(enabled: true, endpoint: "http://10.0.0.5:8000")
        XCTAssertTrue(metrics.status.contains("HTTP address on this Mac"))
        XCTAssertEqual(made, 0)
        XCTAssertEqual(link.calls, 0)
        metrics.stop()
        XCTAssertEqual(metrics.status, "Off")
    }

    // MARK: - The admin activity payload

    func testTheActivityPayloadIsRead() throws {
        // Busy shapes from `admin/routes.py` `_build_active_models_data`
        // (oMLX 0.7.0), wrapped in the recorded idle envelope.
        let body = """
        {"active_models":{"models":[
          {"id":"Qwen3.8-27B-oQ8e-mtp","estimated_size":31501724030,"is_loading":false,"active_requests":1,"waiting_requests":1,
           "waiting":[{"request_id":"r2","queue_position":1,"elapsed_seconds":0.4,"prompt_tokens":512}],
           "activities":[],"prefilling":[],
           "generating":[{"request_id":"r1","elapsed_seconds":3.2,"generated_tokens":128,"tokens_per_second":40.1,
                          "last_activity_age_seconds":0.02,"prompt_tokens":68,"max_tokens":32768}],
           "idle_seconds":0,"ttl_remaining_seconds":null,"dflash":null,"cluster":null},
          {"id":"loading-model","is_loading":true,"loading_elapsed_seconds":2.0,"active_requests":0,"waiting_requests":0,
           "waiting":[],"activities":[],"prefilling":[],"generating":[]}],
         "model_memory_used":35344391664,"model_memory_max":88573582832,
         "total_active_requests":1,"total_waiting_requests":1}}
        """
        let activity = try OMLXActivity.parse(Data(body.utf8))
        XCTAssertEqual(activity.models.map(\.id), ["Qwen3.8-27B-oQ8e-mtp", "loading-model"])
        let qwen = activity.models[0]
        XCTAssertFalse(qwen.isLoading)
        XCTAssertEqual(qwen.waiting, 1)
        XCTAssertEqual(qwen.prefilling, 0)
        XCTAssertEqual(qwen.activities, 0)
        XCTAssertEqual(qwen.generating, [OMLXActivity.Generating(generatedTokens: 128, elapsedSeconds: 3.2,
                                                                  tokensPerSecond: 40.1, promptTokens: 68)])
        XCTAssertTrue(activity.models[1].isLoading)
        XCTAssertTrue(activity.models[1].generating.isEmpty)
    }

    func testTheWrongServiceIsNotAnIdleServer() {
        for body in [#"{"detail":"Admin authentication required"}"#, #"{"active_models":{}}"#,
                     #"{"active_models":{"models":[{"id":""}]}}"#, "not json"] {
            XCTAssertThrowsError(try OMLXActivity.parse(Data(body.utf8)), body) {
                XCTAssertEqual($0 as? OMLXError, .invalidResponse, body)
            }
        }
        XCTAssertEqual(try OMLXActivity.parse(Data(#"{"active_models":{"models":[]}}"#.utf8)).models, [])
    }

    // MARK: - The admin session

    private func link(key: String? = "test-key") -> OMLXLink {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OMLXAdminStubProtocol.self]
        return OMLXLink(endpoint: URL(string: "http://127.0.0.1:8000")!, key: { key }, configuration: configuration)
    }

    private static let idle = Data(#"{"active_models":{"models":[{"id":"Qwen3.8-27B-oQ8e-mtp"}]}}"#.utf8)

    func testARefusedReadLogsInOnceAndRetries() async throws {
        var requests: [URLRequest] = []
        var loggedIn = false
        OMLXAdminStubProtocol.handler = { request in
            requests.append(request)
            switch request.url?.path {
            case "/admin/api/login":
                loggedIn = true
                return (200, Data(#"{"success":true}"#.utf8))
            case "/admin/api/activity":
                return loggedIn ? (200, Self.idle) : (401, Data(#"{"detail":"Admin authentication required"}"#.utf8))
            default:
                return (404, Data())
            }
        }
        let activity = try await link().activity()
        XCTAssertEqual(activity.models.map(\.id), ["Qwen3.8-27B-oQ8e-mtp"])
        XCTAssertEqual(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
                       ["GET /admin/api/activity", "POST /admin/api/login", "GET /admin/api/activity"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"), "the admin routes take the session, not the key")
        let login = try XCTUnwrap(OMLXAdminStubProtocol.body(of: requests[1]))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
        XCTAssertEqual(fields["api_key"] as? String, "test-key")
        XCTAssertEqual(fields["remember"] as? Bool, false)
    }

    func testAKeyThatCannotLogInIsNeedsKey() async {
        var paths: [String] = []
        OMLXAdminStubProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            return (401, Data(#"{"detail":"Invalid API key"}"#.utf8))
        }
        await assertThrows(OMLXError.needsKey) { _ = try await self.link().activity() }
        XCTAssertEqual(paths, ["/admin/api/activity", "/admin/api/login"], "one login attempt per read, no loop")

        paths = []
        await assertThrows(OMLXError.needsKey) { _ = try await self.link(key: nil).activity() }
        XCTAssertEqual(paths, ["/admin/api/activity"], "no key means no login attempt")
    }

    func testOtherFailuresKeepTheirOwnMeaning() async {
        OMLXAdminStubProtocol.handler = { _ in (500, Data()) }
        await assertThrows(OMLXError.http(500)) { _ = try await self.link().activity() }
        OMLXAdminStubProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        await assertThrows(OMLXError.unavailable) { _ = try await self.link().activity() }
        OMLXAdminStubProtocol.handler = { _ in (200, Data("<html>".utf8)) }
        await assertThrows(OMLXError.invalidResponse) { _ = try await self.link().activity() }
    }

    private func assertThrows(_ expected: OMLXError, _ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OMLXError, expected, file: file, line: line)
        }
    }

    func testLiveOMLXActivityWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODENOTCH_OMLX_LIVE"] == "1" else {
            throw XCTSkip("Opt-in live oMLX check (TEST_RUNNER_CODENOTCH_OMLX_LIVE=1)")
        }
        let endpoint = try OMLXEndpoint.parse(OMLXEndpoint.configuredAddress() ?? OMLXEndpoint.defaultAddress)
        let link = OMLXLink(endpoint: endpoint)
        let first = try await link.activity()
        XCTAssertFalse(first.models.isEmpty, "a running oMLX has at least one model loaded")
        // The second read rides on the session cookie the first one obtained.
        let second = try await link.activity()
        XCTAssertEqual(Set(first.models.map(\.id)), Set(second.models.map(\.id)))
        print("oMLX activity: \(second.models.map { "\($0.id) waiting=\($0.waiting) generating=\($0.generating.count)" })")
        await link.close()
    }
}

private final class OMLXAdminStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!

    /// URLSession hands a protocol the body as a stream, not `httpBody`.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var request = self.request
            // Read the stream once, here, so the handler sees a plain body.
            request.httpBody = Self.body(of: request)
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!,
                statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
