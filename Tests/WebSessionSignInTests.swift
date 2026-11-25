import WebKit
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
    private let keys = [
        "perplexity.signedIn", "deepseek.signedIn",
        "WebSessionSignInTests.old.signedIn", "WebSessionSignInTests.replacement.signedIn"
    ]
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

    /// The page a read loads must not outlive the read. A console left alive
    /// between polls was one WebContent process at 540 MB after six days, and
    /// the UI process stalled on its layer tree every time a poll woke it.
    ///
    /// Driven through a real page: the sign-in sheet's view is the same view a
    /// read uses, and opening it creates one without any network. While the
    /// sheet is up the page is the person's; once it is gone, the next
    /// release takes the page with it — and only *that* page, never a newer
    /// one that a superseded read might otherwise have torn down.
    func testReleasingThePageDropsTheViewButKeepsTheSession() {
        let key = "perplexity.signedIn"
        let provider = WebSessionProvider(site: Sites.perplexity)
        provider.signInSheetDidOpen()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))

        provider.releasePage()
        XCTAssertFalse(provider.holdsPageForTesting, "nothing had loaded a page yet")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key),
                      "the session is the cookie jar's, not the page's")
    }

    func testASheetKeepsItsPageAndAClosedSheetReleasesIt() {
        let provider = WebSessionProvider(site: fetchSite("old"))
        provider.presentSignIn()
        XCTAssertTrue(provider.holdsPageForTesting, "the sheet is showing a page")

        // A refresh that races the sheet must leave the sheet's page alone.
        provider.releasePage()
        XCTAssertTrue(provider.holdsPageForTesting, "a sign-in sheet's page is the person's to close")

        provider.signInWindowForTesting?.close()
        XCTAssertFalse(provider.holdsPageForTesting, "with the sheet gone the next release takes the page")
    }

    /// A read that was superseded while suspended — a region change ran
    /// `apply(site:)`, and a newer read loaded its own page — must not tear
    /// the newer page down as it leaves. Real pages here come from opening
    /// the sign-in sheet on a local page.
    func testAStaleReleaseTakesOnlyItsOwnPage() {
        let provider = WebSessionProvider(site: fetchSite("old"))

        provider.presentSignIn()
        let oldPage = try! XCTUnwrap(provider.pageForTesting)
        // The old read's exit, while its page is still the live one: takes it.
        provider.signInWindowForTesting?.close()
        XCTAssertFalse(provider.holdsPageForTesting)

        provider.presentSignIn()
        let newPage = try! XCTUnwrap(provider.pageForTesting)
        XCTAssertNotIdentical(newPage, oldPage, "a fresh sheet loads a fresh page")
        // The sheet goes without `windowWillClose` releasing the page, so the
        // only thing standing between the stale exit and the new page is the
        // `keeping` guard itself.
        provider.signInWindowForTesting?.delegate = nil
        provider.signInWindowForTesting?.close()
        provider.clearSignInWindowForTesting()
        XCTAssertTrue(provider.holdsPageForTesting)

        // The old read's exit arriving *now*, after the newer page exists.
        provider.releasePage(keeping: oldPage)
        XCTAssertTrue(provider.holdsPageForTesting, "the newer page survives a stale read's exit")

        provider.releasePage(keeping: newPage)
        XCTAssertFalse(provider.holdsPageForTesting, "the newer read's own exit takes its page")
    }

    func testCancelledInitialLoadLeavesReplacementPageAlone() async throws {
        try await assertReplacementSurvivesInitialLoad(cancelled: true)
    }

    func testFailedInitialLoadLeavesReplacementPageAlone() async throws {
        try await assertReplacementSurvivesInitialLoad(cancelled: false)
    }

    private func assertReplacementSurvivesInitialLoad(cancelled: Bool) async throws {
        let oldSite = fetchSite("old")
        let replacementSite = fetchSite("replacement")
        let oldLoad = PendingPageLoad(started: expectation(description: "original page loading"))
        let replacementLoad = PendingPageLoad(started: expectation(description: "replacement page loading"))
        let provider = WebSessionProvider(site: oldSite) { page, request in
            let load = request.url == oldSite.origin ? oldLoad : replacementLoad
            try await load.wait(on: page)
        }
        UserDefaults.standard.set(true, forKey: WebSessionProvider.sessionKey(for: oldSite))
        UserDefaults.standard.set(true, forKey: WebSessionProvider.sessionKey(for: replacementSite))

        let oldFetch = Task { try await provider.fetchSnapshot() }
        defer {
            oldFetch.cancel()
            oldLoad.finish(.failure(CancellationError()))
        }
        await fulfillment(of: [oldLoad.started], timeout: 5)
        let oldPage = try XCTUnwrap(oldLoad.page)
        XCTAssertIdentical(provider.pageForTesting, oldPage)

        if cancelled { oldFetch.cancel() }
        provider.apply(site: replacementSite)
        let replacementFetch = Task { try await provider.fetchSnapshot() }
        defer {
            replacementFetch.cancel()
            replacementLoad.finish(.failure(CancellationError()))
        }
        await fulfillment(of: [replacementLoad.started], timeout: 5)
        let replacementPage = try XCTUnwrap(replacementLoad.page)
        XCTAssertNotIdentical(replacementPage, oldPage)
        XCTAssertIdentical(provider.pageForTesting, replacementPage)

        if cancelled { oldLoad.finish(.success(())) }
        else { oldLoad.finish(.failure(LoadFailure())) }
        do {
            _ = try await oldFetch.value
            XCTFail("the original fetch should exit from its initial load")
        } catch {
            if cancelled { XCTAssertTrue(error is CancellationError, "\(error)") }
            else { XCTAssertTrue(error is LoadFailure, "\(error)") }
        }

        XCTAssertIdentical(provider.pageForTesting, replacementPage,
                           "the original fetch must leave the replacement page in place")
        XCTAssertTrue(replacementLoad.isPending, "the replacement fetch is still loading")
        replacementLoad.finish(.failure(LoadFailure()))
        _ = await replacementFetch.result
    }

    func testFailedInitialLoadWithoutReplacementReleasesItsPage() async throws {
        let site = fetchSite("old")
        let load = PendingPageLoad(started: expectation(description: "page loading"))
        let provider = WebSessionProvider(site: site) { page, _ in try await load.wait(on: page) }
        let key = WebSessionProvider.sessionKey(for: site)
        UserDefaults.standard.set(true, forKey: key)

        let fetch = Task { try await provider.fetchSnapshot() }
        defer {
            fetch.cancel()
            load.finish(.failure(CancellationError()))
        }
        await fulfillment(of: [load.started], timeout: 5)
        let page = try XCTUnwrap(load.page)
        XCTAssertIdentical(provider.pageForTesting, page)

        load.finish(.failure(LoadFailure()))
        do {
            _ = try await fetch.value
            XCTFail("the fetch should report the initial load failure")
        } catch {
            XCTAssertTrue(error is LoadFailure, "\(error)")
        }
        XCTAssertNil(provider.pageForTesting)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
    }

    func testFailedAuthReloadKeepsReplacementSignIn() async throws {
        let oldSite = fetchSite("old", reloadsSessionOnAuthFailure: true)
        let replacementSite = fetchSite("replacement")
        let reload = PendingPageLoad(started: expectation(description: "auth reload started"))
        var initialPage: WKWebView?
        let provider = WebSessionProvider(site: oldSite) { page, _ in
            if let initialPage {
                XCTAssertIdentical(page, initialPage, "the auth reload uses the original page")
                try await reload.wait(on: page)
            } else {
                initialPage = page
            }
        }
        UserDefaults.standard.set(true, forKey: WebSessionProvider.sessionKey(for: oldSite))
        let replacementKey = WebSessionProvider.sessionKey(for: replacementSite)
        UserDefaults.standard.set(true, forKey: replacementKey)

        let fetch = Task { try await provider.fetchSnapshot() }
        defer {
            fetch.cancel()
            reload.finish(.failure(CancellationError()))
        }
        await fulfillment(of: [reload.started], timeout: 5)
        XCTAssertIdentical(provider.pageForTesting, try XCTUnwrap(reload.page))

        provider.apply(site: replacementSite)
        reload.finish(.failure(LoadFailure()))
        do {
            _ = try await fetch.value
            XCTFail("the fetch should be retired after the region change")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(UserDefaults.standard.bool(forKey: replacementKey))
    }

    private func fetchSite(_ region: String, reloadsSessionOnAuthFailure: Bool = false) -> WebSessionProvider.Site {
        WebSessionProvider.Site(
            id: "WebSessionSignInTests", displayName: "Test site", glyph: Sites.perplexity.glyph,
            origin: URL(string: "about:blank#\(region)")!,
            script: #"return JSON.stringify({ status: 401, body: "" });"#,
            sessionKey: "WebSessionSignInTests.\(region).signedIn",
            reloadsSessionOnAuthFailure: reloadsSessionOnAuthFailure
        ) { _ in [] }
    }

    private struct LoadFailure: Error {}

    @MainActor
    private final class PendingPageLoad {
        let started: XCTestExpectation
        private(set) var page: WKWebView?
        private var continuation: CheckedContinuation<Void, Error>?
        var isPending: Bool { continuation != nil }

        init(started: XCTestExpectation) {
            self.started = started
        }

        func wait(on page: WKWebView) async throws {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.page = page
                self.continuation = continuation
                started.fulfill()
            }
            try Task.checkCancellation()
        }

        func finish(_ result: Result<Void, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
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
}
