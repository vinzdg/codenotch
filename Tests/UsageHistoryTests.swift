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
