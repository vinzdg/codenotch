import XCTest
@testable import Codenotch

final class ClaudeSessionRecordTests: XCTestCase {
    private func record(_ json: String) -> ClaudeSessionRecord? {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return ClaudeSessionRecord(json: object)
    }

    private func session(_ json: String) -> AgentSession? { record(json)?.session }

    /// A real file, trimmed. Unknown keys must not cost us the session.
    func testDecodesALiveSession() throws {
        let s = try XCTUnwrap(session("""
        { "pid": 2678, "sessionId": "c85d4247", "cwd": "/Users/vinz/usage-notch",
          "startedAt": 1787894126697, "procStart": "Fri Aug 28 05:15:20 2026",
          "kind": "interactive", "entrypoint": "cli", "name": "usage-notch-bc",
          "status": "busy", "statusUpdatedAt": 1787897225305,
          "peerFeatures": ["notify_idle"], "somethingNew": 42 }
        """))
        XCTAssertEqual(s.id, "claude.2678")
        XCTAssertEqual(s.name, "usage-notch-bc")
        XCTAssertEqual(s.state, .busy)
        XCTAssertEqual(s.detail, "Terminal · usage-notch")
    }

    func testWaitingCarriesWhatItIsWaitingFor() throws {
        let s = try XCTUnwrap(session("""
        { "pid": 1, "cwd": "/tmp/x", "status": "waiting", "waitingFor": "permission" }
        """))
        XCTAssertEqual(s.state, .waiting)
        XCTAssertEqual(s.waitingFor, "permission")
    }

    /// `tempo` is the normalised form and outranks the raw status word.
    func testTempoWins() throws {
        XCTAssertEqual(try XCTUnwrap(session("""
        { "pid": 1, "cwd": "/tmp/x", "status": "busy", "tempo": "blocked" }
        """)).state, .waiting)
        XCTAssertEqual(try XCTUnwrap(session("""
        { "pid": 1, "cwd": "/tmp/x", "status": "idle", "tempo": "active" }
        """)).state, .busy)
    }

    func testUnknownStatusIsTreatedAsIdle() throws {
        XCTAssertEqual(try XCTUnwrap(session("""
        { "pid": 1, "cwd": "/tmp/x", "status": "hibernating" }
        """)).state, .idle)
    }

    func testFallsBackToTheFolderWhenUnnamed() throws {
        XCTAssertEqual(try XCTUnwrap(session("""
        { "pid": 1, "cwd": "/Users/vinz/notch-app", "status": "idle" }
        """)).name, "notch-app")
    }

