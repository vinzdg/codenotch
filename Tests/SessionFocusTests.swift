import XCTest
@testable import Codenotch

@MainActor
final class SessionFocusTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        SessionFocus.resetTestHooks()
    }

    func testAgentSessionFocusTargetEquality() {
        let now = Date()
        let s1 = AgentSession(
            id: "1", name: "test", detail: "cli", state: .busy,
            waitingFor: nil, since: now, focusTarget: .process(1234)
        )
        let s2 = AgentSession(
            id: "1", name: "test", detail: "cli", state: .busy,
            waitingFor: nil, since: now, focusTarget: .process(1234)
        )
        let s3 = AgentSession(
            id: "1", name: "test", detail: "cli", state: .busy,
            waitingFor: nil, since: now, focusTarget: .process(5678)
        )
        let s4 = AgentSession(
            id: "1", name: "test", detail: "cli", state: .busy,
            waitingFor: nil, since: now, focusTarget: .application(bundleID: "com.apple.Terminal")
        )
        let s5 = AgentSession(
            id: "1", name: "test", detail: "cli", state: .busy,
            waitingFor: nil, since: now, focusTarget: nil
        )

        XCTAssertEqual(s1, s2)
        XCTAssertNotEqual(s1, s3)
        XCTAssertNotEqual(s1, s4)
        XCTAssertNotEqual(s1, s5)
    }

    func testProcessTargetWalksProcessTreeToAncestor() {
        var activated = false

        // CLI pid 100 -> shell pid 50 -> terminal pid 10 -> launchd pid 1
        let parents: [pid_t: pid_t] = [100: 50, 50: 10, 10: 1]
        SessionFocus.parentPidLookup = { parents[$0] }

        // Only pid 10 is a GUI app (we borrow current running app for pid 10)
        let currentApp = NSRunningApplication.current
        SessionFocus.appLookup = { pid in
            pid == 10 ? currentApp : nil
        }
        SessionFocus.appActivator = { app in
            if app == currentApp {
                activated = true
                return true
            }
            return false
        }

        let result = SessionFocus.activate(target: .process(100))
        XCTAssertTrue(result)
        XCTAssertTrue(activated)
    }

    func testProcessTargetFailsWhenNoAncestorAppFound() {
        let parents: [pid_t: pid_t] = [100: 50, 50: 1]
        SessionFocus.parentPidLookup = { parents[$0] }
        SessionFocus.appLookup = { _ in nil }

        let result = SessionFocus.activate(target: .process(100))
        XCTAssertFalse(result)
    }

    func testApplicationTargetFindsRunningApp() {
        var activated = false
        let currentApp = NSRunningApplication.current
        let targetBundleID = currentApp.bundleIdentifier ?? "com.apple.finder"

        SessionFocus.runningApplicationsLookup = { [currentApp] }
        SessionFocus.appActivator = { app in
            if app == currentApp {
                activated = true
                return true
            }
            return false
        }

        let result = SessionFocus.activate(target: .application(bundleID: targetBundleID))
        XCTAssertTrue(result)
        XCTAssertTrue(activated)
    }

    func testApplicationTargetFailsForNonExistentBundle() {
        SessionFocus.runningApplicationsLookup = { [] }
        let result = SessionFocus.activate(target: .application(bundleID: "com.nonexistent.fakeapp.12345"))
        XCTAssertFalse(result)
    }

    func testClaudeSessionRecordCarriesProcessFocusTarget() throws {
        let json: [String: Any] = [
            "pid": 4567,
            "sessionId": "test-session",
            "cwd": "/Users/vinz/project",
            "status": "busy",
            "statusUpdatedAt": 1787897225305
        ]
        let record = try XCTUnwrap(ClaudeSessionRecord(json: json))
        XCTAssertEqual(record.session.focusTarget, .process(4567))
    }

    func testGrokActivityCarriesProcessFocusTarget() {
        let row: [String: Any] = [
            "session_id": "session-1",
            "pid": 8901,
            "cwd": "/Users/vinz/repo"
        ]
        let pid = (row["pid"] as? NSNumber)?.int32Value
        let target: AgentSession.FocusTarget? = pid.map { .process($0) }
        XCTAssertEqual(target, .process(8901))
    }

    func testCursorSessionCarriesApplicationFocusTarget() {
        let head: [String: Any] = [
            "composerId": "c1",
            "name": "Refactor",
            "unfinishedRunAt": 1787981829823,
            "conversationCheckpointLastUpdatedAt": 1787981829823
        ]
        let data = try! JSONSerialization.data(withJSONObject: head)
        let json = String(data: data, encoding: .utf8)!
        let session = CursorActivityMonitor.session(
            fromHeader: json,
            cursorLaunchedAt: .distantPast,
            staleAfter: 900,
            now: Date(timeIntervalSince1970: 1787981830)
        )
        XCTAssertEqual(session?.focusTarget, .application(bundleID: CursorCredentials.bundleID))
    }

    func testCodexDesktopSessionCarriesApplicationFocusTarget() {
        let now = Date()
        let session = CodexActivityMonitor.session(
            id: "codex.desktop",
            name: "Desktop Chat",
            modified: now,
            staleAfter: 10,
            now: now,
            focusTarget: .application(bundleID: "com.openai.chat")
        )
        XCTAssertEqual(session?.focusTarget, .application(bundleID: "com.openai.chat"))
    }

    func testCodexRolloutSessionCarriesNilFocusTarget() {
        let now = Date()
        let session = CodexActivityMonitor.session(
            id: "codex.rollout.jsonl",
            name: "CLI Turn",
            modified: now,
            staleAfter: 10,
            now: now,
            focusTarget: nil
        )
        XCTAssertNil(session?.focusTarget)
    }
}
