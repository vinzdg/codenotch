import XCTest
@testable import Codenotch

/// The state machine that reads a session's transcript.
///
/// It exists because Claude Code only writes `status` into the session registry
/// from its terminal interface, so a session hosted by the Claude desktop app
/// has no status at all. Every fixture here is the shape of a line found in a
/// real transcript on a Mac running the desktop app.
final class ClaudeTranscriptTests: XCTestCase {
    private func turn(_ lines: String...) -> ClaudeTranscript.Turn? {
        ClaudeTranscript.turn(inTail: Data(lines.joined(separator: "\n").utf8))
    }

    // MARK: - Where the file is

    func testSlugReplacesSeparatorsAndDots() {
        XCTAssertEqual(ClaudeTranscript.projectSlug(forCWD: "/Users/vinz/notch-app"),
                       "-Users-vinz-notch-app")
        // A worktree under a dot directory: both characters collapse, and the
        // run of two dashes is what the real directory names look like.
        XCTAssertEqual(
            ClaudeTranscript.projectSlug(forCWD: "/Users/vinz/app/.claude/worktrees/x"),
            "-Users-vinz-app--claude-worktrees-x"
        )
    }

    // MARK: - What it says

    func testAToolInFlightIsWork() {
        XCTAssertEqual(turn(#"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#),
                       .inFlight)
    }

    func testTheEndOfATurnIsNotWork() {
        XCTAssertEqual(turn(#"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#),
                       .finished)
        XCTAssertEqual(turn(#"{"type":"assistant","message":{"stop_reason":"stop_sequence"}}"#),
                       .finished)
    }

    /// A tool result means the tool is done and the model is thinking about it,
    /// which is the part of a turn that looks quietest from outside.
    func testAToolResultIsStillWork() {
        XCTAssertEqual(turn("""
        {"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
        """), .inFlight)
    }

    func testAFreshPromptIsWork() {
        XCTAssertEqual(turn(#"{"type":"user","message":{"content":"build the thing"}}"#),
                       .inFlight)
    }

    /// Esc writes a record saying so, which is why a stopped session is
    /// something the notch knows rather than something it waits out.
    func testAnInterruptionEndsTheTurn() {
        XCTAssertEqual(turn("""
        {"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}
        """), .finished)
        XCTAssertEqual(turn("""
        {"type":"user","message":{"content":"[Request interrupted by user for tool use]"}}
        """), .finished)
    }

    /// The reason a plain "was the file touched recently" test cannot work
    /// here: Claude Code keeps appending these to a session that is sitting
    /// doing nothing, and on this Mac that made an hour-old parked session look
    /// like it was working.
    func testBookkeepingNeverDecides() {
        XCTAssertEqual(turn(
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
            #"{"type":"attachment"}"#,
            #"{"type":"bridge-session"}"#,
            #"{"type":"atis-latch"}"#,
            #"{"type":"frame-link"}"#,
            #"{"type":"custom-title"}"#,
            #"{"type":"queue-operation","operation":"enqueue"}"#,
            #"{"type":"system","subtype":"stop_hook_summary"}"#
        ), .finished)
    }

    /// An unknown kind must not be read as work either — the list of things
    /// Claude Code writes grows between releases, so only `user` and
    /// `assistant` are allowed to answer.
    func testAnUnknownKindNeverDecides() {
        XCTAssertEqual(turn(
            #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
            #"{"type":"something-shipped-next-month"}"#
        ), .inFlight)
    }

    /// A subagent's records are interleaved with its parent's; the parent's
    /// turn is the one being reported on.
    func testASidechainIsIgnored() {
        XCTAssertEqual(turn(
            #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"stop_reason":"end_turn"}}"#
        ), .inFlight)
    }

    /// The tail starts mid-file, so its first line is usually half a record.
    func testAHalfLineAtTheFrontIsSkipped() {
        XCTAssertEqual(turn(
            #"or":"tool_use"}}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#
        ), .finished)
    }

    /// A session opened and not yet used says nothing, and the monitor leaves
    /// it as the registry described it rather than guessing.
    func testNothingSaidYetIsUnknown() {
        XCTAssertNil(turn(#"{"type":"bridge-session"}"#))
        XCTAssertNil(ClaudeTranscript.turn(inTail: Data()))
    }

    // MARK: - Title Parsing

    private func title(_ lines: String...) -> String? {
        ClaudeTranscript.title(in: Data(lines.joined(separator: "\n").utf8))
    }

    func testTitleReturnsNilWhenNoTitleLines() {
        XCTAssertNil(title(#"{"type":"user","message":{"content":"hello"}}"#))
        XCTAssertNil(title())
    }

    func testTitleExtractsAITitle() {
        XCTAssertEqual(
            title(#"{"type":"ai-title","aiTitle":"Configure lead conversion event","sessionId":"f0c3"}"#),
            "Configure lead conversion event"
        )
    }

    func testTitlePrefersLatestAITitle() {
        XCTAssertEqual(
            title(
                #"{"type":"ai-title","aiTitle":"First AI Title"}"#,
                #"{"type":"user","message":{"content":"update something"}}"#,
                #"{"type":"ai-title","aiTitle":"Refined AI Title"}"#
            ),
            "Refined AI Title"
        )
    }

    func testTitleExtractsCustomTitle() {
        XCTAssertEqual(
            title(#"{"type":"custom-title","customTitle":"My Custom Task","sessionId":"f0c3"}"#),
            "My Custom Task"
        )
    }

    func testTitlePrefersCustomTitleOverAITitle() {
        // Custom title set first, subsequent ai-title line appended: custom title still wins
        XCTAssertEqual(
            title(
                #"{"type":"custom-title","customTitle":"Manual Title"}"#,
                #"{"type":"ai-title","aiTitle":"Auto Generated Title"}"#
            ),
            "Manual Title"
        )

        // AI title set first, user manually renamed afterwards: custom title wins
        XCTAssertEqual(
            title(
                #"{"type":"ai-title","aiTitle":"Auto Generated Title"}"#,
                #"{"type":"custom-title","customTitle":"Manual Title"}"#
            ),
            "Manual Title"
        )
    }

    func testTitlePrefersLatestCustomTitle() {
        XCTAssertEqual(
            title(
                #"{"type":"custom-title","customTitle":"Initial Rename"}"#,
                #"{"type":"custom-title","customTitle":"Final Rename"}"#
            ),
            "Final Rename"
        )
    }

    func testTitleIgnoresSidechains() {
        XCTAssertEqual(
            title(
                #"{"type":"custom-title","customTitle":"Subagent Title","isSidechain":true}"#,
                #"{"type":"ai-title","aiTitle":"Parent AI Title"}"#
            ),
            "Parent AI Title"
        )
    }

    func testTitleTrimsWhitespaceAndIgnoresEmpty() {
        XCTAssertEqual(
            title(
                #"{"type":"custom-title","customTitle":"   "}"#,
                #"{"type":"ai-title","aiTitle":"  Valid AI Title  \n"}"#
            ),
            "Valid AI Title"
        )
    }
}

/// The reader that puts the state machine on a timer.
final class ClaudeTranscriptReaderTests: XCTestCase {
    private var projects: URL!

    override func setUpWithError() throws {
        projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projects)
    }

    @discardableResult
    private func write(_ body: String, folder: String, session: String) throws -> URL {
        let directory = projects.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(session).jsonl")
        try Data(body.utf8).write(to: url)
        return url
    }

    private let working = #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"# + "\n"
    private let done = #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"# + "\n"

    func testReadsTheTranscriptUnderTheSlugForTheWorkingDirectory() throws {
        try write(working, folder: "-Users-vinz-app", session: "abc")
        let reader = ClaudeTranscriptReader(projects: projects)
        XCTAssertEqual(reader.activity(sessionID: "abc", cwd: "/Users/vinz/app")?.turn, .inFlight)
    }

    /// A session resumed somewhere else keeps its transcript where it was first
    /// written, so the slug no longer names it.
    func testFindsATranscriptThatIsNotUnderItsOwnSlug() throws {
        try write(done, folder: "-Users-vinz-elsewhere", session: "abc")
        let reader = ClaudeTranscriptReader(projects: projects)
        XCTAssertEqual(reader.activity(sessionID: "abc", cwd: "/Users/vinz/app")?.turn, .finished)
    }

    func testSaysNothingWhenThereIsNoTranscript() {
        let reader = ClaudeTranscriptReader(projects: projects)
        XCTAssertNil(reader.activity(sessionID: "abc", cwd: "/Users/vinz/app"))
    }

    /// `since` is when the turn last moved, which is what the tooltip counts
    /// from — not the moment the notch happened to look.
    func testReportsWhenTheTranscriptLastMoved() throws {
        let url = try write(working, folder: "-Users-vinz-app", session: "abc")
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
        let reader = ClaudeTranscriptReader(projects: projects)
        XCTAssertEqual(reader.activity(sessionID: "abc", cwd: "/Users/vinz/app")?.since, when)
    }

    /// The whole point of the cache: a tick that finds the file unchanged must
    /// not read it again. Rewriting the body without touching the timestamps
    /// leaves the reader on its old answer.
    func testAnUnchangedFileIsNotReadTwice() throws {
        let url = try write(working, folder: "-Users-vinz-app", session: "abc")
        // Pinned to the same whole second on both sides, so the only thing this
        // can be measuring is the cache.
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: frozen], ofItemAtPath: url.path)
        let reader = ClaudeTranscriptReader(projects: projects)
        XCTAssertEqual(reader.activity(sessionID: "abc", cwd: "/Users/vinz/app")?.turn, .inFlight)

        // Same length as well, so neither size nor date moves.
        XCTAssertEqual(working.utf8.count, done.utf8.count)
        try Data(done.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: frozen], ofItemAtPath: url.path)
        XCTAssertEqual(reader.activity(sessionID: "abc", cwd: "/Users/vinz/app")?.turn, .inFlight)
    }

    func testRereadsOnceTheFileHasGrown() throws {
        let url = try write(working, folder: "-Users-vinz-app", session: "abc")
        let reader = ClaudeTranscriptReader(projects: projects)
        XCTAssertEqual(reader.activity(sessionID: "abc", cwd: "/Users/vinz/app")?.turn, .inFlight)

        try Data((working + done).utf8).write(to: url)
        XCTAssertEqual(reader.activity(sessionID: "abc", cwd: "/Users/vinz/app")?.turn, .finished)
    }
}

/// `since` means when the state was entered, not when the file was last
/// touched. Reporting the latter froze the tooltip's elapsed time at zero for
/// the whole of a long turn, and gave the notch a fresh value to animate every
/// two seconds while nothing visible had changed.
extension ClaudeTranscriptReaderTests {
    func testTheStartOfTheStateIsHeldWhileItLasts() throws {
        let url = try write(working, folder: "-Users-vinz-app", session: "abc")
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: started],
                                              ofItemAtPath: url.path)
        let reader = ClaudeTranscriptReader(projects: projects)
        XCTAssertEqual(reader.activity(sessionID: "abc", cwd: "/Users/vinz/app")?.since, started)

        // The turn goes on: more records, a newer timestamp, same state.
        try Data((working + working).utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: started.addingTimeInterval(30)],
                                              ofItemAtPath: url.path)
        XCTAssertEqual(reader.activity(sessionID: "abc", cwd: "/Users/vinz/app")?.since, started)
    }

    func testTheStartMovesWhenTheStateDoes() throws {
        let url = try write(working, folder: "-Users-vinz-app", session: "abc")
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: started],
                                              ofItemAtPath: url.path)
        let reader = ClaudeTranscriptReader(projects: projects)
        XCTAssertEqual(reader.activity(sessionID: "abc", cwd: "/Users/vinz/app")?.since, started)

        let ended = started.addingTimeInterval(120)
        try Data((working + done).utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: ended], ofItemAtPath: url.path)
        let after = reader.activity(sessionID: "abc", cwd: "/Users/vinz/app")
        XCTAssertEqual(after?.turn, .finished)
        XCTAssertEqual(after?.since, ended)
    }

    func testReaderReturnsTitleFromTranscript() throws {
        let titleLine = #"{"type":"ai-title","aiTitle":"Refactor Authentication"}"# + "\n"
        try write(titleLine, folder: "-Users-vinz-app", session: "abc")
        let reader = ClaudeTranscriptReader(projects: projects)
        XCTAssertEqual(reader.title(sessionID: "abc", cwd: "/Users/vinz/app"), "Refactor Authentication")
    }

    func testReaderPrefersCustomTitleOverAITitle() throws {
        let lines = [
            #"{"type":"ai-title","aiTitle":"Initial Topic"}"#,
            #"{"type":"custom-title","customTitle":"User Renamed Session"}"#,
            #"{"type":"ai-title","aiTitle":"Subsequent AI Title"}"#
        ].joined(separator: "\n") + "\n"
        try write(lines, folder: "-Users-vinz-app", session: "abc")
        let reader = ClaudeTranscriptReader(projects: projects)
        XCTAssertEqual(reader.title(sessionID: "abc", cwd: "/Users/vinz/app"), "User Renamed Session")
    }
}
