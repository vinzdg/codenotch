import Combine
import XCTest
@testable import Codenotch

@MainActor
final class ConfiguredProfileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfiguredProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "ConfiguredProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    // MARK: - ProfileFamily slug normalization & lookup

    func testSlugNormalizationStripsPrefixesAndRejectsInvalidSlugs() {
        XCTAssertEqual(ProfileFamily.claude.normalizeSlug("work"), "work")
        XCTAssertEqual(ProfileFamily.claude.normalizeSlug("  Work  "), "work")
        XCTAssertEqual(ProfileFamily.claude.normalizeSlug(".claude-work"), "work")
        XCTAssertEqual(ProfileFamily.claude.normalizeSlug("~/.claude-work"), "work")
        XCTAssertEqual(ProfileFamily.claude.normalizeSlug("claude-team_1"), "team_1")
        XCTAssertEqual(ProfileFamily.claude.normalizeSlug("my work account"), "my-work-account")
        XCTAssertNil(ProfileFamily.claude.normalizeSlug(""))
        XCTAssertNil(ProfileFamily.claude.normalizeSlug("   "))
        XCTAssertNil(ProfileFamily.claude.normalizeSlug("---"))
        XCTAssertNil(ProfileFamily.antigravity.normalizeSlug("ide"))
        XCTAssertNil(ProfileFamily.antigravity.normalizeSlug("cli"))
        XCTAssertNil(ProfileFamily.antigravity.normalizeSlug("backup"))
        XCTAssertNil(ProfileFamily.antigravity.normalizeSlug("api"))
        XCTAssertEqual(ProfileFamily.antigravity.normalizeSlug("work"), "work")
    }

    func testFamilyAndSlugResolutionFromProviderID() {
        XCTAssertEqual(ProfileFamily.family(forProviderID: "claude"), .claude)
        XCTAssertEqual(ProfileFamily.family(forProviderID: "claude-work"), .claude)
        XCTAssertEqual(ProfileFamily.family(forProviderID: "codex"), .codex)
        XCTAssertEqual(ProfileFamily.family(forProviderID: "codex-work"), .codex)
        XCTAssertEqual(ProfileFamily.family(forProviderID: "gemini"), .antigravity)
        XCTAssertEqual(ProfileFamily.family(forProviderID: "antigravity-work"), .antigravity)
        XCTAssertEqual(ProfileFamily.family(forProviderID: "commandcode"), .commandCode)
        XCTAssertEqual(ProfileFamily.family(forProviderID: "commandcode-work"), .commandCode)
        XCTAssertNil(ProfileFamily.family(forProviderID: "cursor"))

        XCTAssertNil(ProfileFamily.slug(forProviderID: "claude"))
        XCTAssertEqual(ProfileFamily.slug(forProviderID: "claude-work"), "work")
        XCTAssertFalse(ProfileFamily.isExtraProfile(providerID: "claude"))
        XCTAssertTrue(ProfileFamily.isExtraProfile(providerID: "claude-work"))
    }

    // MARK: - Configured slugs in Profile discovery

    func testConfiguredSlugsAreDiscoveredBeforeCredentialsExist() {
        let claude = ClaudeProfile.discover(home: root, configuredSlugs: ["work", "personal"]) { _ in false }
        XCTAssertEqual(claude.map(\.id), ["claude", "claude-personal", "claude-work"])

        let codex = CodexProfile.discover(home: root, configuredSlugs: ["work"])
        XCTAssertEqual(codex.map(\.id), ["codex", "codex-work"])

        let antigravity = AntigravityProfile.discover(home: root, configuredSlugs: ["work", "ide"]) { _ in false }
        XCTAssertEqual(antigravity.map(\.id), ["gemini", "antigravity-work"])

        let commandCode = CommandCodeProfile.discover(home: root, configuredSlugs: ["work"])
        XCTAssertEqual(commandCode.map(\.id), ["commandcode", "commandcode-work"])
    }

    // MARK: - Preferences profile management & active seat switching

    func testAddAndRemoveConfiguredProfilePersistsAndCreatesDirectory() {
        let (defaults, suiteName) = makeDefaults()
        let preferences = Preferences(defaults: defaults)

        let added = preferences.addProfile(family: .claude, slug: "work", home: root)
        XCTAssertEqual(added, ConfiguredProfile(family: .claude, slug: "work"))
        XCTAssertTrue(preferences.isConnected("claude-work"))
        XCTAssertEqual(preferences.configuredSlugs(for: .claude), ["work"])

        var isDir: ObjCBool = false
        let expectedDir = root.appendingPathComponent(".claude-work")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        // Duplicate add returns the existing profile without duplicating the list
        let duplicate = preferences.addProfile(family: .claude, slug: ".claude-work", home: root)
        XCTAssertEqual(duplicate, added)
        XCTAssertEqual(preferences.configuredProfiles.count, 1)

        // Persisted across reloads
        let reloaded = Preferences(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reloaded.configuredProfiles, [ConfiguredProfile(family: .claude, slug: "work")])

        // Removing clears from configuredProfiles and disconnects
        preferences.removeProfile(id: "claude-work")
        XCTAssertTrue(preferences.configuredProfiles.isEmpty)
        XCTAssertFalse(preferences.isConnected("claude-work"))
    }

    func testSwitchActiveProfileSwapsActiveSeatInPlace() {
        let (defaults, _) = makeDefaults()
        let preferences = Preferences(defaults: defaults)
        let allIDs = ["claude", "claude-work", "claude-personal", "codex", "cursor"]
        preferences.reconcile(discoveredIDs: allIDs)
        preferences.setConnected(true, for: "cursor")
        preferences.setConnected(false, for: "claude-work")
        preferences.setConnected(false, for: "claude-personal")
        preferences.setProviderOrder(["cursor", "claude", "codex", "claude-work", "claude-personal"])

        XCTAssertTrue(preferences.isConnected("claude"))
        XCTAssertFalse(preferences.isConnected("claude-work"))

        // Switch active Claude seat from default "claude" to "claude-work"
        preferences.switchActiveProfile(to: "claude-work", among: allIDs)

        XCTAssertTrue(preferences.isConnected("claude-work"))
        XCTAssertFalse(preferences.isConnected("claude"))
        XCTAssertFalse(preferences.isConnected("claude-personal"))
        // Other providers remain untouched
        XCTAssertTrue(preferences.isConnected("codex"))
        XCTAssertTrue(preferences.isConnected("cursor"))
        // "claude-work" takes the slot where "claude" was in providerOrder
        XCTAssertEqual(preferences.providerOrder.prefix(3), ["cursor", "claude-work", "codex"])
    }

    // MARK: - ActivityCoordinator dynamic monitor sync

    func testActivityCoordinatorSyncMonitorsStartsAddedAndStopsRemoved() {
        @MainActor
        final class FakeMonitor: AgentActivityMonitor {
            var sessions: [AgentSession] = []
            private let subject = CurrentValueSubject<[AgentSession], Never>([])
            var sessionsPublisher: AnyPublisher<[AgentSession], Never> { subject.eraseToAnyPublisher() }
            var startCount = 0
            var stopCount = 0
            func start() { startCount += 1 }
            func stop() { stopCount += 1 }
        }

        let claudeDefault = FakeMonitor()
        let claudeWork = FakeMonitor()
        let coordinator = ActivityCoordinator(monitors: ["claude": claudeDefault]) { _, _ in }
        coordinator.setEnabled(["claude", "claude-work"])
        XCTAssertEqual(claudeDefault.startCount, 1)

        // Adding claude-work starts claude-work without restarting claudeDefault
        coordinator.syncMonitors(["claude": claudeDefault, "claude-work": claudeWork])
        XCTAssertEqual(claudeDefault.startCount, 1)
        XCTAssertEqual(claudeDefault.stopCount, 0)
        XCTAssertEqual(claudeWork.startCount, 1)

        // Removing claude-work stops it cleanly
        coordinator.syncMonitors(["claude": claudeDefault])
        XCTAssertEqual(claudeWork.stopCount, 1)
        XCTAssertEqual(claudeDefault.stopCount, 0)
    }
}
