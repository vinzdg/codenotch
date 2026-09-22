import Foundation
import Testing
@testable import Codenotch

struct PluginTrustTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginTrustTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func aUserOwnedDirectoryIsTrusted() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(PluginTrust.isTrustedDirectory(directory))
    }

    @Test func aGroupWritableDirectoryIsNotTrusted() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: directory.path)
        #expect(!PluginTrust.isTrustedDirectory(directory))
    }

    @Test func aSymlinkedDirectoryIsNotTrusted() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(!PluginTrust.isTrustedDirectory(link))
    }

    @Test func aUserOwnedManifestIsTrusted() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plugin.json")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        #expect(PluginTrust.isTrustedManifest(file))
    }

    @Test func aWorldWritableManifestIsNotTrusted() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plugin.json")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o646], ofItemAtPath: file.path)
        #expect(!PluginTrust.isTrustedManifest(file))
    }

    @Test func aSystemExecutableIsTrusted() {
        // Owned by root, mode 0555: the reviewer-approved shape for exec paths.
        #expect(PluginTrust.isTrustedExecutable(URL(fileURLWithPath: "/bin/sh")))
    }

    @Test func aGroupWritableExecutableIsNotTrusted() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tool")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: file.path)
        #expect(!PluginTrust.isTrustedExecutable(file))
    }

    @Test func aNonexistentPathIsNotTrusted() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing")
        #expect(!PluginTrust.isTrustedDirectory(missing))
        #expect(!PluginTrust.isTrustedManifest(missing))
        #expect(!PluginTrust.isTrustedExecutable(missing))
    }

    @Test func aDirectoryIsNotATrustedManifest() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!PluginTrust.isTrustedManifest(directory))
    }

    @Test func aRegularFileIsNotATrustedDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plugin.json")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        #expect(!PluginTrust.isTrustedDirectory(file))
    }

    @Test func aSymlinkedManifestIsNotTrusted() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("plugin.json")
        try "{}".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(!PluginTrust.isTrustedManifest(link))
    }
}
