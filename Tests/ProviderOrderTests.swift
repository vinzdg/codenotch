import XCTest
@testable import Codenotch

/// The order the rings sit in is the user's, and it has to survive a provider
/// set that changes underneath it — Claude Code contributes one provider per
/// `~/.claude-<slug>` found at launch, so an id can turn up on a Mac that has
/// never seen it and disappear from one that has.
final class ProviderOrderTests: XCTestCase {

    private func arrange(_ ids: [String], by order: [String]) -> [String] {
        ProviderOrder.arrange(ids, by: order, id: { $0 })
    }

    /// Never chosen is not the same as having chosen the order the app ships
    /// with — which is what lets a later version change that order for everyone
    /// who has no opinion.
    func testAnEmptyOrderLeavesTheBuiltInOrderAlone() {
        XCTAssertEqual(arrange(["claude", "cursor", "codex"], by: []),
                       ["claude", "cursor", "codex"])
    }

    func testProvidersFollowTheStoredOrder() {
        XCTAssertEqual(arrange(["claude", "cursor", "codex"], by: ["codex", "claude", "cursor"]),
                       ["codex", "claude", "cursor"])
    }

    /// The regression that matters. A provider added by a new version, or a
    /// profile directory created this morning, is in nobody's stored order —
    /// and a strict sort would silently hide it.
    func testAProviderTheOrderHasNeverSeenStillAppears() {
        let arranged = arrange(["claude", "cursor", "opencode"], by: ["cursor", "claude"])
        XCTAssertEqual(arranged, ["cursor", "claude", "opencode"])
        XCTAssertEqual(arranged.count, 3, "a provider the stored order predates must not vanish")
    }

    /// A `~/.claude-work` that is not on this Mac today. Ordinary, not
    /// corruption — and it must not shift anything else.
    func testAStoredIDWithNoProviderIsIgnored() {
        XCTAssertEqual(arrange(["claude", "cursor"], by: ["cursor", "claude-work", "claude"]),
                       ["cursor", "claude"])
    }

    /// What `UsageStore.order` relies on when it re-applies the order to an
    /// already-sorted `snapshots`: the rings must not shuffle.
    func testArrangingTwiceChangesNothing() {
        let order = ["codex", "claude"]
        let once = arrange(["claude", "cursor", "codex"], by: order)
        XCTAssertEqual(arrange(once, by: order), once)
    }

    /// Settings can only show what was discovered at launch, so writing its list
    /// verbatim would forget where an absent profile sat.
    func testAProfileNotOnThisMacKeepsItsPlace() {
        XCTAssertEqual(
            ProviderOrder.remember(["cursor", "claude"], keeping: ["claude", "cursor", "claude-work"]),
            ["cursor", "claude", "claude-work"]
        )
    }

    func testRememberDoesNotDuplicateAnIDItAlreadyHas() {
        XCTAssertEqual(ProviderOrder.remember(["claude", "cursor"], keeping: ["claude"]),
                       ["claude", "cursor"])
    }

    // MARK: - Coming back on

    private func on(_ ids: String...) -> (String) -> Bool {
        { ids.contains($0) }
    }

    /// The rule: after the ones already connected, not back where it used to
    /// sit. `glm` was first, and does not get to be first again.
    func testAReconnectedProviderJoinsTheEndOfTheConnectedOnes() {
        XCTAssertEqual(
            ProviderOrder.joiningConnected("glm",
                                           in: ["glm", "claude", "codex", "gemini"],
                                           isConnected: on("claude", "codex")),
            ["claude", "codex", "glm", "gemini"]
        )
    }

    /// "The end of the connected ones" with none connected is the top, not the
    /// bottom — the first thing switched on has nothing to queue behind.
    func testTheFirstProviderSwitchedOnGoesToTheTop() {
        XCTAssertEqual(
            ProviderOrder.joiningConnected("codex",
                                           in: ["claude", "codex", "cursor"],
                                           isConnected: on()),
            ["codex", "claude", "cursor"]
        )
    }

