import XCTest
@testable import Codenotch

final class PiSessionLivenessTests: XCTestCase {
    private var registry: URL!
    private let sessionID = "01a22022-c911-7471-aa05-f8d5aa6a89da"
    private var sessionPath: String {
        "/agent/sessions/--Users-me-yong_____jjang--/2026-11-28T03-11-20-337Z_\(sessionID).jsonl"
    }

    override func setUpWithError() throws {
        registry = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiSessionLivenessTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: registry)
    }

    private func register(pid: Int32, at createdAt: Date, session: String? = nil) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let meta: [String: Any] = [
            "kind": "p",
            "owner_session_id": session ?? sessionID,
            "created_at": formatter.string(from: createdAt),
            "created_by_pid": pid,
        ]
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: registry.appendingPathComponent("p-\(UUID().uuidString).meta.json"))
    }

    private func exitedPid() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    func testSessionIDIsTheFileNameAfterItsTimestamp() {
        XCTAssertEqual(PiSessionLiveness.sessionID(path: sessionPath), sessionID)
        XCTAssertNil(PiSessionLiveness.sessionID(path: "/agent/sessions/notes.txt"))
    }

    func testSessionOwnedByARunningProcessIsAlive() throws {
        try register(pid: getpid(), at: Date())
        XCTAssertEqual(PiSessionLiveness(registry: registry).state(sessionPath: sessionPath), .alive)
    }

    func testSessionWhoseOwnerExitedHasEnded() throws {
        try register(pid: try exitedPid(), at: Date())
        XCTAssertEqual(PiSessionLiveness(registry: registry).state(sessionPath: sessionPath), .ended)
    }

    func testPidReusedByAYoungerProcessDoesNotKeepTheSessionAlive() throws {
        let started = try XCTUnwrap(ProcessLiveness.startTime(pid: getpid()))
        try register(pid: getpid(), at: started.addingTimeInterval(-60))
        XCTAssertEqual(PiSessionLiveness(registry: registry).state(sessionPath: sessionPath), .ended)
    }

    func testUnregisteredSessionIsUnknown() throws {
        try register(pid: getpid(), at: Date(), session: "someone-else")
        XCTAssertEqual(PiSessionLiveness(registry: registry).state(sessionPath: sessionPath), .unknown)
        let missing = PiSessionLiveness(registry: registry.appendingPathComponent("missing"))
        XCTAssertEqual(missing.state(sessionPath: sessionPath), .unknown)
    }

    func testRecentlyWrittenSessionIsAliveUntilItsAgentRegisters() throws {
        let session = registry.appendingPathComponent("2026-11-28T03-11-20-337Z_\(sessionID).jsonl")
        try Data("{}\n".utf8).write(to: session)
        let liveness = PiSessionLiveness(registry: registry)
        XCTAssertEqual(liveness.state(sessionPath: session.path), .alive)

        try register(pid: try exitedPid(), at: Date())
        XCTAssertEqual(liveness.state(sessionPath: session.path), .alive,
                       "resumed by a process that has not registered yet")

        let old = Date().addingTimeInterval(-PiSessionLiveness.registrationGrace - 1)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: session.path)
        XCTAssertEqual(liveness.state(sessionPath: session.path), .ended)

        let unregistered = PiSessionLiveness(registry: registry.appendingPathComponent("missing"))
        try Data("{}\n".utf8).write(to: session)
        XCTAssertEqual(unregistered.state(sessionPath: session.path), .unknown,
                       "without a registry the file's age proves nothing")
    }

    func testResumedSessionIsAliveWhileItsNewProcessRuns() throws {
        let liveness = PiSessionLiveness(registry: registry)
        try register(pid: try exitedPid(), at: Date())
        XCTAssertEqual(liveness.state(sessionPath: sessionPath), .ended)

        try register(pid: getpid(), at: Date())
        XCTAssertEqual(liveness.state(sessionPath: sessionPath), .alive)
    }
}
