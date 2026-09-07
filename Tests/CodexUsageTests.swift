import SQLite3
import XCTest
@testable import Codenotch

final class CodexUsageTests: XCTestCase {
    private func windows(_ json: String) throws -> [LimitWindow] {
        try CodexUsage.windows(from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testBothWindowsAreReadWhenBothArePresent() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":1800001000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1800600000}},
         "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":99,"limit_window_seconds":18000}}}],
         "code_review_rate_limit":{"primary_window":{"used_percent":90,"limit_window_seconds":604800}},
         "credits":{"balance":"100"},"model_usage":{"spark":99}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.map(\.label), ["5h limit", "Weekly limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10])
        XCTAssertEqual(result.first?.resetsAt, Date(timeIntervalSince1970: 1_800_001_000))
    }

    /// The reported case: a free-plan account's primary window was 30 days,
    /// not 5 hours or 7 — recorded from a live request. The old parser only
    /// recognised two fixed durations and silently dropped anything else,
    /// which on this exact account meant every window vanished and the ring
    /// reported nothing metered on an account that was genuinely 16% through
    /// a real limit.
    func testAMonthlyPrimaryWindowIsNotDropped() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":16,"limit_window_seconds":2592000,
        "reset_after_seconds":1838382,"reset_at":1790585722},"secondary_window":null},
         "plan_type":"free"}
        """)
        XCTAssertEqual(result.map(\.id), ["primary"])
        XCTAssertEqual(result.first?.label, "Monthly limit")
        XCTAssertEqual(result.first?.usedFraction ?? -1, 0.16, accuracy: 0.0001)
    }

    /// A duration that is none of the named buckets still gets a usable label
    /// instead of being the thing that makes the fetch fail.
    func testAnUnrecognisedDurationStillGetsALabel() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":259200}}}
        """)
        XCTAssertEqual(result.first?.label, "3d limit")
    }

    // The endpoint can put a weekly-only allowance in primary_window.
    func testANullSecondaryIsDropped() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800,
        "reset_after_seconds":604119,"reset_at":1789308033},"secondary_window":null}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary"])
        XCTAssertEqual(result.first?.label, "Weekly limit")
        XCTAssertEqual(result.first?.resetsAt, Date(timeIntervalSince1970: 1_789_308_033))
    }

    func testStillReadsACountdownIfABuildEmitsOne() throws {
        let result = try windows("""
        {"rate_limit":{
        "primary_window":{"used_percent":8,"limit_window_seconds":604800},
        "secondary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":120}}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.first?.usedFraction, 0.08)
        XCTAssertNil(result.first?.resetsAt)
        XCTAssertEqual(result.last?.usedFraction, 0)
        XCTAssertEqual(result.last?.resetsAt, Date(timeIntervalSince1970: 1_800_000_120))
    }

    /// The reported symptom: the tooltip showed only the weekly window and the
    /// ring showed a dash. A null `used_percent` on one window threw the whole
    /// fetch away, so a good weekly window was hidden behind the bad hourly
    /// one. One malformed window is skipped, not fatal.
    func testAWindowMissingUsedPercentIsSkippedRatherThanFailing() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":null,"limit_window_seconds":18000,"reset_at":1800001000},
          "secondary_window":{"used_percent":29,"limit_window_seconds":604800,"reset_at":1800600000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["secondary"])
        XCTAssertEqual(result.first?.label, "Weekly limit")
        XCTAssertEqual(result.first?.usedFraction ?? -1, 0.29, accuracy: 0.0001)
    }

    /// A window without a duration still gets a fallback label instead of
    /// failing the decode of the whole response.
    func testAWindowMissingItsDurationStillParses() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":8,"reset_at":1800001000},
          "secondary_window":{"used_percent":42,"limit_window_seconds":604800,"reset_at":1800600000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.first?.label, "Current session")
        XCTAssertEqual(result.last?.label, "Weekly limit")
    }

    /// Both windows malformed is still an error, not an empty success — the
    /// store turns it into "waiting", not a silent 0%.
    func testBothWindowsMissingLeavesNothingMetered() {
        XCTAssertThrowsError(try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":null,"limit_window_seconds":18000},
          "secondary_window":null}}
        """))
    }
}

/// The activity signal is a heuristic — a rollout written moments ago — so what
/// it will and will not claim is worth pinning down.
@MainActor
final class CodexActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    func testARolloutWrittenJustNowIsBusy() throws {
        let s = try XCTUnwrap(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-2), staleAfter: 8, now: now
        ))
        XCTAssertEqual(s.state, .busy)
        XCTAssertEqual(s.name, "Codex")
    }

    /// It errs short on purpose: a finished turn must not keep the ring spinning.
    func testAnOlderRolloutIsNotActivity() {
        XCTAssertNil(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-30), staleAfter: 8, now: now
        ))
    }

    func testTheBoundaryIsInclusive() {
        XCTAssertNotNil(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-8), staleAfter: 8, now: now
        ))
        XCTAssertNil(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-8.1), staleAfter: 8, now: now
        ))
    }
}

/// "Codex" is two programs. The CLI and the VS Code extension append to a
/// rollout under `~/.codex/sessions`; the desktop app — ChatGPT.app, which is
/// what most people now mean — writes none of them, keeping its threads in
/// `~/.codex/sqlite/codex-dev.db` instead.
///
/// The activity monitor watched only the rollouts, so it could never see the
/// desktop app working: on this machine every rollout was written by VS Code
/// and the newest was three days old, while the desktop catalogue had been
/// touched seconds ago. The ring simply never span.
final class CodexDesktopActivityTests: XCTestCase {
    private let store = URL(fileURLWithPath: "/tmp/codex-desktop-test.db")

