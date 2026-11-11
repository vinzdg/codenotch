import XCTest
@testable import Codenotch

@MainActor
final class UsageLimitWatcherTests: XCTestCase {
    private var alerts: [UsageAlertEvent] = []
    private var muted: Set<String> = []
    private var watcher: UsageLimitWatcher!

    override func setUp() {
        super.setUp()
        alerts = []
        muted = []
        watcher = UsageLimitWatcher(
            isMuted: { [weak self] in self?.muted.contains($0) ?? false },
            deliver: { [weak self] in self?.alerts.append($0) }
        )
    }

    private func snapshot(
        _ id: String,
        _ name: String,
        sessionFraction: Double,
        weeklyFraction: Double = 0.50,
        sessionResetsAt: Date? = nil,
        weeklyResetsAt: Date? = nil,
        block: UsageBlock? = nil
    ) -> ProviderSnapshot {
        var windows = [
            LimitWindow(id: "session", label: "5-hour limit", usedFraction: sessionFraction, resetsAt: sessionResetsAt)
        ]
        if weeklyFraction > 0 {
            windows.append(
                LimitWindow(id: "weekly", label: "Weekly limit", usedFraction: weeklyFraction, resetsAt: weeklyResetsAt)
            )
        }
        return ProviderSnapshot(
            id: id,
            displayName: name,
            glyph: .claude,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: "session",
            weeklyID: weeklyFraction > 0 ? "weekly" : nil,
            block: block
        )
    }

