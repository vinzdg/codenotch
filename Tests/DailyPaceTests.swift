import XCTest
@testable import Codenotch

final class DailyPaceTests: XCTestCase {
    private let resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
    private var weekStart: Date { resetsAt.addingTimeInterval(-7 * 86_400) }

    private func weekly(used: Double? = 0.1, resetsAt: Date? = nil) -> LimitWindow {
        LimitWindow(id: "weekly_all", label: "All models", usedFraction: used,
                    resetsAt: resetsAt ?? self.resetsAt, duration: 7 * 86_400)
    }

    private func at(day: Double) -> Date { weekStart.addingTimeInterval(day * 86_400) }

    func testFirstDayAllowsASeventh() throws {
        let reading = try XCTUnwrap(DailyPace.reading(weekly: weekly(used: 0.10), now: at(day: 0.5)))
        XCTAssertEqual(reading.dayIndex, 0)
        XCTAssertEqual(reading.allowedFraction, 1.0 / 7, accuracy: 1e-9)
        XCTAssertEqual(reading.usedFraction, 0.70, accuracy: 1e-9)
        XCTAssertEqual(reading.dayEndsAt, at(day: 1))
    }

    func testEachDayAddsAnotherShare() throws {
        let third = try XCTUnwrap(DailyPace.reading(weekly: weekly(used: 0.30), now: at(day: 2.25)))
        XCTAssertEqual(third.dayIndex, 2)
        XCTAssertEqual(third.usedFraction, 0.70, accuracy: 1e-9)
        XCTAssertEqual(third.dayEndsAt, at(day: 3))

        // Over the day's share: the ring runs past full, as a vendor window does.
        let heavy = try XCTUnwrap(DailyPace.reading(weekly: weekly(used: 0.50), now: at(day: 2.25)))
        XCTAssertEqual(heavy.usedFraction, 0.50 / (3.0 / 7), accuracy: 1e-9)
    }

    func testLastDayEndsWithTheWeek() throws {
        let last = try XCTUnwrap(DailyPace.reading(weekly: weekly(used: 0.98), now: at(day: 6.9)))
        XCTAssertEqual(last.dayIndex, 6)
        XCTAssertEqual(last.allowedFraction, 1, accuracy: 1e-9)
        XCTAssertEqual(last.usedFraction, 0.98, accuracy: 1e-9)
        XCTAssertEqual(last.dayEndsAt, resetsAt)
    }

    func testClockSkewIsClampedToTheWeek() throws {
        let early = try XCTUnwrap(DailyPace.reading(weekly: weekly(used: 0.05), now: at(day: -0.1)))
        XCTAssertEqual(early.dayIndex, 0)
        let late = try XCTUnwrap(DailyPace.reading(weekly: weekly(used: 0.05), now: at(day: 7.1)))
        XCTAssertEqual(late.dayIndex, 6)
        XCTAssertEqual(late.dayEndsAt, resetsAt)
    }

    func testNeedsAReadingAndAReset() {
        XCTAssertNil(DailyPace.reading(weekly: weekly(used: nil), now: at(day: 1)))
        XCTAssertNil(DailyPace.reading(weekly: weekly(used: .nan), now: at(day: 1)))
        let noReset = LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.2)
        XCTAssertNil(DailyPace.reading(weekly: noReset, now: at(day: 1)))
    }

    func testWindowHasNoDurationSoThePaceLineStaysQuiet() throws {
        let window = try XCTUnwrap(DailyPace.window(weekly: weekly(used: 0.10), now: at(day: 0.5)))
        XCTAssertEqual(window.id, DailyPace.windowID)
        XCTAssertNil(window.duration)
        XCTAssertNil(window.usagePace(now: at(day: 0.5)))
        XCTAssertEqual(window.resetsAt, at(day: 1))
    }

    // MARK: - Snapshot

    private func claude(id: String = "claude", windows: [LimitWindow]) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: "Claude", glyph: .claude, fidelity: .official,
                         status: .ok, windows: windows, headlineID: "session", weeklyID: "weekly_all")
    }

    private var session: LimitWindow {
        LimitWindow(id: "session", label: "Current session", usedFraction: 0.42,
                    resetsAt: at(day: 2.1), duration: 5 * 3600)
    }

    func testDailyPaceLeadsTheClaudeSnapshot() throws {
        let paced = DailyPace.apply(to: claude(windows: [session, weekly(used: 0.30)]), now: at(day: 2.25))
        XCTAssertEqual(paced.windows.map(\.id), [DailyPace.windowID, "session", "weekly_all"])
        XCTAssertEqual(paced.headlineID, DailyPace.windowID)
        XCTAssertEqual(try XCTUnwrap(paced.usedFraction), 0.70, accuracy: 1e-9)
        XCTAssertEqual(paced.weeklyID, "session")
        XCTAssertEqual(paced.weeklyFraction, 0.42)
    }

    func testAppliesToEveryClaudeProfileAndNothingElse() {
        let work = DailyPace.apply(to: claude(id: "claude-work", windows: [weekly()]), now: at(day: 1))
        XCTAssertEqual(work.headlineID, DailyPace.windowID)
        XCTAssertNil(work.weeklyID, "no session window to hand the thin ring")

        let codex = ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai, fidelity: .official,
                                     status: .ok, windows: [weekly()], headlineID: "weekly_all")
        XCTAssertEqual(DailyPace.apply(to: codex, now: at(day: 1)), codex)
    }

    func testLeavesASnapshotWithoutAWeeklyReadingAlone() {
        let original = claude(windows: [session])
        XCTAssertEqual(DailyPace.apply(to: original, now: at(day: 1)), original)
    }

    func testDoesNotStackOnARepeatPass() {
        let once = DailyPace.apply(to: claude(windows: [session, weekly()]), now: at(day: 1))
        let twice = DailyPace.apply(to: once, now: at(day: 1))
        XCTAssertEqual(twice, once)
    }

    func testDisabledIsAPassThrough() {
        let snapshots = [claude(windows: [session, weekly()])]
        XCTAssertEqual(DailyPace.apply(to: snapshots, enabled: false, now: at(day: 1)), snapshots)
        XCTAssertEqual(DailyPace.apply(to: snapshots, enabled: true, now: at(day: 1)).first?.headlineID,
                       DailyPace.windowID)
    }
}

