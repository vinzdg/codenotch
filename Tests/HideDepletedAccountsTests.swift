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

    func testAnEmptyDeepSeekBalanceDepletes() {
        // Balance mode carries no fraction on its headline; the band is the
        // only thing that says the wallet is empty.
        let reading = DeepSeekUsage.Reading(currency: "CNY", spent: 100, balance: 0, availableTokens: nil)
        let empty = ProviderSnapshot(id: "deepseek", displayName: "DeepSeek", glyph: .deepseek,
                                     fidelity: .derived, status: .ok,
                                     windows: DeepSeekUsage.windows(from: reading, displayMode: .balance))
        XCTAssertTrue(empty.isDepleted)
    }

    func testAFundedDeepSeekBalanceDoesNotDeplete() {
        let reading = DeepSeekUsage.Reading(currency: "CNY", spent: 100, balance: 5, availableTokens: nil)
        let funded = ProviderSnapshot(id: "deepseek", displayName: "DeepSeek", glyph: .deepseek,
                                      fidelity: .derived, status: .ok,
                                      windows: DeepSeekUsage.windows(from: reading, displayMode: .balance))
        XCTAssertFalse(funded.isDepleted)
    }

    /// The monthly window a custom endpoint builds when it is set to show
    /// what is left: the remaining share as its fraction, the band from the
    /// share spent (CustomEndpointProvider, currency budget branch).
    private func remainingBudget(spent: Double, budget: Double) -> ProviderSnapshot {
        let spentShare = min(max(spent / budget, 0), 1)
        return snapshot(windows: [
            LimitWindow(id: "monthly-budget", label: "Remaining Budget", usedFraction: 1 - spentShare,
                        duration: 30 * 86400, bandOverride: UsageBand.band(for: spentShare)),
        ], headlineID: "monthly-budget", weeklyID: nil)
    }

    func testAnUntouchedRemainingBudgetDoesNotDeplete() {
        XCTAssertFalse(remainingBudget(spent: 0, budget: 20).isDepleted)
    }

    func testASpentRemainingBudgetDepletes() {
        XCTAssertTrue(remainingBudget(spent: 20, budget: 20).isDepleted)
    }

    func testAStaleExhaustedBandDoesNotDeplete() {
        var stale = remainingBudget(spent: 20, budget: 20)
        stale.status = .stale(since: Date())
        XCTAssertFalse(stale.isDepleted)
    }

    func testABudgetShowingUseStillReadsItsFraction() {
        // Without the remaining option there is no band override, and the
        // fraction is the share spent as everywhere else.
        let spent = snapshot(windows: [
            LimitWindow(id: "monthly-budget", label: "Monthly Budget", usedFraction: 1, duration: 30 * 86400),
        ], headlineID: "monthly-budget", weeklyID: nil)
        XCTAssertTrue(spent.isDepleted)
    }

    func testProviderPauseWithRoomDoesNotDeplete() {
        // A pause the provider reported itself — rate limited, not spent —
        // is not a window at 0% left.
        var paused = snapshot()
        paused.block = UsageBlock(reason: "Rate limited", resetsAt: nil)
        XCTAssertFalse(paused.isDepleted)
    }
}
