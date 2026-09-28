import XCTest
@testable import Codenotch

final class UsageHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 604800

    private func history() -> UsageHistory {
        let name = "UsageHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return UsageHistory(defaults: defaults)
    }

    private func snapshot(_ used: Double, resetsAt: Date? = nil, id: String = "claude") -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: "Claude", glyph: .claude, fidelity: .official, status: .ok,
            windows: [
                LimitWindow(id: "session", label: "Session", usedFraction: 0.9,
                            resetsAt: start.addingTimeInterval(3600), duration: 18000),
                LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: used,
                            resetsAt: resetsAt ?? start.addingTimeInterval(week), duration: week),
            ],
            headlineID: "session", weeklyID: "weekly_all"
        )
    }

    func testRecordsTheWeeklyWindowOnChangeAndOnTheHeartbeat() throws {
        let store = history()
        store.record(snapshot(0.10), at: start.addingTimeInterval(60))
        store.record(snapshot(0.10), at: start.addingTimeInterval(20 * 60))
        store.record(snapshot(0.12), at: start.addingTimeInterval(25 * 60))
        store.record(snapshot(0.12), at: start.addingTimeInterval(55 * 60))
        let series = try XCTUnwrap(store.all()["claude"])
        XCTAssertEqual(series.windowID, "weekly_all")
        XCTAssertEqual(series.samples.map(\.used), [0.10, 0.12, 0.12])
        XCTAssertEqual(series.samples.map { $0.at.timeIntervalSince(self.start) }, [60, 1500, 3300])
    }

    func testANewCycleStartsANewSeriesButJitterDoesNot() throws {
        let store = history()
        store.record(snapshot(0.50), at: start.addingTimeInterval(60))
        store.record(snapshot(0.51, resetsAt: start.addingTimeInterval(week + 240)),
                     at: start.addingTimeInterval(120))
        XCTAssertEqual(try XCTUnwrap(store.all()["claude"]).samples.count, 2)

        store.record(snapshot(0.02, resetsAt: start.addingTimeInterval(2 * week)),
                     at: start.addingTimeInterval(week + 60))
        XCTAssertEqual(try XCTUnwrap(store.all()["claude"]).samples.map(\.used), [0.02])
    }

    func testARollingWindowNeverAccumulatesASeries() throws {
        let store = history()
        for minute in 0..<5 {
            let at = start.addingTimeInterval(Double(minute) * 3600)
            store.record(snapshot(0.3 + Double(minute) / 100, resetsAt: at.addingTimeInterval(week)), at: at)
        }
        XCTAssertEqual(try XCTUnwrap(store.all()["claude"]).samples.count, 1)
    }

    func testIgnoresWindowsItCannotPlaceInACycle() {
        let store = history()
        let noReset = ProviderSnapshot(
            id: "kilo", displayName: "Kilo", glyph: .claude, fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "credits", label: "Credits", usedFraction: 0.4)]
        )
        store.record(noReset, at: start)
        XCTAssertNil(store.all()["kilo"])
    }

    func testForgetAndClear() {
        let store = history()
        store.record(snapshot(0.1), at: start)
        store.record(snapshot(0.1, id: "codex"), at: start)
        store.forget("claude")
        XCTAssertNil(store.all()["claude"])
        XCTAssertNotNil(store.all()["codex"])
        store.clear()
        XCTAssertNil(store.all()["codex"])
    }

    func testChangesUnderATenthOfAPercentAddNoSample() throws {
        let store = history()
        store.record(snapshot(0.12341), at: start.addingTimeInterval(60))
        store.record(snapshot(0.12344), at: start.addingTimeInterval(120))
        XCTAssertEqual(try XCTUnwrap(store.all()["claude"]).samples.map(\.used), [0.123])
    }

    func testGapsLongerThanTheThresholdAreNotObserved() {
        let series = UsageHistory.Series(windowID: "weekly_all", cycleStart: start, samples: [
            .init(at: start, used: 0.1),
            .init(at: start.addingTimeInterval(44 * 60), used: 0.2),
            .init(at: start.addingTimeInterval(44 * 60 + 45 * 60), used: 0.4),
        ])
        XCTAssertEqual(series.segments.map(\.observed), [true, false])
    }
}

