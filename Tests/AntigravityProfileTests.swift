import XCTest
@testable import Codenotch

final class AntigravityProfileTests: XCTestCase {
    private func home(_ layout: [String: [String]] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityProfileTests.\(UUID().uuidString)")
        let geminiDir = root.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        for (directory, files) in layout {
            let url = geminiDir.appendingPathComponent(directory)
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

    // MARK: - Identity & Paths

    func testDefaultIdentityAndPathsStayCompatible() {
        let profile = AntigravityProfile.default(home: URL(fileURLWithPath: "/Users/test"))
        XCTAssertNil(profile.slug)
        XCTAssertEqual(profile.id, "gemini")
        XCTAssertEqual(profile.displayName, "Antigravity")
        XCTAssertEqual(profile.configDirectory.path, "/Users/test/.gemini/antigravity")
        XCTAssertEqual(profile.authURL.path, "/Users/test/.gemini/antigravity/oauth_creds.json")
        XCTAssertEqual(profile.brainDirectory.path, "/Users/test/.gemini/antigravity/brain")
        XCTAssertEqual(profile.keychainService, "gemini")
        XCTAssertEqual(profile.keychainAccount, "antigravity")
        XCTAssertEqual(profile.sourceName, "Antigravity")
        XCTAssertEqual(AntigravityProvider(profile: profile).signInRoute,
                       .openApp(bundleID: "com.google.antigravity", name: "Antigravity"))
    }

    func testNamedProfileIdentityAndPaths() {
        let home = URL(fileURLWithPath: "/Users/test")
        let dir = home.appendingPathComponent(".gemini/antigravity-work")
        let profile = AntigravityProfile(slug: "work", configDirectory: dir)
        XCTAssertEqual(profile.slug, "work")
        XCTAssertEqual(profile.id, "antigravity-work")
        XCTAssertEqual(profile.displayName, "Antigravity (work)")
        XCTAssertEqual(profile.authURL.path, "/Users/test/.gemini/antigravity-work/oauth_creds.json")
        XCTAssertEqual(profile.brainDirectory.path, "/Users/test/.gemini/antigravity-work/brain")
        XCTAssertNil(profile.keychainService)
        XCTAssertNil(profile.keychainAccount)
        XCTAssertEqual(profile.sourceName, L10n.t("Antigravity in \(profile.displayPath)"))
        XCTAssertEqual(AntigravityProvider(profile: profile).signInRoute,
                       .guidance(L10n.t("Sign in to Antigravity in ~/.gemini/antigravity-work to read your usage")))
    }

    func testProviderIDsAreRecognised() {
        XCTAssertTrue(AntigravityProfile.isAntigravity(providerID: "gemini"))
        XCTAssertTrue(AntigravityProfile.isAntigravity(providerID: "antigravity-work"))
        XCTAssertTrue(AntigravityProfile.isAntigravity(providerID: "antigravity-alpha"))
        XCTAssertFalse(AntigravityProfile.isAntigravity(providerID: "gemini-api"))
        XCTAssertFalse(AntigravityProfile.isAntigravity(providerID: "gemini-work"))
        XCTAssertFalse(AntigravityProfile.isAntigravity(providerID: "geminiapi"))
        XCTAssertFalse(AntigravityProfile.isAntigravity(providerID: "claude"))
        XCTAssertFalse(AntigravityProfile.isAntigravity(providerID: "cursor"))

        XCTAssertEqual(AntigravityProfile.slug(fromProviderID: "antigravity-work"), "work")
        XCTAssertEqual(AntigravityProfile.slug(fromProviderID: "antigravity-client-a"), "client-a")
        XCTAssertNil(AntigravityProfile.slug(fromProviderID: "gemini"))
        XCTAssertNil(AntigravityProfile.slug(fromProviderID: "gemini-api"))
        XCTAssertNil(AntigravityProfile.slug(fromProviderID: "antigravity-"))
        XCTAssertNil(AntigravityProfile.slug(fromProviderID: "cursor"))
    }

    func testDirectorySlugsIgnoreInternalFlavours() {
        XCTAssertEqual(AntigravityProfile.slug(fromDirectoryName: "antigravity-work"), "work")
        XCTAssertEqual(AntigravityProfile.slug(fromDirectoryName: "antigravity-client-1"), "client-1")
        XCTAssertNil(AntigravityProfile.slug(fromDirectoryName: "antigravity"), "default has no slug")
        XCTAssertNil(AntigravityProfile.slug(fromDirectoryName: "antigravity-"), "empty slug")
        XCTAssertNil(AntigravityProfile.slug(fromDirectoryName: "antigravity-ide"), "ide is internal flavour")
        XCTAssertNil(AntigravityProfile.slug(fromDirectoryName: "antigravity-cli"), "cli is internal flavour")
        XCTAssertNil(AntigravityProfile.slug(fromDirectoryName: "antigravity-backup"), "backup is internal flavour")
        XCTAssertNil(AntigravityProfile.slug(fromDirectoryName: "antigravity-api"), "api is internal flavour")
        XCTAssertNil(AntigravityProfile.slug(fromDirectoryName: "not-antigravity-work"))
    }

    // MARK: - Discovery

    func testDiscoveryFindsProfilesInStableOrder() throws {
        let root = try home([
            "antigravity": ["oauth_creds.json"],
            "antigravity-work": ["oauth_creds.json"],
            "antigravity-alpha": ["oauth_creds.json"],
            "antigravity-ide": ["oauth_creds.json"],
            "antigravity-cli": ["oauth_creds.json"],
            "antigravity-backup": ["agent.db"],
            "antigravity-empty": [],
            "antigravity-settings-only": ["settings.json"],
            "antigravity-state-only": ["state"],
            "antigravity-no-creds": ["brain/uuid/transcript.jsonl"],
            "other-tool": ["oauth_creds.json"]
        ])

        let found = AntigravityProfile.discover(home: root)
        XCTAssertEqual(found.map(\.id), ["gemini", "antigravity-alpha", "antigravity-work"])
        XCTAssertEqual(found.map(\.displayName), ["Antigravity", "Antigravity (alpha)", "Antigravity (work)"])
        XCTAssertEqual(found[0].configDirectory, root.appendingPathComponent(".gemini/antigravity"))
        XCTAssertEqual(found[1].configDirectory, root.appendingPathComponent(".gemini/antigravity-alpha"))
        XCTAssertEqual(found[2].configDirectory, root.appendingPathComponent(".gemini/antigravity-work"))
    }

    func testDiscoveryRequiresCredentials() throws {
        let root = try home([
            "antigravity-work": ["oauth_creds.json"],
            "antigravity-settings": ["settings.json"],
            "antigravity-state": ["state"],
            "antigravity-brain-only": ["brain/agent.db"]
        ])

        let found = AntigravityProfile.discover(home: root)
        XCTAssertEqual(found.map(\.id), ["gemini", "antigravity-work"])
    }

    func testDiscoveryRespectsCredentialFilter() throws {
        let root = try home([
            "antigravity-work": ["oauth_creds.json"],
            "antigravity-test": ["oauth_creds.json"]
        ])

        let found = AntigravityProfile.discover(home: root) { profile in
            profile.slug != "test"
        }
        XCTAssertEqual(found.map(\.id), ["gemini", "antigravity-work"])
    }

    // MARK: - Gemini-API Clash Prevention & Default-Off Rule

    func testGeminiAPIClashPrevention() {
        XCTAssertFalse(AntigravityProfile.isAntigravity(providerID: "gemini-api"))
        XCTAssertNil(AntigravityProfile.slug(fromProviderID: "gemini-api"))
        let summary = ProviderSummary(id: "gemini-api", name: "Gemini API", glyph: .geminiSpark, account: nil, signIn: .guidance(""))
        XCTAssertFalse(summary.usesKeychain)
        XCTAssertFalse(Preferences.isDefaultOnFamily("gemini-api"))
        XCTAssertNil(AntigravityProfile.slug(fromDirectoryName: "antigravity-api"))
    }

    func testAntigravityDefaultsOff() {
        XCTAssertFalse(Preferences.isDefaultOnFamily("gemini"), "Antigravity default must start off")
        XCTAssertFalse(Preferences.isDefaultOnFamily("antigravity-work"), "Antigravity profile must start off")
        XCTAssertFalse(Preferences.isDefaultOnFamily("antigravity-personal"), "Antigravity profile must start off")
        XCTAssertFalse(Preferences.isDefaultOnFamily("gemini-api"), "gemini-api must start off")
        XCTAssertTrue(Preferences.isDefaultOnFamily("claude"), "Claude defaults on")
        XCTAssertTrue(Preferences.isDefaultOnFamily("claude-work"), "Claude profiles default on")
        XCTAssertTrue(Preferences.isDefaultOnFamily("codex"), "Codex defaults on")
        XCTAssertTrue(Preferences.isDefaultOnFamily("codex-work"), "Codex profiles default on")
    }

    // MARK: - Activity Monitor Roots

    @MainActor
    func testActivityMonitorRoots() {
        let defaultProfile = AntigravityProfile.default(home: URL(fileURLWithPath: "/Users/test"))
        let workProfile = AntigravityProfile(slug: "work",
                                             configDirectory: URL(fileURLWithPath: "/Users/test/.gemini/antigravity-work"))

        let defaultMonitor = AntigravityActivityMonitor(profile: defaultProfile)
        XCTAssertNotNil(defaultMonitor)

        let workMonitor = AntigravityActivityMonitor(profile: workProfile)
        XCTAssertNotNil(workMonitor)
    }

    // MARK: - Account Details and Isolation

    func testAccountResolutionFromOAuthCreds() throws {
        let root = try home([
            "antigravity": [],
            "antigravity-work": []
        ])
        let workProfile = AntigravityProfile(slug: "work", configDirectory: root.appendingPathComponent(".gemini/antigravity-work"))

        let credsJSON = """
        {
            "access_token": "ya29.work-test-token",
            "expiry_date": 1893456000000,
            "email": "work@example.com",
            "project_id": "work-project"
        }
        """
        try credsJSON.data(using: .utf8)!.write(to: workProfile.authURL)

        XCTAssertTrue(AntigravityCredentials.isSignedIn(for: workProfile))
        let loaded = try AntigravityCredentials.load(for: workProfile)
        XCTAssertEqual(loaded.accessToken, "ya29.work-test-token")
        XCTAssertEqual(loaded.email, "work@example.com")
        XCTAssertEqual(loaded.projectId, "work-project")

        let provider = AntigravityProvider(profile: workProfile)
        let account = provider.account()
        XCTAssertEqual(account?.label, "work@example.com")
        XCTAssertEqual(account?.plan, "Personal")
        XCTAssertTrue(account?.source.contains("antigravity-work") ?? false)

        AntigravityCredentials.forgetCached(for: workProfile)
        XCTAssertNil(AntigravityCredentials.held(for: workProfile))
    }

    func testForgetCachedCredentialGrantsPromptPermission() {
        let defaultProfile = AntigravityProfile.default()
        let provider = AntigravityProvider(profile: defaultProfile)

        var promptedInteractive: Bool?
        AntigravityCredentials.readKeychainForTesting = { interactive in
            promptedInteractive = interactive
            return (errSecItemNotFound, nil)
        }
        addTeardownBlock { AntigravityCredentials.readKeychainForTesting = nil }

        provider.forgetCachedCredential()
        _ = try? AntigravityCredentials.load(for: defaultProfile)

        XCTAssertEqual(promptedInteractive, true, "Allow access... must grant interactive permission for default profile")
    }

    func testPromptPermissionIsIsolatedPerProfile() {
        let defaultProfile = AntigravityProfile.default()
        let workProfile = AntigravityProfile(slug: "work", configDirectory: URL(fileURLWithPath: "/tmp/antigravity-work"))
        let defaultProvider = AntigravityProvider(profile: defaultProfile)
        let workProvider = AntigravityProvider(profile: workProfile)

        var promptedInteractive: Bool?
        AntigravityCredentials.readKeychainForTesting = { interactive in
            promptedInteractive = interactive
            return (errSecItemNotFound, nil)
        }
        addTeardownBlock { AntigravityCredentials.readKeychainForTesting = nil }

        // Extra profile forgetCachedCredential must not grant default profile's keychain prompt
        AntigravityCredentials.forgetCached(for: defaultProfile)
        workProvider.forgetCachedCredential()
        _ = try? AntigravityCredentials.load(for: defaultProfile)
        XCTAssertEqual(promptedInteractive, false, "Extra profile grant must not grant default profile prompt")

        // Default profile forgetCachedCredential grants default's prompt
        defaultProvider.forgetCachedCredential()
        _ = try? AntigravityCredentials.load(for: defaultProfile)
        XCTAssertEqual(promptedInteractive, true, "Default profile grant must grant default profile prompt")
    }
}
