import Foundation
import Testing
@testable import Codenotch

/// A plugin is marked wherever a provider is named — not only on its settings
/// row. The notch ring and tooltip read `ProviderSnapshot.isPlugin`; the
/// system notifications, which have no room for a badge, say it in words.
@MainActor
struct PluginMarkerTests {
    private let manifest = PluginManifest(
        schema: 1, id: "plugin-codemie-budget", displayName: "CodeMie Budget", version: "0.1.0",
        exec: PluginManifest.Exec(path: "/bin/sh", args: [], timeoutSeconds: nil),
        glyph: nil, signIn: nil, activity: nil)

    @Test func thePlaceholderAndTheReadingAreBothMarked() async {
        let name = "PluginMarkerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let store = UsageStore(providers: [], archive: UsageArchive(defaults: defaults),
                               disconnected: [], order: [])
        let plugin = ExternalPluginProvider(manifest: manifest) { _ in
            ExternalPluginProvider.ExecResult(
                status: 0,
                stdout: Data(#"{"windows": [{"id": "b", "label": "B", "usedFraction": 0.9}]}"#.utf8),
                stderr: Data())
        }

        store.register(plugin)
        #expect(store.snapshots.first?.isPlugin == true, "the placeholder, before any reading")

        await store.refresh()
        #expect(store.snapshots.first?.isPlugin == true, "and the reading itself")
        #expect(store.snapshots.first?.hasReading == true)
    }

    @Test func aBuiltInIsNotMarked() {
        let snapshot = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                                        fidelity: .official, status: .ok, windows: [])
        #expect(!snapshot.isPlugin)
    }

    @Test func notificationsNameThePlugin() {
        let alert = ThresholdAlert(threshold: 80, providerID: "plugin-codemie-budget",
                                   providerName: "CodeMie Budget", windowLabel: "Budget",
                                   usedPercent: 81, resetsAt: nil, isPlugin: true)
        #expect(alert.notifiedName == "CodeMie Budget (plugin)")
        let builtIn = ThresholdAlert(threshold: 80, providerID: "claude", providerName: "Claude",
                                     windowLabel: "Session", usedPercent: 81, resetsAt: nil)
        #expect(builtIn.notifiedName == "Claude")

        let event = UsageAlertEvent(providerID: "plugin-codemie-budget", providerName: "CodeMie Budget",
                                    windowLabel: "Budget", glyph: .external,
                                    previousFraction: 1, currentFraction: 0, resetsAt: nil)
        #expect(event.notifiedName == "CodeMie Budget (plugin)")
    }

    @Test func theThresholdNotifierCarriesTheMark() {
        var delivered: [ThresholdAlert] = []
        let notifier = ThresholdNotifier(deliver: { delivered.append($0) })
        var snapshot = ProviderSnapshot(id: "plugin-codemie-budget", displayName: "CodeMie Budget",
                                        glyph: .external, fidelity: .official, status: .ok,
                                        windows: [LimitWindow(id: "b", label: "Budget", usedFraction: 0.85)])
        snapshot.headlineID = "b"
        notifier.observe([snapshot])
        #expect(delivered.first?.isPlugin == true)
    }
}