    func testNoAlertOnInitialObservation() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.0, weeklyFraction: 1.0)])
        XCTAssertTrue(alerts.isEmpty, "baseline observation records state and does not trigger false alerts on launch")
    }

    /// The store's first publication for a provider can be a placeholder with
    /// no window at all. Counting that as the baseline made the first real
    /// reading a "crossing", and a Codex already spent at launch was announced.
    func testAPlaceholderIsNotTheBaseline() {
        let placeholder = ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai,
                                           fidelity: .official, status: .stale(since: Date()), windows: [])
        watcher.observe([placeholder])
        watcher.observe([snapshot("codex", "Codex", sessionFraction: 1.0, weeklyFraction: 1.0)])
        XCTAssertTrue(alerts.isEmpty, "the first reading with a window is the baseline")

        watcher.observe([snapshot("codex", "Codex", sessionFraction: 0.2, weeklyFraction: 0.2)])
        watcher.observe([snapshot("codex", "Codex", sessionFraction: 1.0, weeklyFraction: 0.2)])
        XCTAssertEqual(alerts.map(\.kind), [.sessionLimitReached])
    }

    /// The archived reading the store publishes at launch is marked stale and
    /// is not a baseline; a limit spent between the archive and the first live
    /// reading is not announced.
    func testAnArchivedReadingIsNotTheBaseline() {
        var archived = snapshot("codex", "Codex", sessionFraction: 0.9)
        archived.status = .stale(since: Date())
        watcher.observe([archived])
        watcher.observe([snapshot("codex", "Codex", sessionFraction: 1.0)])
        XCTAssertTrue(alerts.isEmpty)
    }

    /// The weekly window can arrive a fetch after the session one. Its own
    /// first reading is its baseline, not the provider's.
    func testAWeeklyWindowThatArrivesSpentIsSilent() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.5, weeklyFraction: 0)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.5, weeklyFraction: 1.0)])
        XCTAssertTrue(alerts.isEmpty)
    }

    func testAlertsWhenSessionLimitReached() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.80)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00)])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].kind, .sessionLimitReached)
        XCTAssertEqual(alerts[0].providerID, "claude")
        XCTAssertEqual(alerts[0].providerName, "Claude")
        XCTAssertEqual(alerts[0].currentFraction, 1.00)
    }

    func testAlertsWhenWeeklyLimitReached() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.50, weeklyFraction: 0.80)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.50, weeklyFraction: 1.00)])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].kind, .weeklyLimitReached)
        XCTAssertEqual(alerts[0].providerID, "claude")
        XCTAssertEqual(alerts[0].currentFraction, 1.00)
    }

    func testAlertsWhenBlocked() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.50)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.50, block: UsageBlock(reason: "Rate limited", resetsAt: nil))])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].kind, .sessionLimitReached)
    }

    /// A spent week blocks the headline with it, but the session card must
    /// not claim the session itself spent: the weekly alert is the accurate
    /// one.
    func testWeeklyCausedBlockDoesNotFireSessionAlert() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.50, weeklyFraction: 0.80)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.50, weeklyFraction: 1.00,
                                  block: UsageBlock(reason: "Weekly limit reached", resetsAt: nil,
                                                    isWeeklyExhaustion: true))])
        XCTAssertEqual(alerts.map(\.kind), [.weeklyLimitReached])
    }

    /// Under the daily pace derivation the weekly id points at the session
    /// window, so no weekly alert fires — and the weekly-caused block must
    /// not fire a session one with the wrong copy either. Silent, as before.
    func testWeeklyCausedBlockUnderPaceDerivationStaysSilent() {
        let windows = [
            LimitWindow(id: DailyPace.windowID, label: "Daily pace", usedFraction: 0.5),
            LimitWindow(id: "session", label: "Session", usedFraction: 0.6),
        ]
        func paced(block: UsageBlock?) -> ProviderSnapshot {
            ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                             fidelity: .official, status: .ok, windows: windows,
                             headlineID: DailyPace.windowID, weeklyID: "session", block: block)
        }
        watcher.observe([paced(block: nil)])
        watcher.observe([paced(block: UsageBlock(reason: "Weekly limit reached", resetsAt: nil,
                                                 isWeeklyExhaustion: true))])
        XCTAssertTrue(alerts.isEmpty)
    }

    func testNoRepeatAlertWhileExhausted() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.80)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00)])
        XCTAssertEqual(alerts.count, 1)

        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.02)])
        XCTAssertEqual(alerts.count, 1, "does not spam repeated alerts while remaining exhausted")
    }

    func testReArmsWhenUsageDropsBelowThreshold() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.80)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00)])
        XCTAssertEqual(alerts.count, 1)

        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.90)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00)])
        XCTAssertEqual(alerts.count, 2, "re-arms alert when usage drops and reaches limit again")
    }

    func testReArmsWhenResetsAtRollsOver() {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 5000)

        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.80, sessionResetsAt: date1)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00, sessionResetsAt: date1)])
        XCTAssertEqual(alerts.count, 1)

        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00, sessionResetsAt: date2)])
        XCTAssertEqual(alerts.count, 2, "re-arms when window rolls over to new resetsAt")
    }

    /// A countdown-based reset date drifts forward a few seconds on every
    /// refresh. While the window has not elapsed that is the same window, and
    /// a limit that stays spent must not be announced again on every fetch.
    func testNoRepeatAlertWhileResetDateDrifts() {
        let resetsAt = Date().addingTimeInterval(3 * 86_400)

        watcher.observe([snapshot("codex", "Codex", sessionFraction: 0.50, weeklyFraction: 0.90, weeklyResetsAt: resetsAt)])
        watcher.observe([snapshot("codex", "Codex", sessionFraction: 0.50, weeklyFraction: 1.00, weeklyResetsAt: resetsAt)])
        XCTAssertEqual(alerts.map(\.kind), [.weeklyLimitReached])

        for drift in 1...5 {
            watcher.observe([snapshot("codex", "Codex", sessionFraction: 0.50, weeklyFraction: 1.00,
                                      weeklyResetsAt: resetsAt.addingTimeInterval(Double(drift)))])
        }
        XCTAssertEqual(alerts.count, 1, "a drifting reset date is not a new window")
    }

    func testMutedProviderDoesNotAlert() {
        muted = ["claude"]
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.80)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00)])
        XCTAssertTrue(alerts.isEmpty, "muted provider delivers no limit alerts")
    }

    func testTracksMultipleProvidersIndependently() {
        watcher.observe([
            snapshot("claude", "Claude", sessionFraction: 0.50),
            snapshot("cursor", "Cursor", sessionFraction: 0.50)
        ])

        watcher.observe([
            snapshot("claude", "Claude", sessionFraction: 1.00),
            snapshot("cursor", "Cursor", sessionFraction: 0.60)
        ])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].providerID, "claude")

        watcher.observe([
            snapshot("claude", "Claude", sessionFraction: 1.00),
            snapshot("cursor", "Cursor", sessionFraction: 1.00)
        ])
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts[1].providerID, "cursor")
    }

    /// Codex extras reuse the same "5h limit" label as the headline. The
    /// watcher must still key off the declared headline/weekly ids, or Spark
    /// hitting 100% would fire a session-limit card.
    func testCodexExtrasAtLimitDoNotFireSessionOrWeeklyCards() {
        func snap(session: Double, weekly: Double, spark: Double) -> ProviderSnapshot {
            ProviderSnapshot(
                id: "codex", displayName: "Codex", glyph: .openai,
                fidelity: .official, status: .ok,
                windows: [
                    LimitWindow(id: "primary", label: "5h limit", usedFraction: session),
                    LimitWindow(id: "secondary", label: "Weekly limit", usedFraction: weekly),
                    LimitWindow(id: "spark", group: "Spark", label: "5h limit",
                                usedFraction: spark),
                    LimitWindow(id: "spark-secondary", group: "Spark", label: "Weekly limit",
                                usedFraction: 1.0),
                    LimitWindow(id: "code-review", group: "Code review", label: "Weekly limit",
                                usedFraction: 1.0)
                ],
                headlineID: "primary",
                weeklyID: "secondary"
            )
        }

        watcher.observe([snap(session: 0.50, weekly: 0.40, spark: 0.80)])
        watcher.observe([snap(session: 0.50, weekly: 0.40, spark: 1.00)])
        XCTAssertTrue(alerts.isEmpty, "Spark and code review at 100% are not the session")

        watcher.observe([snap(session: 1.00, weekly: 0.40, spark: 1.00)])
        XCTAssertEqual(alerts.map(\.kind), [.sessionLimitReached])
        XCTAssertEqual(alerts[0].windowLabel, "5h limit")

        watcher.observe([snap(session: 1.00, weekly: 1.00, spark: 1.00)])
        XCTAssertEqual(alerts.map(\.kind), [.sessionLimitReached, .weeklyLimitReached])
    }
}
