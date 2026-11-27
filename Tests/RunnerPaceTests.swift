import XCTest

/// The runner's stride follows the CPU: a busier machine, a quicker figure.
final class RunnerPaceTests: XCTestCase {
    func testRestingIsSlowestAndFullLoadIsFastest() {
        XCTAssertEqual(RunnerPace.interval(busy: 0), RunnerPace.slowest, accuracy: 1e-9)
        XCTAssertEqual(RunnerPace.interval(busy: 1), RunnerPace.fastest, accuracy: 1e-9)
    }

    func testBusierIsNeverSlower() {
        let shares = stride(from: 0.0, through: 1.0, by: 0.1).map { $0 }
        let intervals = shares.map(RunnerPace.interval(busy:))
        XCTAssertEqual(intervals, intervals.sorted(by: >))
    }

    func testOutOfRangeSharesAreClamped() {
        XCTAssertEqual(RunnerPace.interval(busy: -3), RunnerPace.slowest, accuracy: 1e-9)
        XCTAssertEqual(RunnerPace.interval(busy: 7), RunnerPace.fastest, accuracy: 1e-9)
    }

    func testEveryPullUpFrameIsATemplateImage() {
        XCTAssertEqual(PullUpFrames.images.count, PullUpFrames.lifts.count)
        XCTAssertTrue(PullUpFrames.images.allSatisfy { $0.isTemplate })
    }
}
