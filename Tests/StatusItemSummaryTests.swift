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
                         limits: MenuBarLimits? = nil) -> StatusItemSummary {
        StatusItemSummary.make(
            from: snapshots,
            showing: limits ?? MenuBarLimits(isOn: true, chosen: Set(snapshots.map(\.id))),
            now: now)
    }

    private func on(_ chosen: Set<String>?) -> MenuBarLimits {
        MenuBarLimits(isOn: true, chosen: chosen)
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

    func testTheCountdownRunsDownToUnderAMinute() throws {
        XCTAssertEqual(try XCTUnwrap(summary([claude(0.66, resetIn: 47 * minute + 50)]).entries.first).countdown, "47m")
        XCTAssertEqual(try XCTUnwrap(summary([claude(0.93, resetIn: 42)]).entries.first).countdown, "<1m")
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

    /// The items to the left of this one shift whenever it changes width, so
    /// it keeps one width through the ordinary run of a window: single-digit
    /// shares, the last hour, the last minute, an unknown reset.
    func testTheItemKeepsOneWidthAsTheFiguresMove() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        func width(_ used: Double, _ resetIn: TimeInterval?) -> CGFloat {
            StatusItemArtwork(summary: summary([claude(used, resetIn: resetIn)]), font: font, height: 22).size.width
        }
        let reference = width(0.72, 2 * hour + 18 * minute)
        for (used, resetIn) in [(0.07, 2 * hour + 18 * minute), (0.0, 4 * hour + 59 * minute),
                                (0.003, 3 * hour), (0.72, 47 * minute), (0.72, 8 * minute),
                                (0.72, 30), (0.72, nil)] as [(Double, TimeInterval?)] {
            XCTAssertEqual(width(used, resetIn), reference, "\(used) with \(String(describing: resetIn))s left")
        }
        XCTAssertLessThan(width(0.72, nil), 150, "one reading should stay compact")
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