@MainActor
final class UsageHistoryStoreTests: XCTestCase {
    private final class Weekly: UsageProvider, @unchecked Sendable {
        let id = "claude"
        let displayName = "Claude"
        let glyph = ProviderGlyph.claude
        var used = 0.2
        var signInRoute: SignInRoute { .guidance("") }
        func account() -> ProviderAccount? { nil }
        func presentSignIn() {}
        func fetchSnapshot() async throws -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: displayName, glyph: glyph, fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: used,
                                                   resetsAt: Date().addingTimeInterval(3 * 86400),
                                                   duration: 604800)],
                             weeklyID: "weekly_all")
        }
    }

    private func defaults() -> UserDefaults {
        let name = "UsageHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testRecordsNothingWhileOff() async {
        let storage = defaults()
        let store = UsageStore(providers: [Weekly()], archive: UsageArchive(defaults: storage),
                               history: UsageHistory(defaults: storage))
        await store.refresh()
        XCTAssertNil(UsageHistory(defaults: storage).all()["claude"])
        XCTAssertNil(store.snapshots.first?.usageHistory)
    }

    func testRecordsAndAttachesWhileOnAndClearsWhenTurnedOff() async throws {
        let storage = defaults()
        let store = UsageStore(providers: [Weekly()], archive: UsageArchive(defaults: storage),
                               history: UsageHistory(defaults: storage))
        store.recordsUsageHistory = true
        await store.refresh()
        XCTAssertEqual(try XCTUnwrap(store.snapshots.first?.usageHistory).samples.map(\.used), [0.2])

        store.recordsUsageHistory = false
        XCTAssertNil(UsageHistory(defaults: storage).all()["claude"])
        XCTAssertNil(store.snapshots.first?.usageHistory)
    }

    func testARestoredReadingShowsItsHistoryAsSoonAsThePreferenceArrives() async throws {
        let storage = defaults()
        let first = UsageStore(providers: [Weekly()], archive: UsageArchive(defaults: storage),
                               history: UsageHistory(defaults: storage))
        first.recordsUsageHistory = true
        await first.refresh()

        let relaunched = UsageStore(providers: [Weekly()], archive: UsageArchive(defaults: storage),
                                    history: UsageHistory(defaults: storage))
        XCTAssertNil(relaunched.snapshots.first?.usageHistory)
        relaunched.recordsUsageHistory = true
        // Shown from storage, not recorded again: a restored reading is not a live one.
        XCTAssertEqual(relaunched.snapshots.first?.usageHistory?.samples.count, 1)
    }

    private final class Flaky: UsageProvider, @unchecked Sendable {
        let id = "claude"
        let displayName = "Claude"
        let glyph = ProviderGlyph.claude
        var fails = false
        var signInRoute: SignInRoute { .guidance("") }
        func account() -> ProviderAccount? { nil }
        func presentSignIn() {}
        func fetchSnapshot() async throws -> ProviderSnapshot {
            if fails { throw UsageProviderError.badResponse(status: 500) }
            return try await Weekly().fetchSnapshot()
        }
    }

    func testAFailedFetchCannotBringBackADeletedHistory() async {
        let storage = defaults()
        let provider = Flaky()
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: storage),
                               history: UsageHistory(defaults: storage))
        store.recordsUsageHistory = true
        await store.refresh()
        store.recordsUsageHistory = false
        provider.fails = true
        await store.refresh()
        XCTAssertNil(store.snapshots.first?.usageHistory)
    }

    func testARelaunchKeepsTheChartThroughAFailedFetch() async {
        let storage = defaults()
        let first = UsageStore(providers: [Weekly()], archive: UsageArchive(defaults: storage),
                               history: UsageHistory(defaults: storage))
        first.recordsUsageHistory = true
        await first.refresh()

        let provider = Flaky()
        provider.fails = true
        let relaunched = UsageStore(providers: [provider], archive: UsageArchive(defaults: storage),
                                    history: UsageHistory(defaults: storage))
        relaunched.recordsUsageHistory = true
        await relaunched.refresh()
        XCTAssertNotNil(relaunched.snapshots.first?.usageHistory)
    }

    func testSignOutForgetsTheSeries() async {
        let storage = defaults()
        let store = UsageStore(providers: [Weekly()], archive: UsageArchive(defaults: storage),
                               history: UsageHistory(defaults: storage))
        store.recordsUsageHistory = true
        await store.refresh()
        store.signOut(providerID: "claude")
        XCTAssertNil(UsageHistory(defaults: storage).all()["claude"])
    }

    func testThePreferenceDefaultsOff() throws {
        let name = "UsageHistoryPreference.\(UUID().uuidString)"
        let storage = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { storage.removePersistentDomain(forName: name) }
        XCTAssertFalse(Preferences(defaults: storage).showUsageHistory)
        Preferences(defaults: storage).showUsageHistory = true
        XCTAssertTrue(Preferences(defaults: storage).showUsageHistory)
    }
}

