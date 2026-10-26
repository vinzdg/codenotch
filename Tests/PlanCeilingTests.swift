import XCTest
@testable import Codenotch

final class PlanCeilingTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "PlanCeilingTests.\(UUID().uuidString)")!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        defaults = nil
        super.tearDown()
    }

    // MARK: - PlanCeiling calculation

    func testCeilingInferenceProvidesHeadroom() {
        XCTAssertEqual(PlanCeiling.infer(from: 0), 0)
        XCTAssertEqual(PlanCeiling.infer(from: -5), 0)

        // 40 * 1.25 = 50 -> 50
        XCTAssertEqual(PlanCeiling.infer(from: 40), 50)

        // 100 * 1.25 = 125 -> 150
        XCTAssertEqual(PlanCeiling.infer(from: 100), 150)

        // 800 * 1.25 = 1000 -> 1000
        XCTAssertEqual(PlanCeiling.infer(from: 800), 1000)

        // 8,000 * 1.25 = 10,000 -> 10,000
        XCTAssertEqual(PlanCeiling.infer(from: 8_000), 10_000)

        // 10,000 * 1.25 = 12,500 -> 20,000
        XCTAssertEqual(PlanCeiling.infer(from: 10_000), 20_000)
    }

    func testCleanRoundingIncrements() {
        XCTAssertEqual(PlanCeiling.roundToCleanIncrement(7), 7)
        XCTAssertEqual(PlanCeiling.roundToCleanIncrement(23), 25)
        XCTAssertEqual(PlanCeiling.roundToCleanIncrement(78), 80)
        XCTAssertEqual(PlanCeiling.roundToCleanIncrement(142), 150)
        XCTAssertEqual(PlanCeiling.roundToCleanIncrement(640), 700)
        XCTAssertEqual(PlanCeiling.roundToCleanIncrement(4_200), 5_000)
        XCTAssertEqual(PlanCeiling.roundToCleanIncrement(42_000), 50_000)
        XCTAssertEqual(PlanCeiling.roundToCleanIncrement(420_000), 500_000)
    }

    // MARK: - Preferences Plan Ceilings

    @MainActor
    func testDefaultPlanCeilingPreferences() {
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.planCeilingMode, .hybrid)
        XCTAssertEqual(prefs.ceilingWarningThreshold, 80)
        XCTAssertTrue(prefs.manualPlanCeilings.isEmpty)
        XCTAssertTrue(prefs.observedPeakUsage.isEmpty)
    }

    @MainActor
    func testRecordingPeakUsage() {
        let prefs = Preferences(defaults: defaults)
        prefs.recordPeakUsage(providerID: "gemini-api", used: 10_000)
        XCTAssertEqual(prefs.observedPeakUsage["gemini-api"], 10_000)

        // Lower usage does not lower the peak
        prefs.recordPeakUsage(providerID: "gemini-api", used: 5_000)
        XCTAssertEqual(prefs.observedPeakUsage["gemini-api"], 10_000)

        // Higher usage increases the peak
        prefs.recordPeakUsage(providerID: "gemini-api", used: 25_000)
        XCTAssertEqual(prefs.observedPeakUsage["gemini-api"], 25_000)

        // Zero or negative usage is ignored
        prefs.recordPeakUsage(providerID: "gemini-api", used: 0)
        XCTAssertEqual(prefs.observedPeakUsage["gemini-api"], 25_000)
    }

    @MainActor
    func testHybridEffectiveCeilingPrefersManualOverride() {
        let prefs = Preferences(defaults: defaults)
        prefs.planCeilingMode = .hybrid

        // No peak, no manual -> nil
        let initial = prefs.effectiveCeiling(for: "gemini-api")
        XCTAssertNil(initial.ceiling)
        XCTAssertFalse(initial.isInferred)

        // Record peak -> inferred ceiling
        prefs.recordPeakUsage(providerID: "gemini-api", used: 8_000)
        let inferred = prefs.effectiveCeiling(for: "gemini-api")
        XCTAssertEqual(inferred.ceiling, 10_000)
        XCTAssertTrue(inferred.isInferred)

        // Explicit manual override wins in hybrid mode
        prefs.setManualCeiling(50_000, for: "gemini-api")
        let overridden = prefs.effectiveCeiling(for: "gemini-api")
        XCTAssertEqual(overridden.ceiling, 50_000)
        XCTAssertFalse(overridden.isInferred)

        // Clearing manual override reverts to inferred
        prefs.setManualCeiling(nil, for: "gemini-api")
        let reverted = prefs.effectiveCeiling(for: "gemini-api")
        XCTAssertEqual(reverted.ceiling, 10_000)
        XCTAssertTrue(reverted.isInferred)
    }

    @MainActor
    func testManualOnlyModeIgnoresPeak() {
        let prefs = Preferences(defaults: defaults)
        prefs.planCeilingMode = .manual
        prefs.recordPeakUsage(providerID: "gemini-api", used: 8_000)

        // In manual mode, peak usage is ignored if no manual ceiling is provided
        let result = prefs.effectiveCeiling(for: "gemini-api")
        XCTAssertNil(result.ceiling)
        XCTAssertFalse(result.isInferred)

        prefs.setManualCeiling(15_000, for: "gemini-api")
        let manualResult = prefs.effectiveCeiling(for: "gemini-api")
        XCTAssertEqual(manualResult.ceiling, 15_000)
        XCTAssertFalse(manualResult.isInferred)
    }

    @MainActor
    func testInferredOnlyModeIgnoresManual() {
        let prefs = Preferences(defaults: defaults)
        prefs.planCeilingMode = .inferred
        prefs.setManualCeiling(50_000, for: "gemini-api")
        prefs.recordPeakUsage(providerID: "gemini-api", used: 8_000)

        // In inferred-only mode, manual override is ignored in favor of peak calculation
        let result = prefs.effectiveCeiling(for: "gemini-api")
        XCTAssertEqual(result.ceiling, 10_000)
        XCTAssertTrue(result.isInferred)
    }

    @MainActor
    func testStoredEffectiveCeilingOffMainActor() {
        let prefs = Preferences(defaults: defaults)
        prefs.recordPeakUsage(providerID: "gemini-api", used: 8_000)

        // Off-actor static reader
        let stored = Preferences.storedEffectiveCeiling(for: "gemini-api", defaults: defaults)
        XCTAssertEqual(stored, 10_000)

        prefs.setManualCeiling(25_000, for: "gemini-api")
        let storedManual = Preferences.storedEffectiveCeiling(for: "gemini-api", defaults: defaults)
        XCTAssertEqual(storedManual, 25_000)
    }

    // MARK: - ThresholdNotifier with custom warning threshold

    @MainActor
    func testThresholdNotifierHonoursCustomWarningThreshold() {
        var alerts: [ThresholdAlert] = []
        var thresholdValue = 90
        let notifier = ThresholdNotifier(
            warningThreshold: { thresholdValue },
            isMuted: { _ in false },
            deliver: { alerts.append($0) }
        )

        let makeSnapshot: (Double) -> ProviderSnapshot = { fraction in
            ProviderSnapshot(
                id: "gemini-api", displayName: "Gemini API", glyph: .geminiSpark,
                fidelity: .manual, status: .ok,
                windows: [LimitWindow(id: "month", label: "Month", usedFraction: fraction)],
                headlineID: "month"
            )
        }

        // At 85%, does NOT alert since threshold is 90
        notifier.observe([makeSnapshot(0.85)])
        XCTAssertTrue(alerts.isEmpty)

        // At 92%, alerts for 90% threshold
        notifier.observe([makeSnapshot(0.92)])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].threshold, 90)
        XCTAssertEqual(alerts[0].usedPercent, 92)

        // At 100%, alerts again for 100% threshold
        notifier.observe([makeSnapshot(1.0)])
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts[1].threshold, 100)
    }
}
