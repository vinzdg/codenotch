import XCTest
@testable import Codenotch

final class QoderUsageTests: XCTestCase {
    func testSharedQuotaAndMilliseconds() throws {
        let windows = try QoderUsage.windows(fromJSON: #"{"totalQuota":{"quotaSummary":{"usedValue":25.5,"limitValue":100}},"sharedQuota":{"quotaSummary":{"usedValue":10,"limitValue":100}},"nextResetAt":1700000000000}"#)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].usedFraction!, 0.1775, accuracy: 0.000001)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1700000000))
    }

    func testSnakeCaseAndOverage() throws {
        let window = try XCTUnwrap(QoderUsage.windows(fromJSON: #"{"total_quota":{"quota_summary":{"used_value":120,"limit_value":100}},"next_reset_at":"2023-11-14T22:13:20.000Z"}"#).first)
        XCTAssertEqual(window.usedFraction, 1.2)
        XCTAssertEqual(window.resetsAt, Date(timeIntervalSince1970: 1700000000))
    }

    func testRejectsChallengeAndInvalidQuota() {
        for json in ["<html>challenge</html>", "{}",
            #"{"totalQuota":{"quotaSummary":{"usedValue":true,"limitValue":100}}}"#,
            #"{"totalQuota":{"quotaSummary":{"usedValue":-1,"limitValue":100}}}"#,
            #"{"totalQuota":{"quotaSummary":{"usedValue":0,"limitValue":0}}}"#,
            #"{"totalQuota":{"quotaSummary":{"usedValue":1,"limitValue":100}},"sharedQuota":{}}"#] {
            XCTAssertThrowsError(try QoderUsage.windows(fromJSON: json))
        }
    }
}

@MainActor
final class QoderIntegrationTests: XCTestCase {
    func testRegionsKeepIndependentSessionKeysAndOrigins() {
        let global = Sites.qoder(region: .global)
        let china = Sites.qoder(region: .china)
        XCTAssertEqual(global.id, "qoder")
        XCTAssertEqual(china.id, "qoder")
        XCTAssertEqual(global.origin.host, "qoder.com")
        XCTAssertEqual(china.origin.host, "qoder.com.cn")
        XCTAssertNotEqual(WebSessionProvider.sessionKey(for: global), WebSessionProvider.sessionKey(for: china))
        XCTAssertEqual(global.initialPath, "account/usage")
        XCTAssertEqual(global.headlineID, "credits")
        XCTAssertFalse(global.logsResponseBody)
        XCTAssertFalse(global.pollsDuringSignIn)
        XCTAssertNotNil(global.authProbeScript)
        XCTAssertFalse(global.script.contains("2.5.35"))
        XCTAssertFalse(global.script.contains("User-Agent"))
    }

    func testForbiddenDoesNotAssertExpiredSession() throws {
        let site = Sites.qoder(region: .global)
        guard case .apiError = try XCTUnwrap(WebSessionProvider.responseFailure(status: 403, site: site))
        else { return XCTFail("A WAF refusal is not proof of expired authentication") }
        guard case .needsAuth = try XCTUnwrap(WebSessionProvider.responseFailure(status: 401, site: site))
        else { return XCTFail("401 must require authentication") }
        XCTAssertNil(WebSessionProvider.responseFailure(status: 200, site: site))
        guard case .needsAuth = try XCTUnwrap(WebSessionProvider.responseFailure(status: 403, site: Sites.deepSeek))
        else { return XCTFail("Existing provider behavior must remain compatible") }
    }

    func testRegionPreferenceRoundTripWithoutStandardDefaults() {
        let name = "QoderIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.qoderRegion, .global)
        preferences.qoderRegion = .china
        XCTAssertEqual(Preferences(defaults: defaults).qoderRegion, .china)
    }

    func testRegionChangeDiscardsReadingBeforeApplyingNewOrigin() {
        let name = "QoderIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let archive = UsageArchive(defaults: defaults)
        let provider = WebSessionProvider(site: Sites.qoder(region: .global))
        let old = ProviderSnapshot(id: "qoder", displayName: "Qoder", glyph: .qoder,
                                  fidelity: .official, status: .ok,
                                  windows: [LimitWindow(id: "credits", label: "Credits", usedFraction: 0.5)])
        archive.save(["qoder": (snapshot: old, fetchedAt: Date())])
        let store = UsageStore(providers: [provider], archive: archive)
        store.providerContextChanged(providerID: "qoder") {
            XCTAssertNil(archive.load()["qoder"])
            XCTAssertFalse(store.snapshots.contains { $0.id == "qoder" && $0.hasReading })
            provider.apply(site: Sites.qoder(region: .china))
        }
        store.stop()
    }
}