final class UsageHistoryLayoutTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(samples: Int) -> ProviderSnapshot {
        var reading = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 0.4,
                                  resetsAt: start.addingTimeInterval(302400), duration: 604800)],
            weeklyID: "weekly_all"
        )
        reading.usageHistory = UsageHistory.Series(
            windowID: "weekly_all", cycleStart: start.addingTimeInterval(-302400),
            samples: (0..<samples).map { .init(at: start.addingTimeInterval(Double($0) * 1800), used: 0.1 * Double($0 + 1)) }
        )
        return reading
    }

    func testAChartNeedsTwoSamplesOfTheWindowItCharts() {
        XCTAssertNil(snapshot(samples: 1).chartedHistory)
        XCTAssertNotNil(snapshot(samples: 2).chartedHistory)
        var other = snapshot(samples: 3)
        other.usageHistory = UsageHistory.Series(windowID: "session", cycleStart: start,
                                                 samples: other.usageHistory!.samples)
        XCTAssertNil(other.chartedHistory)
    }

    func testTheChartSurvivesTheRingOverlays() {
        var reading = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official, status: .ok,
            windows: [
                LimitWindow(id: "session", label: "Session", usedFraction: 0.3,
                            resetsAt: start.addingTimeInterval(3600), duration: 18000),
                LimitWindow(id: "weekly_all", label: "Weekly", usedFraction: 0.4,
                            resetsAt: start.addingTimeInterval(302400), duration: 604800),
            ],
            headlineID: "session", weeklyID: "weekly_all"
        )
        reading.usageHistory = snapshot(samples: 3).usageHistory
        XCTAssertNotNil(WeeklyHeadline.apply(to: [reading], enabled: true)[0].chartedHistory)
        XCTAssertNotNil(DailyPace.apply(to: [reading], enabled: true, now: start)[0].chartedHistory)
    }

    func testTheChartIsBudgeted() {
        let plain = NotchLayout.cardHeight(windowCount: 1)
        let charted = NotchLayout.cardHeight(windowCount: 1, hasUsageHistory: true)
        XCTAssertEqual(charted - plain, NotchLayout.historyBlockHeight, accuracy: 0.001)
        let budget = NotchLayout.cardHeight(windowCount: NotchLayout.maxWindowCount, groupCount: 2,
                                            sessionCount: 6, sessionCap: 5)
        XCTAssertLessThan(
            NotchLayout.sessionsFitting(cardBudget: budget, windowCount: NotchLayout.maxWindowCount, hasUsageHistory: true),
            NotchLayout.sessionsFitting(cardBudget: budget, windowCount: NotchLayout.maxWindowCount)
        )
    }
}

