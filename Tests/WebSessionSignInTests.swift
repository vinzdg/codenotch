import XCTest
@testable import Codenotch

/// Opening a sign-in sheet has to leave every site able to become signed in.
///
/// DeepSeek confirms a sign-in itself, by probing the page until it sees an
/// authenticated session, so it is not marked signed in until that happens.
/// Perplexity has no such probe. Waiting for one there meant waiting for
/// something that never runs: the sheet closed and the provider stayed at
/// "needs sign-in" for good, with nothing in the suite to notice.
@MainActor
final class WebSessionSignInTests: XCTestCase {
    /// These run inside the app, so the flags are the installed app's own
    /// preferences — saved and put back rather than left clobbered.
    private let keys = ["perplexity.signedIn", "deepseek.signedIn"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testASiteWithoutAProbeIsSignedInOnceItsSheetOpens() {
        WebSessionProvider(site: Sites.perplexity).signInSheetDidOpen()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "perplexity.signedIn"),
                      "Perplexity has no probe to confirm a sign-in, so it could never become signed in")
    }

    func testASiteWithAProbeWaitsForItToConfirm() {
        WebSessionProvider(site: Sites.deepSeek).signInSheetDidOpen()
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "deepseek.signedIn"),
                       "opening the sheet is not a sign-in for a site that can confirm one")
    }

    func testDeepSeekOriginValidationRejectsContainingHostnames() {
        let origin = Sites.deepSeek.origin
        XCTAssertTrue(WebSessionProvider.matchesOrigin(origin, expected: origin))
        XCTAssertTrue(WebSessionProvider.matchesOrigin(
            URL(string: "HTTPS://PLATFORM.DEEPSEEK.COM:443/usage"), expected: origin
        ))

        for value in [
            "https://platform.deepseek.com.attacker.example/",
            "https://attacker-platform.deepseek.com/",
            "http://platform.deepseek.com/",
            "https://platform.deepseek.com:444/",
            "https://[::1]/",
            "https:/usage"
        ] {
            let url = URL(string: value)
            XCTAssertNotNil(url, value)
            XCTAssertFalse(WebSessionProvider.matchesOrigin(url, expected: origin), value)
        }
    }

    /// DeepSeek and MiniMax confirm a sign-in once, when the window closes
    /// (#172): their probes are real API calls to endpoints that have
    /// throttled the app. Polling them while someone types a password came
    /// back once, with a new site that needed it; only that site polls.
    func testOnlyQianwenPollsWhileItsSignInWindowIsOpen() {
        XCTAssertFalse(Sites.deepSeek.pollsDuringSignIn)
        for region in MiniMaxRegion.allCases {
            XCTAssertFalse(Sites.minimax(region: region).pollsDuringSignIn)
        }
        XCTAssertFalse(Sites.perplexity.pollsDuringSignIn)
        XCTAssertTrue(Sites.qianwen.pollsDuringSignIn)
    }

    /// Signing out of QianwenAI also has to drop the Aliyun SSO cookie, or the
    /// next sign-in walks straight back in as the old account.
    func testQianwenSignOutClearsTheAliyunSignIn() {
        XCTAssertTrue(Sites.qianwen.associatedHosts.contains("account.aliyun.com"))
    }

    /// XyToken keeps its own site and parser, but it leans on this provider for
    /// everything the settings list reads: the session flag is the account, so
    /// signing in has to make the row show one and signing out has to clear it.
    /// That is the whole of what the fork's dropped settings-side rework used to
    /// add here, and it already works upstream.
    func testXyTokenSignedInFlagBecomesItsAccount() {
        let key = "xytoken.signedIn"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let provider = WebSessionProvider(site: Sites.xytoken)
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertNil(provider.account(), "a signed-out session is not an account")

        UserDefaults.standard.set(true, forKey: key)
        XCTAssertEqual(provider.account()?.source, "XyToken")
    }
}
