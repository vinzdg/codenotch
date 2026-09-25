import XCTest
@testable import Codenotch

/// A refresh must never be able to wedge the store.
///
/// This is from life: a keychain authorization prompt went unanswered, the
/// Claude fetch behind it blocked on `SecItemCopyMatching`, the pass never
/// returned, and `isRefreshing` stayed true. Every tick for the next eighty
/// minutes logged "refresh skipped: one already in flight" and the app quietly
/// stopped reading anything at all, while still looking perfectly alive.
@MainActor
final class UsageRefreshDeadlineTests: XCTestCase {
    /// Hangs until it is let go, the way a blocked keychain read does.
    private final class BlockingProvider: UsageProvider, @unchecked Sendable {
        let id: String
        let displayName = "Blocked"
        let glyph = ProviderGlyph.claude
        private(set) var calls = 0
        private var resume: CheckedContinuation<Void, Never>?

        init(id: String = "blocked") { self.id = id }

        func fetchSnapshot() async throws -> ProviderSnapshot {
            calls += 1
            await withCheckedContinuation { self.resume = $0 }
            return Self.reading(id: id, displayName: displayName, glyph: glyph, used: 0.9)
        }

        func release() { resume?.resume(); resume = nil }
        func signOut() async {}

        static func reading(id: String, displayName: String, glyph: ProviderGlyph,
                            used: Double) -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                             fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "w", label: "W", usedFraction: used)])
        }
    }

    /// Answers at once, so a pass around a blocked one can be seen to complete.
    private final class QuickProvider: UsageProvider, @unchecked Sendable {
        let id: String
        let displayName = "Quick"
        let glyph = ProviderGlyph.openai
        private(set) var calls = 0
        var fails = false

        init(id: String = "quick") { self.id = id }

        func fetchSnapshot() async throws -> ProviderSnapshot {
            calls += 1
            if fails { throw UsageProviderError.badResponse(status: 500) }
            return BlockingProvider.reading(id: id, displayName: displayName,
                                            glyph: glyph, used: 0.2)
        }

        func signOut() async {}
    }

    private func store(_ providers: [any UsageProvider],
                       deadline: TimeInterval = 0.25) -> UsageStore {
        let name = "UsageRefreshDeadlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return UsageStore(providers: providers, refreshDeadline: deadline,
                          archive: UsageArchive(defaults: defaults))
    }

    private func settle(_ seconds: Double = 0.8) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Success

    func testASuccessfulPassReleasesTheFlag() async {
        let store = store([QuickProvider()])
        store.refreshNow()
        await settle(0.3)
        XCTAssertFalse(store.isRefreshingForTesting)
        XCTAssertTrue(store.inFlightForTesting.isEmpty)
    }

    // MARK: - Error

    /// A thrown error is still an answer, and answers release the flag. This
    /// path always worked; it is here so a change to the deadline cannot break
    /// it without saying so.
    func testAThrownErrorReleasesTheFlag() async {
        let failing = QuickProvider()
        failing.fails = true
        let store = store([failing])
        store.refreshNow()
        await settle(0.3)
        XCTAssertFalse(store.isRefreshingForTesting)
        XCTAssertEqual(store.snapshots.first?.status, .error("HTTP 500"))
    }

    // MARK: - Timeout

    func testABlockedPassIsAbandonedAndTheFlagReleased() async {
        let blocked = BlockingProvider()
        let store = store([blocked])
        store.refreshNow()
        XCTAssertTrue(store.isRefreshingForTesting, "the pass has started")

        await settle()
        XCTAssertFalse(store.isRefreshingForTesting, "the deadline must free the store")
        XCTAssertTrue(store.refreshing.isEmpty, "and stop the cell spinning")
        blocked.release()
    }

    /// The abandoned provider says so rather than sitting there looking fine.
    func testAnAbandonedProviderSaysItGotNoResponse() async {
        let blocked = BlockingProvider()
        let store = store([blocked])
        store.refreshNow()
        await settle()
        XCTAssertEqual(store.snapshots.first { $0.id == "blocked" }?.status,
                       .error("no response"))
        blocked.release()
    }

    // MARK: - No concurrency

    func testASecondRefreshIsRefusedWhileOneIsRunning() async {
        let blocked = BlockingProvider()
        let store = store([blocked], deadline: 30)
        store.refreshNow()
        store.refreshNow()
        await settle(0.2)
        XCTAssertEqual(blocked.calls, 1, "the second must not start a second pass")
        blocked.release()
    }

    /// Refused, but not turned away empty-handed: the second caller is given
    /// the pass that is running, so it can wait for the same readings. The
    /// menu's Refresh all says "Refreshing…" for as long as that takes.
    func testASecondCallerIsHandedThePassAlreadyRunning() async {
        let blocked = BlockingProvider()
        let store = store([blocked], deadline: 30)
        let first = store.refreshNow()
        let second = store.refreshNow()
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        await settle(0.2)
        blocked.release()
    }

    // MARK: - Recovery

    /// The point of the whole change, and the exact shape of the bug: the
    /// blocked provider is *first*, so the wedged pass never reached the one
    /// behind it, permanently — that provider was never read again for as long
    /// as the app ran.
    ///
    /// Each provider now gets its own task, so the one behind the hang is
    /// reached on the same pass rather than the next; the deadline is what
    /// stops the *pass* waiting on the hang for ever.
    func testAProviderBehindAStuckOneIsStillRead() async {
        let blocked = BlockingProvider()
        let quick = QuickProvider()
        let store = store([blocked, quick])

        store.refreshNow()
        await settle()
        XCTAssertFalse(store.isRefreshingForTesting)
        XCTAssertEqual(quick.calls, 1, "the stuck provider does not hold up the one behind it")
        XCTAssertEqual(store.snapshots.first { $0.id == "quick" }?.status, .ok)

        store.refreshNow()
        await settle(0.3)
        XCTAssertEqual(quick.calls, 2, "and it keeps being read while the other stays stuck")
        XCTAssertEqual(blocked.calls, 1, "with no second call queued behind the blocked one")
        blocked.release()
    }

    /// And the stuck one is stepped over rather than queued behind. Queueing is
    /// what made a single blocked provider stop every other one: they are
    /// actors, so the second call waits on the first.
    func testAStuckProviderIsSkippedNotQueued() async {
        let blocked = BlockingProvider()
        let quick = QuickProvider()
        let store = store([blocked, quick])
        store.refreshNow()
        await settle()
        XCTAssertEqual(store.inFlightForTesting, ["blocked"])

        store.refreshNow()
        await settle(0.3)
        XCTAssertEqual(blocked.calls, 1, "no second call queued behind the blocked one")
        XCTAssertFalse(store.isRefreshingForTesting, "and the new pass completed")
        blocked.release()
    }

    /// A pass that comes back after it was given up on must not redraw the
    /// screen over whatever replaced it.
    func testALatePassCannotOverwriteANewerOne() async {
        let blocked = BlockingProvider()
        let store = store([blocked])
        store.refreshNow()
        await settle()

        store.refreshNow()          // bumps the generation
        await settle(0.05)
        blocked.release()           // the abandoned pass now finishes
        await settle(0.4)

        XCTAssertFalse(store.isRefreshingForTesting)
    }

    /// The same guarantee, aimed at `refreshing` rather than `isRefreshing`.
    ///
    /// A pass has two providers; the first hangs and gets abandoned, the second
    /// is what a *newer* pass is legitimately still fetching when the old hang
    /// finally lets go. The abandoned pass returning must not be able to wipe
    /// the spinner out from under work that is genuinely still in flight —
    /// which is exactly what an unconditional `defer { refreshing = [] }` would
    /// do, because a `defer` runs on every return path, guarded or not.
    func testALatePassCannotClearTheSpinnerOfAStillRunningOne() async {
        // A longer deadline than the other tests here: pass 2's own deadline
        // must not fire while this test is deliberately holding it in flight
        // to observe `refreshing` mid-fetch — that would abandon pass 2 for a
        // reason that has nothing to do with what this test is checking.
        let deadline: TimeInterval = 1.0
        let blocked = BlockingProvider(id: "blocked")
        let slow = BlockingProvider(id: "slow")
        let store = store([blocked, slow], deadline: deadline)

        store.refreshNow()                        // pass 1: starts both
        await settle(0.1)
        slow.release()                            // "slow" answers; "blocked" hangs on
        await settle(deadline + 0.2)              // pass 1's deadline fires; abandoned
        XCTAssertFalse(store.isRefreshingForTesting)
        XCTAssertTrue(store.refreshing.isEmpty, "nothing is being fetched between passes")

        store.refreshNow()                        // pass 2: skips "blocked", starts "slow"
        await settle(0.1)
        // "blocked" is not in it: pass 1 gave up on that cell and took its
        // spinner off. "slow" is what pass 2 is genuinely fetching.
        XCTAssertEqual(store.refreshing, ["slow"], "pass 2 genuinely has this one in flight")

        blocked.release()                         // pass 1's old hang resolves now
        await settle(0.3)
        XCTAssertEqual(store.refreshing, ["slow"],
                       "pass 1 finishing late must not touch pass 2's spinner")

        slow.release()
        await settle(0.3)
        XCTAssertTrue(store.refreshing.isEmpty, "pass 2 clears it once it actually finishes")
    }
}
