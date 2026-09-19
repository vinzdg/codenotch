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
    private func writePlugin(_ id: String, in root: URL, displayName: String = "A Plugin",
                             execPath: String = "/bin/sh") throws -> URL {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = #"""
        {"schema": 1, "id": "\#(id)", "displayName": "\#(displayName)", "version": "1",
         "exec": {"path": "\#(execPath)", "args": ["snapshot"]},
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

    @Test func twoPluginsWithTheSameIDDoNotCrashTheScan() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePlugin("codemie-budget", in: root)
        // A second directory declaring the same manifest id. One buggy
        // installer must not take the process down with it.
        let twin = root.appendingPathComponent("codemie-budget-twin", isDirectory: true)
        try FileManager.default.createDirectory(at: twin, withIntermediateDirectories: true)
        let manifest = #"""
        {"schema": 1, "id": "codemie-budget", "displayName": "Twin", "version": "1",
         "exec": {"path": "/bin/sh", "args": ["snapshot"]}}
        """#
        try manifest.write(to: twin.appendingPathComponent("plugin.json"),
                           atomically: true, encoding: .utf8)

        let found = PluginRegistry(directory: root, builtInIDs: { [] }).scan()

        #expect(found.count == 1)
        #expect(found.first?.manifest.id == "codemie-budget")
    }

    // MARK: - Folder trust

    @Test func scanRefusesAnUntrustedRoot() throws {
        let root = try makeRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try writePlugin("codemie-budget", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        #expect(PluginRegistry(directory: root, builtInIDs: { [] }).scan().isEmpty)
    }

    @Test func scanSkipsASymlinkedPluginDirectory() throws {
        let root = try makeRoot()
        // The genuine directory stays outside the scanned root: inside it would
        // be a plugin in its own right, symlink or no symlink.
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let real = try writePlugin("codemie-budget", in: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("codemie-budget", isDirectory: true),
            withDestinationURL: real)
        #expect(PluginRegistry(directory: root, builtInIDs: { [] }).scan().isEmpty)
    }

    @Test func scanSkipsAGroupWritableManifest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try writePlugin("codemie-budget", in: root)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o664],
            ofItemAtPath: directory.appendingPathComponent("plugin.json").path)
        #expect(PluginRegistry(directory: root, builtInIDs: { [] }).scan().isEmpty)
    }

    // MARK: - Content hash

    @Test func theContentHashCoversTheManifestAndTheExecutable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("tool.sh")
        try "#!/bin/sh\necho one\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try writePlugin("codemie-budget", in: root, execPath: script.path)
        let registry = PluginRegistry(directory: root, builtInIDs: { [] })
        let first = registry.scan().first?.contentHash

        try "#!/bin/sh\necho two\n".write(to: script, atomically: true, encoding: .utf8)
        let second = registry.scan().first?.contentHash

        #expect(first != nil)
        #expect(first != second, "a swapped executable must change the pinned hash")
    }

    @Test func theContentHashCoversTheManifestBytes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try writePlugin("codemie-budget", in: root)
        let registry = PluginRegistry(directory: root, builtInIDs: { [] })
        let first = registry.scan().first?.contentHash

        // Same executable, same directory: only the manifest bytes change, so
        // the pinned hash must too.
        let manifestURL = directory.appendingPathComponent("plugin.json")
        let bumped = try String(contentsOf: manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "\"version\": \"1\"", with: "\"version\": \"2\"")
        try bumped.write(to: manifestURL, atomically: true, encoding: .utf8)
        let second = registry.scan().first?.contentHash

        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second, "a manifest edit must change the pinned hash")
    }

    @Test func scanSkipsAPluginWhoseExecutableIsUnreadable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("tool.sh")
        try "#!/bin/sh\necho one\n".write(to: script, atomically: true, encoding: .utf8)
        // Execute-only and user-owned: passes validation's executable and
        // trust checks, but `Data(contentsOf:)` fails — and an unhashable
        // binary must not register.
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: script.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        try writePlugin("codemie-budget", in: root, execPath: script.path)
        #expect(PluginRegistry(directory: root, builtInIDs: { [] }).scan().isEmpty)
    }

    @Test func anExecutableSwapReportsAReregistration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("tool.sh")
        try "#!/bin/sh\necho one\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try writePlugin("codemie-budget", in: root, execPath: script.path)
        let registry = PluginRegistry(directory: root, builtInIDs: { [] })
        registry.seed(registry.scan())

        let changes = ChangeLog()
        registry.onChange = { change in changes.record(change) }
        registry.start()
        defer { registry.stop() }

        try "#!/bin/sh\necho two\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(await waitFor {
            changes.removedIDs().contains("codemie-budget")
                && changes.addedIDs().contains("codemie-budget")
        })
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

    @Test func aStoppedRegistryStaysQuiet() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = PluginRegistry(directory: root, builtInIDs: { [] })
        registry.seed([])

        let changes = ChangeLog()
        registry.onChange = { change in changes.record(change) }
        registry.start()
        registry.stop()

        // A write after `stop` must not be reported: the watches are gone and
        // a late in-flight event must not arm a rescan behind `stop`'s back.
        try writePlugin("codemie-budget", in: root)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
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
