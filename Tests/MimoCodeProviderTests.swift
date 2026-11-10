import XCTest
@testable import Codenotch

final class MimoCodeProviderTests: XCTestCase {
    func testProviderIdentity() {
        let provider = MimoCodeProvider()
        XCTAssertEqual(provider.id, "mimocode")
        XCTAssertEqual(provider.displayName, "MimoCode")
        XCTAssertEqual(provider.glyph, .mimocode)
        XCTAssertEqual(provider.glyph.brandColor, ProviderGlyph.mimocode.brandColor)
    }

    func testSignInRoute() {
        let provider = MimoCodeProvider()
        let route = provider.signInRoute
        if case .command(let cmd, let name, let install) = route {
            XCTAssertEqual(cmd, "mimo auth login")
            XCTAssertEqual(name, "MimoCode")
            XCTAssertEqual(install?.absoluteString, "https://mimo.xiaomi.com")
        } else {
            XCTFail("Expected .command signInRoute, got \(route)")
        }
    }

    func testIsVisibleWhenAbsentReflectsCredentials() {
        var absentSources = MimoCodeCredentialSources()
        absentSources.settingsPresent = { false }
        absentSources.settingsToken = { nil }
        absentSources.environment = [:]
        absentSources.credentialsURLs = []
        absentSources.locateBinary = { nil }

        let absentProvider = MimoCodeProvider(sources: absentSources)
        XCTAssertFalse(absentProvider.isVisibleWhenAbsent)
        XCTAssertNil(absentProvider.account())

        var presentSources = MimoCodeCredentialSources()
        presentSources.settingsPresent = { true }
        presentSources.settingsToken = { "test-token" }
        presentSources.locateBinary = { nil }

        let presentProvider = MimoCodeProvider(sources: presentSources)
        XCTAssertTrue(presentProvider.isVisibleWhenAbsent)
        let acct = presentProvider.account()
        XCTAssertNotNil(acct)
        XCTAssertEqual(acct?.source, "MimoCode")
        XCTAssertEqual(acct?.manageURL?.absoluteString, "https://platform.xiaomimimo.com/console/plan-manage")
    }

    func testSignOutClearsSettingsToken() async {
        var tokenDeleted = false
        var sources = MimoCodeCredentialSources()
        sources.deleteSettingsToken = { tokenDeleted = true }

        let provider = MimoCodeProvider(sources: sources)
        await provider.signOut()
        XCTAssertTrue(tokenDeleted)
    }

    func testFetchSnapshotThrowsNeedsAuthWhenNoCredentials() async {
        var sources = MimoCodeCredentialSources()
        sources.settingsPresent = { false }
        sources.settingsToken = { nil }
        sources.environment = [:]
        sources.credentialsURLs = []
        sources.locateBinary = { nil }

        let provider = MimoCodeProvider(sources: sources)
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("Expected needsAuth error")
        } catch let error as UsageProviderError {
            guard case .needsAuth = error else {
                return XCTFail("Expected .needsAuth, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
