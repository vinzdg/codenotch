import XCTest
@testable import Codenotch

/// Lines as oMLX 0.7.0 wrote them on 2026-10-07, with the surrounding chatter
/// the parser must pass over: other loggers, the MTP summary that also says
/// `tok/`, a rejected API call, a model load and a multi-line HTTP error.
enum OMLXLogFixtures {
    static let zone = TimeZone(identifier: "Europe/Warsaw")!

    static let streamed = "2026-10-07 23:09:35,762 - omlx.server - INFO - [-] - Chat completion: model=Qwen3.8-27B-oQ8e-mtp, 430 tokens in 10.97s (42.8 tok/s), prompt: 68, finish_reason=stop, max_tokens=32768, request_max_tokens=None, stream_model_ttft=0.91s, stream_visible_ttft=0.97s\n"

    static let unstreamed = "2026-10-07 17:12:01,118 - omlx.server - INFO - [-] - Chat completion: model=Qwen3.8-27B-oQ4e-mtp, 112 tokens in 3.41s (32.8 tok/s), prompt: 2534, finish_reason=length, max_tokens=32768, request_max_tokens=None\n"

    static let chatter = """
    2026-10-07 18:21:13,895 - omlx.engine_pool - INFO - [-] - Loaded model: Qwen3.8-27B-oQ4e-mtp (actual: 16.24GB, local estimate: 16.60GB, full model: 16.60GB, total: 16.60GB)
    2026-10-07 18:21:23,219 - omlx.patches.mlx_lm_mtp.batch_generator - INFO - [-] - MTP[0] finish=stop tokens=371 cycles=95 tok/cycle=3.91 accept=274/315 (87.0%)
    2026-10-07 18:22:02,511 - omlx.server - WARNING - [-] - GET /v1/models → 401: API key required
    2026-10-07 18:22:04,004 - omlx.engine_pool - INFO - [-] - Loaded model: Qwen3.8-27B-oQ8e-mtp (actual: 28.13GB, local estimate: 29.34GB, full model: 29.34GB, total: 29.34GB)
    2026-10-07 18:22:05,100 - httpx - INFO - [-] - HTTP Request: GET https://huggingface.co/api/models?search=Qwen3.8 "HTTP/1.1 429 Too Many Requests"

    429 Too Many Requests: you have reached your 'api' rate limit.
    Retry after 27 seconds (0/500 requests remaining in current 300s window).

    """

    static func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int, _ millisecond: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute,
                                                  second: second, nanosecond: millisecond * 1_000_000))!
    }

    static func line(_ message: String, at stamp: String = "2026-10-08 09:00:00,000") -> String {
        "\(stamp) - omlx.server - INFO - [-] - \(message)\n"
    }
}

