import XCTest
@testable import Codenotch

@MainActor
final class ModelVisibilityTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "ModelVisibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testVisibilityPersistsIndependentlyOfConnectionsAndProfiles() {
        let defaults = isolatedDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.setConnected(false, for: "codex-work")
        preferences.setProviderOrder(["codex-work", "codex"])

        XCTAssertTrue(preferences.isShownInNotch("codex"))
        preferences.setShownInNotch(false, for: "codex")
        XCTAssertTrue(preferences.isConnected("codex"))
        XCTAssertTrue(preferences.isShownInNotch("codex-work"))

        let restored = Preferences(defaults: defaults)
        XCTAssertFalse(restored.isShownInNotch("codex"))
        XCTAssertTrue(restored.isShownInNotch("codex-new-profile"))
        XCTAssertEqual(restored.providerOrder, ["codex-work", "codex"])
        restored.setShownInNotch(true, for: "codex-work")
        XCTAssertFalse(restored.isConnected("codex-work"), "Showing a provider must not reconnect it")
        restored.setShownInNotch(true, for: "codex")
        XCTAssertTrue(Preferences(defaults: defaults).hiddenNotchProviders.isEmpty)
    }

    func testLegacyLocalModelChoicesCanBeRestoredWithoutReconnectingTheirRuntime() {
        let defaults = isolatedDefaults()
        // The third is a runtime that does not exist yet: visibility keys off the
        // shared `<runtime>:model:<model>` shape, not a list of known runtimes.
        let ids = ["ollama-local:model:qwen3:8b", "lmstudio:model:qwen3:8b", "mlx:model:phi-4"]
        defaults.set(ids + ["ollama-local", "lmstudio", "codex"], forKey: "hiddenProviders")
        let preferences = Preferences(defaults: defaults)

        for id in ids {
            XCTAssertFalse(preferences.isShownInNotch(id))
            preferences.setShownInNotch(true, for: id)
            XCTAssertTrue(preferences.isShownInNotch(id))
        }
        XCTAssertEqual(preferences.disconnectedProviders, ["ollama-local", "lmstudio", "codex"])
        XCTAssertEqual(Preferences(defaults: defaults).disconnectedProviders, preferences.disconnectedProviders)

        preferences.setShownInNotch(false, for: ids[0])
        XCTAssertFalse(Preferences(defaults: defaults).isShownInNotch(ids[0]))
        XCTAssertFalse(preferences.disconnectedProviders.contains(ids[0]))
    }

    func testHideAndShowImmediatelyPreserveReadingsArchivesAndOrder() async {
        let first = VisibilityProvider(id: "codex"), second = VisibilityProvider(id: "codex-work")
        let archive = UsageArchive(defaults: isolatedDefaults())
        let store = UsageStore(providers: [first, second], archive: archive, order: [second.id, first.id])
        await store.refresh()
        let readings = store.snapshots
        let remembered = archive.load()[first.id]

        store.hiddenNotchProviders = [first.id]
        XCTAssertEqual(store.notchSnapshots.map(\.id), [second.id])
        XCTAssertEqual(store.snapshots, readings)
        XCTAssertEqual(archive.load()[first.id]?.snapshot, remembered?.snapshot)
        XCTAssertEqual(archive.load()[first.id]?.fetchedAt, remembered?.fetchedAt)
        XCTAssertTrue(store.disconnected.isEmpty)
        XCTAssertEqual(store.providerSummaries.map(\.id), [second.id, first.id])

        store.hiddenNotchProviders = []
        XCTAssertEqual(store.notchSnapshots.map(\.id), [second.id, first.id])
        XCTAssertEqual(store.notchSnapshots, readings)
        XCTAssertEqual(first.calls, 1)
        XCTAssertEqual(second.calls, 1)
    }

    func testHiddenProviderLoadsItsArchiveAndContinuesToRefresh() async {
        let defaults = isolatedDefaults()
        let provider = VisibilityProvider(id: "codex")
        let archive = UsageArchive(defaults: defaults)
        let original = UsageStore(providers: [provider], archive: archive)
        await original.refresh()
        let preferences = Preferences(defaults: defaults)
        preferences.setShownInNotch(false, for: provider.id)
        let restored = Preferences(defaults: defaults)
        let store = UsageStore(providers: [provider], archive: archive,
                               hiddenNotchProviders: restored.hiddenNotchProviders)

        XCTAssertTrue(store.notchSnapshots.isEmpty, "Hidden archived cells must not flash during launch")
        XCTAssertTrue(store.snapshots.first?.hasReading == true)
        XCTAssertNotNil(archive.load()[provider.id])
        await store.refresh()
        XCTAssertEqual(provider.calls, 2)
        XCTAssertTrue(store.notchSnapshots.isEmpty)
        XCTAssertEqual(archive.load()[provider.id]?.snapshot, store.snapshots.first)

        store.hiddenNotchProviders = []
        XCTAssertEqual(store.notchSnapshots, store.snapshots)
        XCTAssertEqual(provider.calls, 2)
    }

    func testHidingAnInFlightProviderKeepsAndArchivesItsResult() async {
        let provider = VisibilityProvider(id: "codex")
        let started = expectation(description: "Provider request started")
        provider.started = started
        let archive = UsageArchive(defaults: isolatedDefaults())
        let store = UsageStore(providers: [provider], archive: archive)
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 2)

        store.hiddenNotchProviders = [provider.id]
        XCTAssertTrue(store.refreshing.contains(provider.id))
        provider.finish()
        await refresh.value
        XCTAssertTrue(store.notchSnapshots.isEmpty)
        XCTAssertTrue(store.snapshots.first?.hasReading == true)
        XCTAssertNotNil(archive.load()[provider.id])
        XCTAssertTrue(store.refreshing.isEmpty)
    }

    func testLocalModelsAndRuntimesHideIndependentlyAndKeepDiscovery() async {
        let ollama = VisibilityProvider(id: "ollama-local", kind: .localRuntime)
        let studio = VisibilityProvider(id: "lmstudio", kind: .localRuntime)
        ollama.models = [model("qwen3:8b"), model("llama3.1:8b")]
        studio.models = [model("qwen3:8b")]
        let store = UsageStore(providers: [ollama, studio], archive: UsageArchive(defaults: isolatedDefaults()))
        await store.refresh()
        let original = store.notchSnapshots.map(\.id)
        let hidden = "ollama-local:model:qwen3:8b"

        store.hiddenNotchProviders = [hidden]
        XCTAssertEqual(store.notchSnapshots.map(\.id), ["ollama-local:model:llama3.1:8b", "lmstudio:model:qwen3:8b"])
        XCTAssertEqual(store.localModelSummaries.map(\.id), original)
        store.hiddenNotchProviders = []
        XCTAssertEqual(store.notchSnapshots.map(\.id), original, "A restored model keeps its place")
        XCTAssertEqual(ollama.calls, 1)
        XCTAssertEqual(studio.calls, 1)

        store.hiddenNotchProviders = [ollama.id, "lmstudio:model:qwen3:8b"]
        XCTAssertTrue(store.notchSnapshots.isEmpty)
        ollama.models.append(model("gemma3:4b"))
        await store.refresh()
        XCTAssertEqual(ollama.calls, 2)
        XCTAssertEqual(studio.calls, 2)
        XCTAssertTrue(store.notchSnapshots.isEmpty, "A hidden runtime also hides newly discovered models")
        XCTAssertEqual(store.localModelSummaries.count, 4)
        XCTAssertEqual(store.snapshots.first?.localRuntime?.models, ollama.models)
        XCTAssertTrue(store.disconnected.isEmpty)

        store.hiddenNotchProviders = [hidden]
        XCTAssertEqual(store.notchSnapshots.map(\.id), ["ollama-local:model:llama3.1:8b", "ollama-local:model:gemma3:4b", "lmstudio:model:qwen3:8b"])
        XCTAssertEqual(ollama.calls, 2)
    }

    func testEverythingCanBeHiddenAndRestoredWhileDisconnectedProvidersStayOff() async {
        let enabled = VisibilityProvider(id: "codex"), disconnected = VisibilityProvider(id: "claude")
        let store = UsageStore(providers: [enabled, disconnected], archive: UsageArchive(defaults: isolatedDefaults()),
                               disconnected: [disconnected.id], hiddenNotchProviders: [enabled.id, disconnected.id])
        await store.refresh()
        XCTAssertTrue(store.notchSnapshots.isEmpty)
        XCTAssertEqual(enabled.calls, 1)
        XCTAssertEqual(disconnected.calls, 0)

        store.hiddenNotchProviders = []
        XCTAssertEqual(store.notchSnapshots.map(\.id), [enabled.id])
        XCTAssertEqual(store.disconnected, [disconnected.id])
        XCTAssertEqual(disconnected.calls, 0)
    }

    private func model(_ name: String) -> LocalRuntimeReading.Model {
        .init(name: name, memoryBytes: nil, contextLength: nil, quantizationLevel: nil)
    }
}

@MainActor
private final class VisibilityProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let kind: ProviderKind
    nonisolated let displayName = "Test provider"
    nonisolated let glyph = ProviderGlyph.claude
    var calls = 0
    var models: [LocalRuntimeReading.Model] = []
    var started: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?

    init(id: String, kind: ProviderKind = .usage) {
        self.id = id
        self.kind = kind
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        calls += 1
        if let started {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok,
                                windows: kind == .usage ? [LimitWindow(id: "session", label: "Session", usedFraction: 0.42)] : [],
                                kind: kind, localRuntime: kind == .localRuntime ? LocalRuntimeReading(models: models) : nil)
    }

    func finish() {
        started = nil
        continuation?.resume()
        continuation = nil
    }
}
