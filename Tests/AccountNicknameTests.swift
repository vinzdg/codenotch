import XCTest
@testable import Codenotch

/// An account is called what its owner named it, everywhere at once: the
/// name lives in Preferences and the store writes it into every snapshot it
/// publishes, so the notch, the menu bar and the notifications never
/// disagree with the Accounts row.
@MainActor
final class AccountNicknameTests: XCTestCase {
    private final class Stub: UsageProvider, @unchecked Sendable {
        let id = "claude-work"
        let displayName = "Claude (work)"
        let glyph = ProviderGlyph.claude
        var signInRoute: SignInRoute { .guidance("") }
        func account() -> ProviderAccount? { nil }
        func presentSignIn() {}
        func fetchSnapshot() async throws -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                             fidelity: .official, status: .ok, windows: [])
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "AccountNicknameTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func store() -> UsageStore {
        UsageStore(providers: [Stub()], archive: UsageArchive(defaults: makeDefaults()))
    }

    // MARK: The store

    func testTheStoreRenamesWhatItHasAlreadyPublished() {
        let store = store()
        XCTAssertEqual(store.snapshots.map(\.displayName), ["Claude (work)"])
        store.nicknames = ["claude-work": "Acme"]
        XCTAssertEqual(store.snapshots.map(\.displayName), ["Acme"])
        XCTAssertEqual(store.notchSnapshots.map(\.displayName), ["Acme"])
    }

    func testClearingTheNameGoesBackToTheProviders() {
        let store = store()
        store.nicknames = ["claude-work": "Acme"]
        store.nicknames = [:]
        XCTAssertEqual(store.snapshots.map(\.displayName), ["Claude (work)"])
    }

    func testANameForAnotherAccountChangesNothingHere() {
        let store = store()
        store.nicknames = ["codex": "Work Codex"]
        XCTAssertEqual(store.snapshots.map(\.displayName), ["Claude (work)"])
    }

    // MARK: Preferences

    func testTheNameIsKeptAcrossLaunches() {
        let defaults = makeDefaults()
        Preferences(defaults: defaults).setNickname("Acme", for: "claude-work")
        XCTAssertEqual(Preferences(defaults: defaults).nickname(for: "claude-work"), "Acme")
    }

    func testBlankMeansNoName() {
        let preferences = Preferences(defaults: makeDefaults())
        preferences.setNickname("Acme", for: "claude-work")
        preferences.setNickname("   ", for: "claude-work")
        XCTAssertNil(preferences.nickname(for: "claude-work"))
        XCTAssertTrue(preferences.accountNicknames.isEmpty)
    }

    func testSurroundingSpacesAreNotPartOfTheName() {
        let preferences = Preferences(defaults: makeDefaults())
        preferences.setNickname("  Acme ", for: "claude-work")
        XCTAssertEqual(preferences.nickname(for: "claude-work"), "Acme")
    }
}