    func testRejectsRecordsWithoutAPidOrCwd() {
        XCTAssertNil(session(#"{ "cwd": "/tmp/x", "status": "busy" }"#))
        XCTAssertNil(session(#"{ "pid": 1, "status": "busy" }"#))
    }

    func testSurfaceNamesWhereItIsRunning() throws {
        func surface(_ entrypoint: String) throws -> String {
            ClaudeSessionRecord.surface(entrypoint)
        }
        XCTAssertEqual(try surface("claude-vscode"), "VS Code")
        XCTAssertEqual(try surface("claude-desktop"), "Desktop")
        XCTAssertEqual(try surface("cli"), "Terminal")
    }

    /// `procStart` is a ctime string in UTC. Reading it as local time puts it
    /// hours out, and the liveness check then throws away a live session — which
    /// is exactly what happened the first time this was wired up.
    func testProcStartIsParsedAsUTC() throws {
        let parsed = try XCTUnwrap(ClaudeSessionRecord.parseProcStart("Fri Aug 28 05:15:20 2026"))
        XCTAssertEqual(parsed.timeIntervalSince1970, 1787894120, accuracy: 1)
    }

    func testProcStartHandlesASpacePaddedDay() throws {
        let parsed = try XCTUnwrap(ClaudeSessionRecord.parseProcStart("Sat Aug  8 05:15:20 2026"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.component(.day, from: parsed), 8)
    }

    /// The epoch field is unambiguous, so it wins over the ctime string.
    func testPrefersTheEpochStartTime() throws {
        let r = try XCTUnwrap(record("""
        { "pid": 1, "cwd": "/tmp/x", "status": "busy",
          "startedAt": 1787894126697, "procStart": "Mon Jan 1 00:00:00 2001" }
        """))
        XCTAssertEqual(try XCTUnwrap(r.startedAt).timeIntervalSince1970, 1787894126.697, accuracy: 0.01)
    }
}

/// Which source gets to say what a session is doing.
///
/// Claude Code fills `status` in from its terminal interface, so a terminal
/// session's record answers for itself and a desktop session's never does. The
/// split has to hold in both directions: the desktop case is the bug being
/// fixed, and the terminal case is the behaviour that must not change —
/// `waiting` in particular, which nothing but the terminal interface can know.
@MainActor
final class ClaudeSessionStateSourceTests: XCTestCase {
    private var projects: URL!

    override func setUpWithError() throws {
        projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projects)
    }

    private func record(_ json: String) throws -> ClaudeSessionRecord {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(ClaudeSessionRecord(json: object))
    }

    private func writeTranscript(_ body: String, session: String, cwd: String) throws {
        let directory = projects
            .appendingPathComponent(ClaudeTranscript.projectSlug(forCWD: cwd))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: directory.appendingPathComponent("\(session).jsonl"))
    }

    private var reader: ClaudeTranscriptReader { ClaudeTranscriptReader(projects: projects) }

    /// The real shape of a desktop session's file, trimmed. No status, no
    /// tempo, no `statusUpdatedAt` — and the file is written once, when the
    /// session starts, so its own timestamp says nothing either.
    private let desktop = """
    { "pid": 26440, "sessionId": "0b24b489", "cwd": "/Users/vinz/app",
      "startedAt": 1788731755247, "procStart": "Sun Sep  6 21:55:54 2026",
      "kind": "interactive", "entrypoint": "claude-desktop", "name": "app-6c",
      "messagingSocketPath": "/tmp/cc-socks/26440.sock" }
    """

    func testADesktopRecordAdmitsItSaysNothingAboutState() throws {
        let desktop = try record(desktop)
        XCTAssertFalse(desktop.reportsStatus)
        XCTAssertEqual(desktop.sessionID, "0b24b489")
        XCTAssertEqual(desktop.cwd, "/Users/vinz/app")
        XCTAssertEqual(desktop.session.detail, "Desktop · app")

        let terminal = try record(#"{ "pid": 1, "cwd": "/tmp/x", "status": "busy" }"#)
        XCTAssertTrue(terminal.reportsStatus)
    }

    /// A word neither of us knows is worth no more than no word at all, so it
    /// goes to the transcript too.
    func testAnUnrecognisedStatusIsNotAnAnswer() throws {
        XCTAssertFalse(try record(#"{ "pid": 1, "cwd": "/tmp/x", "status": "hibernating" }"#)
            .reportsStatus)
        XCTAssertTrue(try record(#"{ "pid": 1, "cwd": "/tmp/x", "status": "idle" }"#)
            .reportsStatus)
    }

    func testADesktopSessionTakesItsStateFromTheTranscript() throws {
        try writeTranscript(#"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
                            session: "0b24b489", cwd: "/Users/vinz/app")
        let session = ClaudeSessionMonitor.state(of: try record(desktop), transcripts: reader)
        XCTAssertEqual(session.state, .busy)
        XCTAssertEqual(session.id, "claude.26440")
    }

    func testADesktopSessionThatFinishedItsTurnIsIdle() throws {
        try writeTranscript(#"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
                            session: "0b24b489", cwd: "/Users/vinz/app")
        XCTAssertEqual(
            ClaudeSessionMonitor.state(of: try record(desktop), transcripts: reader).state, .idle
        )
    }

    /// With no transcript to read, the record's own answer stands — which is
    /// exactly what the notch did before any of this existed.
    func testWithNoTranscriptTheRecordStands() throws {
        XCTAssertEqual(
            ClaudeSessionMonitor.state(of: try record(desktop), transcripts: reader).state, .idle
        )
        XCTAssertEqual(
            ClaudeSessionMonitor.state(of: try record(desktop), transcripts: nil).state, .idle
        )
    }

    /// The behaviour that must not regress: a terminal session says `waiting`,
    /// and the transcript — which cannot see a permission prompt at all — is
    /// never allowed to talk it out of that.
    func testATerminalSessionKeepsItsOwnStateAndItsWaitingFor() throws {
        let waiting = try record("""
        { "pid": 7, "sessionId": "0b24b489", "cwd": "/Users/vinz/app",
          "status": "waiting", "waitingFor": "permission" }
        """)
        try writeTranscript(#"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
                            session: "0b24b489", cwd: "/Users/vinz/app")
        let session = ClaudeSessionMonitor.state(of: waiting, transcripts: reader)
        XCTAssertEqual(session.state, .waiting)
        XCTAssertEqual(session.waitingFor, "permission")
    }

    // MARK: - Deduplication

    /// Resuming after a crash registers a new pid while the old process is
    /// still winding down, and for a moment both files are live. One session
    /// must not be drawn twice.
    func testTheSameSessionUnderTwoPidsIsDrawnOnce() throws {
        let old = try record("""
        { "pid": 1, "sessionId": "same", "cwd": "/tmp/x", "startedAt": 1000000 }
        """)
        let new = try record("""
        { "pid": 2, "sessionId": "same", "cwd": "/tmp/x", "startedAt": 2000000 }
        """)
        for pair in [[old, new], [new, old]] {
            let kept = ClaudeSessionMonitor.deduplicated(pair)
            XCTAssertEqual(kept.count, 1)
            XCTAssertEqual(kept.first?.pid, 2, "the most recently started record wins")
        }
    }

    func testDifferentSessionsAreAllKept() throws {
        let a = try record(#"{ "pid": 1, "sessionId": "a", "cwd": "/tmp/x" }"#)
        let b = try record(#"{ "pid": 2, "sessionId": "b", "cwd": "/tmp/x" }"#)
        XCTAssertEqual(ClaudeSessionMonitor.deduplicated([a, b]).count, 2)
    }

    /// A record old enough to have no session id cannot be matched against
    /// anything, so it is kept rather than dropped or merged.
    func testRecordsWithoutASessionIdAreKept() throws {
        let a = try record(#"{ "pid": 1, "cwd": "/tmp/x" }"#)
        let b = try record(#"{ "pid": 2, "cwd": "/tmp/x" }"#)
        XCTAssertEqual(ClaudeSessionMonitor.deduplicated([a, b]).count, 2)
    }
}

/// A record with nothing to date itself by must still answer the same thing
/// twice. It used to answer `Date()`, so every rescan produced a session that
/// compared unequal to the one before it and the notch re-animated at 2 Hz.
extension ClaudeSessionRecordTests {
    func testARecordWithNoTimestampHoldsStill() throws {
        let json = """
        { "pid": 1, "sessionId": "a", "cwd": "/tmp/x", "startedAt": 1788731755247,
          "entrypoint": "claude-desktop" }
        """
        let first = try XCTUnwrap(session(json))
        let second = try XCTUnwrap(session(json))
        XCTAssertEqual(first.since, second.since)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.since.timeIntervalSince1970, 1788731755.247, accuracy: 0.01)
    }
}

/// The session Codenotch starts itself must never reach the notch.
///
/// Renewing the OAuth token runs the Claude CLI, and the CLI registers a
/// session file for the second or so it is alive — verified on a real machine:
/// the count under `~/.claude/sessions` goes six, seven, six, and the file
/// carries the pid of the process Codenotch spawned. Left alone it draws a row
/// nobody asked for, and `isBusy` reads it as work in progress and starts
/// polling usage hard on the strength of it.
@MainActor
final class ClaudeOwnSessionFilterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("own-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// This process, so the liveness check passes and the only thing under test
    /// is the filter.
    private var livePID: Int32 { ProcessInfo.processInfo.processIdentifier }

    private func writeSession(pid: Int32, name: String, cwd: String = "/Users/vinz/app") throws {
        let json = """
        { "pid": \(pid), "sessionId": "\(name)", "cwd": "\(cwd)",
          "name": "\(name)", "entrypoint": "claude-desktop" }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(pid).json"))
    }

    /// The `/usage` probe runs from `ClaudeUsageCLI.scratchDirectory`, and a
    /// session filed from there is Codenotch's whichever pid wrote it. Seen on
    /// a real machine as a "usage-scratch-e1 finished" banner: the probe ran
    /// `busy`, vanished, and was announced as a turn that ended.
    func testASessionFromTheUsageScratchDirectoryIsLeftOut() throws {
        let scratch = ClaudeUsageCLI.scratchLocation(applicationSupport: directory)
        try writeSession(pid: livePID, name: "usage-scratch-e1", cwd: scratch.path + "/")
        try writeSession(pid: getppid(), name: "theirs")
        let found = ClaudeSessionMonitor.read(directory: directory,
                                              ignoringDirectories: [scratch.path])
        XCTAssertEqual(found.map(\.name), ["theirs"])
    }

    func testTheSessionIsReadWhenNothingIsIgnored() throws {
        try writeSession(pid: livePID, name: "mine")
        let found = ClaudeSessionMonitor.read(directory: directory)
        XCTAssertEqual(found.map(\.name), ["mine"])
    }

    func testAnIgnoredPidIsLeftOut() throws {
        try writeSession(pid: livePID, name: "mine")
        let found = ClaudeSessionMonitor.read(directory: directory, ignoring: [livePID])
        XCTAssertTrue(found.isEmpty, "the session Codenotch started is not the user's")
    }

    /// Ignoring one must not hide the rest — the notch still has to show every
    /// session the user actually has open.
    func testEveryOtherSessionSurvives() throws {
        try writeSession(pid: livePID, name: "ours")
        try writeSession(pid: getppid(), name: "theirs")
        let found = ClaudeSessionMonitor.read(directory: directory, ignoring: [livePID])
        XCTAssertEqual(found.map(\.name), ["theirs"])
    }
}

/// A session another program runs in the background is not the user's either.
///
/// claude-mem's worker runs a headless Claude Code (`sdk-cli`, `sdk-ts`) for
/// every session it observes. Each registers like any other session, and on a
/// real machine they spun the ring and were announced as finished turns seven
/// times in a hundred seconds. What sets them apart from a session somebody is
/// at is that nothing is above them: no terminal and no application.
@MainActor
final class ClaudeBackgroundSessionFilterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// This process, so the liveness check passes and the only thing under test
    /// is the filter.
    private var livePID: Int32 { ProcessInfo.processInfo.processIdentifier }

    private func writeSession(entrypoint: String, name: String) throws {
        let json = """
        { "pid": \(livePID), "sessionId": "\(name)", "cwd": "/Users/vinz/app",
          "name": "\(name)", "entrypoint": "\(entrypoint)" }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(livePID).json"))
    }

    func testAnSDKSessionNobodyIsAtIsLeftOut() throws {
        for entrypoint in ["sdk-cli", "sdk-ts", "sdk-py"] {
            try writeSession(entrypoint: entrypoint, name: "observer-sessions-36")
            let found = ClaudeSessionMonitor.read(directory: directory, isAttended: { _ in false })
            XCTAssertTrue(found.isEmpty, "\(entrypoint) with no terminal and no app")
        }
    }

    /// `claude -p` typed into a terminal, or an editor driving Claude Code
    /// through the SDK: somebody is there, so it stays.
    func testAnSDKSessionWithATerminalOrAnAppStays() throws {
        try writeSession(entrypoint: "sdk-ts", name: "editor")
        let found = ClaudeSessionMonitor.read(directory: directory, isAttended: { _ in true })
        XCTAssertEqual(found.map(\.name), ["editor"])
    }

    /// Only the sessions a program started are asked. One somebody opened is
    /// never second-guessed, whatever its process tree looks like.
    func testASessionSomebodyOpenedIsNeverAsked() throws {
        for entrypoint in ["cli", "claude-desktop", "claude-vscode"] {
            try writeSession(entrypoint: entrypoint, name: entrypoint)
            let found = ClaudeSessionMonitor.read(directory: directory, isAttended: { _ in
                XCTFail("\(entrypoint) was asked")
                return false
            })
            XCTAssertEqual(found.map(\.name), [entrypoint])
        }
    }
}

/// A Claude Code suspended with ctrl-Z is a live process that nobody has open.
/// On a real machine one sat stopped for a day behind the session resumed in
/// the same tab, drawn as "idle 26 hr". It is left out until `fg` brings it
/// back, and then it is drawn again.
@MainActor
final class ClaudeStoppedSessionTests: XCTestCase {
    func testASuspendedSessionIsLeftOutUntilItIsResumed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stopped-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier
        // Resumed first: a stopped process holds the terminate signal until then.
        defer { kill(pid, SIGCONT); process.terminate() }

        let json = """
        { "pid": \(pid), "sessionId": "suspended", "cwd": "/Users/vinz/app",
          "name": "suspended", "entrypoint": "cli" }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(pid).json"))
        XCTAssertEqual(ClaudeSessionMonitor.read(directory: directory).map(\.name), ["suspended"])

        kill(pid, SIGSTOP)
        for _ in 0..<50 where !ProcessLiveness.isStopped(pid: pid) { usleep(20_000) }
        XCTAssertTrue(ProcessLiveness.isAlive(pid: pid, startedAt: nil), "stopped is not dead")
        XCTAssertTrue(ClaudeSessionMonitor.read(directory: directory).isEmpty)

        kill(pid, SIGCONT)
        for _ in 0..<50 where ProcessLiveness.isStopped(pid: pid) { usleep(20_000) }
        XCTAssertEqual(ClaudeSessionMonitor.read(directory: directory).map(\.name), ["suspended"])
    }
}


/// Work done on one account drawn on that account's ring, even when Claude Code
/// filed it under another profile's directory.
///
/// The Claude desktop app leaves `CLAUDE_CONFIG_DIR` unset, so every session it
/// hosts is registered in `~/.claude/sessions` — the default profile's
/// directory — whichever account the app is signed in to. Switching account
/// inside the app moves the credential and not the file, so a second account's
/// work spun the first account's ring and nothing about the app said otherwise.
/// The app does record which account hosted each session; this is the join.
@MainActor
final class ClaudeSessionOwnershipTests: XCTestCase {
    private var root: URL!
    /// `~/Library/Application Support/Claude/claude-code-sessions`, as the app
    /// lays it out: one directory per account, then per organization.
    private var desktop: URL!
    private var personal: URL!    // ~/.claude/sessions
    private var work: URL!        // ~/.claude-work/sessions

    private let personalAccount = "acc-personal"
    private let workAccount = "acc-work"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionOwnershipTests.\(UUID().uuidString)",
                                    isDirectory: true)
        desktop = root.appendingPathComponent("claude-code-sessions")
        personal = root.appendingPathComponent(".claude/sessions")
        work = root.appendingPathComponent(".claude-work/sessions")
        for url in [desktop!, personal!, work!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The index

    func testAHostedSessionNamesItsAccount() throws {
        try host("local-1", account: workAccount)
        XCTAssertEqual(index().account(forHostSession: "local-1"), workAccount)
    }

    /// The app writes its record a moment after Claude Code registers the
    /// session, so "not yet" has to stay answerable later — a cached miss would
    /// leave the session on the wrong ring for its whole life.
    func testAMissIsNotRemembered() throws {
        let index = index()
        XCTAssertNil(index.account(forHostSession: "local-1"))

        try host("local-1", account: workAccount)

        XCTAssertEqual(index.account(forHostSession: "local-1"), workAccount)
    }

    /// The id comes out of a file another program writes. A separator in it
    /// would look somewhere else entirely.
    func testAnIdThatWouldWalkOutOfTheDirectoryIsRefused() throws {
        try host("local-1", account: workAccount)
        XCTAssertNil(index().account(forHostSession: "../local-1"))
        XCTAssertNil(index().account(forHostSession: ""))
    }

    // MARK: - Who claims a record

    func testADesktopSessionGoesToTheAccountThatHostsIt() throws {
        try host("local-1", account: workAccount)
        let record = try desktopRecord(pid: 11, host: "local-1")

        // Filed under the personal profile, as the app always files them...
        XCTAssertFalse(ownership(of: personal).claims(record, foundIn: personal),
                       "the personal ring drew the work account's session")
        XCTAssertTrue(ownership(of: work).claims(record, foundIn: personal),
                      "the work ring did not adopt its own session")
    }

    /// A terminal session inherits the variable that chose the directory, so
    /// the directory is already the right answer and nothing may move it.
    func testATerminalSessionStaysWhereItWasFiled() throws {
        try host("local-1", account: workAccount)
        let record = try record(pid: 12, entrypoint: "cli", host: nil)

        XCTAssertTrue(ownership(of: personal).claims(record, foundIn: personal))
        XCTAssertFalse(ownership(of: work).claims(record, foundIn: personal))
    }

    /// Nothing is dropped for want of an answer: a session on the wrong ring is
    /// a bug, a session on no ring at all is a worse one.
    func testAnUnresolvableSessionIsLeftWhereItWas() throws {
        let unknown = try desktopRecord(pid: 13, host: "local-nothing-filed")
        XCTAssertTrue(ownership(of: personal).claims(unknown, foundIn: personal))
        XCTAssertFalse(ownership(of: work).claims(unknown, foundIn: personal))

        // An account this machine has no profile signed in to, likewise.
        try host("local-2", account: "acc-someone-else")
        let stranger = try desktopRecord(pid: 14, host: "local-2")
        XCTAssertTrue(ownership(of: personal).claims(stranger, foundIn: personal))
        XCTAssertFalse(ownership(of: work).claims(stranger, foundIn: personal))
    }

    // MARK: - End to end, through the monitor

    func testTheWorkRingReadsTheSessionTheAppFiledUnderThePersonalOne() throws {
        try host("local-1", account: workAccount)
        try write(pid: livePID, name: "on work", entrypoint: "claude-desktop",
                  host: "local-1", to: personal)

        let onPersonal = ClaudeSessionMonitor.read(directory: personal,
                                                   ownership: ownership(of: personal))
        let onWork = ClaudeSessionMonitor.read(directory: work,
                                               ownership: ownership(of: work))

        XCTAssertEqual(onPersonal.map(\.name), [])
        XCTAssertEqual(onWork.map(\.name), ["on work"])
    }

    /// The sessions that were always attributed correctly must not move.
    func testEveryOtherSessionIsUnmoved() throws {
        try host("local-1", account: personalAccount)
        try write(pid: livePID, name: "desktop here", entrypoint: "claude-desktop",
                  host: "local-1", to: personal)
        try write(pid: parentPID, name: "terminal here", entrypoint: "cli",
                  host: nil, to: personal)

        let onPersonal = ClaudeSessionMonitor.read(directory: personal,
                                                   ownership: ownership(of: personal))
        let onWork = ClaudeSessionMonitor.read(directory: work,
                                               ownership: ownership(of: work))

        XCTAssertEqual(Set(onPersonal.map(\.name)), ["desktop here", "terminal here"])
        XCTAssertTrue(onWork.isEmpty)
    }

    // MARK: Two profiles, one account

    /// Both profiles signed in to the same account, the way a second login is
    /// left behind once the default one has been switched to it.
    private func sameAccount(of own: URL, shown: Set<String>) -> ClaudeSessionOwnership {
        var ownership = ClaudeSessionOwnership(
            own: own,
            directories: [personal, work],
            accounts: [personal.path: workAccount, work.path: workAccount],
            transcripts: [:],
            index: index()
        )
        ownership.isShown = { shown.contains($0.path) }
        return ownership
    }

    /// The reported case: the first profile's ring is switched off, so every
    /// session went to a ring nobody could see while the one that was on, for
    /// the very same account, showed none.
    func testASwitchedOffProfileHandsItsSessionsToTheSameAccount() throws {
        try host("local-1", account: workAccount)
        let desktop = try desktopRecord(pid: 11, host: "local-1")
        let terminal = try record(pid: 12, entrypoint: "cli", host: nil)
        let onlyWork: Set<String> = [work.path]

        XCTAssertTrue(sameAccount(of: work, shown: onlyWork).claims(desktop, foundIn: personal))
        XCTAssertFalse(sameAccount(of: personal, shown: onlyWork).claims(desktop, foundIn: personal))
        XCTAssertTrue(sameAccount(of: work, shown: onlyWork).claims(terminal, foundIn: personal),
                      "a terminal session of the same account follows it too")
    }

    /// With both rings on, nothing moves: the first profile keeps what the
    /// ordinary rule gives it.
    func testWithBothShownTheOrdinaryRuleStands() throws {
        try host("local-1", account: workAccount)
        let desktop = try desktopRecord(pid: 11, host: "local-1")
        let both: Set<String> = [personal.path, work.path]

        XCTAssertTrue(sameAccount(of: personal, shown: both).claims(desktop, foundIn: personal))
        XCTAssertFalse(sameAccount(of: work, shown: both).claims(desktop, foundIn: personal))
    }

    /// A different account is never a stand-in: switching a ring off must not
    /// put its sessions on somebody else's.
    func testAnotherAccountNeverTakesThemOver() throws {
        let terminal = try record(pid: 12, entrypoint: "cli", host: nil)
        let workPath = work.path
        var ownership = ownership(of: work)
        ownership.isShown = { $0.path == workPath }
        XCTAssertFalse(ownership.claims(terminal, foundIn: personal))
    }

    /// With no ownership at all — one profile on the machine — the read is
    /// exactly what it always was.
    func testWithoutOwnershipNothingIsAttributed() throws {
        try host("local-1", account: workAccount)
        try write(pid: livePID, name: "mine", entrypoint: "claude-desktop",
                  host: "local-1", to: personal)

        XCTAssertEqual(ClaudeSessionMonitor.read(directory: personal).map(\.name), ["mine"])
    }

    // MARK: -

    /// This process and its parent, so the liveness check passes and the only
    /// thing under test is the attribution.
    private var livePID: Int32 { ProcessInfo.processInfo.processIdentifier }
    private var parentPID: Int32 { getppid() }

    private func index() -> ClaudeDesktopSessionIndex {
        ClaudeDesktopSessionIndex(root: desktop)
    }

    private func ownership(of own: URL) -> ClaudeSessionOwnership {
        ClaudeSessionOwnership(
            own: own,
            directories: [personal, work],
            accounts: [personal.path: personalAccount, work.path: workAccount],
            transcripts: [:],
            index: index()
        )
    }

    /// The app's own record that `id` ran on `account`.
    private func host(_ id: String, account: String) throws {
        let organization = desktop.appendingPathComponent(account)
            .appendingPathComponent("org-1")
        try FileManager.default.createDirectory(at: organization,
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: organization.appendingPathComponent("\(id).json"))
    }

    private func desktopRecord(pid: Int32, host: String) throws -> ClaudeSessionRecord {
        try record(pid: pid, entrypoint: "claude-desktop", host: host)
    }

    private func record(pid: Int32, entrypoint: String, host: String?) throws
    -> ClaudeSessionRecord {
        let object = try JSONSerialization.jsonObject(
            with: Data(json(pid: pid, name: "r\(pid)", entrypoint: entrypoint, host: host).utf8)
        ) as! [String: Any]
        return try XCTUnwrap(ClaudeSessionRecord(json: object))
    }

    private func write(pid: Int32, name: String, entrypoint: String,
                       host: String?, to directory: URL) throws {
        try Data(json(pid: pid, name: name, entrypoint: entrypoint, host: host).utf8)
            .write(to: directory.appendingPathComponent("\(pid).json"))
    }

    private func json(pid: Int32, name: String, entrypoint: String, host: String?) -> String {
        let hostLine = host.map { #""hostSessionId": "\#($0)","# } ?? ""
        return """
        { "pid": \(pid), "sessionId": "s\(pid)", "cwd": "/Users/vinz/app",
          "name": "\(name)", "entrypoint": "\(entrypoint)", \(hostLine)
          "status": "busy" }
        """
    }
}
