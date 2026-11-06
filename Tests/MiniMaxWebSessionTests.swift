import XCTest
@testable import Codenotch

/// MiniMax is signed into from Codenotch's own WKWebView, the same way
/// DeepSeek is. These pin the regional platform origin, the absolute www
/// remains fetch, and the extra host that sign-out has to clear.
@MainActor
final class MiniMaxWebSessionTests: XCTestCase {
    private let signedInKey = "minimax.signedIn"
    private let deepSeekSignedInKey = "deepseek.signedIn"
    private var savedSignedIn: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in [signedInKey, deepSeekSignedInKey] {
            savedSignedIn[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in [signedInKey, deepSeekSignedInKey] {
            if let value = savedSignedIn[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func testInternationalSiteFetchesWwwMinimaxIoRemains() {
        let site = Sites.minimax(region: .international)
        XCTAssertEqual(site.id, "minimax")
        XCTAssertEqual(site.displayName, "MiniMax")
        XCTAssertEqual(site.glyph, .minimax)
        XCTAssertEqual(site.origin, MiniMaxRegion.international.platformOrigin)
        XCTAssertEqual(site.fidelity, .derived)
        XCTAssertEqual(site.associatedHosts, ["www.minimax.io"])
        XCTAssertTrue(site.script.contains("https://www.minimax.io/v1/api/openplatform/coding_plan/remains"))
        XCTAssertFalse(site.script.contains("fetch('/v1/api"))
        XCTAssertFalse(site.script.contains("fetch(\"/v1/api"))
        XCTAssertFalse(site.script.contains("https://platform.minimax.io/v1/"))
        XCTAssertFalse(site.script.contains("https://api.minimax.io/"))
        XCTAssertTrue(site.script.contains("credentials: 'include'"))
        XCTAssertTrue(site.script.contains("status === 1004 || Number(code) === 1004"))
        XCTAssertTrue(site.script.contains("status = 401"))
        let probe = try! XCTUnwrap(site.authProbeScript)
        XCTAssertTrue(probe.contains("https://www.minimax.io/v1/api/openplatform/coding_plan/remains"))
        XCTAssertTrue(probe.contains("credentials: 'include'"))
        XCTAssertTrue(probe.contains("status === 1004 || Number(code) === 1004"))
        XCTAssertTrue(probe.contains("status = 401"))
    }

    func testChinaSiteFetchesWwwMinimaxCnRemains() {
        let site = Sites.minimax(region: .china)
        XCTAssertEqual(site.id, "minimax")
        XCTAssertEqual(site.origin, MiniMaxRegion.china.platformOrigin)
        XCTAssertEqual(site.fidelity, .derived)
        XCTAssertEqual(site.associatedHosts, ["www.minimax.cn", "platform.minimaxi.com", "www.minimaxi.com"])
        XCTAssertTrue(site.script.contains("https://www.minimax.cn/v1/api/openplatform/coding_plan/remains"))
        XCTAssertFalse(site.script.contains("https://www.minimax.io/"))
        XCTAssertFalse(site.script.contains("minimaxi.com"))
        XCTAssertFalse(site.script.contains("https://platform.minimax.cn/v1/"))
        let probe = try! XCTUnwrap(site.authProbeScript)
        XCTAssertTrue(probe.contains("https://www.minimax.cn/v1/api/openplatform/coding_plan/remains"))
        XCTAssertTrue(probe.contains("status === 1004 || Number(code) === 1004"))
    }

    /// platform.minimaxi.com answers 302 to platform.minimax.cn. The sign-in
    /// poll, the close-time probe and the usage read all wait for a page on
    /// `site.origin`, so an origin the console redirects away from left a
    /// finished sign-in unconfirmed and `minimax.signedIn` false (#516).
    func testChinaOriginIsThePageTheConsoleSettlesOn() {
        let origin = Sites.minimax(region: .china).origin
        XCTAssertTrue(WebSessionProvider.matchesOrigin(
            URL(string: "https://platform.minimax.cn/console/plan"), expected: origin
        ))
        XCTAssertFalse(WebSessionProvider.matchesOrigin(
            URL(string: "https://platform.minimaxi.com/"), expected: origin
        ))
    }

    /// The page reads remains with `credentials: 'include'`, so the remains
    /// host has to sit under the console's cookie domain. A host on another
    /// domain never receives the session, and the probe would always see 1004.
    func testEachRegionReadsRemainsOnTheConsolesOwnSite() throws {
        func site(of host: String?) -> String {
            (host ?? "").lowercased().split(separator: ".").suffix(2).joined(separator: ".")
        }
        for region in MiniMaxRegion.allCases {
            let web = Sites.minimax(region: region)
            let remainsHost = try XCTUnwrap(region.remainsURL.host)
            XCTAssertEqual(site(of: remainsHost), site(of: web.origin.host), "\(region)")
        }
    }

    func testAProbeMeansOpeningTheSheetIsNotYetASignIn() {
        WebSessionProvider(site: Sites.minimax(region: .international)).signInSheetDidOpen()
        XCTAssertFalse(UserDefaults.standard.bool(forKey: signedInKey),
                       "opening the sheet is not a sign-in for a site that can confirm one")
    }

    func testParseUsesTheRemainsWindows() throws {
        let json = """
        { "base_resp": { "status_code": 0 },
          "current_subscribe_title": "Max",
          "model_remains": [
            { "model_name": "general",
              "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "start_time": 1700000000000, "end_time": 1700018000000 } ] }
        """
        let windows = try Sites.minimax(region: .international).parse(json)
        let expected = try MiniMaxUsage.windows(fromJSON: json)
        XCTAssertEqual(windows.map(\.id), expected.map(\.id))
        XCTAssertEqual(windows.first?.usedFraction ?? -1, 0.75, accuracy: 0.0001)
    }

    func testInternationalOriginValidationRejectsContainingHostnames() {
        let origin = Sites.minimax(region: .international).origin
        XCTAssertTrue(WebSessionProvider.matchesOrigin(origin, expected: origin))
        XCTAssertTrue(WebSessionProvider.matchesOrigin(
            URL(string: "HTTPS://PLATFORM.MINIMAX.IO:443/usage"), expected: origin
        ))
        XCTAssertFalse(WebSessionProvider.matchesOrigin(
            MiniMaxRegion.china.platformOrigin, expected: origin
        ))

        for value in [
            "https://platform.minimax.io.attacker.example/",
            "https://attacker-platform.minimax.io/",
            "http://platform.minimax.io/",
            "https://www.minimax.io/",
            "https://platform.minimax.io:444/",
            "https://[::1]/",
            "https:/usage"
        ] {
            let url = URL(string: value)
            XCTAssertNotNil(url, value)
            XCTAssertFalse(WebSessionProvider.matchesOrigin(url, expected: origin), value)
        }
    }

    func testSignedInSessionAppearsAsAnAccountInSettings() {
        UserDefaults.standard.set(true, forKey: signedInKey)
        let international = WebSessionProvider(site: Sites.minimax(region: .international))
        XCTAssertEqual(international.account()?.source, "MiniMax")
        XCTAssertEqual(international.account()?.manageURL?.host, "platform.minimax.io")

        let china = WebSessionProvider(site: Sites.minimax(region: .china))
        XCTAssertEqual(china.account()?.manageURL?.host, "platform.minimax.cn")
    }

    func testApplySwitchesTheRegionalOriginWithoutChangingIdentity() {
        UserDefaults.standard.set(true, forKey: signedInKey)
        let provider = WebSessionProvider(site: Sites.minimax(region: .international))
        XCTAssertEqual(provider.id, "minimax")
        XCTAssertEqual(provider.displayName, "MiniMax")
        XCTAssertEqual(provider.account()?.manageURL?.host, "platform.minimax.io")

        provider.apply(site: Sites.minimax(region: .china))
        XCTAssertEqual(provider.id, "minimax")
        XCTAssertEqual(provider.displayName, "MiniMax")
        XCTAssertEqual(provider.account()?.manageURL?.host, "platform.minimax.cn")
        provider.apply(site: Sites.deepSeek)
        XCTAssertEqual(provider.id, "minimax")
        XCTAssertEqual(provider.displayName, "MiniMax")
        XCTAssertNotNil(provider.account(),
                        "MiniMax's signed-in flag must not follow DeepSeek's site id")
        XCTAssertEqual(provider.account()?.manageURL?.host, "platform.minimax.cn",
                       "a different site id must not replace MiniMax")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: deepSeekSignedInKey))
        XCTAssertTrue(UserDefaults.standard.bool(forKey: signedInKey))
    }

    func testDeepSeekAndPerplexityDoNotPickUpMiniMaxHosts() {
        XCTAssertTrue(Sites.deepSeek.associatedHosts.isEmpty)
        XCTAssertTrue(Sites.perplexity.associatedHosts.isEmpty)
        XCTAssertNil(Sites.perplexity.authProbeScript)
        XCTAssertNotNil(Sites.deepSeek.authProbeScript)
        XCTAssertEqual(WebSessionProvider.websiteDataHosts(for: Sites.deepSeek),
                       ["platform.deepseek.com"])
        XCTAssertEqual(WebSessionProvider.websiteDataHosts(for: Sites.perplexity),
                       ["www.perplexity.ai"])
        XCTAssertFalse(WebSessionProvider.websiteDataHosts(for: Sites.deepSeek)
            .contains("www.minimax.io"))
    }

    func testDeepSeekOriginCheckDoesNotAcceptMiniMaxOrContainingHosts() {
        let origin = Sites.deepSeek.origin
        XCTAssertTrue(WebSessionProvider.matchesOrigin(origin, expected: origin))
        XCTAssertTrue(WebSessionProvider.matchesOrigin(
            URL(string: "HTTPS://PLATFORM.DEEPSEEK.COM:443/usage"), expected: origin
        ))
        for value in [
            "https://www.minimax.io/",
            "https://platform.minimax.io/",
            "https://platform.deepseek.com.attacker.example/",
            "https://attacker-platform.deepseek.com/",
            "http://platform.deepseek.com/",
            "https://platform.deepseek.com:444/"
        ] {
            let url = URL(string: value)
            XCTAssertNotNil(url, value)
            XCTAssertFalse(WebSessionProvider.matchesOrigin(url, expected: origin), value)
        }
    }

    func testSignOutClearsPlatformAndWwwHosts() {
        XCTAssertEqual(
            WebSessionProvider.websiteDataHosts(for: Sites.minimax(region: .international)),
            ["platform.minimax.io", "www.minimax.io"]
        )
        XCTAssertEqual(
            WebSessionProvider.websiteDataHosts(for: Sites.minimax(region: .china)),
            ["platform.minimax.cn", "www.minimax.cn", "platform.minimaxi.com", "www.minimaxi.com"]
        )
    }

    func testAuthenticationFailureStatusesIncludeMiniMaxCookieCode() {
        XCTAssertTrue(WebSessionProvider.isAuthenticationFailureStatus(401))
        XCTAssertTrue(WebSessionProvider.isAuthenticationFailureStatus(403))
        XCTAssertTrue(WebSessionProvider.isAuthenticationFailureStatus(1004),
                      "MiniMax 1004 is a missing cookie, not a transport error")
        XCTAssertFalse(WebSessionProvider.isAuthenticationFailureStatus(200))
        XCTAssertFalse(WebSessionProvider.isAuthenticationFailureStatus(2045))
    }
}
