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

        try writePlugin("plugin-codemie-budget", in: root)

        #expect(await waitFor { coordinator.pendingPlugins.map(\.id) == ["plugin-codemie-budget"] })
        #expect(!store.knownIDs.contains("plugin-codemie-budget"),
                "an unapproved plugin must never reach the store")
        #expect(!preferences.isConnected("plugin-codemie-budget"))
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

        try writePlugin("plugin-codemie-budget", in: root)
        #expect(await waitFor { !coordinator.pendingPlugins.isEmpty })

        coordinator.approve(pluginID: "plugin-codemie-budget")

        #expect(store.knownIDs.contains("plugin-codemie-budget"))
        #expect(preferences.isConnected("plugin-codemie-budget"))
        #expect(coordinator.pendingPlugins.isEmpty)
    }

    @Test func anApprovedPluginRegistersOnArrival() async throws {
        let (root, registry, store, preferences, suite) = try makeWorld()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        // Approve the exact build before the coordinator ever sees it.
        try writePlugin("plugin-codemie-budget", in: root)
        let scanned = registry.scan().first
        let hash = try #require(scanned?.contentHash)
        preferences.approvePlugin("plugin-codemie-budget", hash: hash)

        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.start()
        defer { coordinator.stop() }

        #expect(await waitFor { store.knownIDs.contains("plugin-codemie-budget") })
        #expect(coordinator.pendingPlugins.isEmpty)
    }

    @Test func aChangedHashRependsAnApprovedPlugin() async throws {
        let (root, registry, store, preferences, suite) = try makeWorld()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        try writePlugin("plugin-codemie-budget", in: root, version: "1")
        let hash = try #require(registry.scan().first?.contentHash)
        preferences.approvePlugin("plugin-codemie-budget", hash: hash)

        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.start()
        defer { coordinator.stop() }
        #expect(await waitFor { store.knownIDs.contains("plugin-codemie-budget") })

        try writePlugin("plugin-codemie-budget", in: root, version: "2")

        #expect(await waitFor { coordinator.pendingPlugins.map(\.id) == ["plugin-codemie-budget"] })
        #expect(!store.knownIDs.contains("plugin-codemie-budget"),
                "the old build's provider must be deregistered while pending")
    }

    @Test func revokingForgetsTheApprovalAndRependsTheSameBuild() async throws {
        let (root, registry, store, preferences, suite) = try makeWorld()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.start()
        defer { coordinator.stop() }
        try writePlugin("plugin-codemie-budget", in: root)
        #expect(await waitFor { !coordinator.pendingPlugins.isEmpty })
        let hash = try #require(coordinator.pendingPlugins.first?.contentHash)
        coordinator.approve(pluginID: "plugin-codemie-budget")
        #expect(store.knownIDs.contains("plugin-codemie-budget"))

        coordinator.revoke(pluginID: "plugin-codemie-budget")

        #expect(!store.knownIDs.contains("plugin-codemie-budget"), "a revoked plugin must stop running")
        #expect(preferences.approvedHash(forPlugin: "plugin-codemie-budget") == nil)
        #expect(!preferences.isConnected("plugin-codemie-budget"))
        #expect(coordinator.pendingPlugins.map(\.id) == ["plugin-codemie-budget"],
                "still on disk, so it is back to asking")
        #expect(coordinator.pendingPlugins.first?.contentHash == hash)
    }

    @Test func deletingAnApprovedPluginForgetsTheApproval() async throws {
        let (root, registry, store, preferences, suite) = try makeWorld()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let directory = try writePlugin("plugin-codemie-budget", in: root)
        let hash = try #require(registry.scan().first?.contentHash)
        preferences.approvePlugin("plugin-codemie-budget", hash: hash)
        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.start()
        defer { coordinator.stop() }
        #expect(await waitFor { store.knownIDs.contains("plugin-codemie-budget") })

        try FileManager.default.removeItem(at: directory)
        #expect(await waitFor { !store.knownIDs.contains("plugin-codemie-budget") })
        #expect(preferences.approvedHash(forPlugin: "plugin-codemie-budget") == nil,
                "an approval lives exactly as long as the plugin directory")

        // The same bytes, dropped back in, ask again rather than run.
        try writePlugin("plugin-codemie-budget", in: root)
        #expect(await waitFor { coordinator.pendingPlugins.map(\.id) == ["plugin-codemie-budget"] })
        #expect(!store.knownIDs.contains("plugin-codemie-budget"))
    }

    @Test func thePendingRowShowsTheSignInCommand() async throws {
        let (root, registry, store, preferences, suite) = try makeWorld()
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.start()
        defer { coordinator.stop() }
        let directory = root.appendingPathComponent("plugin-codemie-budget", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"""
        {"schema": 1, "id": "plugin-codemie-budget", "displayName": "A Plugin", "version": "1",
         "exec": {"path": "/bin/sh", "args": ["snapshot"]},
         "signIn": {"guidance": "g", "run": ["/bin/sh", "login.sh"]}}
        """#.write(to: directory.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

        #expect(await waitFor { !coordinator.pendingPlugins.isEmpty })
        #expect(coordinator.pendingPlugins.first?.commandLine == "/bin/sh snapshot")
        #expect(coordinator.pendingPlugins.first?.signInCommandLine == "/bin/sh login.sh")
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

        let directory = try writePlugin("plugin-codemie-budget", in: root)
        #expect(await waitFor { coordinator.pendingPlugins.map(\.id) == ["plugin-codemie-budget"] })

        try FileManager.default.removeItem(at: directory)

        #expect(await waitFor { coordinator.pendingPlugins.isEmpty })
        #expect(!store.knownIDs.contains("plugin-codemie-budget"),
                "a pending plugin that disappears must never reach the store")
        #expect(!preferences.isConnected("plugin-codemie-budget"))
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
        try writePlugin("plugin-codemie-budget", in: root)
        let coordinator = PluginCoordinator(registry: registry, store: store,
                                            preferences: preferences)
        coordinator.bootstrap(approved: [], pending: registry.scan())
        #expect(coordinator.pendingPlugins.map(\.id) == ["plugin-codemie-budget"])
        coordinator.start()
        defer { coordinator.stop() }

        // The seeded set must not come back through `onChange`: three seconds
        // is well past the half-second debounce (same pattern as
        // PluginRegistryTests.aSeededPluginIsNotReportedAgain).
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(coordinator.pendingPlugins.map(\.id) == ["plugin-codemie-budget"])
        #expect(!store.knownIDs.contains("plugin-codemie-budget"))
        #expect(!preferences.isConnected("plugin-codemie-budget"))
    }

    @Test func theCommandLineQuotesArgumentsSoWordBoundariesAreUnambiguous() {
        let plugin = PluginCoordinator.PendingPlugin(
            id: "p", displayName: "P", execPath: "/bin/sh",
            execArgs: ["-c", "echo hi", "it's", "plain-arg_1.sh"],
            contentHash: "abc", directory: URL(fileURLWithPath: "/tmp/p"),
            signInCommand: ["/bin/sh", "login me"])
        #expect(plugin.commandLine == #"/bin/sh -c 'echo hi' 'it'\''s' plain-arg_1.sh"#)
        #expect(plugin.signInCommandLine == "/bin/sh 'login me'")
    }
}
