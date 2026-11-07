import SQLite3
import XCTest
@testable import Codenotch

/// Quota samples: a reading that hasn't changed moves the newest row forward
/// instead of adding one, so the table grows with changes, not with time, while
/// every reader still sees the same first time, latest time and peak.
final class CostSampleTests: XCTestCase {
    private var dir: URL!
    private var store: CostStore!
    private let t = 1_800_000_000

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
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(dir.appendingPathComponent("costs.sqlite").path, &db,
                                     SQLITE_OPEN_READONLY, nil)
        XCTAssertEqual(opened, SQLITE_OK)
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT ts, pct FROM quota_sample WHERE window=?1 ORDER BY ts, id",
                           -1, &st, nil)
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, window.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var out: [[Double]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append([Double(sqlite3_column_int64(st, 0) - Int64(t)), sqlite3_column_double(st, 1)])
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
    }

    func testANewResetTimeIsKeptAndPeriodsStayTheSame() throws {
        for offset in [0, 15, 30, 45] { record(40, at: offset, resets: t + 100) }
        for offset in [60, 75, 90] { record(40, at: offset, resets: t + 200) }
        XCTAssertEqual(try rows(), [[0, 40], [45, 40], [60, 40], [90, 40]])
        let periods = store.periods(window: .weekly)
        XCTAssertEqual(periods.map(\.end), [t + 100, t + 200])
        XCTAssertEqual(periods.map(\.usedPct), [40, 40])
        XCTAssertEqual(store.currentPeriodStart(window: .weekly),
                       max(Int(Date().timeIntervalSince1970) - Int(CostWindow.weekly.duration),
                           t + 200 - Int(CostWindow.weekly.duration)))
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
}
