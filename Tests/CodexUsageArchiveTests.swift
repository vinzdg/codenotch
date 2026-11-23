import XCTest
@testable import Codenotch

final class CodexUsageArchiveTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "CodexUsageArchiveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func snapshot(id: String = "codex",
                          windows: [LimitWindow]) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: "Codex", glyph: .openai,
            fidelity: .official, status: .ok,
            windows: windows
        )
    }

    private func roundTrip(_ snapshot: ProviderSnapshot,
                           defaults: UserDefaults? = nil) -> ProviderSnapshot? {
        let defaults = defaults ?? makeDefaults()
        UsageArchive(defaults: defaults).save([snapshot.id: (snapshot, Date())])
        return UsageArchive(defaults: defaults).load()[snapshot.id]?.snapshot
    }

    /// Spark is a live quota, not leftover rollout data. Reloading it after
    /// a relaunch is the archive's job.
    func testAnArchivedSparkWindowSurvivesRelaunch() {
        let restored = roundTrip(snapshot(windows: [
            LimitWindow(id: "primary", label: "5h limit", usedFraction: 0.2),
            LimitWindow(id: "spark", label: "Spark", usedFraction: 0.5)
        ]))
        XCTAssertEqual(restored?.windows.map(\.id), ["primary", "spark"])
        XCTAssertEqual(restored?.windows.last?.usedFraction, 0.5)
    }

    /// Old rollout quota ids are gone from the live provider. Restoring them
    /// would show numbers the UI no longer has a home for.
    func testAnArchivedRolloutQuotaIsSkipped() {
        XCTAssertNil(roundTrip(snapshot(windows: [
            LimitWindow(id: "rollout-foo", label: "Rollout", usedFraction: 0.9)
        ])))
    }

    /// A leftover rollout quota must not take a live Spark reading with it.
    func testASparkWindowSurvivesBesideAStrippedRolloutQuota() {
        let restored = roundTrip(snapshot(windows: [
            LimitWindow(id: "spark", label: "Spark", usedFraction: 0.5),
            LimitWindow(id: "rollout-foo", label: "Rollout", usedFraction: 0.9)
        ]))
        XCTAssertEqual(restored?.windows.map(\.id), ["spark"])
        XCTAssertEqual(restored?.windows.first?.usedFraction, 0.5)
    }

    func testLiveWindowsOnAnExtraProfileSurviveAndUnknownOnesDoNot() {
        let work = "codex-work"
        let spark = roundTrip(snapshot(id: work, windows: [
            LimitWindow(id: "spark-secondary", label: "Spark weekly", usedFraction: 0.1),
            LimitWindow(id: "code-review", label: "Code review", usedFraction: 0.3),
            LimitWindow(id: "code-review-secondary", label: "Code review weekly",
                        usedFraction: 0.4)
        ]))
        XCTAssertEqual(spark?.windows.map(\.id),
                       ["spark-secondary", "code-review", "code-review-secondary"])

        let mixed = roundTrip(snapshot(id: work, windows: [
            LimitWindow(id: "primary", label: "5h limit", usedFraction: 0.2),
            LimitWindow(id: "rollout-foo", label: "Rollout", usedFraction: 0.9)
        ]))
        XCTAssertEqual(mixed?.windows.map(\.id), ["primary"])
        XCTAssertEqual(mixed?.windows.first?.usedFraction, 0.2)

        XCTAssertNil(roundTrip(snapshot(id: work, windows: [
            LimitWindow(id: "rollout-foo", label: "Rollout", usedFraction: 0.9)
        ])))
    }

    /// The Codex filter is keyed on the provider id. A Claude session window
    /// must not be mistaken for leftover rollout data.
    func testANonCodexReadingIsLeftAlone() {
        let restored = roundTrip(snapshot(id: "claude", windows: [
            LimitWindow(id: "session", label: "Current session", usedFraction: 0.4)
        ]))
        XCTAssertEqual(restored?.windows.map(\.id), ["session"])
    }
}

/// A DeepSeek balance archived before the ring's label was shortened carries
/// "¥51.83 left" under the ring, which the notch clips. Relaunching on the
/// new build must not open on that — the first read may be a minute away, or
/// fail.
@MainActor
final class DeepSeekBalanceArchiveTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "DeepSeekBalanceArchiveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func restored(usedText: String, detail: String?) -> LimitWindow? {
        let window = LimitWindow(id: "balance", label: "Credit balance", used: 0,
                                 usedText: usedText, detail: detail,
                                 bandOverride: .ample, prefersUsedText: true)
        let snapshot = ProviderSnapshot(id: "deepseek", displayName: "DeepSeek", glyph: .deepseek,
                                        fidelity: .derived, status: .ok, windows: [window])
        let defaults = makeDefaults()
        UsageArchive(defaults: defaults).save([snapshot.id: (snapshot, Date())])
        return UsageArchive(defaults: defaults).load()[snapshot.id]?.snapshot.windows.first
    }

    func testAnOldLabelIsRebuiltFromTheExactDetailLine() {
        let english = restored(usedText: "¥51.83 left", detail: "¥51.83 left")
        XCTAssertEqual(english?.usedText, "¥51")
        XCTAssertEqual(english?.detail, "¥51.83 left", "the card keeps the exact figure")

        let chinese = restored(usedText: "剩余 ¥51.39", detail: "剩余 ¥50.26")
        XCTAssertEqual(chinese?.usedText, "¥50", "read from the detail, not the stale label")
        XCTAssertEqual(chinese?.detail, "剩余 ¥50.26")

        let usd = restored(usedText: "$14.28 left", detail: "$14.28 left")
        XCTAssertEqual(usd?.usedText, "$14")
    }

    func testALabelTheNewFormatterAlreadyWroteIsUnchanged() {
        let fresh = restored(usedText: "¥51", detail: "¥51.83 left")
        XCTAssertEqual(fresh?.usedText, "¥51")
    }

    /// Anything that does not look like a money line is left alone rather
    /// than guessed at — an unparseable label is the old behaviour, not a
    /// new wrong number.
    func testAnUnreadableDetailLeavesTheWindowAlone() {
        XCTAssertEqual(restored(usedText: "¥51.83 left", detail: nil)?.usedText, "¥51.83 left")
        XCTAssertEqual(restored(usedText: "odd", detail: "No reading")?.usedText, "odd")
    }
}
