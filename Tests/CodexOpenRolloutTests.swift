import XCTest
@testable import Codenotch

@MainActor
final class CodexOpenRolloutTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexOpenRolloutTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testQuietOpenConversationStaysBusyUntilTaskComplete() throws {
        let rollout = try makeRollout(events: ["task_started"])
        let conversations = CodexActivityMonitor.liveConversations(
            [thread(rollout)], staleAfter: 8, now: now, openRollouts: [rollout.path]
        )

        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.state, .busy)
        XCTAssertTrue(conversations.first?.isOpen == true)
    }

    func testOpenCompletedConversationIsNotBusy() throws {
        let rollout = try makeRollout(events: ["task_started", "task_complete"])
        XCTAssertTrue(CodexActivityMonitor.liveConversations(
            [thread(rollout)], staleAfter: 8, now: now, openRollouts: [rollout.path]
        ).isEmpty)
    }

    func testFindsARolloutHeldOpenByAProcess() throws {
        let sessions = directory.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout.jsonl")
        try Data().write(to: rollout)
        let handle = try FileHandle(forWritingTo: rollout)
        defer { try? handle.close() }

        XCTAssertTrue(CodexOpenRollouts.paths(under: sessions, pids: [getpid()]).contains(rollout.path))
    }

    private func makeRollout(events: [String]) throws -> URL {
        let rollout = directory.appendingPathComponent("rollout.jsonl")
        let lines = events.map { #"{"type":"event_msg","payload":{"type":"\#($0)"}}"# }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rollout)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: rollout.path
        )
        return rollout
    }

    private func thread(_ rollout: URL) -> CodexThread {
        CodexThread(
            id: "thread",
            rollout: rollout,
            name: "Long-running command",
            preview: nil,
            cwd: nil,
            parentID: nil,
            isHelper: false
        )
    }
}
