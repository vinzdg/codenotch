import XCTest
@testable import Codenotch

/// Hiding accounts with nothing left to spend: either the headline window or
/// the weekly allowance at 0% remaining hides the account — one spent window
/// is enough, because the other window's room cannot be spent while it lasts.
/// Stale readings never hide: an old number is not proof the account is empty
/// now.
final class HideDepletedAccountsTests: XCTestCase {
    private func snapshot(status: ProviderStatus = .ok,
                          windows: [LimitWindow]? = nil,
                          headlineID: String? = "session",
                          weeklyID: String? = "weekly_all") -> ProviderSnapshot {
        ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                         fidelity: .official, status: status,
                         windows: windows ?? [
                            LimitWindow(id: "session", label: "Session", usedFraction: 0.5),
                            LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 0.3),
                         ],
                         headlineID: headlineID, weeklyID: weeklyID)
    }

    func testHealthyAccountIsNotDepleted() {
        XCTAssertFalse(snapshot().isDepleted)
    }

    func testSpentHeadlineDepletesWithAHealthyWeek() {
        // A spent 5-hour beside weekly room — the week's room cannot be
        // spent while the short window is shut.
        let spent = snapshot(windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 1.0),
            LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 0.3),
        ])
        XCTAssertTrue(spent.isDepleted)
    }

    func testSpentWeekDepletesWithHeadlineRoom() {
        let spent = snapshot(windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 0.5),
            LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 1.0),
        ])
        XCTAssertTrue(spent.isDepleted)
    }

    func testSpentWeeklyHeadlineDepletes() {
        // Antigravity lands its headline on the weekly window when that is
        // the tightest one: the allowance is still spent either way.
        let spent = snapshot(windows: [
            LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 1.0),
        ], headlineID: "weekly_all", weeklyID: "weekly_all")
        XCTAssertTrue(spent.isDepleted)
    }

    func testStaleSpentWindowsDoNotDeplete() {
        // The whole point of the stale rule: a 100% that is merely old may
        // already have reset, so the account stays until a fresh fetch says
        // otherwise.
        let stale = snapshot(status: .stale(since: Date()), windows: [
            LimitWindow(id: "session", label: "Session", usedFraction: 1.0),
            LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 0.3),
        ])
        XCTAssertFalse(stale.isDepleted)
    }

    func testNoReadingDoesNotDeplete() {
        // A dash is missing, not empty.
        XCTAssertFalse(snapshot(windows: []).isDepleted)
    }

    func testProviderPauseWithRoomDoesNotDeplete() {
        // A pause the provider reported itself — rate limited, not spent —
        // is not a window at 0% left.
        var paused = snapshot()
        paused.block = UsageBlock(reason: "Rate limited", resetsAt: nil)
        XCTAssertFalse(paused.isDepleted)
    }
}
