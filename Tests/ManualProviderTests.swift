import XCTest
@testable import Codenotch

final class ManualProviderTests: XCTestCase {

    // MARK: - Initial State & Snapshots

    func testInitialSnapshotWithDeclaredLimit() async throws {
        let storage = InMemoryManualStorage()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = ManualProvider(
            id: "manual",
            displayName: "Manual Provider",
            limit: 50,
            schedule: .interval(3 * 3600),
            storage: storage,
            now: t0
        )

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.id, "manual")
        XCTAssertEqual(snapshot.displayName, "Manual Provider")
        XCTAssertEqual(snapshot.fidelity, .manual)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.headlineID, "manual.primary")
        XCTAssertEqual(snapshot.windows.count, 1)

        let window = try XCTUnwrap(snapshot.headline)
        XCTAssertEqual(window.id, "manual.primary")
        XCTAssertEqual(window.used, 0)
        XCTAssertEqual(window.remaining, 50)
        XCTAssertEqual(window.usedFraction, 0.0)
        XCTAssertEqual(window.duration, 3 * 3600)
        XCTAssertEqual(window.resetsAt, t0.addingTimeInterval(3 * 3600))
    }

    func testInitialSnapshotWithoutLimit() async throws {
        let storage = InMemoryManualStorage()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = ManualProvider(
            id: "manual",
            limit: nil,
            schedule: .interval(3 * 3600),
            storage: storage,
            now: t0
        )

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.fidelity, .manual)
        let window = try XCTUnwrap(snapshot.headline)
        XCTAssertEqual(window.used, 0)
        XCTAssertNil(window.usedFraction)
        XCTAssertNil(window.remaining)
        XCTAssertEqual(window.summary, "0 used")
    }

    // MARK: - Counting & Usage Recording

    func testCountingAndIncrement() async throws {
        let storage = InMemoryManualStorage()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = ManualProvider(
            limit: 100,
            schedule: .interval(5 * 3600),
            storage: storage,
            now: t0
        )

        await provider.recordUsage(count: 1, at: t0.addingTimeInterval(60))
        var used = await provider.currentUsed()
        XCTAssertEqual(used, 1)

        await provider.recordUsage(count: 9, at: t0.addingTimeInterval(120))
        used = await provider.currentUsed()
        XCTAssertEqual(used, 10)

        var snap = try await provider.fetchSnapshot()
        XCTAssertEqual(snap.headline?.used, 10)
        XCTAssertEqual(snap.headline?.remaining, 90)
        XCTAssertEqual(snap.headline?.usedFraction, 0.10)

        await provider.decrementUsage(count: 2, at: t0.addingTimeInterval(180))
        used = await provider.currentUsed()
        XCTAssertEqual(used, 8)

        await provider.setUsed(45, at: t0.addingTimeInterval(240))
        used = await provider.currentUsed()
        XCTAssertEqual(used, 45)

        snap = try await provider.fetchSnapshot()
        XCTAssertEqual(snap.headline?.used, 45)
        XCTAssertEqual(snap.headline?.remaining, 55)
        XCTAssertEqual(snap.headline?.usedFraction, 0.45)
    }

    func testManualReset() async throws {
        let storage = InMemoryManualStorage()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = ManualProvider(limit: 50, storage: storage, now: t0)

        await provider.recordUsage(count: 30, at: t0)
        let usedBeforeReset = await provider.currentUsed()
        XCTAssertEqual(usedBeforeReset, 30)

        await provider.reset(at: t0.addingTimeInterval(500))
        let usedAfterReset = await provider.currentUsed()
        XCTAssertEqual(usedAfterReset, 0)

        let snap = try await provider.fetchSnapshot()
        XCTAssertEqual(snap.headline?.used, 0)
        XCTAssertEqual(snap.headline?.remaining, 50)
    }

    // MARK: - Reset Scheduling: Interval

    func testIntervalResetSchedulingRollover() async throws {
        let storage = InMemoryManualStorage()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let interval: TimeInterval = 3 * 3600 // 3 hours
        let provider = ManualProvider(
            limit: 50,
            schedule: .interval(interval),
            storage: storage,
            now: t0
        )

        // 1. Record 20 requests at t0 + 1 hour
        let t1 = t0.addingTimeInterval(3600)
        await provider.recordUsage(count: 20, at: t1)
        let usedAtT1 = await provider.currentUsed()
        XCTAssertEqual(usedAtT1, 20)

        // 2. Still in window at t0 + 2.5 hours
        let t2 = t0.addingTimeInterval(2.5 * 3600)
        let resetsAtT2 = await provider.currentResetsAt(at: t2)
        XCTAssertEqual(resetsAtT2, t0.addingTimeInterval(interval))

        // 3. Jump past reset time to t0 + 3.5 hours
        let t3 = t0.addingTimeInterval(3.5 * 3600)
        // Record 5 requests in new window: old count rolled over, so count becomes 5
        await provider.recordUsage(count: 5, at: t3)
        let usedAtT3 = await provider.currentUsed()
        XCTAssertEqual(usedAtT3, 5)

        // Window boundary has advanced to t0 + 3h -> t0 + 6h
        let resetsAtT3 = await provider.currentResetsAt(at: t3)
        XCTAssertEqual(resetsAtT3, t0.addingTimeInterval(2 * interval))
    }

    func testMultiPeriodIntervalRollover() async throws {
        let storage = InMemoryManualStorage()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let interval: TimeInterval = 3 * 3600
        let provider = ManualProvider(
            limit: 50,
            schedule: .interval(interval),
            storage: storage,
            now: t0
        )

        await provider.recordUsage(count: 40, at: t0)
        let usedAtT0 = await provider.currentUsed()
        XCTAssertEqual(usedAtT0, 40)

        // Advance 10 hours (3 full intervals = 9 hours elapsed)
        let tFuture = t0.addingTimeInterval(10 * 3600)
        await provider.recordUsage(count: 2, at: tFuture)
        let usedAtTFuture = await provider.currentUsed()
        XCTAssertEqual(usedAtTFuture, 2)

        // Next reset is at t0 + 12h
        let resetsAt = await provider.currentResetsAt(at: tFuture)
        XCTAssertEqual(resetsAt, t0.addingTimeInterval(12 * 3600))
    }

    // MARK: - Reset Scheduling: Calendar (Daily, Weekly, Monthly)

    func testDailyResetScheduling() async throws {
        let storage = InMemoryManualStorage()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // 2026-05-10 14:00:00 GMT
        var comp = DateComponents(timeZone: calendar.timeZone, year: 2026, month: 5, day: 10, hour: 14, minute: 0, second: 0)
        let t0 = calendar.date(from: comp)!

        let provider = ManualProvider(
            limit: 50,
            schedule: .daily(hour: 0, minute: 0),
            storage: storage,
            calendar: calendar,
            now: t0
        )

        // Before midnight: 2026-05-10 22:00:00
        let tSameDay = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 5, day: 10, hour: 22, minute: 0, second: 0))!
        await provider.recordUsage(count: 15, at: tSameDay)
        let usedSameDay = await provider.currentUsed()
        XCTAssertEqual(usedSameDay, 15)

        let nextMidnight = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 5, day: 11, hour: 0, minute: 0, second: 0))!
        let resetsAtSameDay = await provider.currentResetsAt(at: tSameDay)
        XCTAssertEqual(resetsAtSameDay, nextMidnight)

        // After midnight: 2026-05-11 01:00:00
        let tNextDay = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 5, day: 11, hour: 1, minute: 0, second: 0))!
        await provider.recordUsage(count: 4, at: tNextDay)
        let usedNextDay = await provider.currentUsed()
        XCTAssertEqual(usedNextDay, 4)

        let dayAfterMidnight = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 5, day: 12, hour: 0, minute: 0, second: 0))!
        let resetsAtNextDay = await provider.currentResetsAt(at: tNextDay)
        XCTAssertEqual(resetsAtNextDay, dayAfterMidnight)
    }

    func testManualOnlyScheduleDoesNotAutoReset() async throws {
        let storage = InMemoryManualStorage()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = ManualProvider(
            limit: 50,
            schedule: .manualOnly,
            storage: storage,
            now: t0
        )

        await provider.recordUsage(count: 35, at: t0)
        let resetsAtT0 = await provider.currentResetsAt(at: t0)
        XCTAssertNil(resetsAtT0)

        // 30 days later
        let t30Days = t0.addingTimeInterval(30 * 86400)
        await provider.recordUsage(count: 5, at: t30Days)
        let used30Days = await provider.currentUsed()
        XCTAssertEqual(used30Days, 40)
        let resetsAt30Days = await provider.currentResetsAt(at: t30Days)
        XCTAssertNil(resetsAt30Days)

        // Only explicit reset resets it
        await provider.reset(at: t30Days)
        let usedAfterExplicitReset = await provider.currentUsed()
        XCTAssertEqual(usedAfterExplicitReset, 0)
    }

    // MARK: - Persistence Across Instances

    func testPersistenceAcrossInstances() async throws {
        let storage = InMemoryManualStorage()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Instance 1
        let p1 = ManualProvider(id: "custom-manual", limit: 80, schedule: .interval(4 * 3600), storage: storage, now: t0)
        await p1.recordUsage(count: 27, at: t0)

        // Instance 2 shares the same storage
        let p2 = ManualProvider(id: "custom-manual", limit: nil, schedule: .manualOnly, storage: storage, now: t0)
        let usedP2 = await p2.currentUsed()
        let limitP2 = await p2.currentLimit()
        let schedP2 = await p2.currentSchedule()
        XCTAssertEqual(usedP2, 27)
        XCTAssertEqual(limitP2, 80)
        XCTAssertEqual(schedP2, .interval(4 * 3600))
    }

    // MARK: - Dynamic Limit and Schedule Providers

    func testDynamicLimitAndSchedule() async throws {
        var dynLimit: Int? = 50
        var dynSchedule: ManualResetSchedule? = .interval(3 * 3600)

        let storage = InMemoryManualStorage()
        let provider = ManualProvider(
            limitProvider: { dynLimit },
            scheduleProvider: { dynSchedule },
            storage: storage
        )

        var snap = try await provider.fetchSnapshot()
        XCTAssertEqual(snap.headline?.remaining, 50)
        XCTAssertEqual(snap.headline?.duration, 3 * 3600)

        // Change dynamic settings
        dynLimit = 200
        dynSchedule = .interval(5 * 3600)

        snap = try await provider.fetchSnapshot()
        XCTAssertEqual(snap.headline?.remaining, 200)
        XCTAssertEqual(snap.headline?.duration, 5 * 3600)
    }

    // MARK: - Callback and Account Info

    func testOnChangedFires() async {
        let storage = InMemoryManualStorage()
        let provider = ManualProvider(storage: storage)
        var changeCount = 0

        await provider.setOnChanged {
            changeCount += 1
        }

        await provider.recordUsage(count: 1)
        XCTAssertEqual(changeCount, 1)

        await provider.setUsed(10)
        XCTAssertEqual(changeCount, 2)

        await provider.reset()
        XCTAssertEqual(changeCount, 3)
    }

    func testAccountReflectsLimit() {
        let storage = InMemoryManualStorage()
        let provider = ManualProvider(displayName: "My Service", limit: 100, unit: "calls", storage: storage)
        let account = provider.account()
        XCTAssertEqual(account?.label, "My Service")
        XCTAssertEqual(account?.plan, "100 calls limit")
    }

    // MARK: - Schedule Identifiers

    func testScheduleIdentifiersRoundTrip() {
        let schedules: [ManualResetSchedule] = [
            .interval(3 * 3600),
            .interval(4 * 3600),
            .interval(5 * 3600),
            .interval(12 * 3600),
            .interval(24 * 3600),
            .interval(7200),
            .daily(hour: 0, minute: 0),
            .weekly(weekday: 2, hour: 0, minute: 0),
            .monthly(day: 1, hour: 0, minute: 0),
            .manualOnly
        ]

        for s in schedules {
            let id = s.identifier
            let parsed = ManualResetSchedule.from(identifier: id)
            XCTAssertEqual(parsed, s, "Schedule \(s) failed round-trip via \(id)")
        }
    }
}

private extension ManualProvider {
    func setOnChanged(_ callback: @escaping @Sendable () -> Void) {
        self.onChanged = callback
    }
}
