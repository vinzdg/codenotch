import Combine
import XCTest
@testable import Codenotch

@MainActor
final class OpenCodeActivityTests: XCTestCase {
    private let instance = "00000000-0000-4000-8000-000000000001"
    private let clock: Double = 1_800_000_000_000

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func record(_ state: OpenCodeActivityRecord.State, id: String = "root", parent: String? = nil,
                        provider: String = "llamacpp", model: String = "qwen") -> OpenCodeActivityRecord {
        OpenCodeActivityRecord(sessionID: id, parentID: parent, title: "Local task",
            providerID: provider, modelID: model, state: state,
            reason: state == .waiting ? "approval" : nil, since: clock)
    }

    private func write(_ states: [OpenCodeActivityRecord], to root: URL, first: Int = 1,
                       current: [OpenCodeActivityRecord]? = nil, version: Int = 1) throws {
        let events = states.enumerated().map {
            OpenCodeActivityEnvelope.Event(sequence: first + $0.offset, at: clock, session: $0.element)
        }
        var latest: [String: OpenCodeActivityRecord] = [:]
        for state in states {
            if state.state == .ended { latest.removeValue(forKey: state.sessionID) }
            else { latest[state.sessionID] = state }
        }
        let envelope = OpenCodeActivityEnvelope(version: version, instanceID: instance, pid: 123,
            startedAt: clock - 1000, sequence: first + states.count - 1,
            sessions: current ?? Array(latest.values), events: events)
        try JSONEncoder().encode(envelope).write(to: root.appendingPathComponent("instance.json"), options: .atomic)
    }

    private func monitor(_ directory: URL, provider: String = "llamacpp", model: String = "qwen",
                         fresh: Bool = false) -> OpenCodeActivityMonitor {
        OpenCodeActivityMonitor(providerID: provider, modelID: model, directory: directory,
            beganAt: Date(timeIntervalSince1970: (clock + (fresh ? -100 : 100)) / 1000),
            isAlive: { _, _ in true })
    }

    func testReplaysFastTransitionsThroughTheExistingCompletionWatcher() throws {
        let root = try directory()
        let monitor = monitor(root)
        var watcher = SessionCompletionWatcher()
        var reasons: [SessionCompletionWatcher.Reason] = []
        let subscription = monitor.sessionsPublisher.sink {
            reasons += watcher.absorb(["endpoint": $0]).map(\.reason)
        }
        defer { subscription.cancel() }
        try write([record(.busy)], to: root)
        monitor.rescan()
        try write([record(.busy), record(.waiting), record(.busy), record(.idle)], to: root)
        monitor.rescan()
        XCTAssertEqual(reasons, [.blocked, .finished])
        monitor.rescan()
        XCTAssertEqual(reasons, [.blocked, .finished], "unchanged file must not replay")
        XCTAssertEqual(monitor.sessions.first?.processID, 123)
    }

    func testNewTurnThatFinishesBeforeTheFirstTickIsStillAnnounced() throws {
        let root = try directory()
        let monitor = monitor(root, fresh: true)
        var watcher = SessionCompletionWatcher()
        var reasons: [SessionCompletionWatcher.Reason] = []
        let subscription = monitor.sessionsPublisher.sink {
            reasons += watcher.absorb(["endpoint": $0]).map(\.reason)
        }
        defer { subscription.cancel() }
        try write([record(.busy), record(.idle)], to: root)
        monitor.rescan()
        XCTAssertEqual(reasons, [.finished])
    }

    func testLaunchHistoryIsSeededWithoutAnnouncements() throws {
        let root = try directory()
        try write([record(.busy), record(.waiting), record(.idle)], to: root)
        let monitor = monitor(root)
        var watcher = SessionCompletionWatcher()
        var events: [SessionCompletionWatcher.Event] = []
        let subscription = monitor.sessionsPublisher.sink { events += watcher.absorb(["endpoint": $0]) }
        defer { subscription.cancel() }
        monitor.rescan()
        XCTAssertEqual(monitor.sessions.first?.state, .idle)
        XCTAssertTrue(events.isEmpty)
    }

    func testJournalGapReseedsInsteadOfClaimingCompletion() throws {
        let root = try directory()
        let monitor = monitor(root)
        var watcher = SessionCompletionWatcher()
        var events: [SessionCompletionWatcher.Event] = []
        let subscription = monitor.sessionsPublisher.sink { events += watcher.absorb(["endpoint": $0]) }
        defer { subscription.cancel() }
        try write([record(.busy)], to: root)
        monitor.rescan()
        try write([record(.idle)], to: root, first: 100)
        monitor.rescan()
        XCTAssertEqual(monitor.sessions.first?.state, .idle)
        XCTAssertTrue(events.isEmpty)
    }

