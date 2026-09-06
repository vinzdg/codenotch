import SQLite3
import XCTest
@testable import Codenotch

/// Codex records its own rate-limit snapshots in the rollout log, so no
/// credential and no network are needed.
///
/// Pinned to a rollout recorded from a live run, like the others.
final class CodexUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    /// Verbatim from `~/.codex/sessions/2026/08/29/rollout-…jsonl`, trimmed.
    private let rollout = """
    {"type":"session_meta","payload":{"id":"abc"}}
    {"type":"event_msg","payload":{"type":"token_count",\
    "info":{"total_token_usage":{"total_tokens":23273},"model_context_window":258400},\
    "rate_limits":{"limit_id":"codex","limit_name":null,\
    "primary":{"used_percent":0.0,"window_minutes":43200,"resets_at":1790585719},\
    "secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":null},\
    "individual_limit":null,"spend_control_reached":null,"plan_type":"free"}}}
    {"type":"response_item","payload":{"role":"assistant"}}
    """

    func testReadsTheRecordedRollout() throws {
        let w = try CodexUsage.windows(fromRollout: rollout, now: now)
        XCTAssertEqual(w.map(\.id), ["primary"], "secondary is null on this plan")
        XCTAssertEqual(w[0].usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(w[0].label, "Monthly limit", "43200 minutes is 30 days")
    }

    /// The live payload carries `resets_at`, an absolute epoch — not the
    /// `resets_in_seconds` countdown the published schema suggested. Reading
    /// only the countdown silently loses the reset time.
    func testReadsAnAbsoluteResetTime() throws {
        let w = try CodexUsage.windows(fromRollout: rollout, now: now)
        XCTAssertEqual(try XCTUnwrap(w[0].resetsAt).timeIntervalSince1970, 1_790_585_719, accuracy: 1)
    }

    func testStillReadsACountdownIfABuildEmitsOne() throws {
        let countdown = """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{\
        "primary":{"used_percent":12.5,"window_minutes":300,"resets_in_seconds":7200}}}}
        """
        let w = try CodexUsage.windows(fromRollout: countdown, now: now)
        XCTAssertEqual(try XCTUnwrap(w[0].resetsAt).timeIntervalSince(now), 7200, accuracy: 1)
        XCTAssertEqual(w[0].label, "5h limit")
    }

    /// A rollout is append-only, so earlier lines are stale readings of the same
    /// windows. The last one is the only true one.
    func testTheLastSnapshotWins() throws {
        let later = rollout + "\n" + """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{\
        "primary":{"used_percent":80,"window_minutes":43200,"resets_at":1790585719}}}}
        """
        let w = try CodexUsage.windows(fromRollout: later, now: now)
        XCTAssertEqual(w[0].usedFraction ?? -1, 0.80, accuracy: 0.0001)
    }

    /// Codex names its windows only by length, so the label is derived from it.
    func testWindowsAreNamedByTheirLength() {
        XCTAssertEqual(CodexUsage.label(windowMinutes: 300, fallback: "primary"), "5h limit")
        XCTAssertEqual(CodexUsage.label(windowMinutes: 10080, fallback: "secondary"), "Weekly limit")
        XCTAssertEqual(CodexUsage.label(windowMinutes: 43200, fallback: "primary"), "Monthly limit")
        XCTAssertEqual(CodexUsage.label(windowMinutes: 30, fallback: "primary"), "30m limit")
        XCTAssertEqual(CodexUsage.label(windowMinutes: nil, fallback: "primary"), "Current session")
    }

    /// The rollouts on this machine look exactly like this — no snapshot at all.
    /// That is "nothing to read", not an error and not zero.
    func testARolloutWithoutASnapshotReportsNothingMetered() {
        let bare = """
        {"type":"session_meta","payload":{"id":"abc"}}
        {"type":"response_item","payload":{"role":"assistant"}}
        """
        XCTAssertThrowsError(try CodexUsage.windows(fromRollout: bare, now: now)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testTolueratesRubbishLines() throws {
        let messy = "not json\n" + rollout + "\nhalf a line {"
        XCTAssertEqual(try CodexUsage.windows(fromRollout: messy, now: now).count, 1)
    }
}

/// Newer builds record a `premium`-typed snapshot with null windows. That is
/// "nothing usable in this file", not a zero — and it must not hide an older
/// thread's real percentages when the provider walks recent rollouts.
final class CodexRolloutFallbackTests: XCTestCase {
    /// Verbatim shape from `~/.codex/sessions/2026/09/06/rollout-…jsonl`.
    private let premium = """
    {"timestamp":"2026-09-06T06:13:52.937Z","type":"event_msg","payload":{\
    "type":"token_count","rate_limits":{"limit_id":"premium","primary":null,\
    "secondary":null,"credits":{"has_credits":false,"unlimited":false,\
    "balance":"0"},"plan_type":"plus"}}}
    """

    func testPremiumSnapshotWithNullWindowsReportsNothingMetered() {
        XCTAssertThrowsError(try CodexUsage.windows(fromRollout: premium)) { error in
            guard case UsageProviderError.nothingMetered(let why) = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
            XCTAssertEqual(why, "Codex reported no usage windows")
        }
    }

    /// The read takes the first rollout *with windows*, so the list has to be
    /// newest-first with missing files dropped rather than a single newest URL.
    func testRecentRolloutsAreNewestFirstAndSkipMissingFiles() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-rollouts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let old = dir.appendingPathComponent("old.jsonl")
        let new = dir.appendingPathComponent("new.jsonl")
        try "x".write(to: old, atomically: true, encoding: .utf8)
        try "x".write(to: new, atomically: true, encoding: .utf8)

        let store = dir.appendingPathComponent("state.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE threads (
                rollout_path TEXT, archived INTEGER, updated_at_ms INTEGER);
            """, nil, nil, nil)
        // Newest first in time, plus a missing file and an archived thread —
        // both must be dropped rather than returned.
        for (path, ms, archived) in [
            (new.path, 300, 0), ("/nonexistent/gone.jsonl", 250, 0),
            (old.path, 200, 0), (old.path, 400, 1),
        ] as [(String, Int, Int)] {
            sqlite3_exec(db, """
                INSERT INTO threads (rollout_path, archived, updated_at_ms)
                VALUES ('\(path)', \(archived), \(ms));
                """, nil, nil, nil)
        }

        XCTAssertEqual(CodexStore.recentRollouts(in: store), [new, old])
        XCTAssertEqual(CodexStore.newestRollout(in: store), new)
    }
}

/// A rollout is a record, not a reading: a window whose reset has passed no
/// longer exists, and its percentage is false rather than merely old. The
/// case that prompted this: a three-day-old 0% on the 5h window beside a
/// Codex that had just refused a prompt for lack of that same allowance.
final class CodexExpiredWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func window(id: String, resetsIn seconds: TimeInterval?) -> LimitWindow {
        LimitWindow(id: id, label: id,
                    usedFraction: 0,
                    resetsAt: seconds.map { now.addingTimeInterval($0) })
    }

    func testAResetWindowIsDropped() {
        let kept = CodexLocalProvider.current(
            [window(id: "primary", resetsIn: -3600),
             window(id: "secondary", resetsIn: 3600)],
            now: now)
        XCTAssertEqual(kept.map(\.id), ["secondary"])
    }

    func testAWindowWithNoResetCarriesNoExpiry() {
        let kept = CodexLocalProvider.current(
            [window(id: "primary", resetsIn: nil)], now: now)
        XCTAssertEqual(kept.map(\.id), ["primary"])
    }

    func testAllExpiredLeavesNothing() {
        XCTAssertTrue(CodexLocalProvider.current(
            [window(id: "primary", resetsIn: -10)], now: now).isEmpty)
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

/// Codex writes usage into a file as it runs, so the file stops changing the
/// moment you stop using Codex. Reading it still succeeds instantly, which is
/// how a three-day-old percentage came to be shown as a live one.
final class CodexFreshnessTests: XCTestCase {
    private let line = """
    {"timestamp":"2026-08-29T09:15:07.949Z","type":"event","payload":{"rate_limits":\
    {"primary":{"used_percent":6.0,"window_minutes":43200,"resets_at":1790585722}}}}
    """

    func testItReadsWhenCodexTookTheReading() throws {
        let at = try XCTUnwrap(CodexUsage.recordedAt(inRollout: line))
        XCTAssertEqual(at.timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-08-29T09:15:07Z")!
                           .timeIntervalSince1970,
                       accuracy: 1)
    }

    /// The newest snapshot wins — a rollout accumulates them.
    func testTheLastSnapshotWins() throws {
        let older = line.replacingOccurrences(of: "2026-08-29", with: "2026-08-01")
        let at = try XCTUnwrap(CodexUsage.recordedAt(inRollout: older + "\n" + line))
        XCTAssertEqual(Calendar(identifier: .gregorian)
            .component(.day, from: at), 29)
    }

    func testAFreshReadingIsCurrent() {
        let now = Date()
        XCTAssertEqual(CodexLocalProvider.status(recordedAt: now, now: now), .ok)
    }

    /// The case that was wrong: usable, but not current, and it must say so.
    func testAThreeDayOldReadingIsStaleNotCurrent() {
        let now = Date()
        let old = now.addingTimeInterval(-3 * 24 * 3600)
        XCTAssertEqual(CodexLocalProvider.status(recordedAt: old, now: now), .stale(since: old))
    }

    /// Never claim currency that cannot be supported.
    func testNoTimestampIsTreatedAsStale() {
        guard case .stale = CodexLocalProvider.status(recordedAt: nil) else {
            return XCTFail("a reading with no timestamp was reported as current")
        }
    }

    func testALineWithoutRateLimitsIsIgnored() {
        let noise = #"{"timestamp":"2026-09-01T10:00:00Z","type":"event","payload":{}}"#
        XCTAssertNil(CodexUsage.recordedAt(inRollout: noise))
    }
}

/// Codex publishes no usage endpoint, so the reading used to come from the
/// `rate_limits` snapshot it writes into a thread's rollout. That is a file:
/// written during a turn and never again. Three days without running Codex and
/// the notch reported a three-day-old 14% while Codex's own panel showed 16%.
///
/// Its app server answers `account/rateLimits/read` with the live figure, and
/// this is that reply — recorded from a real run, account id scrubbed.
final class CodexBridgeTests: XCTestCase {
    private let reply = Data("""
    {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,\
    "primary":{"usedPercent":16,"windowDurationMins":43200,"resetsAt":1790585722},\
    "secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":null},\
    "individualLimit":null,"spendControlReached":false,"planType":"free",\
    "rateLimitReachedType":null},"rateLimitResetCredits":{"availableCount":0,"credits":[]},\
    "accountId":"00000000-0000-0000-0000-000000000000","rateLimitUpsell":null}}
    """.utf8)

    func testItReadsTheLiveFigure() throws {
        let windows = CodexBridge.windows(in: reply)
        let primary = try XCTUnwrap(windows.first { $0.id == "primary" })
        XCTAssertEqual(try XCTUnwrap(primary.usedFraction), 0.16, accuracy: 0.0001)
        // 30 days: the same naming the rollout path uses, so the tooltip does
        // not change wording depending on which source answered.
        XCTAssertEqual(primary.label, "Monthly limit")
        XCTAssertEqual(try XCTUnwrap(primary.resetsAt).timeIntervalSince1970, 1_790_585_722)
    }

    /// The disagreement that started this: the same account, at the same
    /// moment, from the two sources.
    func testTheLiveFigureDisagreesWithAStaleRollout() throws {
        let rollout = """
        {"timestamp":"2026-09-02T04:24:03.641Z","payload":{"type":"token_count","rate_limits":\
        {"primary":{"used_percent":14.0,"window_minutes":43200,"resets_at":1790585719}}}}
        """
        let recorded = try XCTUnwrap(CodexUsage.windows(fromRollout: rollout).first)
        let live = try XCTUnwrap(CodexBridge.windows(in: reply).first)
        XCTAssertEqual(try XCTUnwrap(recorded.usedFraction), 0.14, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(live.usedFraction), 0.16, accuracy: 0.0001)
        XCTAssertNotEqual(recorded.usedFraction, live.usedFraction,
                          "the fixture no longer captures the case this was built for")
    }

    /// Only `secondary` when the account has one — a null must not become a
    /// second ring's worth of nothing.
    func testANullSecondaryIsDropped() {
        XCTAssertEqual(CodexBridge.windows(in: reply).count, 1)
    }

    func testBothWindowsAreReadWhenBothArePresent() {
        let two = Data("""
        {"id":2,"result":{"rateLimits":{\
        "primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1790585722},\
        "secondary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1790999999}}}}
        """.utf8)
        let windows = CodexBridge.windows(in: two)
        XCTAssertEqual(windows.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(windows.map(\.label), ["5h limit", "Weekly limit"])
    }

    /// The reply arrives amongst notifications, so it has to be picked out by
    /// id rather than taken as whatever came back first.
    func testTheReplyIsFoundAmongNotifications() throws {
        var stream = Data()
        stream.append(Data(#"{"method":"remoteControl/status/changed","params":{}}"# .utf8))
        stream.append(Data("\n".utf8))
        stream.append(Data(#"{"id":1,"result":{"userAgent":"codenotch/0.1"}}"#.utf8))
        stream.append(Data("\n".utf8))
        stream.append(reply)
        stream.append(Data("\n".utf8))

        let found = try XCTUnwrap(CodexBridge.response(id: 2, inLines: stream))
        XCTAssertEqual(CodexBridge.windows(in: found).first?.id, "primary")
    }

    func testAPartialStreamYieldsNothingYet() {
        let half = Data(#"{"id":2,"result":{"rateLi"#.utf8)
        XCTAssertNil(CodexBridge.response(id: 2, inLines: half))
    }

    func testGarbageIsNotMistakenForAReading() {
        XCTAssertTrue(CodexBridge.windows(in: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(CodexBridge.windows(in: Data(#"{"id":2,"result":{}}"#.utf8)).isEmpty)
    }

    /// The app bundle is called ChatGPT.app even though its identifier is
    /// `com.openai.codex`, which is exactly the sort of thing that gets fixed
    /// by someone tidying up.
    func testItLooksInsideTheDesktopAppFirst() {
        let paths = CodexBridge.candidatePaths(
            home: "/Users/x", appBundle: URL(fileURLWithPath: "/Applications/ChatGPT.app")
        )
        XCTAssertEqual(paths.first?.path,
                       "/Applications/ChatGPT.app/Contents/Resources/codex")
        XCTAssertTrue(paths.contains { $0.path == "/Users/x/.codex/bin/codex" },
                      "a standalone CLI install is not looked for")
    }

    /// The handshake has to name a client and ask by id, or the reply cannot be
    /// matched to the request.
    func testTheHandshakeAsksForRateLimitsLast() {
        let lines = CodexBridge.handshake
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("\"initialize\""))
        XCTAssertTrue(lines[0].contains("codenotch"))
        XCTAssertTrue(lines[2].contains("account/rateLimits/read"))
        XCTAssertTrue(lines[2].contains("\"id\":\(CodexBridge.requestID)"))
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

/// A limit can be *reached* while the headline still shows room: vendors meter
/// some capabilities separately from the plan's main allowance. Codex's own
/// banner — "Chat paused until usage resets at 4:13 PM" — sat above an account
/// the notch was correctly reporting as 84% left, and the question it prompted
/// was "why is there still 84%".
final class UsageBlockTests: XCTestCase {
    private func reply(reached: String?, resetsAt: Double? = 1_790_585_722) -> Data {
        let type = reached.map { "\"\($0)\"" } ?? "null"
        let resets = resetsAt.map { String($0) } ?? "null"
        return Data("""
        {"id":2,"result":{"rateLimits":{"limitId":"codex",\
        "primary":{"usedPercent":16,"windowDurationMins":43200,"resetsAt":\(resets)},\
        "secondary":null,"planType":"free","rateLimitReachedType":\(type)}}}
        """.utf8)
    }

    /// The ordinary case, and the one recorded from this machine: nothing
    /// reached, so nothing is claimed.
    func testNothingReachedIsNotABlock() {
        XCTAssertNil(CodexBridge.block(in: reply(reached: nil)))
    }

    func testAReachedLimitIsABlock() throws {
        let block = try XCTUnwrap(CodexBridge.block(in: reply(reached: "rate_limit_reached")))
        XCTAssertEqual(block.reason, "Paused")
        XCTAssertEqual(try XCTUnwrap(block.resetsAt).timeIntervalSince1970, 1_790_585_722)
    }

    func testWorkspaceLimitsAreNamedAsSuch() throws {
        for type in ["workspace_owner_credits_depleted", "workspace_member_credits_depleted"] {
            XCTAssertEqual(CodexBridge.reason(forReachedType: type), "Workspace credits used up")
        }
        for type in ["workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached"] {
            XCTAssertEqual(CodexBridge.reason(forReachedType: type), "Workspace limit reached")
        }
    }

    /// A spelling we have not seen still means blocked. Saying "Paused" beats
    /// saying nothing because the vocabulary grew.
    func testAnUnknownReachedTypeStillBlocks() throws {
        let block = try XCTUnwrap(CodexBridge.block(in: reply(reached: "some_new_thing")))
        XCTAssertEqual(block.reason, "Paused")
    }

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

