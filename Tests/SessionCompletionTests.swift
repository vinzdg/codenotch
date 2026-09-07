import XCTest
@testable import Codenotch

final class SessionCompletionTests: XCTestCase {
    private func session(
        _ id: String, _ state: AgentSession.State, since: Date = Date(), pid: pid_t? = nil
    ) -> AgentSession {
        AgentSession(id: id, name: id, detail: "Terminal · \(id)",
                     state: state, waitingFor: nil, since: since, processID: pid)
    }

    /// Everything already running at launch arrives with no history. Treating
    /// that as a transition would chime once per open window on every start.
    func testFirstReadingAnnouncesNothing() {
        var watcher = SessionCompletionWatcher()
        XCTAssertTrue(watcher.absorb(["claude": [session("a", .busy), session("b", .idle)]]).isEmpty)
    }

    func testBusyToIdleIsFinished() {
        var watcher = SessionCompletionWatcher()
        _ = watcher.absorb(["claude": [session("a", .busy)]])
        let events = watcher.absorb(["claude": [session("a", .idle)]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .finished)
        XCTAssertEqual(events.first?.providerID, "claude")
        XCTAssertEqual(events.first?.session.id, "a")
    }

    func testBusyToWaitingIsBlocked() {
        var watcher = SessionCompletionWatcher()
        _ = watcher.absorb(["claude": [session("a", .busy)]])
        XCTAssertEqual(watcher.absorb(["claude": [session("a", .waiting)]]).first?.reason, .blocked)
    }

    /// A question that was answered is not a piece of work ending — the work
    /// carries on, and announcing it would fire on every prompt.
    func testWaitingToIdleIsSilent() {
        var watcher = SessionCompletionWatcher()
        _ = watcher.absorb(["claude": [session("a", .waiting)]])
        XCTAssertTrue(watcher.absorb(["claude": [session("a", .idle)]]).isEmpty)
    }

    func testUnchangedStateIsSilent() {
        var watcher = SessionCompletionWatcher()
        _ = watcher.absorb(["claude": [session("a", .busy)]])
        XCTAssertTrue(watcher.absorb(["claude": [session("a", .busy)]]).isEmpty)
    }

    /// Quitting Claude Code mid-turn removes the session file while it still
    /// says `busy`. There is no window left to jump to, so there is nothing to
    /// announce.
    func testSessionThatVanishesIsSilent() {
        var watcher = SessionCompletionWatcher()
        _ = watcher.absorb(["claude": [session("a", .busy)]])
        XCTAssertTrue(watcher.absorb(["claude": []]).isEmpty)
    }

    /// …and it is forgotten, so a later session that recycles the id is seeded
    /// afresh rather than compared against a state from before it existed.
    func testVanishedSessionIsForgotten() {
        var watcher = SessionCompletionWatcher()
        _ = watcher.absorb(["claude": [session("a", .busy)]])
        _ = watcher.absorb(["claude": []])
        XCTAssertTrue(watcher.absorb(["claude": [session("a", .idle)]]).isEmpty)
    }

    /// Two tools can hold the same session id without being the same session.
    func testProvidersAreKeptApart() {
        var watcher = SessionCompletionWatcher()
        _ = watcher.absorb(["claude": [session("a", .busy)], "grok": [session("a", .idle)]])
        let events = watcher.absorb(["claude": [session("a", .idle)], "grok": [session("a", .idle)]])
        XCTAssertEqual(events.map(\.providerID), ["claude"])
    }

    /// One turn ending often unblocks another. The newest is offered, because
    /// it is the window you were most recently in.
    func testNewestEventComesFirst() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        var watcher = SessionCompletionWatcher()
        _ = watcher.absorb(["claude": [session("a", .busy), session("b", .busy)]])
        let events = watcher.absorb([
            "claude": [session("a", .idle, since: old), session("b", .idle, since: new)]
        ])
        XCTAssertEqual(events.map(\.session.id), ["b", "a"])
    }

    /// The pid is what a click on the peek acts on, so it has to survive the
    /// trip from the session file to the event.
    func testProcessIDReachesTheEvent() {
        var watcher = SessionCompletionWatcher()
        _ = watcher.absorb(["claude": [session("a", .busy, pid: 4242)]])
        let events = watcher.absorb(["claude": [session("a", .idle, pid: 4242)]])
        XCTAssertEqual(events.first?.session.processID, 4242)
    }

    // MARK: - Focus

    /// The walk starts with the process it was asked about — an agent's own
    /// pid is a legitimate answer, since a GUI tool may be the app itself.
    func testAncestryStartsWithTheProcessItself() {
        XCTAssertEqual(SessionFocus.ancestry(of: getpid()).first, getpid())
        XCTAssertNotNil(SessionFocus.parent(of: getpid()))
    }

    /// Adopted by launchd — which is what happens to a test host, and to any
    /// agent whose terminal has already quit — the chain is the process alone.
    /// launchd is never the app anybody meant.
    func testAncestryExcludesLaunchd() {
        XCTAssertFalse(SessionFocus.ancestry(of: getpid()).contains(1))
    }

