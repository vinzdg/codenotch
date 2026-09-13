import XCTest
@testable import Codenotch

/// The rename from UsageNotch to Codenotch moved every setting into a new,
/// empty defaults domain — the migration is the difference between a rename
/// and what looks like a reset, so it is pinned here. (Round-trip and
/// first-launch basics live with the other PreferencesTests.)
@MainActor
final class PreferencesMigrationTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "PreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func setOldDomain(_ values: [String: Any], from name: String) {
        let old = UserDefaults(suiteName: name)!
        for (key, value) in values { old.set(value, forKey: key) }
        old.synchronize()
    }

    // MARK: Migration

    func testSettingsSurviveTheRename() {
        let (fresh, freshName) = makeDefaults()
        let oldName = "PreferencesTests.old.\(UUID().uuidString)"
        setOldDomain(["hiddenProviders": ["glm"], "notchVisibility": "alwaysShow"],
                     from: oldName)

        Preferences.migrateFromPreviousName(into: fresh, from: oldName)

        let preferences = Preferences(defaults: fresh)
        XCTAssertFalse(preferences.isConnected("glm"))
        XCTAssertTrue(preferences.isConnected("claude"))
        XCTAssertEqual(preferences.notchVisibility, .alwaysShow)
    }

    /// Once this copy has launched, nothing may be copied again: a stale old
    /// domain beside a live one must never overwrite newer choices.
    func testMigrationRunsOnce() {
        let (fresh, _) = makeDefaults()
        let oldName = "PreferencesTests.old.\(UUID().uuidString)"
        setOldDomain(["notchVisibility": "alwaysShow"], from: oldName)

        Preferences.migrateFromPreviousName(into: fresh, from: oldName)
        let preferences = Preferences(defaults: fresh)
        preferences.notchVisibility = .hidden

        Preferences.migrateFromPreviousName(into: fresh, from: oldName)
        XCTAssertEqual(preferences.notchVisibility, .hidden)
    }

    func testAnEmptyOldDomainMigratesNothing() {
        let (fresh, _) = makeDefaults()
        let oldName = "PreferencesTests.old.\(UUID().uuidString)"
        Preferences.migrateFromPreviousName(into: fresh, from: oldName)
        let preferences = Preferences(defaults: fresh)
        XCTAssertEqual(preferences.notchVisibility, .onHover)
    }

    // MARK: Defaults

    func testAFirstLaunchReadsTheDesignedDefaults() {
        let (fresh, _) = makeDefaults()
        let preferences = Preferences(defaults: fresh)
        XCTAssertTrue(preferences.isFirstLaunch)
        XCTAssertEqual(preferences.notchVisibility, .onHover)
        XCTAssertEqual(preferences.appPresence, .dock)
        XCTAssertEqual(preferences.notchEdge, .right)
        XCTAssertEqual(preferences.notchSize, .medium)
        XCTAssertEqual(preferences.weeklyRing, .off)
        XCTAssertTrue(preferences.isConnected("claude"))
        XCTAssertTrue(preferences.isConnected("codex"))
        XCTAssertTrue(preferences.isConnected("claude-work"))
        XCTAssertFalse(preferences.isConnected("cursor"))
        XCTAssertFalse(preferences.isConnected("glm"))
        XCTAssertTrue(preferences.deepSeekPricingEnabled)
        XCTAssertEqual(preferences.deepSeekPricingSchedule, .current)
    }

    func testAFirstLaunchSeedsClaudeAndCodexOnceDiscovered() {
        let (fresh, name) = makeDefaults()
        let preferences = Preferences(defaults: fresh)
        preferences.reconcile(discoveredIDs: ["claude", "codex", "cursor", "glm", "claude-work"])
        XCTAssertEqual(preferences.connectedProviders, ["claude", "codex", "claude-work"])
        XCTAssertFalse(preferences.isConnected("cursor"))

        let again = Preferences(defaults: UserDefaults(suiteName: name)!)
        again.reconcile(discoveredIDs: ["claude", "codex", "cursor", "glm", "claude-work", "deepseek"])
        XCTAssertFalse(again.isConnected("cursor"))
        XCTAssertFalse(again.isConnected("deepseek"))
        XCTAssertTrue(again.isConnected("claude"))
    }

    func testHiddenProvidersInvertAgainstWhatThisMacHas() {
        let (fresh, _) = makeDefaults()
        fresh.set(["glm", "cursor"], forKey: "hiddenProviders")
        let preferences = Preferences(defaults: fresh)
        XCTAssertFalse(preferences.isConnected("glm"))
        XCTAssertTrue(preferences.isConnected("claude"))
        preferences.reconcile(discoveredIDs: ["claude", "codex", "cursor", "glm"])
        XCTAssertEqual(preferences.connectedProviders, ["claude", "codex"])
        XCTAssertFalse(preferences.isConnected("cursor"))
        XCTAssertTrue(preferences.isConnected("claude"))
    }

    func testANewClaudeProfileTurnsOnWithoutReopeningCursor() {
        let (fresh, name) = makeDefaults()
        let preferences = Preferences(defaults: fresh)
        preferences.reconcile(discoveredIDs: ["claude", "codex", "cursor"])
        XCTAssertFalse(preferences.isConnected("cursor"))

        let later = Preferences(defaults: UserDefaults(suiteName: name)!)
        later.reconcile(discoveredIDs: ["claude", "codex", "cursor", "claude-work"])
        XCTAssertTrue(later.isConnected("claude-work"))
        XCTAssertFalse(later.isConnected("cursor"))
    }

    /// A 1.9 install with nothing hidden still shows each loaded model after
    /// the invert. Model cells are not providers: they are absent from the
    /// on-list, and absence there must not mean off.
    func testAnUpgradeDoesNotHideLoadedModels() {
        let (fresh, _) = makeDefaults()
        fresh.set([String](), forKey: "hiddenProviders")
        let preferences = Preferences(defaults: fresh)
        preferences.reconcile(discoveredIDs: ["claude", "codex", "ollama-local"])
        let model = "ollama-local:model:qwen3:8b"
        XCTAssertFalse(preferences.disconnectedIDs(among: [
            "claude", "codex", "ollama-local", model
        ]).contains(model))
        XCTAssertTrue(preferences.isConnected(model))
        XCTAssertTrue(preferences.isConnected("ollama-local"))
        XCTAssertTrue(preferences.disabledModels.isEmpty)
    }

    /// Model ids on the old off-list stay off. They are not inverted onto
    /// `connectedProviders`.
    func testAHiddenModelStaysHiddenAfterTheOnListInvert() {
        let (fresh, name) = makeDefaults()
        fresh.set(["glm", "ollama-local:model:qwen3"], forKey: "hiddenProviders")
        let preferences = Preferences(defaults: fresh)
        preferences.reconcile(discoveredIDs: ["claude", "codex", "glm", "ollama-local"])
        XCTAssertFalse(preferences.isConnected("glm"))
        XCTAssertTrue(preferences.isConnected("ollama-local"))
        XCTAssertFalse(preferences.isConnected("ollama-local:model:qwen3"))
        XCTAssertEqual(preferences.disabledModels, ["ollama-local:model:qwen3"])
        XCTAssertFalse(preferences.connectedProviders.contains { Preferences.isModelCell($0) })

        let again = Preferences(defaults: UserDefaults(suiteName: name)!)
        XCTAssertFalse(again.isConnected("ollama-local:model:qwen3"))
        XCTAssertTrue(again.isConnected("ollama-local"))
    }

    /// An invert that already wrote `connectedProviders` still left model ids
    /// on `hiddenProviders`. Those hides must not be forgotten.
    func testModelHidesSurviveAPreviousInvertThatDroppedThem() {
        let (fresh, _) = makeDefaults()
        fresh.set(["claude", "codex", "ollama-local"], forKey: "connectedProviders")
        fresh.set(["claude", "codex", "ollama-local"], forKey: "seenProviders")
        fresh.set(["ollama-local:model:qwen3"], forKey: "hiddenProviders")
        let preferences = Preferences(defaults: fresh)
        XCTAssertFalse(preferences.isConnected("ollama-local:model:qwen3"))
        XCTAssertTrue(preferences.isConnected("ollama-local"))
        XCTAssertEqual(preferences.disabledModels, ["ollama-local:model:qwen3"])
    }

    /// Recomputing the store off-list after a provider toggle must not hide
    /// models that nobody hid.
    func testSwitchingAProviderDoesNotHideLoadedModels() {
        let (fresh, _) = makeDefaults()
        let preferences = Preferences(defaults: fresh)
        preferences.reconcile(discoveredIDs: ["claude", "codex", "cursor", "ollama-local"])
        let model = "ollama-local:model:qwen3:8b"
        XCTAssertTrue(preferences.isConnected(model))
        preferences.setConnected(true, for: "cursor")
        XCTAssertTrue(preferences.isConnected(model))
        XCTAssertFalse(preferences.disconnectedIDs(among: [
            "claude", "codex", "cursor", "ollama-local", model
        ]).contains(model))
        XCTAssertTrue(preferences.disabledModels.isEmpty)
    }

    /// A newly loaded model is on until hidden, and hiding it does not put it
    /// on the provider on-list.
    func testALoadedModelStaysOffTheProviderOnList() {
        let (fresh, name) = makeDefaults()
        let preferences = Preferences(defaults: fresh)
        preferences.reconcile(discoveredIDs: ["claude", "codex", "ollama-local"])
        let model = "ollama-local:model:qwen3:8b"
        XCTAssertTrue(preferences.isConnected(model))
        preferences.setConnected(false, for: model)
        XCTAssertEqual(preferences.disabledModels, [model])
        XCTAssertFalse(preferences.connectedProviders.contains(model))
        XCTAssertFalse(preferences.seenProviders.contains(model))

        let hidden = Preferences(defaults: UserDefaults(suiteName: name)!)
        XCTAssertFalse(hidden.isConnected(model))
        hidden.setConnected(true, for: model)
        XCTAssertTrue(hidden.disabledModels.isEmpty)

        let shown = Preferences(defaults: UserDefaults(suiteName: name)!)
        XCTAssertTrue(shown.isConnected(model))
        XCTAssertFalse(shown.connectedProviders.contains(model))
    }

    func testDeepSeekPricingSettingsSurviveARelaunchAndCanBeReset() {
        let (fresh, name) = makeDefaults()
        let preferences = Preferences(defaults: fresh)
        preferences.deepSeekPricingEnabled = false
        preferences.deepSeekPricingSchedule = DeepSeekPricing.Schedule(
            peakWeekdays: [2],
            windows: [
                .init(startMinute: 120, endMinute: 180),
                .init(startMinute: 360, endMinute: 420),
                .init(startMinute: 900, endMinute: 960)
            ]
        )

        let reloaded = Preferences(defaults: UserDefaults(suiteName: name)!)
        XCTAssertFalse(reloaded.deepSeekPricingEnabled)
        XCTAssertEqual(reloaded.deepSeekPricingSchedule.peakWeekdays, [2])
        XCTAssertEqual(reloaded.deepSeekPricingSchedule.windows.count, 3)
        XCTAssertEqual(reloaded.deepSeekPricingSchedule.windows[2].startMinute, 900)

        reloaded.resetDeepSeekPricingSchedule()
        XCTAssertEqual(reloaded.deepSeekPricingSchedule, .current)
    }

    /// Off by default, and it has to stay chosen once it is chosen: an extra
    /// arc in a 44pt circle changes how every reading looks, so it is not
    /// something to switch on for somebody, nor to forget they switched on.
    func testTheWeeklyRingIsOffUntilAskedForAndThenSurvivesARelaunch() {
        let (fresh, name) = makeDefaults()
        XCTAssertEqual(Preferences(defaults: fresh).weeklyRing, .off)

        Preferences(defaults: fresh).weeklyRing = .outside

        XCTAssertEqual(Preferences(defaults: UserDefaults(suiteName: name)!).weeklyRing, .outside)
    }

    /// On by default — it is how the notch is carried to another edge — and
    /// once somebody hides it, it has to stay hidden across a relaunch.
    func testTheMoveHandleShowsUntilHiddenAndStaysHidden() {
        let (fresh, name) = makeDefaults()
        XCTAssertTrue(Preferences(defaults: fresh).showsMoveHandle)

        Preferences(defaults: fresh).showsMoveHandle = false

        XCTAssertFalse(Preferences(defaults: UserDefaults(suiteName: name)!).showsMoveHandle)
    }

    /// The size has to outlive the launch that chose it, or it reads as a
    /// setting that did not take.
    func testTheNotchSizeSurvivesARelaunch() {
        let (fresh, name) = makeDefaults()
        Preferences(defaults: fresh).notchSize = .large

        XCTAssertEqual(Preferences(defaults: UserDefaults(suiteName: name)!).notchSize, .large)
    }

    /// An install that predates the setting keeps exactly the notch it had.
    /// `medium` is the design frame at 1:1, so this is what makes that true.
    func testMediumIsTheSizeEveryEarlierVersionDrew() {
        XCTAssertEqual(NotchSize.medium.scale, 1)
    }

    // MARK: The slider, and which control is in charge

    /// The presets stay in charge until the slider is explicitly chosen, so
    /// an install that predates it draws exactly the notch it always drew.
    func testThePresetsAreStillInChargeByDefault() {
        let (defaults, _) = makeDefaults()
        let preferences = Preferences(defaults: defaults)

        XCTAssertFalse(preferences.usesCustomNotchScale)
        XCTAssertEqual(preferences.notchScale, NotchSize.medium.scale)
    }

    /// Whichever control is in charge is the one `notchScale` answers with —
    /// that resolution is the whole point of keeping the two apart.
    func testTheScaleFollowsWhicheverControlIsInCharge() {
        let (defaults, _) = makeDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.notchSize = .large
        preferences.customNotchScale = 0.9

        XCTAssertEqual(preferences.notchScale, NotchSize.large.scale)
        preferences.usesCustomNotchScale = true
        XCTAssertEqual(preferences.notchScale, 0.9, accuracy: 0.0001)
    }

    /// Switching back to the presets returns to the preset that was chosen,
    /// not to whichever one happens to sit nearest the slider.
    func testLeavingTheSliderReturnsToTheChosenPreset() {
        let (defaults, _) = makeDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.notchSize = .small
        preferences.usesCustomNotchScale = true
        preferences.customNotchScale = 1.5
        preferences.usesCustomNotchScale = false

        XCTAssertEqual(preferences.notchScale, NotchSize.small.scale)
    }

    /// A value written straight into `defaults` could otherwise shrink the
    /// notch to nothing or blow it off the screen, so it is clamped on the
    /// way in as well as on the way out of the slider.
    func testAnOutOfRangeScaleIsClamped() {
        let (defaults, name) = makeDefaults()
        let preferences = Preferences(defaults: defaults)

        preferences.customNotchScale = 12
        XCTAssertEqual(preferences.customNotchScale,
                       Preferences.customScaleRange.upperBound, accuracy: 0.0001)

        preferences.customNotchScale = -3
        XCTAssertEqual(preferences.customNotchScale,
                       Preferences.customScaleRange.lowerBound, accuracy: 0.0001)

        UserDefaults(suiteName: name)!.set(99.0, forKey: "customNotchScale")
        XCTAssertEqual(Preferences(defaults: UserDefaults(suiteName: name)!).customNotchScale,
                       Preferences.customScaleRange.upperBound, accuracy: 0.0001)
    }

    /// Both halves of the choice have to outlive the launch that made it.
    func testTheSliderChoiceSurvivesARelaunch() {
        let (fresh, name) = makeDefaults()
        let preferences = Preferences(defaults: fresh)
        preferences.usesCustomNotchScale = true
        preferences.customNotchScale = 1.35

        let reloaded = Preferences(defaults: UserDefaults(suiteName: name)!)
        XCTAssertTrue(reloaded.usesCustomNotchScale)
        XCTAssertEqual(reloaded.customNotchScale, 1.35, accuracy: 0.0001)
        XCTAssertEqual(reloaded.notchScale, 1.35, accuracy: 0.0001)
    }
}

@MainActor
final class NotchPositionPersistenceTests: XCTestCase {
    func testEachEdgesPositionSurvivesReopeningPreferences() throws {
        let name = "NotchPositionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        for (index, edge) in NotchEdge.allCases.enumerated() {
            preferences.setOffset(CGFloat(index * 150 - 225), for: edge)
        }
        let reopened = Preferences(defaults: defaults)
        for (index, edge) in NotchEdge.allCases.enumerated() {
            XCTAssertEqual(reopened.offset(for: edge), CGFloat(index * 150 - 225))
        }
    }
}