final class OMLXServerLogTests: XCTestCase {
    private func events(_ text: String, chunk: Int? = nil) -> [OMLXServerLog.Event] {
        var parser = OMLXServerLog(timeZone: OMLXLogFixtures.zone)
        let data = Data(text.utf8)
        guard let chunk else { return parser.append(data) + parser.finish() }
        var collected: [OMLXServerLog.Event] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            collected += parser.append(data[offset..<end])
            offset = end
        }
        return collected + parser.finish()
    }

    private func predictions(_ text: String) -> [LocalPrediction] {
        events(text).map { switch $0 { case .prediction(let p): p } }
    }

    func testTheStreamedLineCarriesCountsSpeedAndTimeToFirstToken() throws {
        let p = try XCTUnwrap(predictions(OMLXLogFixtures.streamed).first)
        XCTAssertEqual(p.instance, "Qwen3.8-27B-oQ8e-mtp")
        XCTAssertEqual(p.at.timeIntervalSince1970, OMLXLogFixtures.date(7, 23, 9, 35, 762).timeIntervalSince1970,
                       accuracy: 0.0005)
        XCTAssertEqual(p.outputTokens, 430)
        XCTAssertEqual(p.inputTokens, 68)
        XCTAssertEqual(try XCTUnwrap(p.tokensPerSecond), 42.8, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(p.timeToFirstToken), 0.91, accuracy: 0.0001)
        // Tokens over oMLX's own rate, not its elapsed minus TTFT: the derived
        // speed must be the one oMLX printed.
        XCTAssertEqual(try XCTUnwrap(p.generationSeconds), 430 / 42.8, accuracy: 0.0001)
        XCTAssertNil(p.reasoningTokens)
        XCTAssertNil(p.draftTokens)
        XCTAssertNil(p.acceptedDraftTokens)
    }

    func testTheUnstreamedLineHasNoTimeToFirstToken() throws {
        let p = try XCTUnwrap(predictions(OMLXLogFixtures.unstreamed).first)
        XCTAssertEqual(p.instance, "Qwen3.8-27B-oQ4e-mtp")
        XCTAssertEqual(p.at.timeIntervalSince1970, OMLXLogFixtures.date(7, 17, 12, 1, 118).timeIntervalSince1970,
                       accuracy: 0.0005)
        XCTAssertEqual(p.outputTokens, 112)
        XCTAssertEqual(p.inputTokens, 2534)
        XCTAssertEqual(try XCTUnwrap(p.tokensPerSecond), 32.8, accuracy: 0.0001)
        XCTAssertNil(p.timeToFirstToken)
        XCTAssertEqual(try XCTUnwrap(p.generationSeconds), 112 / 32.8, accuracy: 0.0001)
    }

    func testTheDiffusionVariantTakesTheFirstFigureAndThePromptCountOutsideTheParentheses() throws {
        let text = OMLXLogFixtures.line("Chat completion: model=Dream-v0-7B, 256 tokens in 4.00s (64.0 tok/s e2e, output=80.5 tok/s, canvas=120.0 tok/s, prompt=900.0 tok/s), prompt: 40, finish_reason=stop, max_tokens=2048, request_max_tokens=None")
        let p = try XCTUnwrap(predictions(text).first)
        XCTAssertEqual(p.instance, "Dream-v0-7B")
        XCTAssertEqual(try XCTUnwrap(p.tokensPerSecond), 64.0, accuracy: 0.0001)
        XCTAssertEqual(p.inputTokens, 40)
        XCTAssertEqual(p.outputTokens, 256)
    }

    func testALegacyCompletionLineCarriesItsPromptCount() throws {
        let text = OMLXLogFixtures.line("Completion: model=Qwen3.8-27B-oQ8e-mtp, 96 tokens in 2.40s (40.0 tok/s), prompt: 31",
                                        at: "2026-10-08 09:15:42,250")
        let p = try XCTUnwrap(predictions(text).first)
        XCTAssertEqual(p.instance, "Qwen3.8-27B-oQ8e-mtp")
        XCTAssertEqual(p.at.timeIntervalSince1970, OMLXLogFixtures.date(8, 9, 15, 42, 250).timeIntervalSince1970,
                       accuracy: 0.0005)
        XCTAssertEqual(p.outputTokens, 96)
        XCTAssertEqual(p.inputTokens, 31)
        XCTAssertEqual(try XCTUnwrap(p.tokensPerSecond), 40.0, accuracy: 0.0001)
        XCTAssertNil(p.timeToFirstToken)
        XCTAssertEqual(try XCTUnwrap(p.generationSeconds), 96 / 40.0, accuracy: 0.0001)
    }

    func testAnAnthropicMessageLineHasNoInputCount() throws {
        let text = OMLXLogFixtures.line("Anthropic message: model=Qwen3.8-27B-oQ8e-mtp, 1200 tokens in 40.00s (30.0 tok/s)")
        let p = try XCTUnwrap(predictions(text).first)
        XCTAssertEqual(p.instance, "Qwen3.8-27B-oQ8e-mtp")
        XCTAssertEqual(p.at.timeIntervalSince1970, OMLXLogFixtures.date(8, 9, 0, 0, 0).timeIntervalSince1970,
                       accuracy: 0.0005)
        XCTAssertEqual(p.outputTokens, 1200)
        XCTAssertNil(p.inputTokens)
        XCTAssertEqual(try XCTUnwrap(p.tokensPerSecond), 30.0, accuracy: 0.0001)
        XCTAssertNil(p.timeToFirstToken)
        XCTAssertEqual(try XCTUnwrap(p.generationSeconds), 1200 / 30.0, accuracy: 0.0001)
    }

    func testAResponsesAPILineHasNoInputCount() throws {
        let text = OMLXLogFixtures.line("Responses API: model=qwen3.8-27b-oq8e:nomtp, 250 tokens in 6.25s (40.0 tok/s)")
        let p = try XCTUnwrap(predictions(text).first)
        XCTAssertEqual(p.instance, "qwen3.8-27b-oq8e:nomtp")
        XCTAssertEqual(p.outputTokens, 250)
        XCTAssertNil(p.inputTokens)
        XCTAssertEqual(try XCTUnwrap(p.tokensPerSecond), 40.0, accuracy: 0.0001)
        XCTAssertNil(p.timeToFirstToken)
        XCTAssertEqual(try XCTUnwrap(p.generationSeconds), 250 / 40.0, accuracy: 0.0001)
    }

    func testAnUnavailableTimeToFirstTokenIsNil() throws {
        let text = OMLXLogFixtures.line("Chat completion: model=Qwen3.8-27B-oQ8e-mtp, 10 tokens in 1.00s (10.0 tok/s), prompt: 5, finish_reason=stop, max_tokens=32768, request_max_tokens=None, stream_model_ttft=unavailable, stream_visible_ttft=unavailable")
        let p = try XCTUnwrap(predictions(text).first)
        XCTAssertNil(p.timeToFirstToken)
        XCTAssertEqual(p.outputTokens, 10)
    }

    func testEverythingElseInTheLogIsNotAnEvent() {
        XCTAssertTrue(events(OMLXLogFixtures.chatter).isEmpty)
        // An empty or unmeasurable response has nothing to add up.
        XCTAssertTrue(events(OMLXLogFixtures.line("Chat completion: model=Qwen3.8-27B-oQ8e-mtp, 0 tokens in 0.05s (0.0 tok/s), prompt: 12, finish_reason=stop, max_tokens=32768, request_max_tokens=None")).isEmpty)
        XCTAssertTrue(events(OMLXLogFixtures.line("Chat completion: model=Qwen3.8-27B-oQ8e-mtp, 3 tokens in 0.00s (0.0 tok/s), prompt: 12, finish_reason=stop")).isEmpty)
        // The same message from a different logger, a different message from
        // the right one, and a stamp of the wrong shape.
        XCTAssertTrue(events(OMLXLogFixtures.streamed.replacingOccurrences(of: "omlx.server", with: "omlx.server2")).isEmpty)
        XCTAssertTrue(events(OMLXLogFixtures.line("Completion request: model=Qwen3.8-27B-oQ8e-mtp")).isEmpty)
        XCTAssertTrue(events(OMLXLogFixtures.streamed.replacingOccurrences(of: ",762", with: ".762")).isEmpty)
        XCTAssertTrue(events("garbage\n\n - omlx.server - INFO - [-] - Chat completion: model=x, 5 tokens in 1s (5.0 tok/s)\n").isEmpty)
    }

    func testALineWithoutARequestIDIsReadToo() throws {
        let bare = OMLXLogFixtures.streamed.replacingOccurrences(of: " - [-] - ", with: " - ")
        XCTAssertEqual(predictions(bare), predictions(OMLXLogFixtures.streamed))
        let tagged = OMLXLogFixtures.streamed.replacingOccurrences(of: "[-]", with: "[req-7f3a]")
        XCTAssertEqual(predictions(tagged), predictions(OMLXLogFixtures.streamed))
    }

    func testBytesArrivingInAnyPiecesGiveTheSameEvents() {
        let text = OMLXLogFixtures.chatter + OMLXLogFixtures.unstreamed + OMLXLogFixtures.chatter
            + OMLXLogFixtures.streamed
        let whole = events(text)
        XCTAssertEqual(whole.count, 2)
        for chunk in [1, 7, 64, 1000] {
            XCTAssertEqual(events(text, chunk: chunk), whole, "chunk \(chunk)")
        }
        XCTAssertEqual(events(text.replacingOccurrences(of: "\n", with: "\r\n")), whole, "CRLF")
        // A last line with no newline yet is held, then counted at the end.
        var parser = OMLXServerLog(timeZone: OMLXLogFixtures.zone)
        XCTAssertTrue(parser.append(Data(OMLXLogFixtures.streamed.dropLast().utf8)).isEmpty)
        XCTAssertEqual(parser.finish().count, 1)
    }

    // MARK: - Tail

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OMLXServerLogTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    private func append(_ text: String, to name: String) throws {
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(name))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func outputs(_ events: [OMLXServerLog.Event]) -> [Int?] {
        events.map { switch $0 { case .prediction(let p): p.outputTokens } }
    }

    private func line(_ tokens: Int, day: Int = 8) -> String {
        OMLXLogFixtures.line("Chat completion: model=Qwen3.8-27B-oQ8e-mtp, \(tokens) tokens in 1.00s (\(tokens).0 tok/s), prompt: 1, finish_reason=stop",
                             at: "2026-10-0\(day) 12:00:00,000")
    }

    func testRotatedFilesComeFirstByDateThenTheLiveFile() throws {
        for name in ["server.log", "server.log.2026-10-07", "server.log.2026-10-06", "crash.log",
                     "server.log.old", "server.log.2026-10-6"] {
            try write("", to: name)
        }
        XCTAssertEqual(OMLXLogTail.logFiles(in: directory).map(\.lastPathComponent),
                       ["server.log.2026-10-06", "server.log.2026-10-07", "server.log"])
        XCTAssertTrue(OMLXLogTail.logFiles(in: directory.appendingPathComponent("missing")).isEmpty)
    }

    func testHistoryThenOnlyWhatWasAppended() throws {
        try write(line(1, day: 6), to: "server.log.2026-10-06")
        try write(OMLXLogFixtures.chatter + line(2, day: 7), to: "server.log.2026-10-07")
        // The live file ends mid-line: the half is held, not lost or misread.
        let third = line(3)
        try write(line(30) + String(third.prefix(40)), to: "server.log")
        let tail = OMLXLogTail(directory: directory, timeZone: OMLXLogFixtures.zone)
        XCTAssertEqual(outputs(tail.loadHistory()), [1, 2, 30])
        XCTAssertEqual(tail.file?.lastPathComponent, "server.log")
        XCTAssertTrue(tail.poll().isEmpty, "nothing was appended")

        try append(String(third.dropFirst(40)) + line(4), to: "server.log")
        XCTAssertEqual(outputs(tail.poll()), [3, 4], "the split line was completed across the two reads")
        XCTAssertTrue(tail.poll().isEmpty)
    }

    func testMidnightRotationFinishesTheRenamedFileBeforeTheNewOne() throws {
        try write(line(1, day: 7), to: "server.log.2026-10-07")
        try write(line(10), to: "server.log")
        let tail = OMLXLogTail(directory: directory, timeZone: OMLXLogFixtures.zone)
        XCTAssertEqual(outputs(tail.loadHistory()), [1, 10])

        // Written after the last poll, then renamed at midnight, then a new
        // `server.log` starts.
        try append(line(11), to: "server.log")
        try FileManager.default.moveItem(at: directory.appendingPathComponent("server.log"),
                                         to: directory.appendingPathComponent("server.log.2026-10-08"))
        try write(line(20, day: 9), to: "server.log")
        XCTAssertEqual(outputs(tail.poll()), [11, 20], "the old file's last line, then the new file, nothing twice")
        XCTAssertTrue(tail.poll().isEmpty)

        // The new file outgrows the old offset before the next look: its
        // identity, not its size, says it was replaced.
        try append(line(21, day: 9), to: "server.log")
        try FileManager.default.moveItem(at: directory.appendingPathComponent("server.log"),
                                         to: directory.appendingPathComponent("server.log.2026-10-09"))
        try write(line(30) + line(31) + line(32) + line(33), to: "server.log")
        XCTAssertEqual(outputs(tail.poll()), [21, 30, 31, 32, 33])
    }

    func testAMissingLiveFileIsPickedUpWhenItAppears() throws {
        try write(line(1, day: 7), to: "server.log.2026-10-07")
        let tail = OMLXLogTail(directory: directory, timeZone: OMLXLogFixtures.zone)
        XCTAssertEqual(outputs(tail.loadHistory()), [1])
        XCTAssertNil(tail.file)
        XCTAssertTrue(tail.poll().isEmpty)
        try write(line(2), to: "server.log")
        XCTAssertEqual(outputs(tail.poll()), [2], "the rotated file is not read twice")
    }

    func testLiveOMLXLogWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["CODENOTCH_OMLX_LIVE"] == "1" else {
            throw XCTSkip("Opt-in live oMLX check (TEST_RUNNER_CODENOTCH_OMLX_LIVE=1)")
        }
        let started = Date()
        let tail = OMLXLogTail(directory: OMLXEndpoint.serverLogsDirectory())
        let logged = tail.loadHistory().count
        print("oMLX history: \(logged) responses, \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        XCTAssertGreaterThanOrEqual(logged, 1)
    }
}
