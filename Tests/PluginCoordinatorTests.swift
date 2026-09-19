import Foundation
import Testing
@testable import Codenotch

/// The approval gate: unapproved plugins must never reach the store, and a
/// changed hash must re-pend a previously approved one. Driven through the
/// real registry watcher, like `PluginRegistryTests`.
@MainActor
struct PluginCoordinatorTests {
    private func makeWorld() throws -> (URL, PluginRegistry, UsageStore, Preferences, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginCoordinatorTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "PluginCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        let store = UsageStore(providers: [], archive: UsageArchive(defaults: defaults),
                               disconnected: [], order: [])
        return (root, PluginRegistry(directory: root, builtInIDs: { [] }), store, preferences, suite)
    }

    @discardableResult
    private func writePlugin(_ id: String, in root: URL, version: String = "1") throws -> URL {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = #"""
        {"schema": 1, "id": "\#(id)", "displayName": "A Plugin", "version": "\#(version)",
         "exec": {"path": "/bin/sh", "args": ["snapshot"]}}
        """#
        try manifest.write(to: directory.appendingPathComponent("plugin.json"),
                           atomically: true, encoding: .utf8)
        return directory
    }

    private func waitFor(_ timeoutSeconds: Int = 10,
                         _ condition: @Sendable @MainActor () -> Bool) async -> Bool {
        for _ in 0..<(timeoutSeconds * 10) {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    @Test func anUnapprovedPluginPendsInsteadOfRegistering() async throws {
        let (root, registry, store, preferences, suite) = try makeWorld()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.start()
        defer { coordinator.stop() }

        try writePlugin("codemie-budget", in: root)

        #expect(await waitFor { coordinator.pendingPlugins.map(\.id) == ["codemie-budget"] })
        #expect(!store.knownIDs.contains("codemie-budget"),
                "an unapproved plugin must never reach the store")
        #expect(!preferences.isConnected("codemie-budget"))
    }

    @Test func approvingRegistersAndConnects() async throws {
        let (root, registry, store, preferences, suite) = try makeWorld()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.start()
        defer { coordinator.stop() }

        try writePlugin("codemie-budget", in: root)
        #expect(await waitFor { !coordinator.pendingPlugins.isEmpty })

        coordinator.approve(pluginID: "codemie-budget")

        #expect(store.knownIDs.contains("codemie-budget"))
        #expect(preferences.isConnected("codemie-budget"))
        #expect(coordinator.pendingPlugins.isEmpty)
    }

    @Test func anApprovedPluginRegistersOnArrival() async throws {
        let (root, registry, store, preferences, suite) = try makeWorld()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        // Approve the exact build before the coordinator ever sees it.
        try writePlugin("codemie-budget", in: root)
        let scanned = registry.scan().first
        let hash = try #require(scanned?.contentHash)
        preferences.approvePlugin("codemie-budget", hash: hash)

        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.start()
        defer { coordinator.stop() }

        #expect(await waitFor { store.knownIDs.contains("codemie-budget") })
        #expect(coordinator.pendingPlugins.isEmpty)
    }

    @Test func aChangedHashRependsAnApprovedPlugin() async throws {
        let (root, registry, store, preferences, suite) = try makeWorld()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        try writePlugin("codemie-budget", in: root, version: "1")
        let hash = try #require(registry.scan().first?.contentHash)
        preferences.approvePlugin("codemie-budget", hash: hash)

        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.start()
        defer { coordinator.stop() }
        #expect(await waitFor { store.knownIDs.contains("codemie-budget") })

        try writePlugin("codemie-budget", in: root, version: "2")

        #expect(await waitFor { coordinator.pendingPlugins.map(\.id) == ["codemie-budget"] })
        #expect(!store.knownIDs.contains("codemie-budget"),
                "the old build's provider must be deregistered while pending")
    }

    @Test func aRemovedPendingPluginLeavesTheList() async throws {
        let (root, registry, store, preferences, suite) = try makeWorld()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.start()
        defer { coordinator.stop() }

        let directory = try writePlugin("codemie-budget", in: root)
        #expect(await waitFor { coordinator.pendingPlugins.map(\.id) == ["codemie-budget"] })

        try FileManager.default.removeItem(at: directory)

        #expect(await waitFor { coordinator.pendingPlugins.isEmpty })
        #expect(!store.knownIDs.contains("codemie-budget"),
                "a pending plugin that disappears must never reach the store")
        #expect(!preferences.isConnected("codemie-budget"))
    }

    @Test func approvingAnUnknownPluginIsANoOp() async throws {
        let (root, registry, store, preferences, suite) = try makeWorld()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.start()
        defer { coordinator.stop() }

        coordinator.approve(pluginID: "nonexistent")

        #expect(coordinator.pendingPlugins.isEmpty)
        #expect(store.knownIDs.isEmpty)
        #expect(preferences.approvedHash(forPlugin: "nonexistent") == nil)
    }

    @Test func bootstrapSeedsPendingWithoutReReporting() async throws {
        let (root, registry, store, preferences, suite) = try makeWorld()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        try writePlugin("codemie-budget", in: root)
        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.bootstrap(approved: [], pending: registry.scan())
        #expect(coordinator.pendingPlugins.map(\.id) == ["codemie-budget"])
        coordinator.start()
        defer { coordinator.stop() }

        // The seeded set must not come back through `onChange`: three seconds
        // is well past the half-second debounce (same pattern as
        // PluginRegistryTests.aSeededPluginIsNotReportedAgain).
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(coordinator.pendingPlugins.map(\.id) == ["codemie-budget"])
        #expect(!store.knownIDs.contains("codemie-budget"))
        #expect(!preferences.isConnected("codemie-budget"))
    }
}
