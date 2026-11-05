import XCTest
@testable import Codenotch

/// The wire state machine: turn records are top-level lines with millisecond
/// `time`, approval records may arrive wrapped in a loop-event envelope, and
/// subagent records never speak for the session.
final class KimiTurnTests: XCTestCase {
    private func tail(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    func testAPromptIsBusy() {
        let turn = KimiActivity.turn(inTail: tail([
            #"{"type":"turn.prompt","agentId":"main","promptId":"msg_1","time":1789140953652}"#,
        ]))
        guard case .busy(let at) = turn, let since = at else {
            return XCTFail("expected busy, got \(String(describing: turn))")
        }
        XCTAssertEqual(since.timeIntervalSince1970, 1789140953.652, accuracy: 0.001)
    }

    /// A long turn fills the tail with tool chatter, pushing its own
    /// `turn.prompt` out of the window — loop records still mean busy.
    func testLoopActivityWithoutThePromptIsStillBusy() {
        let turn = KimiActivity.turn(inTail: tail([
            #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"tool.result","toolCallId":"t1"}}"#,
            #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"tool.call","name":"Bash"}}"#,
        ]))
        guard case .busy = turn else { return XCTFail("expected busy, got \(String(describing: turn))") }
    }

    /// Post-turn bookkeeping is not loop activity — after `turn.ended` the
    /// session is finished even with usage records trailing it.
    func testBookkeepingAfterTheTurnIsFinished() {
        let turn = KimiActivity.turn(inTail: tail([
            #"{"type":"turn.ended","agentId":"main","reason":"completed","time":1789140953652}"#,
            #"{"type":"usage.record","agentId":"main"}"#,
            #"{"type":"token_counting.turn_recorded","agentId":"main"}"#,
        ]))
        guard case .finished = turn else { return XCTFail("expected finished, got \(String(describing: turn))") }
    }

    func testAnEndedTurnIsFinished() {
        let turn = KimiActivity.turn(inTail: tail([
            #"{"type":"turn.prompt","agentId":"main","time":1789140953000}"#,
            #"{"type":"turn.ended","agentId":"main","reason":"completed","time":1789140953652}"#,
        ]))
        guard case .finished = turn else { return XCTFail("expected finished, got \(String(describing: turn))") }
    }

    func testAnOpenApprovalIsWaiting() {
        let turn = KimiActivity.turn(inTail: tail([
            #"{"type":"turn.prompt","agentId":"main","time":1789140953000}"#,
            #"{"type":"approval.requested","agentId":"main","tool":"Bash","time":1789140954000}"#,
        ]))
        guard case .waiting(_, let what) = turn else { return XCTFail("expected waiting, got \(String(describing: turn))") }
        XCTAssertEqual(what, "Bash")
    }

    /// Wrapped approval records are read through the envelope, and a resolved
    /// one hands the turn back to whatever came before it.
    func testAResolvedWrappedApprovalIsBusyAgain() {
        let turn = KimiActivity.turn(inTail: tail([
            #"{"type":"turn.prompt","agentId":"main","time":1789140953000}"#,
            #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"approval.requested","tool":"Bash","time":1789140954000}}"#,
            #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"approval.resolved","time":1789140955000}}"#,
        ]))
        guard case .busy = turn else { return XCTFail("expected busy, got \(String(describing: turn))") }
    }

    func testASubagentRecordIsNotTheSessionsTurn() {
        let turn = KimiActivity.turn(inTail: tail([
            #"{"type":"turn.ended","agentId":"main","time":1789140953000}"#,
            #"{"type":"turn.prompt","agentId":"agent-0","time":1789140954000}"#,
        ]))
        guard case .finished = turn else { return XCTFail("expected finished, got \(String(describing: turn))") }
    }

    func testAKimiKAgentRecordIsTracked() {
        let turn = KimiActivity.turn(inTail: tail([
            #"{"type":"turn.ended","agentId":"main","time":1789140953000}"#,
            #"{"type":"turn.prompt","agentId":"kimi-k","time":1789140954000}"#,
        ]))
        guard case .busy = turn else { return XCTFail("expected busy for Kimi K agent, got \(String(describing: turn))") }
    }

    func testModelIsExtractedFromWire() {
        let model1 = KimiActivity.model(inTail: tail([
            #"{"type":"turn.prompt","agentId":"main","model":"kimi-k3"}"#
        ]))
        XCTAssertEqual(model1, "Kimi K3")

        let model2 = KimiActivity.model(inTail: tail([
            #"{"type":"context.append_loop_event","agentId":"main","event":{"type":"llm.request","model":"kimi-k3.1-pro"}}"#
        ]))
        XCTAssertEqual(model2, "Kimi K3.1 Pro")

        let model3 = KimiActivity.model(inTail: tail([
            #"{"type":"turn.prompt","agentId":"kimi-k"}"#
        ]))
        XCTAssertEqual(model3, "Kimi K")
    }

    func testUnrelatedRecordsAndBrokenLinesAreSkipped() {
        let turn = KimiActivity.turn(inTail: tail([
            #"{"type":"turn.prompt","agentId":"main","time":1789140953000}"#,
            "not json at all",
            #"{"type":"tool.call","agentId":"main","name":"Bash"}"#,
            #"{"type":"usage.record","agentId":"main"}"#,
        ]))
        guard case .busy = turn else { return XCTFail("expected busy, got \(String(describing: turn))") }
    }

    func testAnEmptyWireHasNoTurn() {
        XCTAssertNil(KimiActivity.turn(inTail: Data()))
    }
}

/// Session assembly: a live pid plus a wire fixture, with time injected.
final class KimiActivitySessionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kimi-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("agents/main"),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func wire(_ lines: [String], modified: Date) throws -> URL {
        let url = directory.appendingPathComponent("agents/main/wire.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func session(now: Date, staleAfter: TimeInterval = 90) -> AgentSession? {
        KimiActivity.session(sessionDir: directory, pid: getpid(), startedAt: nil,
                             workDir: "/tmp/some-project", staleAfter: staleAfter, now: now)
    }

