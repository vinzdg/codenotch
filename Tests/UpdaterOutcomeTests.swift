import Sparkle
import XCTest
@testable import Codenotch

/// "Checking…" is a state the settings sheet must always leave: a check that
/// ends any other way, or never reports back, still lands somewhere.
@MainActor
final class UpdaterOutcomeTests: XCTestCase {
    func testACycleThatEndsSilentlyClearsChecking() {
        XCTAssertEqual(Updater.outcome(afterCycleFrom: .checking, errorCode: nil), .idle)
    }

    func testACycleThatCouldNotReachTheFeedSaysSo() {
        let code = Int(SUError.appcastError.rawValue)
        XCTAssertEqual(Updater.outcome(afterCycleFrom: .checking, errorCode: code), .unreachable)
    }

    func testAnAnswerAlreadyGivenIsKept() {
        XCTAssertEqual(Updater.outcome(afterCycleFrom: .found("1.14.0"), errorCode: nil), .found("1.14.0"))
        let upToDate = Updater.Outcome.upToDate(Date(timeIntervalSince1970: 1))
        XCTAssertEqual(Updater.outcome(afterCycleFrom: upToDate, errorCode: nil), upToDate)
    }

    func testACheckThatNeverAnswersStopsSayingChecking() {
        guard case .failed(let why) = Updater.outcome(afterTimeoutFrom: .checking) else {
            return XCTFail("a stalled check must not stay on Checking…")
        }
        XCTAssertTrue(why.contains("hivinz.com"), why)
        XCTAssertEqual(Updater.outcome(afterTimeoutFrom: .upToDate(Date(timeIntervalSince1970: 1))),
                       .upToDate(Date(timeIntervalSince1970: 1)))
    }

    /// The line under an update offered in the notch is the appcast's HTML
    /// release notes read as plain text.
    func testReleaseNotesAreReadAsOnePlainLine() {
        let html = "<h2>New</h2>\n<ul>\n  <li>Carry the notch by its dots &amp; drop it anywhere.</li>\n</ul>"
        XCTAssertEqual(UpdatePrompt.summary(of: html), "New Carry the notch by its dots & drop it anywhere.")
        XCTAssertEqual(UpdatePrompt.summary(of: ""), "")
    }

    func testThePreviewNamesTheNextVersion() {
        XCTAssertEqual(Updater.nextVersion(after: "1.18.0"), "1.19.0")
        XCTAssertEqual(Updater.nextVersion(after: "1.18.3"), "1.19.0")
        XCTAssertEqual(Updater.nextVersion(after: "2"), "2.1.0")
    }
}
