import XCTest
@testable import Codenotch

/// Guards the crossing rule: 80% and 100% are announced once as they are
/// crossed, never twice while they stay crossed, and again only after the
/// window has genuinely rolled over.
@MainActor
final class ThresholdNotifierTests: XCTestCase {
    private var alerts: [ThresholdAlert] = []
    private var muted: Set<String> = []
    private var notifier: ThresholdNotifier!

    override func setUp() {
        super.setUp()
        alerts = []
        muted = []
        notifier = ThresholdNotifier(
            isMuted: { [weak self] in self?.muted.contains($0) ?? false },
            deliver: { [weak self] in self?.alerts.append($0) }
        )
    }

    private func snapshot(_ id: String, _ name: String, _ fraction: Double,
                          label: String = "Current session") -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: name, glyph: .claude, fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: label, usedFraction: fraction)],
            headlineID: "session"
        )
    }

    func testCrossingEightyAlertsOnce() {
        notifier.observe([snapshot("claude", "Claude", 0.5)])
        XCTAssertNil(alerts.first, "parked under the threshold is nobody's business")

        notifier.observe([snapshot("claude", "Claude", 0.82)])
        notifier.observe([snapshot("claude", "Claude", 0.91)])
        XCTAssertEqual(alerts.count, 1, "still crossing, not crossing again")
        XCTAssertEqual(alerts[0].threshold, 80)
        XCTAssertEqual(alerts[0].usedPercent, 82)
        XCTAssertEqual(alerts[0].windowLabel, "Current session")
    }

    func testCrossingHundredAfterEightyAlertsAgain() {
        notifier.observe([snapshot("claude", "Claude", 0.5)])
        notifier.observe([snapshot("claude", "Claude", 0.85)])
        notifier.observe([snapshot("claude", "Claude", 1.02)])
        XCTAssertEqual(alerts.map(\.threshold), [80, 100])
    }

    /// The archived reading published at launch is marked stale, and the live
    /// one that follows is the baseline, not a crossing.
    func testAnArchivedReadingIsNotTheBaseline() {
        var archived = snapshot("codex", "Codex", 0.5)
        archived.status = .stale(since: Date())
        notifier.observe([archived])
        notifier.observe([snapshot("codex", "Codex", 1.0)])
        XCTAssertTrue(alerts.isEmpty)
        notifier.observe([snapshot("codex", "Codex", 0.1)])
        notifier.observe([snapshot("codex", "Codex", 0.9)])
        XCTAssertEqual(alerts.map(\.threshold), [80])
    }

    /// The first reading is the baseline, whatever it says. After a restart it
    /// is the archived reading, often already spent, and announcing it rang
    /// "limit reached" on every launch.
    func testTheFirstReadingOnlyRecordsEvenAtTheLimit() {
        notifier.observe([snapshot("codex", "Codex", 1.0)])
        XCTAssertTrue(alerts.isEmpty, "a launch is not a crossing")

        // Still crossed: nothing to say. Rolled over and climbing again: news.
        notifier.observe([snapshot("codex", "Codex", 1.0)])
        XCTAssertTrue(alerts.isEmpty)
        notifier.observe([snapshot("codex", "Codex", 0.05)])
        notifier.observe([snapshot("codex", "Codex", 0.85)])
        XCTAssertEqual(alerts.map(\.threshold), [80])
    }

    /// A spent window that comes back is a new fact, not a re-announcement of
    /// the old one — so the memory clears and the next climb alerts again.
    func testARolledOverWindowAlertsAgain() {
        notifier.observe([snapshot("claude", "Claude", 0.2)])
        notifier.observe([snapshot("claude", "Claude", 0.9)])
        notifier.observe([snapshot("claude", "Claude", 0.1)])
        XCTAssertEqual(alerts.count, 1)
        notifier.observe([snapshot("claude", "Claude", 0.84)])
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts[1].threshold, 80)
    }

    func testMutedProvidersAreSilentButRemembered() {
        notifier.observe([snapshot("claude", "Claude", 0.1)])
        muted = ["claude"]
        notifier.observe([snapshot("claude", "Claude", 0.85)])
        XCTAssertTrue(alerts.isEmpty)

        // Unmuting must not replay the crossing that happened in the silence.
        muted = []
        notifier.observe([snapshot("claude", "Claude", 0.86)])
        XCTAssertTrue(alerts.isEmpty, "an old crossing replayed is noise, not news")

        // But the next real crossing still reaches the user.
        notifier.observe([snapshot("claude", "Claude", 1.0)])
        XCTAssertEqual(alerts.map(\.threshold), [100])
    }

    func testProvidersWithoutARingAreIgnored() {
        // A remaining-count window has no fraction, so there is nothing to
        // compare against a threshold.
        let window = LimitWindow(id: "q", label: "Free queries", remaining: 12)
        let snapshot = ProviderSnapshot(id: "p", displayName: "P", glyph: .third,
                                        fidelity: .official, status: .ok, windows: [window])
        notifier.observe([snapshot, snapshot])
        XCTAssertTrue(alerts.isEmpty)
    }

    func testSeveralProvidersAlertIndependently() {
        notifier.observe([
            snapshot("claude", "Claude", 0.3),
            snapshot("cursor", "Cursor", 0.4)
        ])
        notifier.observe([
            snapshot("claude", "Claude", 0.3),
            snapshot("cursor", "Cursor", 0.95)
        ])
        XCTAssertEqual(alerts.map(\.providerID), ["cursor"])
        notifier.observe([
            snapshot("claude", "Claude", 0.99),
            snapshot("cursor", "Cursor", 0.96)
        ])
        XCTAssertEqual(alerts.map(\.providerID), ["cursor", "claude"])
        XCTAssertEqual(alerts.last?.threshold, 80)
    }

    /// Spark at 100% is not a headline crossing. The notifier reads
    /// `usedFraction`, which is the declared headline window.
    func testCodexExtrasDoNotCountAsAHeadlineCrossing() {
        func snap(primary: Double, spark: Double) -> ProviderSnapshot {
            ProviderSnapshot(
                id: "codex", displayName: "Codex", glyph: .openai,
                fidelity: .official, status: .ok,
                windows: [
                    LimitWindow(id: "primary", label: "5h limit", usedFraction: primary),
                    LimitWindow(id: "spark", group: "Spark", label: "5h limit",
                                usedFraction: spark)
                ],
                headlineID: "primary"
            )
        }
        notifier.observe([snap(primary: 0.50, spark: 0.50)])
        notifier.observe([snap(primary: 0.50, spark: 1.00)])
        XCTAssertTrue(alerts.isEmpty, "Spark hitting 100% is not the Codex session")
        notifier.observe([snap(primary: 0.85, spark: 1.00)])
        XCTAssertEqual(alerts.map(\.threshold), [80])
        XCTAssertEqual(alerts[0].windowLabel, "5h limit")
    }
}