    func testATurnInFlightIsBusy() throws {
        let now = Date()
        _ = try wire([#"{"type":"turn.prompt","agentId":"main","time":\#(Int(now.timeIntervalSince1970 * 1000))}"#],
                     modified: now)
        let session = try XCTUnwrap(session(now: now))
        XCTAssertEqual(session.state, .busy)
        XCTAssertEqual(session.id, "kimi.\(directory.lastPathComponent)")
        XCTAssertEqual(session.name, "tmp/some-project")
        /// The second line names where the CLI runs — the app SessionFocus
        /// would jump to — the way Claude's rows name the surface.
        XCTAssertEqual(session.detail,
                       SessionFocus.owningApp(of: getpid())?.localizedName ?? "Terminal")
        XCTAssertEqual(session.processID, getpid())
    }

    func testSessionDetailIncludesModelWhenPresent() throws {
        let now = Date()
        _ = try wire([
            #"{"type":"turn.prompt","agentId":"main","model":"kimi-k3","time":\#(Int(now.timeIntervalSince1970 * 1000))}"#
        ], modified: now)
        let session = try XCTUnwrap(session(now: now))
        let surface = SessionFocus.owningApp(of: getpid())?.localizedName ?? "Terminal"
        XCTAssertEqual(session.detail, "\(surface) · Kimi K3")
    }

    /// A turn whose wire has not moved in longer than the stale window is a
    /// stalled CLI, not work in progress.
    func testAStaleTurnIsIdle() throws {
        let now = Date()
        _ = try wire([#"{"type":"turn.prompt","agentId":"main","time":1}"#],
                     modified: now.addingTimeInterval(-300))
        XCTAssertEqual(session(now: now)?.state, .idle)
    }

    func testAJustEndedTurnIsSuccessThenIdle() throws {
        let now = Date()
        let ended = Int(now.addingTimeInterval(-5).timeIntervalSince1970 * 1000)
        _ = try wire([#"{"type":"turn.ended","agentId":"main","reason":"completed","time":\#(ended)}"#],
                     modified: now.addingTimeInterval(-5))
        XCTAssertEqual(session(now: now)?.state, .success)
        XCTAssertEqual(session(now: now.addingTimeInterval(60))?.state, .idle)
    }

    /// An approval holds however long it takes — no staleness ladder.
    func testAWaitingApprovalDoesNotGoStale() throws {
        let now = Date()
        _ = try wire([#"{"type":"approval.requested","agentId":"main","tool":"Bash","time":1}"#],
                     modified: now.addingTimeInterval(-3600))
        let session = try XCTUnwrap(session(now: now))
        XCTAssertEqual(session.state, .waiting)
        XCTAssertEqual(session.waitingFor, "Bash")
    }

    func testADeadPidIsNoSession() throws {
        let now = Date()
        _ = try wire([#"{"type":"turn.prompt","agentId":"main","time":1}"#], modified: now)
        let dead = KimiActivity.session(sessionDir: directory, pid: 16_777_000, startedAt: nil,
                                        workDir: "/tmp/some-project", staleAfter: 90, now: now)
        XCTAssertNil(dead)
    }

    /// The monitor's own cwd lookup, checked against the process it runs in.
    func testReadsAProcessWorkingDirectory() {
        let cwd = SessionFocus.currentDirectory(of: getpid())
        XCTAssertEqual(cwd?.hasPrefix("/"), true)
        XCTAssertEqual(URL(fileURLWithPath: cwd ?? "").lastPathComponent,
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent)
    }

    /// #227: matched as text, never by resolving symlinks on disk, which
    /// prompts for Documents and network volumes every poll.
    func testWorkingDirectoriesAreMatchedWithoutTouchingTheDisk() {
        XCTAssertEqual(KimiActivity.resolve("/private/var/folders/x/project"), "/var/folders/x/project")
        XCTAssertEqual(KimiActivity.resolve("/private/tmp/work/"), "/tmp/work")
        XCTAssertEqual(KimiActivity.resolve("/Users/me//Documents/app"), "/Users/me/Documents/app")
        XCTAssertEqual(KimiActivity.resolve("/private"), "/private")
        XCTAssertEqual(KimiActivity.resolve("/privately/owned"), "/privately/owned")
        // A folder that does not exist still comes back spelled as given.
        XCTAssertEqual(KimiActivity.resolve("/Volumes/NoSuchShare/code"), "/Volumes/NoSuchShare/code")
    }
}
