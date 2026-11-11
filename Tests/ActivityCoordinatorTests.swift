import Combine
import XCTest
@testable import Codenotch

@MainActor
final class ActivityCoordinatorTests: XCTestCase {
    private final class Monitor: AgentActivityMonitor {
        @Published var sessions: [AgentSession] = []
        var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }
        var starts = 0
        var stops = 0
        func start() { starts += 1 }
        func stop() { stops += 1 }
    }

    func testOnlyConnectedMonitorsRunAndReapplyingDoesNotRestartThem() {
        let firstMonitor = Monitor(), secondMonitor = Monitor()
        let coordinator = ActivityCoordinator(
            monitors: ["a": firstMonitor, "b": secondMonitor]
        ) { _, _ in }
        coordinator.setEnabled(["a", "unknown"])
        coordinator.setEnabled(["a"])
        XCTAssertEqual(firstMonitor.starts, 1)
        XCTAssertEqual(secondMonitor.starts, 0)
        XCTAssertEqual(coordinator.activeIDs, ["a"])
        coordinator.setEnabled(["b"])
        XCTAssertEqual(firstMonitor.stops, 1)
        XCTAssertEqual(secondMonitor.starts, 1)
        coordinator.stop()
        coordinator.stop()
        XCTAssertEqual(secondMonitor.stops, 1)
    }

    func testDisconnectClearsSessionsAndIgnoresLateUpdatesAndBusyState() async throws {
        let monitor = Monitor()
        var delivered: [[AgentSession]] = []
        let coordinator = ActivityCoordinator(monitors: ["a": monitor]) { _, sessions in
            delivered.append(sessions)
        }
        coordinator.setEnabled(["a"])
        monitor.sessions = [AgentSession(id: "work", name: "Work", detail: "Working",
                                         state: .busy, waitingFor: nil, since: Date())]
        XCTAssertTrue(coordinator.isBusy)
        coordinator.setEnabled([])
        let countAfterDisconnect = delivered.count
        XCTAssertEqual(delivered.last, [])
        XCTAssertFalse(coordinator.isBusy)
        // Even a buggy/stopped monitor that publishes again cannot update the UI.
        monitor.sessions = monitor.sessions
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(delivered.count, countAfterDisconnect)
    }

    func testSupplementalSessionsMergeWithNativeActivity() async throws {
        let monitor = Monitor()
        var delivered: [AgentSession] = []
        let coordinator = ActivityCoordinator(monitors: ["a": monitor]) { _, sessions in
            delivered = sessions
        }
        coordinator.setEnabled(["a"])
        monitor.sessions = [AgentSession(id: "native", name: "Native", detail: "Working",
                                         state: .busy, waitingFor: nil, since: Date())]
        coordinator.setSupplementalSessions(
            providerID: "a",
            source: "pi",
            sessions: [AgentSession(id: "pi", name: "Pi", detail: "Working",
                                    state: .busy, waitingFor: nil, since: Date())]
        )
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(Set(delivered.map(\.id)), ["native", "pi"])
        XCTAssertTrue(coordinator.isBusy)
    }

    func testSupplementalOnlyProviderHonorsConnectionState() {
        var delivered: [AgentSession] = []
        let coordinator = ActivityCoordinator(monitors: [:]) { _, sessions in
            delivered = sessions
        }
        let session = AgentSession(id: "pi", name: "Pi", detail: "Working",
                                   state: .busy, waitingFor: nil, since: Date())

        coordinator.setSupplementalSessions(providerID: "glm", source: "pi", sessions: [session])
        XCTAssertTrue(delivered.isEmpty)
        coordinator.setEnabled(["glm"])
        coordinator.setSupplementalSessions(providerID: "glm", source: "pi", sessions: [session])
        XCTAssertEqual(delivered.map(\.id), ["pi"])
        XCTAssertTrue(coordinator.isBusy)
        coordinator.setEnabled([])
        XCTAssertEqual(delivered, [])
        XCTAssertFalse(coordinator.isBusy)
    }

    func testReconnectResubscribesAndPublishesAgain() async {
        let monitor = Monitor()
        let received = expectation(description: "Reconnected activity reaches the notch")
        let coordinator = ActivityCoordinator(monitors: ["a": monitor]) { _, sessions in
            if sessions.first?.id == "new" { received.fulfill() }
        }
        defer { coordinator.stop() }
        coordinator.setEnabled(["a"])
        coordinator.stop()
        coordinator.setEnabled(["a"])
        monitor.sessions = [AgentSession(id: "new", name: "New", detail: "Working",
                                         state: .busy, waitingFor: nil, since: Date())]
        await fulfillment(of: [received], timeout: 1)
        XCTAssertEqual(monitor.starts, 2)
    }
}
