import XCTest
import AppKit
@testable import Codenotch

/// What the menu bar item says in place of its icon: each five-hour window as
/// its provider's mark, the share spent, and the time until it resets.
@MainActor
final class StatusItemSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)
    private let hour: TimeInterval = 3600
    private let minute: TimeInterval = 60

    private func claude(_ used: Double?, resetIn: TimeInterval?, id: String = "claude",
                        status: ProviderStatus = .ok) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: id == "claude" ? "Claude" : "Claude (work)", glyph: .claude,
            fidelity: .official, status: status,
            windows: [
                LimitWindow(id: "session", label: "Current session", usedFraction: used,
                            resetsAt: resetIn.map { now.addingTimeInterval($0) }, duration: 5 * hour),
                LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.31,
                            resetsAt: now.addingTimeInterval(3 * 86400), duration: 7 * 86400),
            ],
            headlineID: "session", weeklyID: "weekly_all")
    }

    private func codex(_ used: Double, resetIn: TimeInterval,
                       length: TimeInterval = 5 * 3600) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "codex", displayName: "Codex", glyph: .openai, fidelity: .official, status: .ok,
            windows: [
                LimitWindow(id: "primary", label: CodexUsage.label(windowSeconds: length, fallback: "primary"),
                            usedFraction: used, resetsAt: now.addingTimeInterval(resetIn), duration: length),
                LimitWindow(id: "secondary", label: "Weekly limit", usedFraction: 0.12,
                            resetsAt: now.addingTimeInterval(4 * 86400), duration: 7 * 86400),
            ],
            headlineID: "primary", weeklyID: "secondary")
    }

    private func other(_ id: String, glyph: ProviderGlyph, length: TimeInterval,
                       kind: ProviderKind = .usage) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: id, glyph: glyph, fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "main", label: "Limit", usedFraction: 0.5,
                                  resetsAt: now.addingTimeInterval(hour), duration: length)],
            headlineID: "main", kind: kind)
    }

    private func waiting(_ id: String, _ name: String, glyph: ProviderGlyph,
                         status: ProviderStatus = .stale(since: .distantPast)) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: name, glyph: glyph, fidelity: .official,
                         status: status, windows: [])
    }

    /// Everything it is given, chosen, unless told otherwise: most of these
    /// tests are about what the bar says, not about who asked for it.
    private func summary(_ snapshots: [ProviderSnapshot],
                         limits: MenuBarLimits? = nil,
                         format: ResetTimeFormat = .automatic,
                         weekly: Bool = false,
                         remaining: Bool = false,
                         hideDepleted: Bool = false,
                         reading: MenuBarReading = .automatic,
                         autoOrder: Bool = false) -> StatusItemSummary {
        StatusItemSummary.make(
            from: snapshots,
            showing: limits ?? MenuBarLimits(isOn: true, chosen: Set(snapshots.map(\.id))),
            now: now, format: format, showingWeeklyLimit: weekly,
            showingRemaining: remaining, hidingDepleted: hideDepleted, reading: reading,
            autoOrdering: autoOrder)
    }

    private func on(_ chosen: Set<String>?) -> MenuBarLimits {
        MenuBarLimits(isOn: true, chosen: chosen)
    }

    /// A defaults domain of this test's own, so a stored choice is read back
    /// from the same place it was written and never from the installed app's.
    private func scratchDefaults() -> UserDefaults {
        let name = "StatusItemSummaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Which providers

    func testClaudeReadsAsItsSessionShareAndCountdown() throws {
        let entry = try XCTUnwrap(summary([claude(0.72, resetIn: 2 * hour + 18 * minute + 20)]).entries.first)
        XCTAssertEqual(entry.glyph, .claude)
        XCTAssertEqual(entry.percent, "72%")
        XCTAssertEqual(entry.countdown, "2h 18m")
        XCTAssertNil(entry.label)
        XCTAssertFalse(entry.isStale)
        XCTAssertEqual(entry.detail, "Claude — Current session: 72% Used · 28% left · 2h 18m")
    }

    func testCodexReadsItsFiveHourPrimaryWindow() throws {
        let entry = try XCTUnwrap(summary([codex(0.41, resetIn: 4 * hour + 5 * minute + 30)]).entries.first)
        XCTAssertEqual(entry.glyph, .openai)
        XCTAssertEqual(entry.percent, "41%")
        XCTAssertEqual(entry.countdown, "4h 05m")
    }

    /// Both, in the order the store keeps — which is the user's order, the
    /// same the notch draws its rings in.
    func testSeveralProvidersKeepTheStoresOrder() {
        let both = summary([codex(0.41, resetIn: 4 * hour), claude(0.72, resetIn: 2 * hour)])
        XCTAssertEqual(both.entries.map(\.id), ["codex", "claude"])
        XCTAssertFalse(both.isCompact)
    }

    /// The daily pace ring takes Claude's headline; the bar still means the
    /// five-hour session.
    func testTheDailyPaceRingDoesNotTakeTheSessionsPlace() throws {
        let paced = DailyPace.apply(to: claude(0.72, resetIn: 2 * hour), now: now)
        XCTAssertEqual(paced.headlineID, DailyPace.windowID)
        XCTAssertEqual(try XCTUnwrap(summary([paced]).entries.first).percent, "72%")
    }

    /// A monthly figure in the five-hour slot would be a different fact in
    /// the same clothes, and a local model has no quota at all.
    func testOnlyFiveHourWindowsAreSummarised() {
        let result = summary([
            other("cursor", glyph: .cursor, length: 30 * 86400),
            other("glm", glyph: .glm, length: 5 * hour),
            other("ollama-local", glyph: .ollamaLocal, length: 5 * hour, kind: .localRuntime),
        ])
        XCTAssertEqual(result.entries.map(\.id), ["glm"])
        XCTAssertTrue(summary([other("cursor", glyph: .cursor, length: 30 * 86400)]).entries.isEmpty,
                      "with nothing to summarise the item goes back to its icon")
    }

    /// Spark's five hours are Spark's, not the account's: with Codex's own
    /// window missing the bar shows a dash rather than Spark's figure. A
    /// grouped window the provider chose as its headline — an Antigravity
    /// model's — is still read.
    func testAGroupedWindowNeverStandsInForTheAccount() throws {
        var codex = codex(0.41, resetIn: 4 * hour)
        codex.windows = [LimitWindow(id: "spark", group: "Spark", label: "5h limit", usedFraction: 0.9,
                                     resetsAt: now.addingTimeInterval(hour), duration: 5 * hour)]
        XCTAssertTrue(try XCTUnwrap(summary([codex]).entries.first).isBlank)

        let antigravity = ProviderSnapshot(
            id: "gemini", displayName: "Antigravity", glyph: .antigravity, fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "gemini-hourly", group: "Gemini Models", label: "5-hour Limit",
                                  usedFraction: 0.25, resetsAt: now.addingTimeInterval(hour), duration: 5 * hour)],
            headlineID: "gemini-hourly")
        XCTAssertEqual(try XCTUnwrap(summary([antigravity]).entries.first).percent, "25%")
    }

    /// Found by length, with room for a window sent as a start and an end.
    func testTheFiveHourWindowIsFoundByItsLength() {
        func window(_ length: TimeInterval?) -> LimitWindow {
            LimitWindow(id: "w", label: "W", usedFraction: 0.1, duration: length)
        }
        XCTAssertTrue(window(5 * hour).isFiveHour)
        XCTAssertTrue(window(5 * hour - 0.4).isFiveHour)
        XCTAssertFalse(window(4 * hour).isFiveHour)
        XCTAssertFalse(window(7 * 86400).isFiveHour)
        XCTAssertFalse(window(nil).isFiveHour)
    }

    /// Claude and Codex keep their place before the first reading and while
    /// signed out — with a dash, never a figure nobody measured.
    func testClaudeAndCodexShowADashWhileThereIsNoReading() {
        let result = summary([
            waiting("claude", "Claude", glyph: .claude, status: .needsAuth),
            waiting("codex", "Codex", glyph: .openai),
            waiting("cursor", "Cursor", glyph: .cursor),
        ])
        XCTAssertEqual(result.entries.map(\.id), ["claude", "codex"])
        for entry in result.entries {
            XCTAssertEqual(entry.percent, "—")
            XCTAssertEqual(entry.countdown, "—")
            XCTAssertTrue(entry.isBlank)
            XCTAssertFalse(entry.isStale, "a dash is not a reading to dim")
        }
        XCTAssertEqual(result.entries[0].detail, "Claude — Sign in to Claude Code to read your usage")
        XCTAssertEqual(result.entries[1].detail, "Codex — Waiting for the first reading…")
        XCTAssertNil(result.nextChange)
    }

    /// A free Codex plan meters thirty days, not five hours: the bar has no
    /// figure for it, and the tooltip says what the account does meter.
    func testAnAccountWithoutAFiveHourWindowSaysWhatItMetersInstead() throws {
        let entry = try XCTUnwrap(summary([codex(0.12, resetIn: 20 * 86400, length: 30 * 86400)]).entries.first)
        XCTAssertTrue(entry.isBlank)
        XCTAssertTrue(entry.detail.hasPrefix("Codex — Monthly limit: 12% Used"), entry.detail)
    }

    /// That sentence is the notch's, so it is worded the way Settings asks for
    /// — the item used to word it "remaining" whatever the preference said.
    func testTheMeteredSentenceFollowsTheChosenResetWording() throws {
        let account = codex(0.12, resetIn: 20 * 86400, length: 30 * 86400)
        let automatic = try XCTUnwrap(summary([account], format: .automatic).entries.first)
        let remaining = try XCTUnwrap(summary([account], format: .remaining).entries.first)
        XCTAssertNotEqual(automatic.detail, remaining.detail)
        XCTAssertEqual(remaining.detail,
                       StatusItemSummary.make(from: [account],
                                              showing: on(nil), now: now,
                                              format: .remaining).entries.first?.detail)
    }

    /// And so do the menu's own rows. They are built by a static function that
    /// cannot read the controller's copy of the setting, so the setting has to
    /// be handed to it — and was not: the menu said "Resets Tue 17:25" under a
    /// card and a tooltip that both said "Resets in 4h 52m".
    func testTheMenusRowsFollowTheChosenResetWording() throws {
        let account = claude(0.53, resetIn: 4 * hour + 52 * minute)

        let automatic = StatusItemController.detailLines(for: account, now: now, format: .automatic)
        let remaining = StatusItemController.detailLines(for: account, now: now, format: .remaining)

        let session = try XCTUnwrap(remaining.first)
        XCTAssertTrue(session.contains("Resets in 4h 52m"), session)
        XCTAssertNotEqual(automatic, remaining)
        // The tooltip beside it is built from the same choice, so the two agree.
        let detail = try XCTUnwrap(summary([account], format: .remaining).entries.first?.detail)
        XCTAssertTrue(detail.contains("4h 52m"), detail)
    }

    // MARK: - What Settings chose

    /// Off is the icon every earlier version drew, whatever the readings say,
    /// and nothing is left counting down to wake the item.
    func testWithLimitsOffTheItemIsTheIcon() {
        let result = summary([claude(0.72, resetIn: 2 * hour), codex(0.41, resetIn: 4 * hour)], limits: .off)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertNil(result.nextChange)
    }

    func testOnlyTheChosenProvidersAreShown() {
        let readings = [claude(0.72, resetIn: 2 * hour), codex(0.41, resetIn: 4 * hour)]
        XCTAssertEqual(summary(readings, limits: on(["claude"])).entries.map(\.id), ["claude"])
        XCTAssertEqual(summary(readings, limits: on(["codex"])).entries.map(\.id), ["codex"])
        XCTAssertEqual(summary(readings, limits: on(["claude", "codex"])).entries.map(\.id), ["claude", "codex"])
    }

    /// Choosing never reorders: the bar keeps the notch's order, which is the
    /// one the user dragged the rings into.
    func testTheChosenKeepTheNotchsOrder() {
        let readings = [codex(0.41, resetIn: 4 * hour), claude(0.72, resetIn: 2 * hour)]
        XCTAssertEqual(summary(readings, limits: on(["claude", "codex"])).entries.map(\.id), ["codex", "claude"])
    }

    /// None chosen is a choice. It gives the icon back rather than an empty,
    /// invisible item — and never a provider picked on the user's behalf.
    func testChoosingNoneGivesTheIconBack() {
        let result = summary([claude(0.72, resetIn: 2 * hour), codex(0.41, resetIn: 4 * hour)], limits: on([]))
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertNil(result.nextChange)
    }

    /// Switched off keeps the choice, so on again brings back exactly that.
    func testSwitchingOffAndOnKeepsTheChoice() {
        let readings = [claude(0.72, resetIn: 2 * hour), codex(0.41, resetIn: 4 * hour)]
        var limits = MenuBarLimits(isOn: false, chosen: ["codex"])
        XCTAssertTrue(summary(readings, limits: limits).entries.isEmpty)
        limits.isOn = true
        XCTAssertEqual(summary(readings, limits: limits).entries.map(\.id), ["codex"])
    }

    /// Before anyone chooses, the bar is for Claude and Codex, whose headline
    /// is the five-hour window. Another provider with such a window waits to
    /// be chosen rather than turning up by itself.
    func testNeverChosenMeansClaudeAndCodex() {
        let readings = [claude(0.72, resetIn: 2 * hour), other("glm", glyph: .glm, length: 5 * hour),
                        codex(0.41, resetIn: 4 * hour)]
        XCTAssertEqual(summary(readings, limits: on(nil)).entries.map(\.id), ["claude", "codex"])
        XCTAssertEqual(summary(readings, limits: on(["glm"])).entries.map(\.id), ["glm"])
    }

    /// The bar draws only what it is handed, and the store hands it only what
    /// is being read: a chosen provider that is switched off shows nothing,
    /// and choosing it starts no reading.
    func testAChosenProviderThatIsNotReadIsNotShown() {
        XCTAssertTrue(summary([codex(0.41, resetIn: 4 * hour)], limits: on(["claude"])).entries.isEmpty)
    }

    /// Chosen but without a figure yet is the same dash as ever — never a 0%
    /// nobody measured.
    func testAChosenProviderWithoutAReadingShowsADashNotZero() throws {
        let entry = try XCTUnwrap(summary([waiting("claude", "Claude", glyph: .claude)],
                                          limits: on(["claude"])).entries.first)
        XCTAssertTrue(entry.isBlank)
        XCTAssertEqual(entry.percent, "—")
        XCTAssertEqual(entry.countdown, "—")
    }

    /// The room in the bar goes to the chosen alone: leaving providers out
    /// makes way for the ones that are in.
    func testTheBarsRoomGoesToTheChosen() {
        let many = [claude(0.72, resetIn: hour), codex(0.41, resetIn: hour),
                    other("glm", glyph: .glm, length: 5 * hour), other("kimi", glyph: .kimi, length: 5 * hour),
                    other("opencode", glyph: .opencode, length: 5 * hour)]
        XCTAssertEqual(summary(many, limits: on(["codex", "kimi", "opencode"])).entries.map(\.id),
                       ["codex", "kimi", "opencode"])
        let two = summary(many, limits: on(["kimi", "opencode"]))
        XCTAssertEqual(two.entries.map(\.id), ["kimi", "opencode"])
        XCTAssertFalse(two.isCompact, "two chosen keep their countdowns")
    }

    /// What Settings may offer: exactly what the bar can draw.
    func testWhatTheBarCanSummarise() {
        XCTAssertTrue(StatusItemSummary.canSummarise(claude(0.72, resetIn: hour)))
        XCTAssertTrue(StatusItemSummary.canSummarise(waiting("codex", "Codex", glyph: .openai)),
                      "Codex before its first reading")
        XCTAssertTrue(StatusItemSummary.canSummarise(other("glm", glyph: .glm, length: 5 * hour)))
        XCTAssertFalse(StatusItemSummary.canSummarise(other("cursor", glyph: .cursor, length: 30 * 86400)),
                       "a monthly limit has no five-hour figure to show")
        XCTAssertFalse(StatusItemSummary.canSummarise(waiting("cursor", "Cursor", glyph: .cursor)))
        XCTAssertFalse(StatusItemSummary.canSummarise(
            other("ollama-local", glyph: .ollamaLocal, length: 5 * hour, kind: .localRuntime)))
    }

    // MARK: - What each figure says

    func testPercentagesAreWholeAndNeverRoundToAFigureThatDidNotHappen() {
        let cases: [(Double, String)] = [
            (0, "0"), (0.003, "<1"), (0.07, "7"), (0.42, "42"), (0.72, "72"),
            (0.996, "99"), (1.0, "100"), (1.04, "104"), (-0.01, "0"),
        ]
        for (fraction, expected) in cases {
            XCTAssertEqual(Percent.whole(for: fraction), expected, "\(fraction)")
        }
    }

    func testASpentWindowReadsAsTheLimit() throws {
        XCTAssertEqual(try XCTUnwrap(summary([claude(1.0, resetIn: hour)]).entries.first).percent, "100%")
        XCTAssertEqual(try XCTUnwrap(summary([claude(1.04, resetIn: hour)]).entries.first).percent, "104%")
    }

    func testAnUnknownResetLeavesADashWhereTheCountdownWouldBe() throws {
        let result = summary([claude(0.72, resetIn: nil)])
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.percent, "72%")
        XCTAssertEqual(entry.countdown, "—")
        XCTAssertNil(result.nextChange, "nothing is counting down, so nothing needs to wake")
    }

    /// Past the reset the old share belongs to a window that is over. The
    /// store re-reads on its next tick; until then there is no figure.
    func testAPassedResetShowsNoFigureUntilTheNextReading() throws {
        let result = summary([claude(0.93, resetIn: -20)])
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.percent, "—")
        XCTAssertEqual(entry.countdown, "—")
        XCTAssertEqual(entry.detail, "Claude — Current session: Resetting…")
        XCTAssertNil(result.nextChange)
    }

    func testTheCountdownRunsDownThroughTheLastMinuteInSeconds() throws {
        XCTAssertEqual(try XCTUnwrap(summary([claude(0.66, resetIn: 47 * minute + 50)]).entries.first).countdown, "47m")
        XCTAssertEqual(try XCTUnwrap(summary([claude(0.93, resetIn: 42)]).entries.first).countdown, "42s")
    }

    /// The last minute ticks every second, and a figure that changed width as
    /// it fell would push every status item to its left along with it, once a
    /// second. The item is as wide as what it says — see `StatusItemArtwork.size`
    /// — so it may step once as "1m" becomes "59s", as it does whenever a
    /// figure changes shape; through the seconds themselves it holds still.
    func testTheItemHoldsOneWidthThroughTheLastMinute() throws {
        let widths = [59, 42, 10, 9, 1].map { seconds in
            StatusItemArtwork(summary: summary([claude(0.5, resetIn: TimeInterval(seconds))])).size.width
        }
        XCTAssertEqual(Set(widths).count, 1,
                       "the item changes width as the last minute counts down: \(widths)")
    }

    /// A remembered reading is dimmed, as the notch dims its ring, and says
    /// how old it is.
    func testARememberedReadingIsDimmedAndAged() throws {
        let stale = claude(0.72, resetIn: 2 * hour, status: .stale(since: now.addingTimeInterval(-40 * minute)))
        let entry = try XCTUnwrap(summary([stale]).entries.first)
        XCTAssertTrue(entry.isStale)
        XCTAssertEqual(entry.percent, "72%")
        XCTAssertTrue(entry.detail.hasSuffix("· 40 min ago"), entry.detail)
    }

    /// The minute the item next needs redrawing: the earliest of its countdowns.
    func testTheNextChangeIsTheEarliestCountdownMinute() {
        let result = summary([claude(0.72, resetIn: 2 * hour + 18 * minute + 20),
                              codex(0.41, resetIn: 4 * hour + 5 * minute + 30)])
        XCTAssertEqual(result.nextChange, now.addingTimeInterval(20))
    }

    /// A wake-up scheduled a minute out may be a second late; the whole point of
    /// one scheduled a second out is that it is not. A second of slack there let
    /// the timer wake having already skipped the figure it woke up to show.
    @MainActor
    func testTheWakeUpTakesLessSlackWhenItIsCountingSeconds() {
        XCTAssertEqual(StatusItemController.tolerance(untilChange: 60), 1)
        XCTAssertEqual(StatusItemController.tolerance(untilChange: 20), 1)
        XCTAssertLessThan(StatusItemController.tolerance(untilChange: 1), 1)
        XCTAssertLessThan(StatusItemController.tolerance(untilChange: 0.2), 1)
    }

    // MARK: - Weekly ring

    func testWeeklyRingUsesTheProvidersDeclaredConsumedFraction() throws {
        let off = try XCTUnwrap(summary([claude(0.32, resetIn: hour)]).entries.first)
        let on = try XCTUnwrap(summary([claude(0.32, resetIn: hour)], weekly: true).entries.first)
        XCTAssertNil(off.weeklyFraction, "the new presentation is opt-in")
        XCTAssertEqual(on.weeklyFraction, 0.31)
        // The window's own label, which for Claude's second window is the one
        // the provider declared. The line used to say "Weekly Limit" whatever
        // the window was, which misnamed this one and would misname a monthly
        // allowance too.
        XCTAssertTrue(on.detail.contains("All models: 31% Used · 69% left"), on.detail)
        XCTAssertEqual(on.percent, "32%", "weekly usage never replaces the existing session share")
    }

    /// A provider whose second window is not a week still gets its own name for
    /// it: the label comes from the window, not from a string baked into the
    /// menu bar.
    func testTheWeeklyLineNamesWhateverWindowTheProviderDeclared() throws {
        var snapshot = claude(0.32, resetIn: hour)
        snapshot.windows[1] = LimitWindow(id: "weekly_all", label: "Monthly limit",
                                          usedFraction: 0.31, duration: 30 * 86400)
        let entry = try XCTUnwrap(summary([snapshot], weekly: true).entries.first)
        XCTAssertTrue(entry.detail.contains("Monthly limit: 31% Used · 69% left"), entry.detail)
        XCTAssertFalse(entry.detail.contains("Weekly"), entry.detail)
    }

    func testWeeklyRingOmitsUnavailableInvalidAndExpiredReadings() throws {
        XCTAssertNil(try XCTUnwrap(summary([
            other("glm", glyph: .glm, length: 5 * hour)
        ], weekly: true).entries.first).weeklyFraction)

        var invalid = claude(0.32, resetIn: hour)
        invalid.windows[1] = LimitWindow(id: "weekly_all", label: "All models",
                                         usedFraction: .nan, duration: 7 * 86400)
        XCTAssertNil(try XCTUnwrap(summary([invalid], weekly: true).entries.first).weeklyFraction)

        var expired = claude(0.32, resetIn: hour)
        expired.windows[1] = LimitWindow(id: "weekly_all", label: "All models",
                                         usedFraction: 0.67,
                                         resetsAt: now.addingTimeInterval(-1), duration: 7 * 86400)
        XCTAssertNil(try XCTUnwrap(summary([expired], weekly: true).entries.first).weeklyFraction)
    }

    func testWeeklyRingCoversEmptyLowHalfFullAndOverLimit() throws {
        for (fraction, expected) in [(0.0, 0.0), (0.03, 0.03), (0.5, 0.5),
                                     (1.0, 1.0), (1.08, 1.08)] {
            var snapshot = claude(0.32, resetIn: hour)
            snapshot.windows[1] = LimitWindow(id: "weekly_all", label: "All models",
                                               usedFraction: fraction, duration: 7 * 86400)
            XCTAssertEqual(try XCTUnwrap(summary([snapshot], weekly: true).entries.first).weeklyFraction,
                           expected, "\(fraction)")
        }
    }

    /// Antigravity may choose its weekly allowance as the notch headline. The
    /// status item still leads with its independent five-hour reading, so the
    /// declared weekly allowance remains useful rather than becoming a duplicate.
    func testWeeklyRingStillWorksWhenTheNotchHeadlineIsWeekly() throws {
        let snapshot = ProviderSnapshot(
            id: "antigravity", displayName: "Antigravity", glyph: .antigravity,
            fidelity: .official, status: .ok,
            windows: [
                LimitWindow(id: "five", label: "5-hour Limit", usedFraction: 0.21,
                            resetsAt: now.addingTimeInterval(hour), duration: 5 * hour),
                LimitWindow(id: "week", label: "Weekly Limit", usedFraction: 0.67,
                            resetsAt: now.addingTimeInterval(3 * 86400), duration: 7 * 86400),
            ],
            headlineID: "week", weeklyID: "week")
        XCTAssertNil(snapshot.weeklyWindow, "the notch still avoids drawing the same ring twice")
        XCTAssertEqual(snapshot.weeklyLimitWindow?.usedFraction, 0.67)
        let entry = try XCTUnwrap(summary([snapshot], weekly: true).entries.first)
        XCTAssertEqual(entry.percent, "21%")
        XCTAssertEqual(entry.weeklyFraction, 0.67)
    }

    func testEachProviderKeepsItsOwnWeeklyReading() {
        var first = claude(0.32, resetIn: hour)
        first.windows[1] = LimitWindow(id: "weekly_all", label: "All models",
                                       usedFraction: 0.67, duration: 7 * 86400)
        var second = codex(0.14, resetIn: 2 * hour)
        second.windows[1] = LimitWindow(id: "secondary", label: "Weekly limit",
                                        usedFraction: 0.28, duration: 7 * 86400)
        let entries = summary([first, second], weekly: true).entries
        XCTAssertEqual(entries.map(\.weeklyFraction), [0.67, 0.28])
    }

    // MARK: - Reading what is left

    /// One account must not read two ways in one app: the notch, the cards in
    /// the menu and now the item's own face all answer from the same end.
    func testTheFaceReadsWhatIsLeftWhenTheAppIsSetThatWay() throws {
        let spent = try XCTUnwrap(summary([claude(0.72, resetIn: 2 * hour + 18 * minute + 20)]).entries.first)
        let left = try XCTUnwrap(summary([claude(0.72, resetIn: 2 * hour + 18 * minute + 20)],
                                         remaining: true).entries.first)
        XCTAssertEqual(spent.percent, "72%")
        XCTAssertEqual(left.percent, "28%")
        // Only the figure flips. The countdown is a time, not a share of one.
        XCTAssertEqual(left.countdown, spent.countdown)
    }

    /// The tooltip carries both ends either way — it is the detailed view —
    /// and leads with the one the bar above it is showing.
    func testTheTooltipLeadsWithTheEndTheBarIsShowing() throws {
        let left = try XCTUnwrap(summary([claude(0.72, resetIn: 2 * hour)], remaining: true).entries.first)
        XCTAssertEqual(left.detail, "Claude — Current session: 28% left · 72% Used · 2h 00m")
    }

    /// Derived from the rounded used half, the rule `Percent.halves` follows,
    /// so the figure on the bar and the one in the tooltip under it always add
    /// up to a hundred.
    func testTheFigureAndItsTooltipAlwaysAddUp() throws {
        for used in [0.0, 0.004, 0.095, 0.5, 0.994, 1.0, 1.2] {
            let entry = try XCTUnwrap(summary([claude(used, resetIn: hour)], remaining: true).entries.first)
            let halves = Percent.halves(for: used)
            XCTAssertTrue(entry.detail.contains("\(halves.left)% left · \(halves.used)% Used"),
                          "\(used): \(entry.detail)")
        }
    }

    /// The two figures `Percent.whole` protects, answered from the other end:
    /// a window barely touched is not a full hundred left, and one nearly
    /// spent still has something left rather than none.
    func testTheRemainingFigureNeverRoundsToAFullHundredOrToNothing() throws {
        let barelyTouched = try XCTUnwrap(summary([claude(0.003, resetIn: hour)], remaining: true).entries.first)
        XCTAssertEqual(barelyTouched.percent, ">99%")
        let nearlySpent = try XCTUnwrap(summary([claude(0.994, resetIn: hour)], remaining: true).entries.first)
        XCTAssertEqual(nearlySpent.percent, "<1%")
        let overspent = try XCTUnwrap(summary([claude(1.2, resetIn: hour)], remaining: true).entries.first)
        XCTAssertEqual(overspent.percent, "0%", "an overspent window has nothing left, not less than nothing")
    }

    /// The ring sweeps from the end the figure beside it is read from, as the
    /// notch's own rings do.
    func testTheWeeklyRingSweepsFromTheSameEndAsTheFigure() throws {
        let spent = try XCTUnwrap(summary([claude(0.32, resetIn: hour)], weekly: true).entries.first)
        let left = try XCTUnwrap(summary([claude(0.32, resetIn: hour)], weekly: true,
                                         remaining: true).entries.first)
        XCTAssertEqual(spent.weeklyFraction, 0.31)
        XCTAssertEqual(try XCTUnwrap(left.weeklyFraction), 0.69, accuracy: 0.0001)
        XCTAssertTrue(left.detail.contains("All models: 69% left · 31% Used"), left.detail)
    }

    /// A provider with no five-hour reading is a dash whichever end the bar
    /// reads from: there is no figure to turn around.
    func testADashStaysADashWhenReadingWhatIsLeft() throws {
        let entry = try XCTUnwrap(summary([claude(nil, resetIn: nil)], remaining: true).entries.first)
        XCTAssertEqual(entry.percent, "—")
        XCTAssertTrue(entry.isBlank)
    }

    // MARK: - Accounts with nothing left to spend

    /// The same switch that takes an empty account's ring out of the notch.
    func testAnEmptyAccountLeavesTheFaceWhenTheAppHidesDepletedOnes() {
        let full = claude(1.0, resetIn: hour)
        let codex = codex(0.41, resetIn: 2 * hour)
        XCTAssertEqual(summary([full, codex]).entries.map(\.id), ["claude", "codex"])
        XCTAssertEqual(summary([full, codex], hideDepleted: true).entries.map(\.id), ["codex"])
    }

    /// A spent week empties the account as surely as a spent session does,
    /// which is the rule `ProviderSnapshot.isDepleted` already applies in the
    /// notch.
    func testASpentWeekEmptiesTheAccountToo() {
        var spentWeek = claude(0.12, resetIn: hour)
        spentWeek.windows[1] = LimitWindow(id: "weekly_all", label: "All models",
                                           usedFraction: 1.0, duration: 7 * 86400)
        XCTAssertEqual(summary([spentWeek], hideDepleted: true).entries.count, 0)
    }

    /// Stale readings stay: an old number is not proof the account is empty.
    func testAStaleFullReadingIsNotProofTheAccountIsEmpty() {
        let stale = claude(1.0, resetIn: hour, status: .stale(since: .distantPast))
        XCTAssertEqual(summary([stale], hideDepleted: true).entries.map(\.id), ["claude"])
    }

    /// Dropped before the count, so an empty account never takes one of the
    /// four places from an account there is still something to say about.
    func testAnEmptyAccountDoesNotTakeAPlaceInTheBar() {
        let spent = (1...3).map { claude(1.0, resetIn: hour, id: "claude-\($0)") }
        let live = [codex(0.41, resetIn: hour), other("glm", glyph: .glm, length: 5 * hour)]
        XCTAssertEqual(summary(spent + live).entries.map(\.id),
                       ["claude-1", "claude-2", "claude-3", "codex"])
        XCTAssertEqual(summary(spent + live, hideDepleted: true).entries.map(\.id), ["codex", "glm"])
    }

    /// Hiding is the item's face alone. The menu behind it lists every
    /// provider read, because the item is the way into an app that has left
    /// the Dock and an account that cannot be reached is not hidden but lost.
    func testHidingAnEmptyAccountNeverTakesItOutOfTheMenu() {
        let controller = StatusItemController(onOpenSettings: {})
        controller.hidesDepleted = true
        controller.snapshots = [claude(1.0, resetIn: hour), codex(0.41, resetIn: 2 * hour)]
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: now)
        let listed = menu.items.compactMap { $0.representedObject as? String }
        XCTAssertEqual(listed, ["claude", "codex"])
    }

    // MARK: - Working indicator

    /// What the item has always done, and what Reduce Motion has always made
    /// of it, now said out loud so Settings can ask for either outright.
    func testThePulseIsTheDefaultAndReduceMotionStillOverridesIt() {
        XCTAssertEqual(Preferences(defaults: scratchDefaults()).menuBarActivityStyle, .pulse)
        XCTAssertTrue(MenuBarActivityStyle.pulse.animates(reducesMotion: false))
        XCTAssertFalse(MenuBarActivityStyle.pulse.showsStillBadge(reducesMotion: false))
        XCTAssertFalse(MenuBarActivityStyle.pulse.animates(reducesMotion: true))
        XCTAssertTrue(MenuBarActivityStyle.pulse.showsStillBadge(reducesMotion: true))
    }

    /// The still dot is the Reduce Motion treatment, chosen outright: a badge
    /// and no animation, whatever the Mac's own setting says.
    func testTheStillDotNeverAnimatesAndTheBadgeIsAlwaysThere() {
        for reduced in [false, true] {
            XCTAssertFalse(MenuBarActivityStyle.dot.animates(reducesMotion: reduced), "\(reduced)")
            XCTAssertTrue(MenuBarActivityStyle.dot.showsStillBadge(reducesMotion: reduced), "\(reduced)")
        }
    }

    /// Off is off: nothing moves and nothing is drawn.
    func testNoneLeavesTheMarkAlone() {
        for reduced in [false, true] {
            XCTAssertFalse(MenuBarActivityStyle.off.animates(reducesMotion: reduced), "\(reduced)")
            XCTAssertFalse(MenuBarActivityStyle.off.showsStillBadge(reducesMotion: reduced), "\(reduced)")
        }
    }

    func testTheChosenIndicatorSurvivesARestart() {
        let defaults = scratchDefaults()
        Preferences(defaults: defaults).menuBarActivityStyle = .off
        XCTAssertEqual(Preferences(defaults: defaults).menuBarActivityStyle, .off)
    }

    /// A working mark is dimmed and brought back, so the ink in its box moves
    /// between frames; with the indicator off, the same mark is drawn exactly
    /// as it is when nothing is working at all.
    func testTheWorkingDotIsDrawnForTheStillDotAndNotForNone() throws {
        let result = summary([claude(0.72, resetIn: hour)])
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let idle = StatusItemArtwork(summary: result, font: font, height: 22)
        let dotted = StatusItemArtwork(summary: result, font: font, height: 22,
                                       activityBadgeProviderIDs: ["claude"])
        let glyph = try XCTUnwrap(idle.glyphFrame(for: "claude")).insetBy(dx: -3, dy: -3)
        XCTAssertGreaterThan(ink(dotted.image(), in: glyph), ink(idle.image(), in: glyph),
                             "the still dot adds ink to the mark")
        XCTAssertEqual(dotted.size, idle.size, "and never moves the items beside it")
    }

    // MARK: - Room in the bar

    /// Two Claude logins are two identical marks; the second says which it is.
    func testProfilesWithTheSameMarkAreToldApartBySlug() {
        let result = summary([claude(0.72, resetIn: 2 * hour), claude(0.12, resetIn: 4 * hour, id: "claude-work")])
        XCTAssertEqual(result.entries.map(\.label), [nil, "work"])
    }

    /// Past two, the countdowns stay in the tooltip; past four, in the menu.
    func testTheBarGoesCompactPastTwoAndStopsAtFour() {
        let many = [claude(0.72, resetIn: hour), codex(0.41, resetIn: hour),
                    other("glm", glyph: .glm, length: 5 * hour), other("kimi", glyph: .kimi, length: 5 * hour),
                    other("opencode", glyph: .opencode, length: 5 * hour)]
        let result = summary(many)
        XCTAssertEqual(result.entries.map(\.id), ["claude", "codex", "glm", "kimi"])
        XCTAssertTrue(result.isCompact)
        XCTAssertFalse(summary(Array(many.prefix(2))).isCompact)
    }

    // MARK: - Which readings get the room

    /// Off, the bar keeps the order Accounts was dragged into.
    func testTheBarKeepsTheManualOrderUntilAutoOrderIsOn() {
        let snapshots = [claude(0.80, resetIn: hour), codex(0.10, resetIn: hour)]
        XCTAssertEqual(summary(snapshots).entries.map(\.id), ["claude", "codex"])
        XCTAssertEqual(summary(snapshots, autoOrder: true).entries.map(\.id), ["codex", "claude"])
    }

    /// The order is taken before the four places are, so auto-order decides
    /// who is on the bar at all and not merely where.
    func testAutoOrderDecidesWhichFourAreOnTheBar() {
        let crowded = [claude(0.99, resetIn: hour, id: "claude-1"),
                       claude(0.98, resetIn: hour, id: "claude-2"),
                       claude(0.97, resetIn: hour, id: "claude-3"),
                       claude(0.96, resetIn: hour, id: "claude-4"),
                       claude(0.05, resetIn: hour, id: "claude-5")]
        XCTAssertFalse(summary(crowded).entries.map(\.id).contains("claude-5"),
                       "the manual order leaves the emptiest account out")
        XCTAssertEqual(summary(crowded, autoOrder: true).entries.first?.id, "claude-5")
        XCTAssertEqual(summary(crowded, autoOrder: true).entries.count, 4)
    }

    /// And before the countdowns, which only the first readings carry.
    func testAutoOrderDecidesWhoKeepsTheCountdown() throws {
        let three = [claude(0.90, resetIn: hour, id: "claude-1"),
                     claude(0.80, resetIn: 2 * hour, id: "claude-2"),
                     claude(0.10, resetIn: 3 * hour, id: "claude-3")]
        let ordered = summary(three, autoOrder: true)
        XCTAssertEqual(ordered.entries.map(\.id), ["claude-3", "claude-2", "claude-1"])
        XCTAssertTrue(ordered.isCompact, "three readings still drop the countdowns from the face")
        XCTAssertFalse(summary(Array(three.prefix(2)), autoOrder: true).isCompact)
    }

    /// The bar sorts by the window it prints, not by the one leading the
    /// notch's ring — see `ProviderOrderTests` for the rule itself.
    func testTheBarSortsByTheWindowItPrints() {
        var weeklyLed = claude(0.90, resetIn: hour, id: "claude-week")
        weeklyLed.headlineID = "weekly_all"
        weeklyLed.weeklyID = "session"
        let other = claude(0.50, resetIn: hour, id: "claude-plain")
        XCTAssertEqual(summary([weeklyLed, other], autoOrder: true).entries.map(\.id),
                       ["claude-plain", "claude-week"])
    }

    // MARK: - How much of each reading is printed

    /// The rule the item has always followed, which is now one answer of
    /// three rather than the only one there is.
    func testAutomaticIsTheDefaultAndStillCountsToTwo() {
        XCTAssertEqual(Preferences(defaults: scratchDefaults()).menuBarReading, .automatic)
        for count in 1...4 {
            XCTAssertEqual(MenuBarReading.automatic.isCompact(entryCount: count), count > 2, "\(count)")
        }
    }

    /// Share only is the narrow answer: no countdown, however few there are.
    func testShareOnlyDropsTheCountdownEvenFromASingleReading() {
        let one = summary([claude(0.72, resetIn: 2 * hour)], reading: .share)
        XCTAssertTrue(one.isCompact)
        // Dropped from the face, not from the reading: the tooltip still has
        // it, and so does the entry the menu and VoiceOver are built from.
        XCTAssertEqual(try? XCTUnwrap(one.entries.first).countdown, "2h 00m")
        XCTAssertTrue(try XCTUnwrap(one.entries.first?.detail).contains("2h 00m"))
    }

    /// Share and countdown is the wide answer: the countdown stays past the
    /// two the automatic rule would have stopped at.
    func testShareAndCountdownKeepsTheCountdownPastTwo() {
        let four = [claude(0.72, resetIn: hour), codex(0.41, resetIn: hour),
                    other("glm", glyph: .glm, length: 5 * hour), other("kimi", glyph: .kimi, length: 5 * hour)]
        XCTAssertTrue(summary(four).isCompact, "the automatic rule stops at two")
        XCTAssertFalse(summary(four, reading: .full).isCompact)
    }

    /// The ceiling Settings cannot move: a fifth reading only ever lengthens
    /// the item, so it stays in the menu whatever is chosen here.
    func testTheFourReadingCeilingHoldsWhicheverAnswerIsChosen() {
        let five = [claude(0.72, resetIn: hour), codex(0.41, resetIn: hour),
                    other("glm", glyph: .glm, length: 5 * hour), other("kimi", glyph: .kimi, length: 5 * hour),
                    other("opencode", glyph: .opencode, length: 5 * hour)]
        for reading in MenuBarReading.allCases {
            XCTAssertEqual(summary(five, reading: reading).entries.count, 4, "\(reading)")
        }
    }

    /// What the answer actually buys, in the only currency the menu bar deals
    /// in. Two readings: narrow drops both countdowns, wide keeps them, and
    /// automatic sits where it always did.
    func testTheAnswerIsWidthAndTheWidthsAreOrdered() {
        let two = [claude(0.72, resetIn: 2 * hour + 18 * minute), codex(0.41, resetIn: 4 * hour + 5 * minute)]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        func width(_ reading: MenuBarReading, _ snapshots: [ProviderSnapshot]) -> CGFloat {
            StatusItemArtwork(summary: summary(snapshots, reading: reading), font: font, height: 22).size.width
        }
        XCTAssertLessThan(width(.share, two), width(.automatic, two))
        XCTAssertEqual(width(.full, two), width(.automatic, two), "two is where the automatic rule is wide")

        let four = two + [other("glm", glyph: .glm, length: 5 * hour),
                          other("kimi", glyph: .kimi, length: 5 * hour)]
        XCTAssertEqual(width(.share, four), width(.automatic, four), "four is where it is narrow")
        XCTAssertGreaterThan(width(.full, four), width(.automatic, four))
    }

    /// A change of answer is a change of summary, so the item redraws for it
    /// rather than deciding nothing has happened.
    func testChangingTheAnswerIsAChangeTheItemNotices() {
        let two = [claude(0.72, resetIn: hour), codex(0.41, resetIn: hour)]
        XCTAssertNotEqual(summary(two, reading: .automatic), summary(two, reading: .share))
    }

    func testTheChosenReadingSurvivesARestart() {
        let defaults = scratchDefaults()
        Preferences(defaults: defaults).menuBarReading = .share
        XCTAssertEqual(Preferences(defaults: defaults).menuBarReading, .share)
    }

    /// The items to the left of this one shift whenever it changes width, so
    /// it keeps one width through the ordinary run of a window: single-digit
    /// shares, the last hour, the last minute, an unknown reset.
    /// Replaces `testTheItemKeepsOneWidthAsTheFiguresMove`, deliberately and in
    /// the other direction. That test guarded padding each figure to the widest
    /// reading it could take, so the item held one width for a whole window.
    /// The room that buys is empty whenever the figures are shorter, and there
    /// is nowhere inside the item to put it that does not read as a hole. The
    /// item is as wide as what it says instead; how often that moves is
    /// measured in the test below, not assumed.
    func testTheItemFollowsTheFiguresItPrints() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        func width(_ used: Double, _ resetIn: TimeInterval?) -> CGFloat {
            StatusItemArtwork(summary: summary([claude(used, resetIn: resetIn)]), font: font, height: 22).size.width
        }
        // A digit fewer in either figure is a digit narrower in the item.
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        let reference = width(0.72, 2 * hour + 18 * minute)   // "72% · 2h 18m"
        XCTAssertEqual(width(0.07, 2 * hour + 18 * minute),   // "7% · 2h 18m"
                       reference - digit, accuracy: 1)
        XCTAssertEqual(width(1.0, 2 * hour + 18 * minute),    // "100% · 2h 18m"
                       reference + digit, accuracy: 1)
        // The same figure in the same shape is the same width, whatever it
        // reads — monospaced digits are the whole reason the width moves as
        // rarely as it does.
        for used in [0.07, 0.72, 0.99] {
            XCTAssertEqual(width(used, 2 * hour + 18 * minute), width(used, 4 * hour + 5 * minute),
                           "\(used): two countdowns of the same shape")
        }
        XCTAssertLessThan(width(0.72, nil), 150, "one reading should stay compact")
    }

    /// What the menu bar is actually given, rather than what the artwork
    /// measures: the item is its artwork and nothing besides.
    ///
    /// An `NSStatusBarButton` left to size itself pads an image by 7pt a side.
    /// That is what a lone icon wants; either end of a line of figures it is
    /// dead space, and it lands against the next status item's own padding, so
    /// a reading ended a clear 14pt before anything else began.
    func testTheItemIsGivenExactlyItsArtworksWidth() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.show()
        defer { controller.hide() }
        guard let item = controller.item, let button = item.button else {
            throw XCTSkip("no status item on this host")
        }
        // Windows against the wall clock, because setting `snapshots` redraws
        // the button against `Date()`.
        let live = Date()
        func reading(_ id: String, _ glyph: ProviderGlyph, _ used: Double,
                     _ left: TimeInterval) -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: id, glyph: glyph, fidelity: .official,
                             status: .ok,
                             windows: [LimitWindow(id: "session", label: "Current session",
                                                   usedFraction: used,
                                                   resetsAt: live.addingTimeInterval(left),
                                                   duration: 5 * hour)],
                             headlineID: "session")
        }
        func length(_ snapshots: [ProviderSnapshot]) -> (given: CGFloat, drawn: CGFloat) {
            controller.limits = MenuBarLimits(isOn: true, chosen: Set(snapshots.map(\.id)))
            controller.snapshots = snapshots
            return (item.length, button.image?.size.width ?? 0)
        }
        let long = length([reading("claude", .claude, 0.72, 2 * hour + 18 * minute),
                           reading("codex", .openai, 0.41, 4 * hour + 5 * minute)])
        XCTAssertEqual(long.given, long.drawn, "the item is the artwork, with nothing added")
        // And it gives the room back as the reading gets shorter.
        let short = length([reading("claude", .claude, 0.7, 8 * minute)])
        XCTAssertEqual(short.given, short.drawn)
        XCTAssertLessThan(short.given, long.given)
    }

    /// What following the figures actually costs the items beside it, counted
    /// rather than guessed: a five-hour window walked minute by minute, filling
    /// as it goes, and every width the item takes along the way.
    ///
    /// Monospaced digits mean the width can only move when a figure gains or
    /// loses a *character*, not when it changes value. Over 300 minutes the
    /// shapes a window passes through are 2/6 → 3/6 → 2/6 → 3/6 → 3/3 → 3/2
    /// (percent characters over countdown characters): five steps, one an
    /// hour. A second provider on its own schedule brings the pair to eleven,
    /// about one every twenty-seven minutes.
    func testTheItemChangesWidthOnlyAsTheFiguresChangeShape() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        func width(_ snapshots: [ProviderSnapshot]) -> CGFloat {
            StatusItemArtwork(summary: summary(snapshots), font: font, height: 22).size.width
        }
        var alone: [CGFloat] = []
        var paired: [CGFloat] = []
        for minutesLeft in stride(from: 300, through: 1, by: -1) {
            let filling = claude(Double(300 - minutesLeft) / 300,
                                 resetIn: TimeInterval(minutesLeft) * minute)
            // Half a window out of step, the way two providers actually are.
            let other = ((minutesLeft + 150) % 300) + 1
            alone.append(width([filling]))
            paired.append(width([filling, codex(Double(300 - other) / 300,
                                                resetIn: TimeInterval(other) * minute)]))
        }
        func steps(_ widths: [CGFloat]) -> Int { zip(widths, widths.dropFirst()).filter { $0 != $1 }.count }
        XCTAssertEqual(steps(alone), 5, "one provider, across a whole window")
        XCTAssertEqual(steps(paired), 11, "two providers, across a whole window")
    }

    /// A template, as the icon it stands in for is, so macOS tints it for
    /// light, dark and wallpaper-tinted menu bars alike.
    func testTheArtworkIsATemplateTheHeightOfTheBar() {
        let artwork = StatusItemArtwork(summary: summary([claude(0.72, resetIn: hour)]),
                                        font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                                        height: 22)
        let image = artwork.image()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.height, 22)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    private func ink(_ image: NSImage, in rect: NSRect) -> Int {
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(image.size.width * scale),
                                   pixelsHigh: Int(image.size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let point = NSPoint(x: CGFloat(x) / scale,
                                    y: image.size.height - CGFloat(y) / scale)
                if rect.contains(point),
                   (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    count += 1
                }
            }
        }
        return count
    }

    func testReduceMotionUsesAStaticBadgeOnOnlyTheActiveProvider() throws {
        let result = summary([claude(0.72, resetIn: hour), codex(0.41, resetIn: 2 * hour)])
        let plain = StatusItemArtwork(summary: result,
                                      font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                                      height: 22)
        let badged = StatusItemArtwork(summary: result,
                                       font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                                       height: 22,
                                       activityBadgeProviderIDs: ["codex"])
        let claude = try XCTUnwrap(plain.glyphFrame(for: "claude")).insetBy(dx: -2, dy: -2)
        let codex = try XCTUnwrap(plain.glyphFrame(for: "codex")).insetBy(dx: -2, dy: -2)

        XCTAssertEqual(badged.size, plain.size, "activity never moves other menu bar items")
        XCTAssertEqual(ink(badged.image(), in: claude), ink(plain.image(), in: claude),
                       "the idle provider is unchanged")
        XCTAssertNotEqual(ink(badged.image(), in: codex), ink(plain.image(), in: codex),
                          "the active provider carries a still badge")
        XCTAssertTrue(badged.image().isTemplate)
    }

    func testPulseRunsFromFullToSubtleAndBackThroughTheArtworkMask() throws {
        let result = summary([claude(0.72, resetIn: hour), codex(0.41, resetIn: 2 * hour)])
        let artwork = StatusItemArtwork(summary: result,
                                        font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                                        height: 22)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: artwork.size.width + 14, height: 22))
        view.wantsLayer = true
        let glyphs = Dictionary(uniqueKeysWithValues: result.entries.compactMap { entry in
            artwork.glyphFrame(for: entry.id).map { (entry.id, $0) }
        })
        let pulse = StatusItemPulse()
        pulse.update(view: view, imageSize: artwork.size, glyphs: glyphs, working: ["codex"])

        XCTAssertEqual(pulse.pulsing, ["codex"])
        let mask = try XCTUnwrap(view.layer?.mask)
        let marks = (mask.sublayers ?? []).filter { !($0 is CAShapeLayer) }
        let mark = try XCTUnwrap(marks.first)
        let animation = try XCTUnwrap(
            mark.animation(forKey: StatusItemPulse.animationKey) as? CABasicAnimation)
        XCTAssertEqual(animation.keyPath, "opacity")
        XCTAssertEqual(animation.fromValue as? Float, 1)
        XCTAssertEqual(animation.toValue as? Float, StatusItemPulse.dimmest)
        XCTAssertTrue(animation.autoreverses)
        XCTAssertEqual(animation.repeatCount, .infinity)
        XCTAssertEqual(animation.duration * 2, StatusItemPulse.period)
        XCTAssertGreaterThan(animation.beginTime, 0)

        pulse.update(view: view, imageSize: artwork.size, glyphs: glyphs, working: ["codex"])
        let redrawnMask = try XCTUnwrap(view.layer?.mask)
        let redrawnMarks = (redrawnMask.sublayers ?? []).filter { !($0 is CAShapeLayer) }
        let redrawnMark = try XCTUnwrap(redrawnMarks.first)
        let redrawnAnimation = try XCTUnwrap(
            redrawnMark.animation(forKey: StatusItemPulse.animationKey) as? CABasicAnimation)
        XCTAssertTrue(redrawnMask === mask, "routine redraws retain the mask layer")
        XCTAssertEqual(redrawnMarks.count, 1)
        XCTAssertTrue(redrawnMark === mark, "routine redraws retain the provider layer")
        XCTAssertEqual(redrawnAnimation.beginTime, animation.beginTime,
                       "routine redraws preserve the animation phase")

        pulse.clear()
        XCTAssertNil(view.layer?.mask, "Reduce Motion can remove the animation synchronously")
        XCTAssertTrue(pulse.pulsing.isEmpty)
    }

    func testWeeklyRingAddsNoMenuBarWidth() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let snapshot = claude(0.72, resetIn: hour)
        let ordinary = StatusItemArtwork(summary: summary([snapshot]), font: font, height: 22).size.width
        let weekly = StatusItemArtwork(summary: summary([snapshot], weekly: true), font: font, height: 22).size.width
        XCTAssertEqual(weekly, ordinary, "the ring occupies the provider glyph's existing box")

        var full = snapshot
        full.windows[1] = LimitWindow(id: "weekly_all", label: "All models",
                                      usedFraction: 1, duration: 7 * 86400)
        XCTAssertEqual(
            StatusItemArtwork(summary: summary([full], weekly: true), font: font, height: 22).size.width,
            weekly,
            "fill changes in place instead of moving other menu bar items")
    }

    /// "72% · 2h 18m | 41% · 4h 05m": a second reading costs its own width
    /// and a rule between the two, and nothing more.
    func testASecondReadingSitsBesideTheFirstPastARule() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        func width(_ snapshots: [ProviderSnapshot]) -> CGFloat {
            StatusItemArtwork(summary: summary(snapshots), font: font, height: 22).size.width
        }
        let one = width([claude(0.72, resetIn: 2 * hour)])
        let two = width([claude(0.72, resetIn: 2 * hour), codex(0.41, resetIn: 4 * hour)])
        XCTAssertGreaterThan(two, one * 2, "the rule and its gaps sit between the readings")
        XCTAssertLessThan(two, one * 2 + 20, "and take no more room than that")
    }

    /// Opt-in visual QA fixture. The status artwork is drawn at four times its
    /// menu-bar dimensions so a reviewer can inspect its actual vector output.
    func testRenderWeeklyRingContactSheetWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["CODENOTCH_WEEKLY_RENDER"] else { return }
        let levels: [(String, Double)] = [
            ("0%", 0), ("3%", 0.03), ("50%", 0.5), ("87%", 0.87), ("100%", 1),
        ]
        let scale: CGFloat = 4
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13 * scale, weight: .regular)
        let rows: [(String, StatusItemArtwork)] = levels.map { label, fraction in
            var snapshot = claude(0.32, resetIn: 2 * hour + 18 * minute)
            snapshot.windows[1] = LimitWindow(id: "weekly_all", label: "All models",
                                               usedFraction: fraction, duration: 7 * 86400)
            return (label, StatusItemArtwork(summary: summary([snapshot], weekly: true),
                                             font: font, height: 22 * scale))
        }
        let two = StatusItemArtwork(
            summary: summary([claude(0.32, resetIn: hour), codex(0.14, resetIn: 2 * hour)], weekly: true),
            font: font, height: 22 * scale)
        let all = rows + [("2 providers", two)]
        let labelWidth: CGFloat = 140
        let rowHeight: CGFloat = 112
        let canvas = NSImage(size: NSSize(width: labelWidth + (all.map { $0.1.size.width }.max() ?? 0) + 32,
                                          height: rowHeight * CGFloat(all.count)), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            for (index, row) in all.enumerated() {
                let y = rect.maxY - CGFloat(index + 1) * rowHeight + 12
                NSAttributedString(string: row.0, attributes: [
                    .font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.black,
                ]).draw(at: NSPoint(x: 12, y: y + 30))
                row.1.image().draw(at: NSPoint(x: labelWidth, y: y),
                                   from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        let data = try XCTUnwrap(canvas.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}

/// The menu bar choice on its own: what "never chosen" means, and how the
/// first choice gets written down.
final class MenuBarLimitsTests: XCTestCase {
    /// Before anyone chooses, the bar is for the providers whose headline is
    /// the five-hour window — every profile of them.
    func testNeverChosenReadsAsEveryClaudeAndCodexProfile() {
        let limits = MenuBarLimits(isOn: true, chosen: nil)
        for id in ["claude", "claude-work", "codex", "codex-side"] {
            XCTAssertTrue(limits.isChosen(id), id)
        }
        for id in ["gemini", "glm", "kimi", "cursor"] {
            XCTAssertFalse(limits.isChosen(id), id)
        }
    }

    /// The first choice writes down everything that was on screen, ticked as
    /// it was showing — so what is stored is what the user saw.
    func testTheFirstChoiceWritesDownWhatWasShowing() {
        let listed = ["claude", "codex", "gemini"]
        let never = MenuBarLimits(isOn: true, chosen: nil)
        XCTAssertEqual(never.choosing(true, "gemini", among: listed).chosen, ["claude", "codex", "gemini"])
        XCTAssertEqual(never.choosing(false, "claude", among: listed).chosen, ["codex"])
    }

    /// Once written down, a Claude profile that turns up later is not put in
    /// the bar behind anyone's back.
    func testAProfileThatTurnsUpLaterWaitsToBeChosen() {
        let chosen = MenuBarLimits(isOn: true, chosen: nil).choosing(false, "codex", among: ["claude", "codex"])
        XCTAssertTrue(chosen.isChosen("claude"))
        XCTAssertFalse(chosen.isChosen("claude-work"))
    }

    /// Taking the last one out leaves an empty choice, not a forgotten one:
    /// the bar goes back to its icon instead of back to the default.
    func testTakingTheLastOneOutIsNotTheSameAsNeverChoosing() {
        let none = MenuBarLimits(isOn: true, chosen: ["claude"]).choosing(false, "claude", among: ["claude"])
        XCTAssertEqual(none.chosen, [])
        XCTAssertFalse(none.isChosen("claude"))
    }

    /// Choosing a provider is about that provider; the switch stays as it was.
    func testChoosingLeavesTheSwitchAlone() {
        let off = MenuBarLimits(isOn: false, chosen: ["claude"])
        XCTAssertFalse(off.choosing(true, "codex", among: ["claude", "codex"]).isOn)
        XCTAssertTrue(MenuBarLimits(isOn: true, chosen: nil).choosing(false, "codex", among: ["codex"]).isOn)
    }
}
