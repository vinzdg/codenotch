import SQLite3
import XCTest
@testable import Codenotch

/// Quota samples: a reading that hasn't changed moves the newest row forward
/// instead of adding one, so the table grows with changes, not with time, while
/// every reader still sees the same first time, latest time and peak. And the
/// limit periods read from them, whose reset times can differ by a few seconds.
final class CostSampleTests: XCTestCase {
    private var dir: URL!
    private var store: CostStore!
    private let t = 4_000_000_000              // far ahead, so a reset time always beats "now"
    private let week = Int(CostWindow.weekly.duration)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostSampleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try XCTUnwrap(CostStore(url: dir.appendingPathComponent("costs.sqlite")))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func record(_ pct: Double, at offset: Int, resets: Int? = nil, _ window: CostWindow = .weekly) {
        store.recordSample(window: window, pct: pct,
                           resetsAt: resets.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                           at: Date(timeIntervalSince1970: TimeInterval(t + offset)))
    }

    /// The rows of one window as (seconds after `t`, pct), oldest first.
    private func rows(_ window: CostWindow = .weekly) throws -> [[Double]] {
        try select("SELECT ts, pct FROM quota_sample WHERE window=?1 ORDER BY ts, id", window)
    }

    /// Reset boundaries of one window, as seconds after `t`.
    private func boundaries(_ window: CostWindow = .weekly) throws -> [Double] {
        try select("SELECT ts FROM period_boundary WHERE window=?1 ORDER BY ts", window).map { $0[0] }
    }