    func testAncestryIsBounded() {
        XCTAssertLessThanOrEqual(SessionFocus.ancestry(of: getpid(), limit: 3).count, 3)
    }

    /// launchd is nobody's child, and a pid that does not exist has no parent
    /// to report — neither may be walked past.
    func testAncestryStopsAtTheTop() {
        XCTAssertEqual(SessionFocus.ancestry(of: 1), [])
    }

    /// Above the kernel's pid ceiling, so nothing can ever be there. A session
    /// file outliving its process is the ordinary case this stands in for.
    func testUnknownProcessHasNoParent() {
        XCTAssertNil(SessionFocus.parent(of: 999_999))
        XCTAssertEqual(SessionFocus.ancestry(of: 999_999), [999_999])
        XCTAssertNil(SessionFocus.owningApp(of: 999_999))
    }

    /// A pid the session file left behind must not raise whatever window has
    /// since been given that number — it simply finds nothing.
    func testSessionFileRecordsThePID() {
        let record = ClaudeSessionRecord(json: [
            "pid": NSNumber(value: 4242),
            "cwd": "/tmp/project",
            "status": "busy"
        ])
        XCTAssertEqual(record?.session.processID, 4242)
    }
}

/// The peek has to survive the pointer not being there.
@MainActor
final class PeekTests: XCTestCase {
    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The regression this exists for: the cursor poll runs every 0.3s and
    /// folds the notch 0.45s after finding the pointer somewhere else, which
    /// during a peek it almost always is. The notch opened and shut inside a
    /// second — the announcement was there, and nobody could have seen it.
    ///
    /// Only asserts that it is *still open* well past that window. Whether it
    /// closes afterwards depends on where the mouse happens to be on the
    /// machine running this, which is not something a test may assume.
    func testAPeekOutlastsTheHoverFold() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.peek(for: 2, focusing: nil)
        XCTAssertTrue(controller.model.isExpanded)
        pump(1.2)
        XCTAssertTrue(controller.model.isExpanded,
                      "the pointer being elsewhere must not end a peek early")
    }

    /// Hidden is a standing choice. Something finishing does not overrule it.
    func testAPeekDoesNotOverrideHidden() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.apply(.hidden)
        controller.peek(for: 2, focusing: nil)
        XCTAssertFalse(controller.model.isExpanded)
    }
}

/// The peek's length is a setting, so the setting has to survive a round trip.
final class PeekDurationTests: XCTestCase {
    func testEveryDurationIsAUsefulLength() {
        for duration in PeekDuration.allCases {
            XCTAssertGreaterThanOrEqual(duration.seconds, 1)
            XCTAssertLessThanOrEqual(duration.seconds, 30)
        }
    }

    /// The raw values are written to UserDefaults, so renaming a case would
    /// silently reset everybody's choice to the default.
    func testRawValuesAreStable() {
        XCTAssertEqual(PeekDuration.allCases.map(\.rawValue), ["brief", "standard", "long"])
        XCTAssertEqual(PeekDuration(rawValue: "standard")?.seconds, 5)
    }

    /// An unrecognised stored value — a downgrade, a hand-edited domain — has
    /// to land on the default rather than on nothing.
    func testAnUnknownStoredValueFallsBack() {
        XCTAssertNil(PeekDuration(rawValue: "forever"))
    }
}

/// The chime resolves files itself, so that resolution is worth checking.
final class SessionChimeTests: XCTestCase {
    func testTheDefaultSoundsExist() {
        XCTAssertNotNil(SessionChime.url(for: SessionChime.defaultFinished))
        XCTAssertNotNil(SessionChime.url(for: SessionChime.defaultBlocked))
    }

    func testTheSystemSoundsAreOffered() {
        let available = SessionChime.available
        XCTAssertTrue(available.contains("Glass"))
        XCTAssertTrue(available.contains("Funk"))
        XCTAssertEqual(available, available.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
    }

    /// The picker shows the stored name whether or not it resolves, so a sound
    /// that has gone missing must not silently become a different one.
    func testAnUnknownSoundResolvesToNothing() {
        XCTAssertNil(SessionChime.url(for: "NotASound"))
        XCTAssertFalse(SessionChime.available.contains("NotASound"))
    }

    /// The regression this exists for: `play()` was written inside the log
    /// interpolation that reports its result. `Logger`'s interpolations are
    /// autoclosures, evaluated only when the level is enabled — so on an
    /// ordinary run, with debug logging off, the call never happened. Nothing
    /// logged, nothing played, and every line of it looked right.
    ///
    /// Asserting on the return value is what keeps the call on its own line.
    func testPlayingActuallyStarts() {
        XCTAssertTrue(SessionChime.play(SessionChime.defaultFinished))
        XCTAssertFalse(SessionChime.play("NotASound"))
    }

    /// Names are extension-free: the picker shows them and the preference
    /// stores them, so a stored name has to be one the resolver accepts back.
    func testEveryOfferedSoundResolves() {
        for name in SessionChime.available {
            XCTAssertNotNil(SessionChime.url(for: name), "\(name) is offered but does not resolve")
        }
    }
}
