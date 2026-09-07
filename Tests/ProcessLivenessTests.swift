import XCTest
@testable import Codenotch

/// The pid check that decides whether a session file tells the truth. Its
/// whole subtlety is pid reuse: a recycled pid would resurrect a dead session,
/// so a start-time comparison has to settle it.
final class ProcessLivenessTests: XCTestCase {
    private func launchSleep() throws -> (Process, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return (process, Int32(process.processIdentifier))
    }

    func testALivingProcessIsAlive() throws {
        let (process, pid) = try launchSleep()
        defer { process.terminate() }
        // Give the kernel a beat to have actually started it.
        for _ in 0..<50 where ProcessLiveness.startTime(pid: pid) == nil {
            usleep(20_000)
        }

        let started = try XCTUnwrap(ProcessLiveness.startTime(pid: pid))
        XCTAssertTrue(ProcessLiveness.isAlive(pid: pid, startedAt: started))
    }

    /// A registered time within the tolerance of the process's real start is
    /// the ordinary case: registration happens seconds after launch.
    func testStartTimesWithinTheToleranceAgree() throws {
        let (process, pid) = try launchSleep()
        defer { process.terminate() }
        let started = try XCTUnwrap(ProcessLiveness.startTime(pid: pid))
        let registered = started.addingTimeInterval(3 * 60)   // under the 5-minute tolerance
        XCTAssertTrue(ProcessLiveness.isAlive(pid: pid, startedAt: registered))
    }

    /// A start time far from the process's actual one means the pid has been
    /// handed to something else entirely — the session is dead even though the
    /// pid answers.
    func testAReusedPidIsRejected() throws {
        let (process, pid) = try launchSleep()
        defer { process.terminate() }
        let started = try XCTUnwrap(ProcessLiveness.startTime(pid: pid))
        let imposter = started.addingTimeInterval(-30 * 60)   // half an hour off
        XCTAssertFalse(ProcessLiveness.isAlive(pid: pid, startedAt: imposter))
    }

    /// When the registration time is missing there is nothing to compare, and
    /// hiding a session that is probably real is worse than trusting the pid.
    func testAnUnknownStartTimeTrustsThePid() throws {
        let (process, pid) = try launchSleep()
        defer { process.terminate() }
        XCTAssertTrue(ProcessLiveness.isAlive(pid: pid, startedAt: nil))
    }

    func testADeadProcessIsNotAlive() throws {
        let (process, pid) = try launchSleep()
        process.terminate()
        process.waitUntilExit()
        XCTAssertFalse(ProcessLiveness.isAlive(pid: pid, startedAt: nil))
        XCTAssertNil(ProcessLiveness.startTime(pid: pid))
    }
}
