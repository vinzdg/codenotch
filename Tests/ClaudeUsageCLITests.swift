import XCTest
@testable import Codenotch

/// `claude "/usage"` is asked before the keychain, because Claude Code files a
/// new keychain item on every token rotation and a grant against the old one
/// stops working about an hour later. These pin what its output means.
final class ClaudeUsageCLITests: XCTestCase {
    /// A real answer, trimmed of the prose below the limits. Everything after
    /// the two limit lines is Claude Code describing what drove the usage; it
    /// is approximate by its own admission and carries no limit.
    private let live = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 38% used · resets Sep 7 at 2:59pm (Asia/Jakarta)
    Current week (all models): 4% used · resets Sep 14 at 5:59am (Asia/Jakarta)

    What's contributing to your limits usage?
    Approximate, based on local sessions on this machine — does not include other devices.

    Last 24h · 268 requests · 3 sessions
      37% of your usage was at >150k context
      Top skills: /jira-tools 1%
    """

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    // MARK: - What the output means

    func testANamedTierAboveTheWindowsIsRead() {
        let extra = """
        You are currently using your extra usage to power your Claude Code usage

        Current session: 10% used · resets Sep 7 at 2:59pm (Asia/Jakarta)
        """
        XCTAssertEqual(ClaudeUsageCLI.plan(in: extra), "extra usage")
        XCTAssertNil(ClaudeUsageCLI.plan(in: live))
        XCTAssertEqual(ClaudeUsageCLI.plan(in: """
        You are currently using Max 5x

