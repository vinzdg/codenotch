import Foundation
import Testing
@testable import Codenotch

struct PluginManifestTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginManifestTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func manifestJSON(
        id: String = "codemie-budget",
        schema: Int = 1,
        displayName: String = "CodeMie Budget",
        execPath: String = "/bin/sh",
        signInRun: String? = #""signIn": {"guidance": "Run codemie profile login.", "run": ["/bin/sh", "-l"]},"#,
        glyph: String? = nil
    ) -> Data {
        var glyphSection = ""
        if let glyph {
            glyphSection = #""glyph": {"image": "\#(glyph)", "opticalScale": 0.95},"#
        }
        return Data(#"""
        {
            "schema": \#(schema),
            "id": "\#(id)",
            "displayName": "\#(displayName)",
            "version": "0.1.0",
            "exec": {"path": "\#(execPath)", "args": ["snapshot"], "timeoutSeconds": 12},
            \#(glyphSection)
            \#(signInRun ?? "")
            "activity": {"type": "claudeSessions", "configDir": "~/.claude"}
        }
        """#.utf8)
    }

    private func decode(_ data: Data) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: data)
    }

    // MARK: - Decoding

    @Test func decodesAFullManifest() throws {
        let manifest = try decode(manifestJSON(glyph: "glyph.png"))

        #expect(manifest.schema == 1)
        #expect(manifest.id == "codemie-budget")
        #expect(manifest.displayName == "CodeMie Budget")
        #expect(manifest.exec.path == "/bin/sh")
        #expect(manifest.exec.args == ["snapshot"])
        #expect(manifest.exec.timeout == 12)
        #expect(manifest.glyph?.image == "glyph.png")
        #expect(manifest.glyph?.opticalScale == 0.95)
        #expect(manifest.signIn?.guidance == "Run codemie profile login.")
        #expect(manifest.signIn?.run == ["/bin/sh", "-l"])
        #expect(manifest.activity?.type == "claudeSessions")
    }

    @Test func timeoutDefaultsToTwentySeconds() throws {
        let data = Data(#"""
        {"schema": 1, "id": "x", "displayName": "X", "version": "1",
         "exec": {"path": "/bin/sh", "args": []}}
        """#.utf8)
        #expect(try decode(data).exec.timeout == 20)
    }

    // MARK: - ID shape

    @Test(arguments: ["claude", "codemie-budget", "a", "a1", "1a", "codemie-claude-2"])
    func validIDs(id: String) {
        #expect(PluginManifest.isValidID(id))
    }

    @Test(arguments: ["", "Codemie", "-codemie", "codemie_claude", "codemie claude",
                      "codemie.budget", String(repeating: "a", count: 65),
                      "caf\u{301}", "克劳德"])
    func invalidIDs(id: String) {
        #expect(!PluginManifest.isValidID(id))
    }

    // MARK: - Validation

    @Test func acceptsAValidManifest() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON())
        let validated = try manifest.validated(builtInIDs: ["claude"], pluginDirectory: directory)
        #expect(validated == manifest)
    }

    @Test func rejectsAnUnknownSchema() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(schema: 2))
        #expect(throws: PluginManifest.ValidationError.unsupportedSchema(2)) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAMalformedID() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(id: "CodeMie"))
        #expect(throws: PluginManifest.ValidationError.malformedID("CodeMie")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsACollisionWithABuiltIn() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(id: "claude"))
        #expect(throws: PluginManifest.ValidationError.collidesWithBuiltIn("claude")) {
            try manifest.validated(builtInIDs: ["claude"], pluginDirectory: directory)
        }
    }

    @Test func rejectsARelativeExecPath() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(execPath: "bin/sh"))
        #expect(throws: PluginManifest.ValidationError.execNotAbsolute("bin/sh")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAMissingExec() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(execPath: "/no/such/binary"))
        #expect(throws: PluginManifest.ValidationError.execMissing("/no/such/binary")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsANonExecutableExec() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-executable")
        try "echo hi".write(to: file, atomically: true, encoding: .utf8)
        let manifest = try decode(manifestJSON(execPath: file.path))
        #expect(throws: PluginManifest.ValidationError.execNotExecutable(file.path)) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAMissingGlyphFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(glyph: "glyph.png"))
        #expect(throws: PluginManifest.ValidationError.glyphMissing("glyph.png")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func acceptsAGlyphThatExists() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: directory.appendingPathComponent("glyph.png"))
        let manifest = try decode(manifestJSON(glyph: "glyph.png"))
        #expect(throws: Never.self) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAnUnknownActivityType() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(#"""
        {"schema": 1, "id": "x", "displayName": "X", "version": "1",
         "exec": {"path": "/bin/sh", "args": []},
         "activity": {"type": "watchDirectory", "configDir": "/tmp"}}
        """#.utf8)
        let manifest = try decode(data)
        #expect(throws: PluginManifest.ValidationError.unknownActivity("watchDirectory")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    // MARK: - Display name

    @Test func rejectsAnEmptyDisplayName() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(displayName: "   "))
        #expect(throws: PluginManifest.ValidationError.malformedDisplayName("   ")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsATooLongDisplayName() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = String(repeating: "a", count: 41)
        let manifest = try decode(manifestJSON(displayName: name))
        #expect(throws: PluginManifest.ValidationError.malformedDisplayName(name)) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsADisplayNameWithControlCharacters() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A raw BEL would be invalid JSON; the `\u0007` escape decodes to it.
        let manifest = try decode(manifestJSON(displayName: #"Code\u0007Mie"#))
        #expect(throws: PluginManifest.ValidationError.malformedDisplayName("Code\u{7}Mie")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsADisplayNameImpersonatingABuiltIn() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(displayName: "claude"))
        #expect(throws: PluginManifest.ValidationError.impersonatesBuiltIn("claude")) {
            try manifest.validated(builtInIDs: [], builtInDisplayNames: ["Claude"],
                                   pluginDirectory: directory)
        }
    }

    @Test func rejectsAPaddedBuiltInDisplayName() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(displayName: " Claude"))
        #expect(throws: PluginManifest.ValidationError.impersonatesBuiltIn(" Claude")) {
            try manifest.validated(builtInIDs: [], builtInDisplayNames: ["Claude"],
                                   pluginDirectory: directory)
        }
    }

    // MARK: - Glyph containment

    @Test func rejectsAGlyphThatEscapesThePluginDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(glyph: "../outside.png"))
        #expect(throws: PluginManifest.ValidationError.glyphEscapesPluginDirectory("../outside.png")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAGlyphSymlinkThatEscapesThePluginDirectory() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: outside)
        let directory = root.appendingPathComponent("plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("glyph.png"),
            withDestinationURL: outside)
        let manifest = try decode(manifestJSON(glyph: "glyph.png"))
        #expect(throws: PluginManifest.ValidationError.glyphEscapesPluginDirectory("glyph.png")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAGlyphInASiblingDirectorySharingANamePrefix() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("plugin", isDirectory: true)
        let sibling = root.appendingPathComponent("plugin-extra", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sibling.appendingPathComponent("glyph.png"))
        let manifest = try decode(manifestJSON(glyph: "../plugin-extra/glyph.png"))
        #expect(throws: PluginManifest.ValidationError.glyphEscapesPluginDirectory("../plugin-extra/glyph.png")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func acceptsAGlyphSymlinkThatStaysInsideThePluginDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("glyph.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("icon.png"),
            withDestinationURL: target)
        let manifest = try decode(manifestJSON(glyph: "icon.png"))
        #expect(throws: Never.self) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    // MARK: - signIn.run

    @Test func rejectsARelativeSignInExecutable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(
            signInRun: #""signIn": {"guidance": "g", "run": ["codemie", "login"]},"#))
        #expect(throws: PluginManifest.ValidationError.signInNotAbsolute("codemie")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAMissingSignInExecutable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(
            signInRun: #""signIn": {"guidance": "g", "run": ["/no/such/tool"]},"#))
        #expect(throws: PluginManifest.ValidationError.signInMissing("/no/such/tool")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsANonExecutableSignInExecutable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tool")
        try "echo hi".write(to: file, atomically: true, encoding: .utf8)
        let manifest = try decode(manifestJSON(
            signInRun: "\"signIn\": {\"guidance\": \"g\", \"run\": [\"\(file.path)\"]},"))
        #expect(throws: PluginManifest.ValidationError.signInNotExecutable(file.path)) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAGroupWritableSignInExecutable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tool")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: file.path)
        let manifest = try decode(manifestJSON(
            signInRun: "\"signIn\": {\"guidance\": \"g\", \"run\": [\"\(file.path)\"]},"))
        #expect(throws: PluginManifest.ValidationError.signInUntrusted(file.path)) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    // MARK: - Executable trust

    @Test func rejectsAGroupWritableExec() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tool")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: file.path)
        let manifest = try decode(manifestJSON(execPath: file.path))
        #expect(throws: PluginManifest.ValidationError.execUntrusted(file.path)) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func acceptsASystemExec() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(execPath: "/bin/sh"))
        #expect(throws: Never.self) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }
}