    private func makeCatalogue(rows: [(Double, String)]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-dev-\(UUID().uuidString).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE local_thread_catalog (
                thread_id TEXT, display_title TEXT NOT NULL,
                source_updated_at REAL NOT NULL, source_kind TEXT);
            """, nil, nil, nil)
        for (at, title) in rows {
            sqlite3_exec(db, """
                INSERT INTO local_thread_catalog
                (thread_id, display_title, source_updated_at, source_kind)
                VALUES ('t', '\(title)', \(at), 'chatgpt');
                """, nil, nil, nil)
        }
        return url
    }

    func testItReadsTheNewestDesktopThread() throws {
        let url = try makeCatalogue(rows: [(1_788_000_000, "Older"),
                                           (1_788_582_173.099, "Deep SaaS Research")])
        defer { try? FileManager.default.removeItem(at: url) }

        let newest = try XCTUnwrap(CodexStore.newestDesktopThread(in: url))
        XCTAssertEqual(newest.title, "Deep SaaS Research")
        // Seconds with a fraction, not the milliseconds the `threads` table
        // next door uses — reading it as milliseconds puts it in 1970.
        XCTAssertEqual(newest.updatedAt.timeIntervalSince1970, 1_788_582_173.099, accuracy: 0.01)
    }

    /// The reported symptom: the desktop app is working now, the rollouts are
    /// days old, and the ring has to spin.
    @MainActor func testDesktopWorkCountsAsActivity() throws {
        let now = Date()
        let url = try makeCatalogue(rows: [(now.addingTimeInterval(-2).timeIntervalSince1970,
                                            "Deep SaaS Research")])
        defer { try? FileManager.default.removeItem(at: url) }

        // No rollout store at all, which is the case for someone who has only
        // ever used the desktop app.
        let sessions = CodexActivityMonitor.read(
            stateStore: URL(fileURLWithPath: "/nonexistent/state.sqlite"),
            desktopStore: url, staleAfter: 8, now: now
        )
        XCTAssertEqual(sessions.count, 1, "the desktop app's work was invisible")
        XCTAssertEqual(sessions.first?.state, .busy)
        XCTAssertEqual(sessions.first?.name, "Deep SaaS Research",
                       "the thread's own name is more use than \"Codex\"")
    }

    /// And it still errs short: a finished conversation must not keep spinning.
    @MainActor func testAnOldDesktopThreadIsNotActivity() throws {
        let now = Date()
        let url = try makeCatalogue(rows: [(now.addingTimeInterval(-600).timeIntervalSince1970,
                                            "Yesterday's chat")])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(CodexActivityMonitor.read(
            stateStore: URL(fileURLWithPath: "/nonexistent/state.sqlite"),
            desktopStore: url, staleAfter: 8, now: now
        ).isEmpty)
    }

    func testAMissingCatalogueIsNotAnError() {
        XCTAssertNil(CodexStore.newestDesktopThread(
            in: URL(fileURLWithPath: "/nonexistent/codex-dev.db")
        ))
    }
}

final class UsageBlockTests: XCTestCase {
    /// The wording the vendor's own banner uses — a clock time, not a
    /// countdown, because that is the thing you are waiting for.
    func testItReadsAsAClockTime() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let block = UsageBlock(reason: "Paused", resetsAt: now.addingTimeInterval(90 * 60))
        let text = block.summary(now: now)
        XCTAssertTrue(text.hasPrefix("Paused until "), text)
        XCTAssertFalse(text.contains("min"), "a countdown, not the time it lifts")
    }

    /// With no reset time there is nothing to promise, so it says only what it
    /// knows.
    func testWithoutAResetItSaysOnlyTheReason() {
        XCTAssertEqual(UsageBlock(reason: "Paused", resetsAt: nil).summary(), "Paused")
    }

    /// A reset already in the past is not worth showing as a deadline.
    func testAPastResetIsDropped() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let block = UsageBlock(reason: "Paused", resetsAt: now.addingTimeInterval(-60))
        XCTAssertEqual(block.summary(now: now), "Paused")
    }

    /// The card has to be tall enough for the line, or it is clipped — the same
    /// mistake the status message made.
    func testTheCardMakesRoomForIt() {
        let plain = NotchLayout.cardHeight(windowCount: 1)
        let blocked = NotchLayout.cardHeight(windowCount: 1,
                                             blockMessage: "Paused until 4:13 PM")
        XCTAssertGreaterThan(blocked, plain, "the blocked line has no room to be drawn in")
    }

    /// And a long one gets the room it actually needs.
    func testALongBlockMessageGetsMoreThanOneLine() {
        let long = "Workspace limit reached until Thu 4:13 PM — every seat on this "
                 + "workspace shares one allowance and it is spent"
        XCTAssertGreaterThan(NotchLayout.bodyTextHeight(long),
                             NotchLayout.cardBodyLineHeight)
        XCTAssertGreaterThan(
            NotchLayout.cardHeight(windowCount: 1, blockMessage: long),
            NotchLayout.cardHeight(windowCount: 1, blockMessage: "Paused")
        )
    }
}