    /// It joins the connected block, not the switched-off one it was sitting
    /// in — even when that means moving up past other switched-off rows.
    func testItDoesNotSettleAmongTheOtherSwitchedOffOnes() {
        XCTAssertEqual(
            ProviderOrder.joiningConnected("opencode",
                                           in: ["claude", "glm", "gemini", "opencode"],
                                           isConnected: on("claude")),
            ["claude", "opencode", "glm", "gemini"]
        )
    }

    /// Arriving must not reshuffle the arrangement it is arriving into.
    func testTheConnectedOrderIsUndisturbed() {
        let after = ProviderOrder.joiningConnected("glm",
                                                   in: ["glm", "codex", "claude", "cursor"],
                                                   isConnected: on("codex", "claude", "cursor"))

        XCTAssertEqual(after.filter { $0 != "glm" }, ["codex", "claude", "cursor"])
        XCTAssertEqual(after.last, "glm")
    }

    // MARK: - Auto-order by remaining usage

    private func cell(_ id: String, session: Double?, weekly: Double? = nil,
                      weeklyHeadline: Bool = false) -> ProviderSnapshot {
        var windows: [LimitWindow] = []
        if let session {
            windows.append(LimitWindow(id: "session", label: "Session", usedFraction: session))
        }
        if let weekly {
            windows.append(LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: weekly))
        }
        // The swapped shape is what WeeklyHeadline.apply leaves: the ids
        // exchange, so the other window is found beside the lead either way.
        return ProviderSnapshot(id: id, displayName: id, glyph: .claude,
                                fidelity: .official, status: .ok, windows: windows,
                                headlineID: weeklyHeadline ? "weekly_all" : "session",
                                weeklyID: weeklyHeadline ? "session" : "weekly_all")
    }

    private func ordered(_ snapshots: [ProviderSnapshot]) -> [String] {
        ProviderOrder.byRemainingUsage(snapshots).map(\.id)
    }

    func testUsableCellsSortByHeadlineRemaining() {
        XCTAssertEqual(ordered([cell("a", session: 0.7), cell("b", session: 0.2), cell("c", session: 0.5)]),
                       ["b", "c", "a"])
    }

    func testWeeklyHeadlineCellsSortByWeeklyRemaining() {
        // The lead is whatever the derivations left leading: with the week
        // first, "more weekly up" is the same rule.
        XCTAssertEqual(ordered([cell("a", session: 0.1, weekly: 0.8, weeklyHeadline: true),
                                cell("b", session: 0.9, weekly: 0.2, weeklyHeadline: true)]),
                       ["b", "a"])
    }

    func testShutWithRoomSinksBelowUsableButAboveEmpty() {
        let usable = cell("usable", session: 0.9, weekly: 0.9)
        let shut = cell("shut", session: 0.0, weekly: 1.0)
        let empty = cell("empty", session: 1.0, weekly: 0.0)
        XCTAssertEqual(ordered([shut, empty, usable]), ["usable", "shut", "empty"])
    }

    func testSessionShutSinksWeeklyHeadlineBelowUsable() {
        // The mirror case: the weekly number is high but the 5-hour is
        // empty, so the account cannot be used right now.
        let usable = cell("usable", session: 0.9, weekly: 0.9, weeklyHeadline: true)
        let shut = cell("shut", session: 1.0, weekly: 0.1, weeklyHeadline: true)
        XCTAssertEqual(ordered([shut, usable]), ["usable", "shut"])
    }

    func testFullyEmptySortsByHowDeep() {
        // Both at or past the limit; the deficit sinks furthest.
        XCTAssertEqual(ordered([cell("over", session: 1.5), cell("spent", session: 1.0)]),
                       ["spent", "over"])
    }

    func testUnmeasurableCellsSinkToTheEndInManualOrder() {
        // No reading yet, or a runtime with no quota: nothing to rank by,
        // so they trail in the arrangement dragging made.
        let unknown = ProviderSnapshot(id: "unknown", displayName: "u", glyph: .claude,
                                       fidelity: .official, status: .ok, windows: [],
                                       headlineID: "session")
        let runtime = ProviderSnapshot(id: "runtime", displayName: "r", glyph: .ollama,
                                       fidelity: .official, status: .ok, windows: [],
                                       headlineID: "session")
        XCTAssertEqual(ordered([unknown, cell("spent", session: 1.0), runtime]),
                       ["spent", "unknown", "runtime"])
    }

    func testTiesKeepManualOrder() {
        XCTAssertEqual(ordered([cell("a", session: 0.5), cell("b", session: 0.5)]),
                       ["a", "b"])
    }

    // MARK: - Auto-order by burn deficit

    private let deficitNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 86400

    /// A cell with a clock: used fraction of a weekly window with `hoursLeft`
    /// of the week remaining. The burn deficit is remaining minus time left.
    private func timedCell(_ id: String, used: Double, hoursLeft: Double,
                           headlineID: String = "weekly_all") -> ProviderSnapshot {
        let window = LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: used,
                                 resetsAt: deficitNow.addingTimeInterval(hoursLeft * 3600),
                                 duration: week)
        return ProviderSnapshot(id: id, displayName: id, glyph: .claude,
                                fidelity: .official, status: .ok, windows: [window],
                                headlineID: headlineID, weeklyID: "weekly_all")
    }

    private func deficitOrdered(_ snapshots: [ProviderSnapshot]) -> [String] {
        ProviderOrder.byBurnDeficit(snapshots, now: deficitNow).map(\.id)
    }

    /// A cell with both clocks running: a 5-hour session beside a week, led
    /// by whichever window `weeklyHeadline` names — the shape
    /// `WeeklyHeadline` leaves when the weekly limit is the main ring, and
    /// its mirror when the main ring stays the session.
    private func dualCell(_ id: String, sessionUsed: Double, sessionHoursLeft: Double,
                          weeklyUsed: Double, weeklyHoursLeft: Double,
                          weeklyHeadline: Bool) -> ProviderSnapshot {
        let session = LimitWindow(id: "session", label: "Session", usedFraction: sessionUsed,
                                  resetsAt: deficitNow.addingTimeInterval(sessionHoursLeft * 3600),
                                  duration: 5 * 3600)
        let weekly = LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: weeklyUsed,
                                 resetsAt: deficitNow.addingTimeInterval(weeklyHoursLeft * 3600),
                                 duration: week)
        return ProviderSnapshot(id: id, displayName: id, glyph: .claude,
                                fidelity: .official, status: .ok,
                                windows: [session, weekly],
                                headlineID: weeklyHeadline ? "weekly_all" : "session",
                                weeklyID: weeklyHeadline ? "session" : "weekly_all")
    }

    /// The case this exists for: 70% left expiring in 23h (~56 to burn)
    /// outranks 100% left with 6 days (~14 to burn), where most-remaining
    /// would put the fresh 100% first and let the expiring 70% die.
    func testExpiringQuotaOutranksFreshQuota() {
        let expiring = timedCell("expiring", used: 0.3, hoursLeft: 23)
        let fresh = timedCell("fresh", used: 0.0, hoursLeft: 6 * 24)
        XCTAssertEqual(deficitOrdered([fresh, expiring]), ["expiring", "fresh"])
        // Most-remaining disagrees: pin the difference the toggle exists for.
        XCTAssertEqual(ordered([fresh, expiring]), ["fresh", "expiring"])
    }

    func testMostToBurnFirst() {
        let high = timedCell("high", used: 0.2, hoursLeft: 12)
        let low = timedCell("low", used: 0.2, hoursLeft: 5 * 24)
        XCTAssertEqual(deficitOrdered([low, high]), ["high", "low"])
    }

    func testOverPaceSinksBelowToBurn() {
        // Over pace (negative burn, will run out early) has nothing to
        // waste, so it trails behind-pace rings within usable.
        let waste = timedCell("waste", used: 0.3, hoursLeft: 23)
        let over = timedCell("over", used: 0.95, hoursLeft: 5 * 24)
        XCTAssertEqual(deficitOrdered([over, waste]), ["waste", "over"])
    }

    func testTimelessUsableSortsByRemainingBelowTimed() {
        // No clock, no deficit: still usable, but nothing expiring, so it
        // trails timed rings and orders by what is left among itself.
        let timed = timedCell("timed", used: 0.9, hoursLeft: 23)
        let timelessFull = cell("full", session: 0.0)
        let timelessHalf = cell("half", session: 0.5)
        XCTAssertEqual(deficitOrdered([timelessFull, timed, timelessHalf]),
                       ["timed", "full", "half"])
    }

    func testExpiryFollowsAWeeklyHeadlineToTheWeeklyReset() {
        // The weekly limit is the main ring: its reset (23h) is the deadline,
        // not the session's (4.5h), which the ring is not showing. A bench
        // resetting sooner (12h) still beats it.
        let bench = timedCell("bench", used: 0.5, hoursLeft: 12)
        let weeklyLed = dualCell("dual", sessionUsed: 0.9, sessionHoursLeft: 4.5,
                                 weeklyUsed: 0.3, weeklyHoursLeft: 23, weeklyHeadline: true)
        XCTAssertEqual(deficitOrdered([bench, weeklyLed]), ["bench", "dual"])
        // The same readings led by the session: the deadline becomes the
        // session's 4.5h, which is sooner than the bench's 12h.
        let sessionLed = dualCell("dual", sessionUsed: 0.9, sessionHoursLeft: 4.5,
                                  weeklyUsed: 0.3, weeklyHoursLeft: 23, weeklyHeadline: false)
        // sessionLed is over-pace (will run out on its own), so it sinks
        // below the under-pace bench even though its reset is sooner.
        XCTAssertEqual(deficitOrdered([sessionLed, bench]), ["bench", "dual"])
    }

    func testExpiryFollowsASessionHeadlineToTheSessionReset() {
        // The 5-hour window is the main ring: its reset (4.5h) is the
        // deadline, not the week's (6 days). A bench resetting sooner (2h)
        // still beats it.
        let bench = timedCell("bench", used: 0.5, hoursLeft: 24)
        let sessionLed = dualCell("dual", sessionUsed: 0.05, sessionHoursLeft: 4.5,
                                  weeklyUsed: 0.9, weeklyHoursLeft: 6 * 24, weeklyHeadline: false)
        XCTAssertEqual(deficitOrdered([bench, sessionLed]), ["dual", "bench"])
        // Led by the week instead, the deadline becomes the week's 6 days,
        // which is later than the bench's 24h.
        let weeklyLed = dualCell("dual", sessionUsed: 0.1, sessionHoursLeft: 4.5,
                                 weeklyUsed: 0.9, weeklyHoursLeft: 6 * 24, weeklyHeadline: true)
        XCTAssertEqual(deficitOrdered([weeklyLed, bench]), ["bench", "dual"])
    }

    func testDeficitIgnoresATimedWindowThatDoesNotLead() {
        // The leading window has no clock, so there is no deficit to sort
        // by — an urgent week beside it does not invent one, any more than
        // most-remaining reads the weekly figure for a session-led ring.
        let clockless = ProviderSnapshot(
            id: "clockless", displayName: "clockless", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.0),
                      LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 0.3,
                                  resetsAt: deficitNow.addingTimeInterval(23 * 3600), duration: week)],
            headlineID: "session", weeklyID: "weekly_all")
        let timed = timedCell("timed", used: 0.9, hoursLeft: 23)
        XCTAssertEqual(deficitOrdered([clockless, timed]), ["timed", "clockless"])
    }

    func testDeficitTiersMirrorRemainingTiers() {
        let usable = timedCell("usable", used: 0.5, hoursLeft: 23)
        let shut = ProviderSnapshot(
            id: "shut", displayName: "shut", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.0),
                      LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 1.0)],
            headlineID: "session", weeklyID: "weekly_all")
        let empty = timedCell("empty", used: 1.0, hoursLeft: 23)
        let unknown = ProviderSnapshot(id: "unknown", displayName: "u", glyph: .claude,
                                       fidelity: .official, status: .ok, windows: [],
                                       headlineID: "session")
        XCTAssertEqual(deficitOrdered([unknown, empty, shut, usable]),
                       ["usable", "shut", "empty", "unknown"])
    }

    func testDeficitTiesKeepManualOrder() {
        XCTAssertEqual(deficitOrdered([timedCell("a", used: 0.5, hoursLeft: 48),
                                       timedCell("b", used: 0.5, hoursLeft: 48)]),
                       ["a", "b"])
    }

    // MARK: - Auto-order for the menu bar

    /// A five-hour window and a week, with whichever the caller says leading
    /// — the shape the menu bar reads and the notch may read differently.
    private func metered(_ id: String, fiveHour: Double?, weekly: Double? = nil,
                         weeklyHeadline: Bool = false) -> ProviderSnapshot {
        var windows: [LimitWindow] = []
        if let fiveHour {
            windows.append(LimitWindow(id: "session", label: "Session",
                                       usedFraction: fiveHour, duration: 5 * 3600))
        }
        if let weekly {
            windows.append(LimitWindow(id: "weekly_all", label: "Weekly",
                                       usedFraction: weekly, duration: 7 * 86400))
        }
        return ProviderSnapshot(id: id, displayName: id, glyph: .claude,
                                fidelity: .official, status: .ok, windows: windows,
                                headlineID: weeklyHeadline ? "weekly_all" : "session",
                                weeklyID: weeklyHeadline ? "session" : "weekly_all")
    }

    private func barOrdered(_ snapshots: [ProviderSnapshot]) -> [String] {
        ProviderOrder.byRemainingFiveHour(snapshots).map(\.id)
    }

    func testTheBarSortsByWhatIsLeftOfTheFiveHourWindow() {
        XCTAssertEqual(barOrdered([metered("a", fiveHour: 0.7), metered("b", fiveHour: 0.2),
                                   metered("c", fiveHour: 0.5)]),
                       ["b", "c", "a"])
    }

    /// The point of a second rule. With the week leading the notch's ring,
    /// the notch sorts by the week and the bar by the window it is actually
    /// printing — so the bar is never ordered by a figure it does not show.
    func testAWeeklyLeadMovesTheNotchsOrderAndNotTheBars() {
        let rich = metered("rich-week", fiveHour: 0.9, weekly: 0.1, weeklyHeadline: true)
        let poor = metered("poor-week", fiveHour: 0.1, weekly: 0.8, weeklyHeadline: true)
        XCTAssertEqual(ordered([poor, rich]), ["rich-week", "poor-week"], "the notch reads the week")
        XCTAssertEqual(barOrdered([rich, poor]), ["poor-week", "rich-week"], "the bar reads its own window")
    }

    /// The tiers are the notch's, read off the other window: a five-hour
    /// window with room that the week has shut still sinks below what can
    /// actually be spent, and stays above what is spent outright.
    func testTheBarKeepsTheSameTiers() {
        let usable = metered("usable", fiveHour: 0.9, weekly: 0.9)
        let shut = metered("shut", fiveHour: 0.0, weekly: 1.0)
        let empty = metered("empty", fiveHour: 1.0, weekly: 0.0)
        XCTAssertEqual(barOrdered([shut, empty, usable]), ["usable", "shut", "empty"])
    }

    /// An account the bar cannot measure trails in the manual order, as it
    /// does in the notch.
    func testAnAccountWithNoFiveHourWindowTrailsInManualOrder() {
        let weeklyOnly = ProviderSnapshot(id: "weekly-only", displayName: "w", glyph: .claude,
                                          fidelity: .official, status: .ok,
                                          windows: [LimitWindow(id: "weekly_all", label: "Weekly",
                                                                usedFraction: 0.1, duration: 7 * 86400)],
                                          headlineID: "weekly_all")
        XCTAssertEqual(barOrdered([weeklyOnly, metered("spent", fiveHour: 1.0)]),
                       ["spent", "weekly-only"])
    }

    func testTheBarsTiesKeepManualOrder() {
        XCTAssertEqual(barOrdered([metered("a", fiveHour: 0.5), metered("b", fiveHour: 0.5)]),
                       ["a", "b"])
    }
}