final class UsageHistoryDetailTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 604800
    private let en = Locale(identifier: "en_GB")

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func weekly(_ used: Double = 0.78) -> LimitWindow {
        LimitWindow(id: "weekly_all", label: "All models", usedFraction: used,
                    resetsAt: start.addingTimeInterval(week), duration: week)
    }

    private var series: UsageHistory.Series {
        UsageHistory.Series(windowID: "weekly_all", cycleStart: start, samples: [
            .init(at: start.addingTimeInterval(3600), used: 0.10),
            .init(at: start.addingTimeInterval(5400), used: 0.12),
            .init(at: start.addingTimeInterval(3 * 86400), used: 0.40),
            .init(at: start.addingTimeInterval(3 * 86400 + 1800), used: 0.42),
        ])
    }

    private var now: Date { start.addingTimeInterval(3 * 86400 + 1800) }

    private func detail(hovering date: Date?, window: LimitWindow? = nil,
                        fidelity: Fidelity = .official, staleSince: Date? = nil) -> String {
        UsageHistory.detail(series: series, window: window ?? weekly(), hovering: date, now: now,
                            fidelity: fidelity, staleSince: staleSince, calendar: utc, locale: en)
    }

    func testWithoutHoverTheVerdictFollowsTheLineAtThisRate() {
        XCTAssertEqual(detail(hovering: nil), "Used 78% · steady use 43% → fast")
        XCTAssertEqual(detail(hovering: nil, window: weekly(0.50)), "Used 50% · steady use 43% → a bit fast")
        XCTAssertEqual(detail(hovering: nil, window: weekly(0.40)), "Used 40% · steady use 43% → on track")
        XCTAssertEqual(detail(hovering: nil, window: weekly(0.20)), "Used 20% · steady use 43% → room to spare")
    }

    func testTooEarlyInTheWindowThereIsNoVerdict() {
        let early = LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.1,
                                resetsAt: now.addingTimeInterval(0.97 * week), duration: week)
        XCTAssertEqual(detail(hovering: nil, window: early), "Used 10% · steady use 3%")
    }

    func testAtTheLimitItSaysSoAndProjectsNothing() {
        XCTAssertEqual(detail(hovering: nil, window: weekly(1.3)), "Used 130% · steady use 43% → limit reached")
        XCTAssertEqual(detail(hovering: start.addingTimeInterval(5 * 86400), window: weekly(1.3)), "Wed 08:00 · steady use 71%")
        XCTAssertNil(weekly(1.0).rateLine(now: now))
    }

    func testHoverGivesTheNearestReadingAtItsOwnTime() {
        XCTAssertEqual(detail(hovering: start.addingTimeInterval(5300)), "Fri 09:30 · used 12% (steady use 1%)")
    }

    func testHoverOverAGapSaysNoDataWithoutGuessingWhy() {
        XCTAssertEqual(detail(hovering: start.addingTimeInterval(1.5 * 86400)), "Sat 20:00 · no data recorded")
    }

    func testHoverBeforeTheFirstReadingSaysHistoryHadNotBegun() {
        XCTAssertEqual(detail(hovering: start.addingTimeInterval(60)), "Fri 08:01 · before history began")
    }

    func testADerivedReadingKeepsItsTilde() {
        XCTAssertEqual(detail(hovering: nil, fidelity: .derived), "Used ~78% · steady use 43% → fast")
        XCTAssertEqual(detail(hovering: start.addingTimeInterval(5300), fidelity: .derived),
                       "Fri 09:30 · used ~12% (steady use 1%)")
    }

    func testReadingsArePrintedLikeTheRestOfTheCard() {
        XCTAssertEqual(detail(hovering: nil, window: weekly(0.003)), "Used 0.3% · steady use 43% → room to spare")
    }

    func testAnOldReadingIsDatedNotCalledNow() {
        XCTAssertEqual(detail(hovering: nil, staleSince: now.addingTimeInterval(-7200)),
                       "At 06:30 · used 78% (steady use 42%)")
    }

    func testHoveringTheFutureGivesTheRateAsAnEstimate() {
        XCTAssertEqual(detail(hovering: start.addingTimeInterval(5 * 86400)),
                       "Wed 08:00 · at this rate ~100% (steady use 71%)")
        XCTAssertEqual(detail(hovering: start.addingTimeInterval(4 * 86400), window: weekly(0.20)),
                       "Tue 08:00 · at this rate ~26% (steady use 57%)")
    }

    func testTooEarlyInTheWindowTheFutureGivesSteadyUseOnly() {
        let early = LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.1,
                                resetsAt: now.addingTimeInterval(0.97 * week), duration: week)
        XCTAssertEqual(detail(hovering: now.addingTimeInterval(2 * 86400), window: early), "Wed 08:30 · steady use 32%")
    }

    func testAMonthlyWindowNamesADateWeeksAway() {
        let monthly = LimitWindow(id: "weekly_all", label: "Monthly", usedFraction: 0.2,
                                  resetsAt: start.addingTimeInterval(30 * 86400), duration: 30 * 86400)
        XCTAssertEqual(detail(hovering: start.addingTimeInterval(25 * 86400), window: monthly),
                       "9 Feb at 08:00 · at this rate ~100% (steady use 83%)")
    }

    func testTheHeadingNamesTheWindowItsPeriodAndAYoungHistory() {
        let weeklyHeading = UsageHistory.heading(series: series, window: weekly(), now: now, calendar: utc, locale: en)
        XCTAssertEqual(weeklyHeading.title, "All models · this week")
        XCTAssertEqual(weeklyHeading.since, "history since Fri 09:00")
        let monthly = LimitWindow(id: "weekly_all", label: "Monthly", usedFraction: 0.2,
                                  resetsAt: start.addingTimeInterval(30 * 86400), duration: 30 * 86400)
        XCTAssertEqual(UsageHistory.heading(series: series, window: monthly, now: now, calendar: utc, locale: en).title,
                       "Monthly · this month")
        let full = UsageHistory.Series(windowID: "weekly_all", cycleStart: start,
                                       samples: [.init(at: start.addingTimeInterval(600), used: 0.01)] + series.samples)
        XCTAssertNil(UsageHistory.heading(series: full, window: weekly(), now: now, calendar: utc, locale: en).since)
    }

    func testTheRateLineEndsAtTheLimitOrAtTheReset() throws {
        let fast = try XCTUnwrap(weekly(0.78).rateLine(now: now))
        XCTAssertEqual(fast.used, 1, accuracy: 0.0001)
        XCTAssertEqual(fast.end.timeIntervalSince(now), 0.22 * (3 * 86400 + 1800) / 0.78, accuracy: 1)
        let slow = try XCTUnwrap(weekly(0.20).rateLine(now: now))
        XCTAssertEqual(slow.end, start.addingTimeInterval(week))
        XCTAssertEqual(slow.used, 0.20 * week / (3 * 86400 + 1800), accuracy: 0.0001)
        let early = LimitWindow(id: "w", label: "W", usedFraction: 0.1,
                                resetsAt: now.addingTimeInterval(0.97 * week), duration: week)
        XCTAssertNil(early.rateLine(now: now))
        let reset = LimitWindow(id: "w", label: "W", usedFraction: 0.5,
                                resetsAt: now.addingTimeInterval(-60), duration: week)
        XCTAssertNil(reset.rateLine(now: now), "the window already rolled over")
    }

    func testNowIsNamedOnlyWhereItClearsBothEnds() {
        func fits(_ fraction: Double) -> Bool {
            NotchLayout.fitsBetween("now", at: fraction, width: 172, leading: "Fri 25", trailing: "Resets Fri 2")
        }
        XCTAssertTrue(fits(0.45))
        XCTAssertFalse(fits(0.72), "runs into the reset label")
        XCTAssertFalse(fits(0.12), "runs into the start label")
    }

    func testTheLongestLinesFitTheCard() {
        let us = Locale(identifier: "en_US")
        let lines = [
            UsageHistory.detail(series: series, window: weekly(1), hovering: start.addingTimeInterval(4.18 * 86400),
                                now: now, calendar: utc, locale: us),
            UsageHistory.detail(series: series, window: weekly(1), hovering: start.addingTimeInterval(1.5 * 86400),
                                now: now, calendar: utc, locale: us),
            UsageHistory.detail(series: series, window: weekly(0.003), hovering: nil, now: now,
                                fidelity: .derived, calendar: utc, locale: us),
        ]
        for line in lines {
            let width = (line as NSString).size(withAttributes: [.font: NotchLayout.cardBodyFont]).width
            XCTAssertLessThanOrEqual(width, NotchLayout.cardTextWidth / 0.8, line)
        }
    }
}
