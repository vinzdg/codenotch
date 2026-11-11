import XCTest
@testable import Codenotch

@MainActor
final class UsageResetWatcherTests: XCTestCase {
    private var alerts: [UsageResetEvent] = []
    private var muted: Set<String> = []
    private var watcher: UsageResetWatcher!
    private var clock = Date(timeIntervalSince1970: 1_000)

    override func setUp() {
        super.setUp()
        alerts = []
        muted = []
        watcher = UsageResetWatcher(
            isMuted: { [weak self] in self?.muted.contains($0) ?? false },
            deliver: { [weak self] in self?.alerts.append($0) },
            now: { [weak self] in self?.clock ?? .distantPast }
        )
    }

    private func snapshot(_ id: String, _ name: String, _ fraction: Double,
                          resetsAt: Date? = nil,
                          label: String = "5-hour limit") -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: name, glyph: .claude, fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: label, usedFraction: fraction, resetsAt: resetsAt)],
            headlineID: "session"
        )
    }

    func testNoAlertOnInitialObservation() {
        watcher.observe([snapshot("claude", "Claude", 0.85)])
        XCTAssertTrue(alerts.isEmpty, "initial reading records baseline and does not alert")
    }

    /// At launch the store publishes the archived reading, marked stale, and
    /// the live one follows. A newer reset date between the two is not a reset
    /// that happened; it is the archive being old.
    func testAnArchivedReadingIsNotTheBaseline() {
        let old = Date(timeIntervalSince1970: 1_000_000)
        var archived = snapshot("claude", "Claude", 0.85, resetsAt: old)
        archived.status = .stale(since: old)
        clock = old.addingTimeInterval(3600)
        watcher.observe([archived])
        watcher.observe([snapshot("claude", "Claude", 0.10, resetsAt: old.addingTimeInterval(5 * 3600))])
        XCTAssertTrue(alerts.isEmpty, "the first live reading only records")

        // The next roll-over, seen live against live once the window has
        // elapsed, is announced.
        watcher.observe([snapshot("claude", "Claude", 0.60, resetsAt: old.addingTimeInterval(5 * 3600))])
        clock = old.addingTimeInterval(6 * 3600)
        watcher.observe([snapshot("claude", "Claude", 0.05, resetsAt: old.addingTimeInterval(10 * 3600))])
        XCTAssertEqual(alerts.count, 1)
    }

    func testAlertsWhenUsageDropsSignificantly() {
        watcher.observe([snapshot("claude", "Claude", 0.90)])
        watcher.observe([snapshot("claude", "Claude", 0.05)])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].providerID, "claude")
        XCTAssertEqual(alerts[0].providerName, "Claude")
        XCTAssertEqual(alerts[0].windowLabel, "5-hour limit")
        XCTAssertEqual(alerts[0].previousFraction, 0.90)
        XCTAssertEqual(alerts[0].currentFraction, 0.05)
    }

    func testAlertsWhenResetsAtRolledOver() {
        let date1 = Date(timeIntervalSince1970: 900)
        let date2 = Date(timeIntervalSince1970: 2_000)

        watcher.observe([snapshot("claude", "Claude", 0.40, resetsAt: date1)])
        watcher.observe([snapshot("claude", "Claude", 0.05, resetsAt: date2)])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].resetsAt, date2)
    }

    func testDoesNotAlertWhenFutureResetTimestampDriftsLater() {
        let firstDeadline = Date(timeIntervalSince1970: 2_000)
        let shiftedDeadline = Date(timeIntervalSince1970: 2_001)

        watcher.observe([snapshot("codex", "Codex", 0.29, resetsAt: firstDeadline)])
        watcher.observe([snapshot("codex", "Codex", 0.29, resetsAt: shiftedDeadline)])

        XCTAssertTrue(alerts.isEmpty)
    }

    func testDoesNotAlertForLargeDropBeforeKnownResetDeadline() {
        let deadline = Date(timeIntervalSince1970: 2_000)

        watcher.observe([snapshot("codex", "Codex", 0.51, resetsAt: deadline)])
        watcher.observe([snapshot("codex", "Codex", 0.29, resetsAt: deadline)])

        XCTAssertTrue(alerts.isEmpty)
    }

    /// The window's deadline passed and the fresh reading carries no reset
    /// date of its own: the drop is the only evidence, and it is enough.
    func testAlertsWhenTheDeadlinePassedAndTheNewWindowHasNoDate() {
        watcher.observe([snapshot("claude", "Claude", 0.80, resetsAt: Date(timeIntervalSince1970: 900))])
        watcher.observe([snapshot("claude", "Claude", 0.04, resetsAt: nil)])
        XCTAssertEqual(alerts.count, 1)
    }

    func testNoAlertForNegligibleFluctuation() {
        watcher.observe([snapshot("claude", "Claude", 0.05)])
        watcher.observe([snapshot("claude", "Claude", 0.01)])
        XCTAssertTrue(alerts.isEmpty, "negligible low-level fluctuation does not alert")
    }

    func testMutedProviderDoesNotAlert() {
        muted = ["claude"]
        watcher.observe([snapshot("claude", "Claude", 0.95)])
        watcher.observe([snapshot("claude", "Claude", 0.00)])
        XCTAssertTrue(alerts.isEmpty, "muted provider is silent")
    }

    func testMultipleProvidersTrackedIndependently() {
        watcher.observe([
            snapshot("claude", "Claude", 0.80),
            snapshot("cursor", "Cursor", 0.10)
        ])
        watcher.observe([
            snapshot("claude", "Claude", 0.02),
            snapshot("cursor", "Cursor", 0.70)
        ])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].providerID, "claude")

        watcher.observe([
            snapshot("claude", "Claude", 0.05),
            snapshot("cursor", "Cursor", 0.05)
        ])

        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts[1].providerID, "cursor")
    }
}

/// A hidden notch has nowhere to put the card, and used to swallow the alert
/// without a word — so the caller has to be able to tell, and reach for a
/// system notification instead.
@MainActor
final class ResetAlertVisibilityTests: XCTestCase {
    private let event = UsageResetEvent(
        providerID: "claude",
        providerName: "Claude",
        windowLabel: "5-hour limit",
        glyph: .claude,
        previousFraction: 0.95,
        currentFraction: 0.0,
        resetsAt: Date().addingTimeInterval(5 * 3600)
    )

    /// Deliberately only the hidden case. Showing a real panel here perturbs the
    /// arrival-animation timing `EdgeArrivalTests` measures, and the branch that
    /// matters — the one that used to lose the alert — is this one.
    func testAControllerWithNoPanelSaysItDidNotShow() {
        let controller = NotchWindowController()
        XCTAssertFalse(controller.showResetAlert(event, duration: 0.1))
        XCTAssertNil(controller.model.activeResetAlert)
    }
}
