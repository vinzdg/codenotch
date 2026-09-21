import Combine
import XCTest
@testable import Codenotch

/// Remote extra rings are a separate reading of the same assistant. Settings
/// still toggles the assistant id; the extra cell must not leak when that
/// assistant is off, even if a remote session exists.
@MainActor
final class RemoteUsageTests: XCTestCase {
    private func makeStore(_ providers: [UsageProvider], disconnected: Set<String> = [])
        -> UsageStore {
        let name = "RemoteUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let archive = UsageArchive(defaults: defaults)
        return UsageStore(providers: providers, archive: archive, disconnected: disconnected)
    }

    // SPECSFY: US-001 US-002 FR-001 NFR-003 AC-001
    func testDisabledRemoteAssistantDoesNotPublishAnExtraRing() {
        let assistant = RemoteUsageProbe(id: "claude", connectionName: "local")
        let remoteSession = RemoteUsageProbe(id: "claude:Artemis", connectionName: "Artemis")
        let store = makeStore([assistant, remoteSession], disconnected: [assistant.id])

        XCTAssertFalse(
            store.notchSnapshots.contains { $0.id == remoteSession.id },
            "an extra remote ring appeared while the assistant was off in Settings"
        )
        XCTAssertFalse(
            store.notchSnapshots.contains { $0.id == assistant.id },
            "the local assistant ring also has to stay off"
        )
    }
}

/// Same glyph as the assistant, distinct identity for the remote connection.
private final class RemoteUsageProbe: UsageProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let glyph = ProviderGlyph.claude

    init(id: String, connectionName: String) {
        self.id = id
        self.displayName = connectionName
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.42)]
        )
    }

    func account() -> ProviderAccount? {
        ProviderAccount(label: displayName, plan: nil, source: "RemoteUsageProbe", manageURL: nil)
    }

    nonisolated var signInRoute: SignInRoute { .guidance("") }
    func signOut() async {}
    func presentSignIn() {}
    nonisolated func forgetCachedCredential() {}
}