@MainActor
final class DailyPacePreferenceTests: XCTestCase {
    func testDefaultsOffAndSurvivesARelaunch() throws {
        let name = "DailyPacePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(Preferences(defaults: defaults).claudeDailyPaceRing)
        Preferences(defaults: defaults).claudeDailyPaceRing = true
        XCTAssertTrue(Preferences(defaults: defaults).claudeDailyPaceRing)
    }
}

/// The weekly limit as the big ring, for every provider that has one beside a
/// shorter window — decided by how long the window runs, never by its name.
@MainActor
final class WeeklyHeadlineTests: XCTestCase {
    private func window(_ id: String, _ used: Double, hours: Double?) -> LimitWindow {
        LimitWindow(id: id, label: id, usedFraction: used,
                    resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                    duration: hours.map { $0 * 3600 })
    }

    private func snapshot(_ id: String = "claude", windows: [LimitWindow],
                          headline: String?, weekly: String?) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: id, glyph: .claude, fidelity: .official,
                         status: .ok, windows: windows, headlineID: headline, weeklyID: weekly)
    }

    private var claude: ProviderSnapshot {
        snapshot(windows: [window("session", 0.01, hours: 5), window("weekly_all", 0.94, hours: 168)],
                 headline: "session", weekly: "weekly_all")
    }

    /// The reported case: the big ring said 1% while the week was at 94%.
    func testTheWeekLeadsAndTheSessionMovesToTheThinRing() {
        let led = WeeklyHeadline.apply(to: claude)
        XCTAssertEqual(led.headlineID, "weekly_all")
        XCTAssertEqual(led.usedFraction ?? -1, 0.94, accuracy: 1e-9)
        XCTAssertEqual(led.weeklyID, "session", "the thin ring, when on, draws the session now")
        XCTAssertEqual(led.windows, claude.windows, "nothing leaves the card")
    }

    func testOffLeavesEverySnapshotAsTheVendorSentIt() {
        XCTAssertEqual(WeeklyHeadline.apply(to: [claude], enabled: false), [claude])
    }

    /// Codex can report the week as its *primary* window and the five hours as
    /// its second. Swapping by name would put the five hours on the big ring —
    /// the opposite of the point.
    func testAWeekAlreadyLeadingIsLeftAlone() {
        let codex = snapshot("codex", windows: [window("primary", 0.95, hours: 168),
                                                window("secondary", 0.10, hours: 5)],
                             headline: "primary", weekly: "secondary")
        XCTAssertEqual(WeeklyHeadline.apply(to: codex), codex)
    }

    /// And a Codex plan that only reports the week has nothing to swap.
    func testASecondWindowThatIsNotThereIsNotSwappedIn() {
        let codex = snapshot("codex", windows: [window("primary", 0.95, hours: 168)],
                             headline: "primary", weekly: "secondary")
        XCTAssertEqual(WeeklyHeadline.apply(to: codex), codex)
    }

    /// Grok's second ring is its credits, not a week.
    func testASecondRingThatIsNotAWeekIsLeftAlone() {
        let grok = snapshot("grok", windows: [window("daily", 0.3, hours: 24),
                                              window("credits", 0.8, hours: nil)],
                            headline: "daily", weekly: "credits")
        XCTAssertEqual(WeeklyHeadline.apply(to: grok), grok)

        let monthly = snapshot("x", windows: [window("day", 0.3, hours: 24),
                                              window("month", 0.8, hours: 720)],
                               headline: "day", weekly: "month")
        XCTAssertEqual(WeeklyHeadline.apply(to: monthly), monthly)
    }

    /// Cursor has one window, its monthly cycle, and no second one at all.
    func testAProviderWithNoSecondWindowIsUnchanged() {
        let cursor = snapshot("cursor", windows: [window("auto", 0, hours: 720)],
                              headline: "auto", weekly: nil)
        XCTAssertEqual(WeeklyHeadline.apply(to: cursor), cursor)
    }

    /// Where both are on, the daily pace — Claude's alone, and the more
    /// specific of the two — still leads.
    func testTheDailyPaceStillLeadsWhereItIsOn() {
        let drawn = AppDelegate.drawn([claude], weekly: true, paced: true)
        XCTAssertEqual(drawn.first?.headlineID, DailyPace.windowID)
        XCTAssertEqual(drawn.first?.weeklyID, "session")
    }

    func testThePreferenceIsOffByDefaultAndRemembered() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WeeklyHeadlineTests.\(UUID().uuidString)"))
        XCTAssertFalse(Preferences(defaults: defaults).weeklyHeadline)
        Preferences(defaults: defaults).weeklyHeadline = true
        XCTAssertTrue(Preferences(defaults: defaults).weeklyHeadline)
    }
}