    /// Runs a query bound to one window; the first column is a time, made relative to `t`.
    private func select(_ sql: String, _ window: CostWindow) throws -> [[Double]] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let opened = sqlite3_open_v2(dir.appendingPathComponent("costs.sqlite").path, &db,
                                     SQLITE_OPEN_READONLY, nil)
        guard opened == SQLITE_OK else { XCTFail("cannot open the store"); return [] }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            XCTFail(String(cString: sqlite3_errmsg(db))); return []
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, window.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var out: [[Double]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var row = [Double(sqlite3_column_int64(st, 0) - Int64(t))]
            for i in 1..<sqlite3_column_count(st) { row.append(sqlite3_column_double(st, i)) }
            out.append(row)
        }
        return out
    }

    func testAnUnchangedReadingMovesTheNewestRowForward() throws {
        for offset in stride(from: 0, through: 600, by: 15) { record(10, at: offset) }
        XCTAssertEqual(try rows(), [[0, 10], [600, 10]])
    }

    func testAChangedReadingStartsANewRun() throws {
        for offset in [0, 15, 30] { record(10, at: offset) }
        for offset in [45, 60, 75] { record(20, at: offset) }
        record(10, at: 90)                                      // a reset
        XCTAssertEqual(try rows(), [[0, 10], [30, 10], [45, 20], [75, 20], [90, 10]])
        XCTAssertEqual(try boundaries(), [90])
    }

    func testAResetAWeekLaterAddsARowAndAPeriod() throws {
        for offset in [0, 15, 30, 45] { record(40, at: offset, resets: t + 100) }
        for offset in [60, 75, 90] { record(40, at: offset, resets: t + 100 + week) }
        XCTAssertEqual(try rows(), [[0, 40], [45, 40], [60, 40], [90, 40]])
        let periods = store.periods(window: .weekly)
        XCTAssertEqual(periods.map(\.end), [t + 100, t + 100 + week])
        XCTAssertEqual(periods.map(\.usedPct), [40, 40])
        XCTAssertEqual(store.currentPeriodStart(window: .weekly), t + 100)
    }

    func testAPeriodKeepsItsFirstTimeAndPeakAcrossRuns() throws {
        for offset in [0, 15, 30] { record(30, at: offset, resets: t + 500, .credits) }
        for offset in [45, 60, 75] { record(50, at: offset, resets: t + 500, .credits) }
        let periods = store.periods(window: .credits)
        XCTAssertEqual(periods.count, 1)
        XCTAssertEqual(periods.first?.start, t)                 // the first sample of the cycle
        XCTAssertEqual(periods.first?.usedPct, 50)
    }

    func testAClockStepBackAddsARowInsteadOfMovingOne() throws {
        for offset in [0, 15, 30] { record(10, at: offset) }
        record(10, at: 20)
        XCTAssertEqual(try rows(), [[0, 10], [20, 10], [30, 10]])
    }

    func testWindowsAreKeptApart() throws {
        for offset in [0, 15, 30] {
            record(10, at: offset, .session)
            record(50, at: offset, .weekly)
        }
        XCTAssertEqual(try rows(.session), [[0, 10], [30, 10]])
        XCTAssertEqual(try rows(.weekly), [[0, 50], [30, 50]])
    }

    // MARK: Periods

    /// Claude has reported one weekly reset as 23:59:00, 23:59:59 and 00:00:00.
    /// The week keeps its highest reading, wherever it falls, and starts a week
    /// before its earliest reset time.
    func testResetTimesSecondsApartAreOnePeriod() throws {
        let reset = t + week
        record(81, at: 0, resets: reset - 60)
        record(100, at: 15, resets: reset - 1)
        record(19, at: 30, resets: reset)
        let periods = store.periods(window: .weekly)
        XCTAssertEqual(periods.map(\.end), [reset])
        XCTAssertEqual(periods.map(\.usedPct), [100])
        XCTAssertEqual(periods.map(\.start), [reset - 60 - week])
    }

    /// Jitter joins reset times at most five minutes apart in all, so they can't chain.
    func testJitterJoinsAtMostFiveMinutesInAll() throws {
        let reset = t + week
        for (i, offset) in [0, 300, 480, 781].enumerated() { record(40, at: i * 15, resets: reset + offset) }
        XCTAssertEqual(store.periods(window: .weekly).map(\.end), [reset + 300, reset + 480, reset + 781])
    }

    /// Credit cycles' reset times don't move, so 0% ones don't move the jitter's start either.
    func testCreditJitterCountsFromTheFirstResetTime() throws {
        let reset = t + 1_000
        record(0, at: 0, resets: reset, .credits)
        record(0, at: 15, resets: reset + 240, .credits)
        record(20, at: 30, resets: reset + 480, .credits)
        let periods = store.periods(window: .credits)
        XCTAssertEqual(periods.map(\.end), [reset + 240, reset + 480])
        XCTAssertEqual(periods.map(\.usedPct), [0, 20])
        XCTAssertEqual(periods.first?.start, t)                // the joined cycle's first sample
    }

    /// A week that ends at midnight, then one stored as both 23:59:00 and 00:00:00: the
    /// second starts where the first ends, so a session in that minute is priced in the
    /// first week and only weighed there.
    func testWhatAJoinAddsStopsWhereThePreviousPeriodEnds() throws {
        let midnight = t + week
        record(40, at: 0, resets: midnight)
        record(50, at: week, resets: midnight + week - 60)
        record(50, at: week + 15, resets: midnight + week)
        let periods = store.periods(window: .weekly)
        XCTAssertEqual(periods.map(\.start), [midnight - week, midnight])
        let session = midnight - 30
        XCTAssertEqual(periods.first { session >= $0.start && session < $0.end }?.usedPct, 40)
    }

    /// The last 0% reading before use can sit minutes before the week's reset time.
    /// Jitter counts from the first used reset time, so the week's own jitter still joins.
    func testJitterCountsFromTheFirstUsedResetTime() throws {
        let reset = t + week
        record(0, at: 0, resets: reset - 290)
        record(10, at: 290, resets: reset)
        record(20, at: 305, resets: reset + 20)
        let periods = store.periods(window: .weekly)
        XCTAssertEqual(periods.map(\.end), [reset + 20])
        XCTAssertEqual(periods.map(\.usedPct), [20])
    }

    /// A week that ends at T, then 0% readings after an early rollover, the second joined
    /// by a used reading: what the join adds still stops at T, with a 0% period between.
    func testWhatAJoinAddsStopsAtTheLastUsedPeriod() throws {
        let end = t + week
        record(40, at: 0, resets: end)
        record(0, at: week - 340, resets: end - 340 + week)
        record(0, at: week - 25, resets: end - 25 + week)
        record(20, at: week + 15, resets: end + 15 + week)
        let periods = store.periods(window: .weekly)
        XCTAssertEqual(periods.map(\.usedPct), [40, 0, 20])
        XCTAssertEqual(periods.map(\.start), [end - week, end - 340, end])
        let session = end - 10
        XCTAssertEqual(periods.first { session >= $0.start && session < $0.end }?.usedPct, 40)
    }

    /// Codex at 0% reads a new reset time every 15 s. The whole chain joins the week it
    /// leads to, which keeps its highest reading and starts with the chain.
    func testAChainOfZeroReadingsJoinsTheWeekItLeadsTo() throws {
        let reset = t + week
        for offset in stride(from: -600, to: 0, by: 15) { record(0, at: offset, resets: reset + offset) }
        record(10, at: 0, resets: reset)
        record(20, at: 20, resets: reset + 20)
        let periods = store.periods(window: .weekly)
        XCTAssertEqual(periods.map(\.usedPct), [20])
        XCTAssertEqual(periods.map(\.start), [t - 600])
    }

    /// A week stored only as 23:59:00, then one whose reset times include 00:00:00:
    /// a session in the minute between them still falls into the second week.
    func testNoGapOpensBetweenWeeks() throws {
        let midnight = t + week
        record(40, at: 0, resets: midnight - 60)
        record(50, at: week, resets: midnight + week - 60)
        record(50, at: week + 15, resets: midnight + week)
        record(30, at: 2 * week, resets: midnight + 2 * week)
        let periods = store.periods(window: .weekly)
        let session = midnight - 30
        XCTAssertEqual(periods.first { session >= $0.start && session < $0.end }?.usedPct, 50)
    }

    /// Codex at 0%: each reading's reset time is "now plus a week". The unused
    /// stretch, here cut by a nine-hour sleep, then use from 33,300 s on.
    private func recordAnUnusedStretchThenUse() {
        for offset in [0, 315, 630, 33_000] { record(0, at: offset, resets: t + offset + week) }
        record(5, at: 33_300, resets: t + 33_300 + week)
        record(20, at: 40_000, resets: t + 33_300 + week)
    }

    /// Each 0% period of the stretch ends where the next period starts, so none of them
    /// reaches into the week after it, and that week keeps its own reset times.
    func testAnUnusedStretchEndsWhereTheWeekAfterItStarts() throws {
        recordAnUnusedStretchThenUse()
        let periods = store.periods(window: .weekly)
        XCTAssertEqual(periods.map(\.usedPct), [0, 0, 0, 20])
        XCTAssertEqual(periods.map(\.start), [t, t + 315, t + 630, t + 33_000])
        XCTAssertEqual(periods.map(\.end), [t + 315, t + 630, t + 33_000, t + 33_300 + week])
    }

    func testASessionInThatWeekIsPricedFromItsUse() throws {
        recordAnUnusedStretchThenUse()
        let periods = store.periods(window: .weekly).map { (start: $0.start, end: $0.end, usedPct: $0.usedPct, weight: 100.0) }
        let plan = CostEstimator(billing: .subscription, monthlyPrice: 435, periods: periods, pricer: Pricer(prices: [], rate: 1))
        // Week = 435 ÷ 4.35 = 100; 20 % used = 20; half the week's weight → 10.
        let cost = plan.cost(at: t + 36_000, weight: 50, model: "x", input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
        XCTAssertEqual(cost ?? 0, 10, accuracy: 0.01)
    }

    /// Nothing after an unused week overlaps it, so it stays a period of its own.
    func testAnUnusedWeekStaysItsOwnPeriod() throws {
        record(0, at: 0, resets: t + week)
        record(30, at: week + 60, resets: t + 2 * week)
        XCTAssertEqual(store.periods(window: .weekly).map(\.usedPct), [0, 30])
    }

    /// After a schedule change, a used week can end a day earlier than a week after an
    /// unused one. The unused week stays a period of its own and ends where the used one
    /// starts, so a session in that day is priced from the used week.
    func testAnUnusedWeekEndsWhereAnOverlappingWeekStarts() throws {
        for offset in [0, 3_600, 7_200] { record(0, at: offset, resets: t + week) }
        record(30, at: week + 60, resets: t + 2 * week - 86_400)
        let periods = store.periods(window: .weekly)
        XCTAssertEqual(periods.map(\.usedPct), [0, 30])
        XCTAssertEqual(periods.map(\.end), [t + week - 86_400, t + 2 * week - 86_400])
        let session = t + week - 3_600
        XCTAssertEqual(periods.first { session >= $0.start && session < $0.end }?.usedPct, 30)
    }

    /// While a fetch fails, the last 0% reading is recorded again for hours. Its period
    /// still ends where the next starts, so the week after it isn't priced at 0.
    func testARepeatedZeroReadingDoesNotTakeTheWeekAfterIt() throws {
        for offset in [0, 3_600, 7_200] { record(0, at: offset, resets: t + week) }
        record(0, at: 7_300, resets: t + 7_300 + week)
        record(20, at: 7_700, resets: t + 7_700 + week)
        let periods = store.periods(window: .weekly)
        XCTAssertEqual(periods.map(\.usedPct), [0, 0, 20])
        let session = t + 8_000
        XCTAssertEqual(periods.first { session >= $0.start && session < $0.end }?.usedPct, 20)
    }

    /// A provider can move a week's reset; two used weeks that overlap stay apart, even
    /// when the first began with a 0% reading.
    func testUsedWeeksThatOverlapStayApart() throws {
        record(0, at: 0, resets: t + week - 100)
        record(72, at: 100, resets: t + week)
        record(24, at: 160, resets: t + week + 2 * 86_400)
        let periods = store.periods(window: .weekly)
        XCTAssertEqual(periods.map(\.usedPct), [72, 24])
        XCTAssertEqual(periods.map(\.start), [t - 100, t + 2 * 86_400])   // each its own window,
        XCTAssertEqual(periods.map(\.end), [t + week, t + week + 2 * 86_400]) // as before
    }

    /// Credit cycles have no fixed length: an unused cycle isn't joined to a shorter one after it.
    func testAnUnusedCreditCycleStaysItsOwnPeriod() throws {
        record(0, at: 0, resets: t + 1_000, .credits)
        record(30, at: 2_000, resets: t + 1_000 + 28 * 86_400, .credits)
        XCTAssertEqual(store.periods(window: .credits).map(\.usedPct), [0, 30])
    }
}
