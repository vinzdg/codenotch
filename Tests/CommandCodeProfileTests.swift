import XCTest
@testable import Codenotch

final class CommandCodeProfileTests: XCTestCase {
    private func home(_ layout: [String: [String]] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandCodeProfileTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (directory, files) in layout {
            let url = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for file in files {
                let path = url.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data().write(to: path)
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func archive() -> UsageArchive {
        let name = "CommandCodeProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return UsageArchive(defaults: defaults)
    }

    private func writeAuth(_ url: URL, user: String, key: String = "fake") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["apiKey": key, "userName": user]).write(to: url)
    }

    func testDefaultIdentityAndPathsStayCompatible() {
        let profile = CommandCodeProfile.default(home: URL(fileURLWithPath: "/Users/test"))
        XCTAssertEqual(profile.id, "commandcode")
        XCTAssertEqual(profile.displayName, "Command Code")
        XCTAssertEqual(profile.authURL.path, "/Users/test/.commandcode/auth.json")
        XCTAssertEqual(profile.sourceName, "Command Code")
        let provider = CommandCodeProvider(profile: profile, archive: archive())
        XCTAssertEqual(provider.id, "commandcode")
        guard case .guidance = provider.signInRoute else {
            return XCTFail("the default profile keeps its guidance")
        }
    }

    func testDiscoveryIsStableAndIgnoresUnrelatedFiles() throws {
        let root = try home([".commandcode-work": [".commandcode/auth.json"],
                             ".commandcode-alpha": [".commandcode/config.json"],
                             ".commandcode-flat": ["auth.json"],
                             ".commandcode-empty": [], ".commandcode-notes": ["README.md"],
                             ".commandcode-": ["auth.json"], "commandcode-other": ["auth.json"]])
        try Data().write(to: root.appendingPathComponent(".commandcode-file"))
        let found = CommandCodeProfile.discover(home: root)
        XCTAssertEqual(found.map(\.id),
                       ["commandcode", "commandcode-alpha", "commandcode-flat", "commandcode-work"])
        XCTAssertEqual(found.map(\.displayName),
                       ["Command Code", "Command Code (alpha)", "Command Code (flat)", "Command Code (work)"])
        XCTAssertEqual(CommandCodeProfile.discover(home: root.appendingPathComponent("missing")).map(\.id),
                       ["commandcode"])
    }

    func testAProfileIsAHomeSoItsLoginIsOneLevelDown() throws {
        let root = try home([".commandcode-work": [".commandcode/auth.json"],
                             ".commandcode-flat": ["auth.json"],
                             ".commandcode-both": [".commandcode/auth.json", "auth.json"],
                             ".commandcode-out": [".commandcode/config.json"]])
        let found = Dictionary(uniqueKeysWithValues:
            CommandCodeProfile.discover(home: root).map { ($0.slug ?? "", $0.authURL.path) })
        XCTAssertEqual(found["work"], root.appendingPathComponent(".commandcode-work/.commandcode/auth.json").path)
        XCTAssertEqual(found["flat"], root.appendingPathComponent(".commandcode-flat/auth.json").path)
        // `commandcode login` writes the nested file, so it is the one that stays current.
        XCTAssertEqual(found["both"], root.appendingPathComponent(".commandcode-both/.commandcode/auth.json").path)
        // Signed out: point at where a login will land.
        XCTAssertEqual(found["out"], root.appendingPathComponent(".commandcode-out/.commandcode/auth.json").path)
    }

    func testProviderIDsRoundTrip() {
        XCTAssertNil(CommandCodeProfile.slug(fromProviderID: "commandcode"))
        XCTAssertNil(CommandCodeProfile.slug(fromProviderID: "commandcode-"))
        XCTAssertNil(CommandCodeProfile.slug(fromProviderID: "codex-work"))
        XCTAssertEqual(CommandCodeProfile.slug(fromProviderID: "commandcode-work"), "work")
        XCTAssertTrue(CommandCodeProfile.isCommandCode(providerID: "commandcode"))
        XCTAssertTrue(CommandCodeProfile.isCommandCode(providerID: "commandcode-work"))
        XCTAssertFalse(CommandCodeProfile.isCommandCode(providerID: "codex"))
    }

    func testSignInNamesAndQuotesTheCorrectProfile() {
        let profile = CommandCodeProfile(slug: "work",
                                         configDirectory: URL(fileURLWithPath: "/Users/O'Brien/.commandcode-work"))
        XCTAssertEqual(profile.signInCommand,
                       "HOME='/Users/O'\"'\"'Brien/.commandcode-work' commandcode login")
        XCTAssertEqual(CommandCodeProvider(profile: profile, archive: archive()).signInRoute,
                       .command(profile.signInCommand, name: "Command Code (work)",
                                install: URL(string: "https://commandcode.ai")))
    }

    func testEachProfileReadsItsOwnAccount() throws {
        let root = try home()
        let personal = CommandCodeProfile.default(home: root)
        let work = CommandCodeProfile(slug: "work",
                                      configDirectory: root.appendingPathComponent(".commandcode-work"))
        try writeAuth(personal.authURL, user: "personal")
        try writeAuth(root.appendingPathComponent(".commandcode-work/.commandcode/auth.json"), user: "work")

        let store = archive()
        XCTAssertEqual(CommandCodeProvider(profile: personal, archive: store, environment: [:]).account()?.label,
                       "personal")
        let workAccount = CommandCodeProvider(profile: work, archive: store, environment: [:]).account()
        XCTAssertEqual(workAccount?.label, "work")
        XCTAssertEqual(workAccount?.source, "Command Code in \(work.displayPath)")
    }

    func testTheEnvironmentKeyBelongsToTheDefaultProfileOnly() throws {
        let root = try home()
        let personal = CommandCodeProfile.default(home: root)
        let work = CommandCodeProfile(slug: "work",
                                      configDirectory: root.appendingPathComponent(".commandcode-work"))
        try writeAuth(personal.authURL, user: "personal")
        try writeAuth(work.authURL, user: "work")
        let environment = ["COMMAND_CODE_API_KEY": "from-env"]

        let store = archive()
        // The key in the environment carries no user name, so a nil label proves it won.
        XCTAssertNil(CommandCodeProvider(profile: personal, archive: store, environment: environment)
            .account()?.label)
        XCTAssertEqual(CommandCodeProvider(profile: work, archive: store, environment: environment)
            .account()?.label, "work")
    }

    func testSignedOutProfileAsksForThatProfile() async throws {
        let root = try home([".commandcode-work": [".commandcode/config.json"]])
        let work = try XCTUnwrap(CommandCodeProfile.discover(home: root).last)
        let provider = CommandCodeProvider(profile: work, archive: archive(), environment: [:])
        XCTAssertNil(provider.account())
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("a profile with no login must not fetch")
        } catch {
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }
}