        Current session: 1% used · resets Sep 7 at 2:59pm
        """), "Max 5x")
    }

    func testItReadsBothWindowsOffARealAnswer() throws {
        let windows = try ClaudeUsageCLI.parse(live, now: date("2026-09-07T06:00:00Z"))

        XCTAssertEqual(windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(windows.map(\.label), ["Current session", "All models"])
    }

    /// The one number the ring is drawn from.
    func testAPercentageBecomesAFraction() throws {
        let windows = try ClaudeUsageCLI.parse(live, now: date("2026-09-07T06:00:00Z"))

        XCTAssertEqual(windows[0].usedFraction!, 0.38, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction!, 0.04, accuracy: 0.0001)
    }

    /// The prose underneath mentions percentages of its own — "37% of your
    /// usage was at >150k context". Read as a limit, they would be nonsense.
    func testTheProseUnderneathIsNotMistakenForALimit() throws {
        let windows = try ClaudeUsageCLI.parse(live, now: date("2026-09-07T06:00:00Z"))

        XCTAssertEqual(windows.count, 2)
    }

    /// #519: a plan with no five-hour window prints only the weeks. Refused,
    /// every poll fell back to the endpoint, and its 429s froze the ring.
    func testAnAnswerWithOnlyWeeklyLimitsIsRead() throws {
        let text = """
        Current week (all models): 15% used · resets Nov 6 at 1pm (Europe/Paris)
        Current week (Fable): 0% used · resets Nov 6 at 1pm (Europe/Paris)
        """

        let windows = try ClaudeUsageCLI.parse(text, now: date("2026-11-03T12:00:00Z"))

        XCTAssertEqual(windows.map(\.id), ["weekly_all", "weekly_fable"])
        XCTAssertEqual(windows[0].usedFraction!, 0.15, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction!, 0, accuracy: 0.0001)
        // 1pm in Paris on Nov 6 is 12:00 UTC, summer time being over.
        XCTAssertEqual(windows[0].resetsAt, date("2026-11-06T12:00:00Z"))
    }

    func testUnrecognisedOutputIsRefusedRatherThanGuessedAt() {
        XCTAssertThrowsError(try ClaudeUsageCLI.parse("Please run /login first", now: Date()))
    }

    /// The per-model weekly windows use the endpoint's own vocabulary, so one
    /// table of labels serves both sources and an archived reading survives the
    /// source changing under it.
    func testPerModelWeeklyWindowsKeepTheEndpointsNames() throws {
        let text = """
        Current session: 10% used · resets Sep 7 at 2:59pm (Asia/Jakarta)
        Current week (Opus): 12% used · resets Sep 14 at 5:59am (Asia/Jakarta)
        """

        let windows = try ClaudeUsageCLI.parse(text, now: date("2026-09-07T06:00:00Z"))

        XCTAssertEqual(windows.map(\.id), ["session", "weekly_opus"])
        XCTAssertEqual(windows[1].label, "Opus")
        XCTAssertEqual(windows[1].label, UsageResponse.label(forKind: "weekly_opus"))
    }

    /// A percentage that parsed is worth keeping even when the date beside it
    /// did not. `resetsAt` is optional by design, and losing the reading over
    /// the wording of a date is the worse of the two failures.
    func testAWindowSurvivesAnUnreadableResetDate() throws {
        let text = "Current session: 38% used · resets whenever it feels like it"

        let windows = try ClaudeUsageCLI.parse(text, now: Date())

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].usedFraction!, 0.38, accuracy: 0.0001)
        XCTAssertNil(windows[0].resetsAt)
    }

    // MARK: - Reset dates

    func testTheZoneInBracketsIsHonoured() throws {
        let windows = try ClaudeUsageCLI.parse(live, now: date("2026-09-07T06:00:00Z"))

        // 2:59pm in Jakarta is 07:59 UTC.
        XCTAssertEqual(windows[0].resetsAt, date("2026-09-07T07:59:00Z"))
        XCTAssertEqual(windows[0].duration, 5 * 3600)
    }

    /// No year is printed. Read on New Year's Eve, a window resetting on Jan 2
    /// belongs to next year — picking the current one puts the reset eleven
    /// months in the past and the ring reads as permanently expired.
    func testAJanuaryResetReadInDecemberBelongsToNextYear() {
        let reset = ClaudeUsageCLI.resetDate(from: "Jan 2 at 3:00am (UTC)",
                                             now: date("2026-12-31T12:00:00Z"))

        XCTAssertEqual(reset, date("2027-01-02T03:00:00Z"))
    }

    /// And the same mistake in the other direction: a window that reset on
    /// New Year's Eve, read on Jan 2, is last year's.
    func testADecemberResetReadInJanuaryBelongsToLastYear() {
        let reset = ClaudeUsageCLI.resetDate(from: "Dec 31 at 3:00am (UTC)",
                                             now: date("2027-01-02T12:00:00Z"))

        XCTAssertEqual(reset, date("2026-12-31T03:00:00Z"))
    }

    /// On the hour the minutes are dropped: `3pm`, not `3:00pm`. Reading only
    /// the `h:mm` spelling left the window with no reset for one hour in
    /// sixty — which is how this was found, by looking at the notch rather
    /// than at the tests.
    func testATimeOnTheHourHasNoMinutesToRead() {
        let reset = ClaudeUsageCLI.resetDate(from: "Sep 7 at 3pm (Asia/Jakarta)",
                                             now: date("2026-09-07T06:00:00Z"))

        // 3pm in Jakarta is 08:00 UTC.
        XCTAssertEqual(reset, date("2026-09-07T08:00:00Z"))
    }

    /// The whole line, not just the date fragment — a window on the hour has
    /// to arrive with its reset intact.
    func testAWindowResettingOnTheHourKeepsItsResetDate() throws {
        let text = "Current session: 72% used · resets Sep 7 at 3pm (Asia/Jakarta)"

        let windows = try ClaudeUsageCLI.parse(text, now: date("2026-09-07T06:00:00Z"))

        XCTAssertEqual(windows[0].resetsAt, date("2026-09-07T08:00:00Z"))
    }

    /// Midnight is the other end of the same spelling.
    func testMidnightIsReadAsMidnight() {
        let reset = ClaudeUsageCLI.resetDate(from: "Sep 8 at 12am (Asia/Jakarta)",
                                             now: date("2026-09-07T06:00:00Z"))

        // Midnight in Jakarta is 17:00 UTC the day before.
        XCTAssertEqual(reset, date("2026-09-07T17:00:00Z"))
    }

    /// `America/...` carries an "am" of its own, so the zone has to come off
    /// before the lower-case meridiem is fixed up for the formatter.
    func testAZoneNameContainingAMDoesNotCorruptTheTime() {
        let reset = ClaudeUsageCLI.resetDate(from: "Sep 7 at 2:59pm (America/Panama)",
                                             now: date("2026-09-07T06:00:00Z"))

        // 2:59pm in Panama (UTC-5) is 19:59 UTC.
        XCTAssertEqual(reset, date("2026-09-07T19:59:00Z"))
    }

    // MARK: - Finding the binary

    func testItFindsClaudeWhereTheInstallerPutsIt() throws {
        let home = try makeHome(executableAt: ".local/bin/claude")

        XCTAssertEqual(ClaudeUsageCLI.locate(home: home, root: home)?.binary.lastPathComponent, "claude")
    }

    /// Nil is the signal to use the token path, so a machine without Claude
    /// Code keeps working exactly as it did.
    func testNoBinaryMeansNoCLI() throws {
        let home = try makeHome(executableAt: nil)

        XCTAssertNil(ClaudeUsageCLI.locate(home: home, root: home))
    }

    /// A file at the right path that cannot be run is not an installation —
    /// npm leaves one behind after an uninstall.
    func testANonExecutableFileIsNotAnInstallation() throws {
        let home = try makeHome(executableAt: ".local/bin/claude", executable: false)

        XCTAssertNil(ClaudeUsageCLI.locate(home: home, root: home))
    }

    // MARK: - Where it runs

    /// One directory, reused. Claude Code files a transcript folder per working
    /// directory, so a fresh one per call left a folder behind every five
    /// minutes.
    func testTheScratchDirectoryIsOneFixedPlace() throws {
        let support = try makeHome(executableAt: nil)

        let first = try ClaudeUsageCLI.scratchDirectory(applicationSupport: support)
        let second = try ClaudeUsageCLI.scratchDirectory(applicationSupport: support)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.path, support.appendingPathComponent("Codenotch/usage-scratch").path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// A place that cannot be made is an error for the caller to fall back
    /// from, not a silent run in whatever directory the app was launched in.
    func testAScratchDirectoryThatCannotBeMadeThrows() throws {
        let support = try makeHome(executableAt: nil)
        // A file where the parent directory has to go.
        FileManager.default.createFile(atPath: support.appendingPathComponent("Codenotch").path,
                                       contents: Data())

        XCTAssertThrowsError(try ClaudeUsageCLI.scratchDirectory(applicationSupport: support))
    }

    /// Print mode without a transcript: the two flags are what stop Claude Code
    /// filing a session for every poll, and `/usage` still has to be what is
    /// asked.
    func testItAsksInPrintModeWithoutATranscript() {
        XCTAssertTrue(ClaudeUsageCLI.arguments.contains("--print"))
        XCTAssertTrue(ClaudeUsageCLI.arguments.contains("--no-session-persistence"))
        XCTAssertEqual(ClaudeUsageCLI.arguments.last, "/usage")
    }

    /// No MCP servers for a usage poll. `--strict-mcp-config` on its own is
    /// the whole switch; a `--mcp-config` beside it would eat `/usage` as a
    /// second config path, so it must stay absent.
    func testItStartsNoMCPServers() {
        XCTAssertTrue(ClaudeUsageCLI.arguments.contains("--strict-mcp-config"))
        XCTAssertFalse(ClaudeUsageCLI.arguments.contains("--mcp-config"))
    }

    // MARK: - Where it is found

    /// npm is how most people install Claude Code, and under a Node version
    /// manager its bin directory is named for the Node version — a path no
    /// fixed string can spell.
    func testItFindsClaudeInstalledUnderNVM() throws {
        let home = try makeHome(executablesAt: [".nvm/versions/node/v22.22.3/bin/claude"])

        XCTAssertEqual(ClaudeUsageCLI.locate(home: home, root: home)?.binary.lastPathComponent,
                       "claude")
    }

    /// A machine that has upgraded Node keeps every old version tree, and only
    /// the current one is guaranteed to hold the install that is actually run.
    func testTheNewestNodeVersionWins() throws {
        let home = try makeHome(executablesAt: [".nvm/versions/node/v20.20.2/bin/claude",
                                                ".nvm/versions/node/v22.22.3/bin/claude"])

        let found = ClaudeUsageCLI.locate(home: home, root: home)?.binary.path

        XCTAssertEqual(found?.contains("v22.22.3"), true, "expected v22.22.3, got \(found ?? "nil")")
    }

    /// Volta and pnpm keep a single stable bin directory of their own, outside
    /// every path the installers use.
    func testItFindsClaudeInAVoltaShimDirectory() throws {
        let home = try makeHome(executablesAt: [".volta/bin/claude"])

        XCTAssertNotNil(ClaudeUsageCLI.locate(home: home, root: home))
    }

    func testItFindsClaudeInPnpmsGlobalBin() throws {
        let home = try makeHome(executablesAt: ["Library/pnpm/claude"])

        XCTAssertNotNil(ClaudeUsageCLI.locate(home: home, root: home))
    }

    /// The native installer still wins when both are present: it is the layout
    /// Claude Code keeps up to date itself.
    func testTheNativeInstallerOutranksANodeManager() throws {
        let home = try makeHome(executablesAt: [".nvm/versions/node/v22.22.3/bin/claude",
                                                ".local/bin/claude"])

        XCTAssertEqual(ClaudeUsageCLI.locate(home: home, root: home)?.binary.path,
                       home.appendingPathComponent(".local/bin/claude").path)
    }

    private func makeHome(executablesAt paths: [String]) throws -> URL {
        let root = try makeHome(executableAt: nil)
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(),
                                           attributes: [.posixPermissions: 0o755])
        }
        return root
    }

    private func makeHome(executableAt path: String?, executable: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageCLITests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        if let path {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: executable ? 0o755 : 0o644]
            )
        }
        return root
    }
}
