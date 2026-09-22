import Foundation
import Testing
@testable import Codenotch

/// `UsageStore.register`/`deregister` — the dynamic-provider surface plugins
/// register through. The stub provider answers immediately; the
/// timing-sensitive patterns live in `ProviderDisconnectionTests`.
@MainActor
struct UsageStorePluginTests {
    private func makeStore(_ providers: [UsageProvider] = [], disconnected: Set<String> = [],
                           order: [String] = [])
        -> (UsageStore, UsageArchive, String) {
        let name = "UsageStorePluginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let archive = UsageArchive(defaults: defaults)
        return (UsageStore(providers: providers, archive: archive,
                           disconnected: disconnected, order: order), archive, name)
    }

    private func cleanup(_ suiteName: String) {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test func registerPublishesAPlaceholderAndFetches() async {
        let (store, _, suite) = makeStore()
        defer { cleanup(suite) }
        #expect(store.snapshots.isEmpty)

        let plugin = Stub(id: "plugin-codemie-budget")
        store.register(plugin)

        #expect(store.snapshots.map(\.id) == ["plugin-codemie-budget"])
        #expect(!store.snapshots[0].hasReading, "a placeholder is not a reading")

        await store.refresh()
        #expect(store.snapshots[0].hasReading)
        #expect(store.snapshots[0].windows.first?.usedFraction == 0.42)
    }

    @Test func summariesMarkOnlyRealPluginsAsPlugins() async {
        let (store, _, suite) = makeStore()
        defer { cleanup(suite) }
        store.register(Stub(id: "stub-tool"))

        let manifest = PluginManifest(
            schema: 1, id: "plugin-codemie-budget", displayName: "CodeMie Budget", version: "0.1.0",
            exec: PluginManifest.Exec(path: "/bin/sh", args: [], timeoutSeconds: nil),
            glyph: nil, signIn: nil, activity: nil)
        let plugin = ExternalPluginProvider(manifest: manifest) { _ in
            ExternalPluginProvider.ExecResult(status: 0,
                                              stdout: Data(#"{"windows":[]}"#.utf8),
                                              stderr: Data())
        }
        store.register(plugin)

        // The badge a settings row draws hangs off this flag: a real plugin
        // must never read as built-in, and anything else must never read as a
        // plugin.
        #expect(store.providerSummaries.first { $0.id == "plugin-codemie-budget" }?.isPlugin == true)
        #expect(store.providerSummaries.first { $0.id == "stub-tool" }?.isPlugin == false)
    }

    @Test func registeringADisconnectedPluginStaysQuiet() async {
        let (store, _, suite) = makeStore(disconnected: ["plugin-codemie-budget"])
        defer { cleanup(suite) }

        store.register(Stub(id: "plugin-codemie-budget"))

        #expect(store.snapshots.isEmpty)
        #expect(store.providerSummaries.map(\.id) == ["plugin-codemie-budget"])
        await store.refresh()
        #expect(!store.snapshots.contains { $0.hasReading })
    }

    @Test func registeringTwiceKeepsOneProvider() async {
        let (store, _, suite) = makeStore()
        defer { cleanup(suite) }
        let plugin = Stub(id: "plugin-codemie-budget")
        store.register(plugin)
        store.register(plugin)

        await store.refresh()

        #expect(store.snapshots.map(\.id) == ["plugin-codemie-budget"])
        #expect(store.providerSummaries.map(\.id) == ["plugin-codemie-budget"])
        #expect(plugin.calls >= 1)
    }

    @Test func deregisterRemovesTheCellTheArchiveAndTheProvider() async {
        let (store, archive, suite) = makeStore()
        defer { cleanup(suite) }
        store.register(Stub(id: "plugin-codemie-budget"))
        await store.refresh()
        #expect(archive.load()["plugin-codemie-budget"] != nil)

        store.deregister(providerID: "plugin-codemie-budget")

        #expect(store.snapshots.isEmpty)
        #expect(store.providerSummaries.isEmpty)
        #expect(!store.knownIDs.contains("plugin-codemie-budget"))
        #expect(archive.load()["plugin-codemie-budget"] == nil)
    }

    @Test func deregisteringAnUnknownIDIsANoOp() async {
        let (store, _, suite) = makeStore()
        defer { cleanup(suite) }
        store.register(Stub(id: "plugin-codemie-budget"))

        store.deregister(providerID: "no-such-plugin")

        #expect(store.snapshots.map(\.id) == ["plugin-codemie-budget"])
    }

    @Test func aReregisteredPluginFetchesAgain() async {
        let (store, _, suite) = makeStore()
        defer { cleanup(suite) }
        store.register(Stub(id: "plugin-codemie-budget"))
        await store.refresh()
        store.deregister(providerID: "plugin-codemie-budget")

        let second = Stub(id: "plugin-codemie-budget")
        store.register(second)
        await store.refresh()

        #expect(second.calls >= 1)
        #expect(store.snapshots[0].hasReading)
    }
}

private final class Stub: UsageProvider, @unchecked Sendable {
    let id: String
    let displayName = "Stub Plugin"
    let glyph = ProviderGlyph.external
    private let lock = NSLock()
    private var fetchCount = 0

    init(id: String) { self.id = id }

    var calls: Int { lock.withLock { fetchCount } }

    func account() -> ProviderAccount? { nil }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        lock.withLock { fetchCount += 1 }
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok,
                                windows: [LimitWindow(id: "budget", label: "Budget", usedFraction: 0.42)])
    }
}