    func testErrorsAndMissingFilesAreSilent() throws {
        let root = try directory()
        let monitor = monitor(root)
        var watcher = SessionCompletionWatcher()
        var events: [SessionCompletionWatcher.Event] = []
        let subscription = monitor.sessionsPublisher.sink { events += watcher.absorb(["endpoint": $0]) }
        defer { subscription.cancel() }
        try write([record(.busy)], to: root)
        monitor.rescan()
        try write([record(.busy), record(.ended)], to: root)
        monitor.rescan()
        XCTAssertTrue(monitor.sessions.isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("instance.json"))
        monitor.rescan()
        XCTAssertTrue(events.isEmpty)
    }

    func testDeadProcessAndInvalidFilesCannotLeaveStaleActivity() throws {
        let root = try directory()
        try write([record(.waiting)], to: root)
        let dead = OpenCodeActivityMonitor(providerID: "llamacpp", directory: root, isAlive: { _, _ in false })
        dead.rescan()
        XCTAssertTrue(dead.sessions.isEmpty)
        let monitor = monitor(root)
        monitor.rescan()
        XCTAssertEqual(monitor.sessions.first?.state, .waiting)
        try write([record(.busy)], to: root, version: 999)
        monitor.rescan()
        XCTAssertTrue(monitor.sessions.isEmpty)
        try Data("{partial".utf8).write(to: root.appendingPathComponent("instance.json"))
        monitor.rescan()
        XCTAssertTrue(monitor.sessions.isEmpty)
    }

    func testProviderAndModelAreMatchedExplicitly() throws {
        let root = try directory()
        try write([record(.busy)], to: root)
        let otherProvider = monitor(root, provider: "google")
        let otherModel = monitor(root, model: "different")
        let correct = monitor(root)
        [otherProvider, otherModel, correct].forEach { $0.rescan() }
        XCTAssertTrue(otherProvider.sessions.isEmpty)
        XCTAssertTrue(otherModel.sessions.isEmpty)
        XCTAssertEqual(correct.sessions.count, 1)
    }

    func testOldInvalidFilesDoNotDisplaceALiveProducer() throws {
        let root = try directory()
        for index in 0..<70 {
            let url = root.appendingPathComponent("aaa-old-\(index).json")
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: url.path)
        }
        try write([record(.busy)], to: root)
        let monitor = monitor(root)
        monitor.rescan()
        XCTAssertEqual(monitor.sessions.first?.state, .busy)
    }

    func testChildWaitIsFoldedIntoRootAndChildCompletionDoesNotFinishRoot() throws {
        let root = try directory()
        let monitor = monitor(root)
        let parent = record(.busy)
        let child = record(.waiting, id: "child", parent: "root")
        try write([parent, child], to: root)
        monitor.rescan()
        XCTAssertEqual(monitor.sessions.count, 1)
        XCTAssertEqual(monitor.sessions.first?.state, .waiting)
        try write([parent, child, record(.idle, id: "child", parent: "root")], to: root)
        monitor.rescan()
        XCTAssertEqual(monitor.sessions.first?.state, .busy)
    }

    func testLegacyEndpointsStayOptedOutAndMappingSurvivesEncoding() throws {
        var endpoint = CustomEndpoint(name: "Local", baseURL: "http://localhost:8080/v1")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(CustomEndpoint.self, from: encoder.encode(endpoint)).openCodeProviderID)
        endpoint.openCodeProviderID = "llamacpp"
        XCTAssertEqual(try decoder.decode(CustomEndpoint.self, from: encoder.encode(endpoint)).openCodeProviderID, "llamacpp")
    }

    func testInstallerBundlesPluginAndPreservesAnExistingFile() throws {
        let root = try directory()
        let existing = Data("// user customization".utf8)
        try existing.write(to: root.appendingPathComponent("codenotch.js"))
        try OpenCodePluginInstaller.install(directory: root)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.pathExtension == "backup" })
        XCTAssertEqual(try Data(contentsOf: backup), existing)
        let installed = try String(contentsOf: root.appendingPathComponent("codenotch.js"), encoding: .utf8)
        XCTAssertTrue(installed.contains("permission.v2.asked"))
        try OpenCodePluginInstaller.install(directory: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }
}
