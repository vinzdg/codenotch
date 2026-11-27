import XCTest

/// The arithmetic behind the CPU, storage and network readings. The kernel
/// calls themselves are exercised by running the app, not here.
final class SystemMetricTests: XCTestCase {
    func testBusyFractionIsBusyShareOfTicksSinceLastSample() {
        // user, system, idle, nice. Between samples: 30 user, 10 system, 60 idle.
        let before: [UInt32] = [100, 50, 400, 0]
        let after: [UInt32] = [130, 60, 460, 0]
        XCTAssertEqual(SystemMetricMath.busyFraction(from: before, to: after) ?? -1, 0.4, accuracy: 1e-9)
    }

    func testBusyFractionSurvivesA32BitCounterWrap() {
        let before: [UInt32] = [UInt32.max - 5, 0, 0, 0]
        let after: [UInt32] = [4, 0, 5, 0]   // 10 user ticks, 5 idle ticks, across the wrap
        XCTAssertEqual(SystemMetricMath.busyFraction(from: before, to: after) ?? -1, 10.0 / 15.0, accuracy: 1e-9)
    }

    func testBusyFractionIsNilWhenNothingTicked() {
        let same: [UInt32] = [1, 2, 3, 4]
        XCTAssertNil(SystemMetricMath.busyFraction(from: same, to: same))
    }

    func testUsedFractionIsClampedAndNilWithoutCapacity() {
        XCTAssertEqual(SystemMetricMath.usedFraction(total: 1_000, available: 250) ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertEqual(SystemMetricMath.usedFraction(total: 1_000, available: 2_000) ?? -1, 0, accuracy: 1e-9)
        XCTAssertNil(SystemMetricMath.usedFraction(total: 0, available: 0))
    }

    func testThroughputIsBytesPerSecondPerDirection() {
        let before: [String: (rx: UInt32, tx: UInt32)] = ["en0": (1_000, 500)]
        let after: [String: (rx: UInt32, tx: UInt32)] = ["en0": (3_000, 900)]
        let speed = SystemMetricMath.throughput(from: before, to: after, over: 2)
        XCTAssertEqual(speed.down, 1_000, accuracy: 1e-9)
        XCTAssertEqual(speed.up, 200, accuracy: 1e-9)
    }

    func testThroughputIgnoresInterfacesSeenOnOnlyOneSide() {
        let before: [String: (rx: UInt32, tx: UInt32)] = ["en0": (0, 0)]
        let after: [String: (rx: UInt32, tx: UInt32)] = ["en0": (100, 100), "utun3": (9_999, 9_999)]
        let speed = SystemMetricMath.throughput(from: before, to: after, over: 1)
        XCTAssertEqual(speed.down, 100, accuracy: 1e-9)
        XCTAssertEqual(speed.up, 100, accuracy: 1e-9)
    }

    func testMemoryUsedFractionIsUsedShareOfPhysicalMemory() {
        XCTAssertEqual(SystemMetricMath.memoryUsedFraction(used: 6, total: 8) ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertNil(SystemMetricMath.memoryUsedFraction(used: 1, total: 0))
    }

    func testBatteryChargeIsTheShareLeft() {
        XCTAssertEqual(SystemMetricMath.batteryCharge(current: 78, full: 100) ?? -1, 0.78, accuracy: 1e-9)
        XCTAssertNil(SystemMetricMath.batteryCharge(current: 0, full: 0))
    }

    func testThermalStatesClimbTheScale() {
        let levels = [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical]
            .map(SystemMetricMath.thermalLevel)
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertEqual(levels.last, 1)
    }

    func testEveryMetricHasItsOwnProviderID() {
        let ids = SystemMetric.allCases.map(\.providerID)
        XCTAssertEqual(Set(ids).count, SystemMetric.allCases.count)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("system-") })
    }
}
