import Foundation
import Testing
@testable import Codenotch

struct PluginRegistryTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginRegistryTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func writePlugin(_ id: String, in root: URL, displayName: String = "A Plugin") throws -> URL {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = #"""
        {"schema": 1, "id": "\#(id)", "displayName": "\#(displayName)", "version": "1",
         "exec": {"path": "/bin/sh", "args": ["snapshot"]},
         "glyph": {"image": "glyph.png", "opticalScale": 0.9}}
        """#
        try manifest.write(to: directory.appendingPathComponent("plugin.json"),
                           atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: directory.appendingPathComponent("glyph.png"))
        return directory
    }

    /// The watch is debounced half a second and delivered on a queue; poll
    /// rather than guess at timing.
    private func waitFor(_ timeoutSeconds: Int = 10,
                         _ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<(timeoutSeconds * 10) {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    // MARK: - Scanning

    @Test func scanFindsAValidPlugin() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try writePlugin("codemie-budget", in: root, displayName: "CodeMie Budget")

        let found = PluginRegistry(directory: root, builtInIDs: { [] }).scan()

        #expect(found.count == 1)
        #expect(found.first?.manifest.id == "codemie-budget")
        #expect(found.first?.manifest.displayName == "CodeMie Budget")
        #expect(found.first?.manifest.glyph?.opticalScale == 0.9)
        // Not `==` on the URLs: `contentsOfDirectory` and `temporaryDirectory`
        // can disagree on `/var` vs `/private/var`.
        #expect(found.first?.directory.lastPathComponent == directory.lastPathComponent)
    }

    @Test func scanSkipsAnInvalidManifestAndKeepsTheValidOne() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePlugin("good-plugin", in: root)
        let bad = root.appendingPathComponent("bad-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try #"{"schema": 99, "id": "bad-plugin"}"#.write(
            to: bad.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

        let found = PluginRegistry(directory: root, builtInIDs: { [] }).scan()

        #expect(found.map(\.manifest.id) == ["good-plugin"])
    }

    @Test func scanSkipsACollisionWithABuiltIn() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePlugin("claude", in: root)
        #expect(PluginRegistry(directory: root, builtInIDs: { ["claude"] }).scan().isEmpty)
    }

    @Test func scanIgnoresDirectoriesWithoutAManifest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-plugin", isDirectory: true),
            withIntermediateDirectories: true)
        #expect(PluginRegistry(directory: root, builtInIDs: { [] }).scan().isEmpty)
    }

    // MARK: - Watching

    @Test func addedAndRemovedPluginsAreReported() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = PluginRegistry(directory: root, builtInIDs: { [] })
        registry.seed([])

        let changes = ChangeLog()
        registry.onChange = { change in changes.record(change) }
        registry.start()
        defer { registry.stop() }

        try writePlugin("codemie-budget", in: root)
        #expect(await waitFor { changes.addedIDs().contains("codemie-budget") })

        try FileManager.default.removeItem(at: root.appendingPathComponent("codemie-budget", isDirectory: true))
        #expect(await waitFor { changes.removedIDs().contains("codemie-budget") })

        #expect(changes.addedIDs() == ["codemie-budget"],
                "a seeded set must not be re-reported")
    }

    @Test func aSeededPluginIsNotReportedAgain() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePlugin("codemie-budget", in: root)
        let registry = PluginRegistry(directory: root, builtInIDs: { [] })
        registry.seed(registry.scan())

        let changes = ChangeLog()
        registry.onChange = { change in changes.record(change) }
        registry.start()
        defer { registry.stop() }

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(changes.isEmpty())
    }

    /// Thread-safe accumulation of reported changes.
    private final class ChangeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var added: [String] = []
        private var removed: [String] = []

        func record(_ change: PluginRegistry.Change) {
            lock.withLock {
                added.append(contentsOf: change.added.map(\.manifest.id))
                removed.append(contentsOf: change.removedIDs)
            }
        }

        func addedIDs() -> [String] { lock.withLock { added } }
        func removedIDs() -> [String] { lock.withLock { removed } }
        func isEmpty() -> Bool { lock.withLock { added.isEmpty && removed.isEmpty } }
    }
}
