import Combine
import XCTest
@testable import Codenotch

/// Two configuration directories on one organization are one ring, and the
/// sessions running in either of them are that ring's sessions. Watching only
/// the surviving directory would hide the other's work behind a ring that
/// looks perfectly healthy.
@MainActor
final class CombinedClaudeSessionMonitorTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    /// A `sessions` directory with one live session file in it.
    ///
    /// This process's pid, so the monitor's liveness check passes and the only
    /// thing under test is which directories are being read.
    private func sessionsDirectory(named name: String, pid: Int32) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("combined-\(UUID().uuidString)")
        roots.append(root)
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        { "pid": \(pid), "sessionId": "\(name)", "cwd": "/Users/vinz/app",
          "name": "\(name)", "entrypoint": "claude-desktop" }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(pid).json"))
        return directory
    }

    private func monitor(_ directory: URL) -> ClaudeSessionMonitor {
        ClaudeSessionMonitor(directory: directory, livenessInterval: 60)
    }

    func testEveryDirectorysSessionsReachTheRing() throws {
        let mine = try sessionsDirectory(named: "team", pid: ProcessInfo.processInfo.processIdentifier)
        let theirs = try sessionsDirectory(named: "personal", pid: getppid())
        let combined = CombinedClaudeSessionMonitor([monitor(mine), monitor(theirs)])
        combined.start()
        defer { combined.stop() }
        XCTAssertEqual(combined.sessions.map(\.name).sorted(), ["personal", "team"])
    }

    /// The surviving profile's own directory is read first, so the rows keep
    /// the order the group was built in rather than whichever monitor last
    /// happened to rescan.
    func testTheFirstDirectoryComesFirst() throws {
        let first = try sessionsDirectory(named: "team", pid: ProcessInfo.processInfo.processIdentifier)
        let second = try sessionsDirectory(named: "personal", pid: getppid())
        let combined = CombinedClaudeSessionMonitor([monitor(first), monitor(second)])
        combined.start()
        defer { combined.stop() }
        XCTAssertEqual(combined.sessions.map(\.name), ["team", "personal"])
    }

    /// `combineLatest`, not `merge`: the published array has to be the whole
    /// ring every time. Merging would publish one directory's sessions alone
    /// and blank out the other's, which is the bug this monitor exists to
    /// avoid — a directory's work disappearing from a ring that covers it.
    func testThePublishedArrayIsAlwaysTheWholeRing() throws {
        let mine = try sessionsDirectory(named: "team", pid: ProcessInfo.processInfo.processIdentifier)
        let theirs = try sessionsDirectory(named: "personal", pid: getppid())
        let combined = CombinedClaudeSessionMonitor([monitor(mine), monitor(theirs)])
        var published: [[String]] = []
        let cancellable = combined.sessionsPublisher.sink { published.append($0.map(\.name)) }
        defer { cancellable.cancel() }
        combined.start()
        defer { combined.stop() }
        XCTAssertEqual(published.last?.sorted(), ["personal", "team"],
                       "every emission carries both directories, not one of them")
        XCTAssertFalse(published.contains(["personal"]),
                       "no emission ever drops the first directory's sessions")
    }

    /// An empty directory contributes nothing and hides nothing.
    func testADirectoryWithNoSessionsDoesNotBlankTheOthers() throws {
        let mine = try sessionsDirectory(named: "team", pid: ProcessInfo.processInfo.processIdentifier)
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("combined-empty-\(UUID().uuidString)")
        roots.append(empty)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let combined = CombinedClaudeSessionMonitor([monitor(mine), monitor(empty)])
        combined.start()
        defer { combined.stop() }
        XCTAssertEqual(combined.sessions.map(\.name), ["team"])
    }
}
