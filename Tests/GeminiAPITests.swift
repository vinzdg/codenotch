import SQLite3
import XCTest
@testable import Codenotch

/// A date in the calendar the readers use, so a fixture and the `now` it is
/// measured against cannot disagree about the zone.
private func localDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    return GeminiTokenUsage.calendar.date(from: components)!
}

/// The three readers all funnel through `bucket`, so its edges decide whether
/// the tooltip's rows add up to its headline.
final class GeminiTokenUsageTests: XCTestCase {
    private let now = localDate(2026, 9, 15)

    func testAnEntryTodayCountsInBothWindows() {
        let usage = GeminiTokenUsage.bucket(
            [(at: localDate(2026, 9, 15, hour: 9), tokens: 1200, calls: 1)], now: now)
        XCTAssertEqual(usage, GeminiTokenUsage(
            tokensThisMonth: 1200, tokensToday: 1200, callsThisMonth: 1))
    }

    func testAnEntryEarlierThisMonthCountsInTheMonthOnly() {
        let usage = GeminiTokenUsage.bucket(
            [(at: localDate(2026, 9, 3), tokens: 1200, calls: 1)], now: now)
        XCTAssertEqual(usage, GeminiTokenUsage(
            tokensThisMonth: 1200, tokensToday: 0, callsThisMonth: 1))
    }

    /// Same day of a different month. Comparing days alone would file it under
    /// "today".
    func testAnEntryLastMonthCountsInNeither() {
        let usage = GeminiTokenUsage.bucket(
            [(at: localDate(2026, 8, 15), tokens: 1200, calls: 1)], now: now)
        XCTAssertEqual(usage, GeminiTokenUsage.zero)
    }

    /// An aborted call costs nothing and is not a call.
    func testAZeroTokenEntryAddsNoCall() {
        let usage = GeminiTokenUsage.bucket([
            (at: now, tokens: 0, calls: 1),
            (at: now, tokens: 300, calls: 1)
        ], now: now)
        XCTAssertEqual(usage, GeminiTokenUsage(
            tokensThisMonth: 300, tokensToday: 300, callsThisMonth: 1))
    }

    func testStartOfMonthIsLocalMidnightOnTheFirst() {
        XCTAssertEqual(GeminiTokenUsage.startOfMonth(now: now), localDate(2026, 9, 1, hour: 0))
    }

    func testAddingSumsEveryWindow() {
        let first = GeminiTokenUsage(tokensThisMonth: 10, tokensToday: 4, callsThisMonth: 1)
        let second = GeminiTokenUsage(tokensThisMonth: 5, tokensToday: 5, callsThisMonth: 2)
        XCTAssertEqual(first.adding(second), GeminiTokenUsage(
            tokensThisMonth: 15, tokensToday: 9, callsThisMonth: 3))
    }
}

/// Fixtures follow the real recording: a header line, records written twice,
/// and the patches the CLI appends between them.
final class GeminiCLIUsageTests: XCTestCase {
    private var root: URL!
    private let now = localDate(2026, 9, 15)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gemini-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The modification date is set explicitly because the reader skips files
    /// older than the month under test, and the machine's own clock is not the
    /// `now` these tests measure against.
    private func write(
        _ lines: [String],
        project: String = "9d2c",
        name: String = "session-a",
        modified: Date? = nil
    ) throws {
        let chats = root.appendingPathComponent("\(project)/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("\(name).jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modified ?? now], ofItemAtPath: file.path)
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")!
        return formatter.string(from: date)
    }

    private func gemini(_ id: String, at: Date, total: Int?) -> String {
        let tokens = total.map {
            #","tokens":{"input":11,"output":7,"cached":4,"thoughts":2,"tool":0,"total":\#($0)}"#
        } ?? ""
        return #"{"id":"\#(id)","timestamp":"\#(stamp(at))","type":"gemini","#
            + #""model":"gemini-2.5-pro","content":"ok"\#(tokens)}"#
    }

    private let header = #"{"sessionId":"6f0a","projectHash":"9d2c","#
        + #""startTime":"2026-09-15T09:12:33.104Z","#
        + #""lastUpdated":"2026-09-15T09:41:02.881Z","kind":"main"}"#

    /// The CLI appends the same record twice, once when the turn starts and
    /// once when `usageMetadata` arrives. Counting lines would bill it twice.
    func testTheSameRecordAppendedTwiceCountsOnce() throws {
        try write([
            header,
            gemini("c7f2", at: now, total: 1200),
            gemini("c7f2", at: now, total: 1200)
        ])
        XCTAssertEqual(GeminiCLIUsage.read(root: root, now: now), GeminiTokenUsage(
            tokensThisMonth: 1200, tokensToday: 1200, callsThisMonth: 1))
    }

    /// Everything the file holds besides an answered call, including the
    /// `$rewindTo` marker: the rewound call was still billed, but it is counted
    /// through its own record, never through the marker.
    func testItIgnoresHeadersPatchesAndAnythingUnparsable() throws {
        try write([
            header,
            gemini("c7f2", at: now, total: nil),
            #"{"id":"u1","timestamp":"\#(stamp(now))","type":"user","content":"hi"}"#,
            #"{"$set":{"lastUpdated":"2026-09-15T09:41:02.881Z"}}"#,
            #"{"$rewindTo":"c7f2"}"#,
            "not json at all",
            gemini("d3a9", at: now, total: 500)
        ])
        XCTAssertEqual(GeminiCLIUsage.read(root: root, now: now), GeminiTokenUsage(
            tokensThisMonth: 500, tokensToday: 500, callsThisMonth: 1))
    }

    /// `model` is missing, `null` or `"auto"` depending on how the turn was
    /// routed; none of that says anything about whether it was billed.
    func testARecordWithANullModelStillCounts() throws {
        try write([
            header,
            #"{"id":"c7f2","timestamp":"\#(stamp(now))","type":"gemini","model":null,"#
                + #""tokens":{"input":11,"output":7,"cached":4,"thoughts":2,"tool":0,"total":900}}"#
        ])
        XCTAssertEqual(GeminiCLIUsage.read(root: root, now: now), GeminiTokenUsage(
            tokensThisMonth: 900, tokensToday: 900, callsThisMonth: 1))
    }

    func testItSeparatesTodayFromTheRestOfTheMonthAndDropsLastMonth() throws {
        try write([
            header,
            gemini("a", at: localDate(2026, 9, 15, hour: 8), total: 100),
            gemini("b", at: localDate(2026, 9, 3), total: 200),
            gemini("c", at: localDate(2026, 8, 28), total: 400)
        ])
        XCTAssertEqual(GeminiCLIUsage.read(root: root, now: now), GeminiTokenUsage(
            tokensThisMonth: 300, tokensToday: 100, callsThisMonth: 2))
    }

    /// The pre-filter is what keeps the scan cheap after months of sessions,
    /// and it is only sound because the file is append-only.
    func testAFileLastWrittenBeforeThisMonthIsNotEvenOpened() throws {
        try write([header, gemini("c7f2", at: now, total: 1200)],
                  modified: localDate(2026, 8, 20))
        XCTAssertEqual(GeminiCLIUsage.read(root: root, now: now), GeminiTokenUsage.zero)
    }

    /// "Never installed" is not "spent nothing": the provider drops the row for
    /// the first and shows a zero for the second.
    func testAMissingRootReadsAsNil() {
        let missing = root.appendingPathComponent("nowhere")
        XCTAssertNil(GeminiCLIUsage.read(root: missing, now: now))
    }

    func testAProjectWithoutChatsReadsAsZero() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("9d2c"), withIntermediateDirectories: true)
        XCTAssertEqual(GeminiCLIUsage.read(root: root, now: now), GeminiTokenUsage.zero)
    }
}

/// Fixtures carry OpenCode's real `message` shape, because the reader asks
/// SQLite to reach into the JSON and a wrong nesting would silently read zero.
final class OpenCodeGeminiUsageTests: XCTestCase {
    private let now = localDate(2026, 9, 15)
    private var databases: [URL] = []

    override func tearDownWithError() throws {
        for url in databases { try? FileManager.default.removeItem(at: url) }
        databases = []
    }

    /// Written and closed before the reader opens it, so the WAL is
    /// checkpointed away — the same state a quit OpenCode leaves behind.
    private func makeDatabase(rows: [(created: Date, data: String)]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-\(UUID().uuidString).db")
        databases.append(url)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER,
                              time_updated INTEGER, data TEXT);
        """, nil, nil, nil)
        for (index, row) in rows.enumerated() {
            let milliseconds = Int(row.created.timeIntervalSince1970 * 1000)
            sqlite3_exec(db, """
            INSERT INTO message VALUES ('m\(index)', 's1', \(milliseconds), \(milliseconds),
                                        '\(row.data)');
            """, nil, nil, nil)
        }
        sqlite3_close(db)
        return url
    }

    private func message(
        provider: String = "google",
        role: String = "assistant",
        total: Int? = nil,
        input: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        read: Int = 0,
        write: Int = 0
    ) -> String {
        let totalField = total.map { #","total":\#($0)"# } ?? ""
        return #"{"role":"\#(role)","providerID":"\#(provider)","modelID":"gemini-2.5-pro","#
            + #""tokens":{"input":\#(input),"output":\#(output),"reasoning":\#(reasoning),"#
            + #""cache":{"read":\#(read),"write":\#(write)}\#(totalField)},"cost":0.0}"#
    }

    func testAnAnsweredCallTodayCountsInBothWindows() throws {
        let url = try makeDatabase(rows: [(now, message(total: 1200, input: 900, output: 300))])
        XCTAssertEqual(OpenCodeGeminiUsage.read(database: url, now: now), GeminiTokenUsage(
            tokensThisMonth: 1200, tokensToday: 1200, callsThisMonth: 1))
    }

    func testACallEarlierThisMonthCountsInTheMonthOnly() throws {
        let url = try makeDatabase(rows: [(localDate(2026, 9, 3), message(total: 200))])
        XCTAssertEqual(OpenCodeGeminiUsage.read(database: url, now: now), GeminiTokenUsage(
            tokensThisMonth: 200, tokensToday: 0, callsThisMonth: 1))
    }

    /// The SQL pre-filter on `time_created` is what makes the read cheap, so
    /// last month has to be gone before the JSON is ever extracted.
    func testACallLastMonthIsNotCounted() throws {
        let url = try makeDatabase(rows: [(localDate(2026, 8, 28), message(total: 400))])
        XCTAssertEqual(OpenCodeGeminiUsage.read(database: url, now: now), GeminiTokenUsage.zero)
    }

    /// The prompt is a row of its own and carries no tokens of its own; only
    /// the assistant's reply records what the API charged for the pair.
    func testAUserRowIsNotCounted() throws {
        let url = try makeDatabase(rows: [(now, message(role: "user", total: 1200))])
        XCTAssertEqual(OpenCodeGeminiUsage.read(database: url, now: now), GeminiTokenUsage.zero)
    }

    /// OpenCode talks to several providers out of one database, and only
    /// `google` is the Gemini API key this ring is about.
    func testAnotherProvidersRowIsNotCounted() throws {
        let url = try makeDatabase(rows: [(now, message(provider: "lmstudio", total: 1200))])
        XCTAssertEqual(OpenCodeGeminiUsage.read(database: url, now: now), GeminiTokenUsage.zero)
    }

    /// A message aborted before the model answered: every counter zero and no
    /// `total` at all. It was not billed, so it is not a call.
    func testAnAbortedMessageAddsNoCall() throws {
        let url = try makeDatabase(rows: [(now, message())])
        XCTAssertEqual(OpenCodeGeminiUsage.read(database: url, now: now), GeminiTokenUsage.zero)
    }

    /// The real row that fixes the sum: `input` excludes the cache, so only
    /// adding `cache.read` back reproduces the `total` OpenCode itself wrote.
    func testWithoutATotalTheComponentsIncludeTheCache() throws {
        let url = try makeDatabase(rows: [
            (now, message(input: 2834, output: 51, reasoning: 17, read: 93106, write: 0))
        ])
        XCTAssertEqual(OpenCodeGeminiUsage.read(database: url, now: now), GeminiTokenUsage(
            tokensThisMonth: 96008, tokensToday: 96008, callsThisMonth: 1))
    }

    /// "Never installed" is not "spent nothing".
    func testAMissingDatabaseReadsAsNil() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-\(UUID().uuidString).db")
        XCTAssertNil(OpenCodeGeminiUsage.read(database: missing, now: now))
    }
}

/// Fixtures carry Hermes's real `session_model_usage` columns, because the
/// reader adds four of them together in SQL and a renamed column would sum to
/// nothing without failing.
final class HermesGeminiUsageTests: XCTestCase {
    private let now = localDate(2026, 9, 15)
    private var databases: [URL] = []

    override func tearDownWithError() throws {
        for url in databases { try? FileManager.default.removeItem(at: url) }
        databases = []
    }

    /// One row of `session_model_usage`, defaulted to the shape the reader is
    /// looking for so each test states only what it is about.
    private struct Row {
        var lastSeen: Date
        var provider = "gemini"
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var reasoning = 0
        var calls = 1
    }

    /// Written and closed before the reader opens it, so the WAL is
    /// checkpointed away — the same state a quit Hermes leaves behind. The
    /// foreign key to `sessions` is dropped because the reader never joins.
    private func makeDatabase(rows: [Row]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hermes-\(UUID().uuidString).db")
        databases.append(url)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE session_model_usage (
            session_id TEXT NOT NULL, model TEXT NOT NULL,
            billing_provider TEXT NOT NULL DEFAULT '',
            billing_base_url TEXT NOT NULL DEFAULT '',
            billing_mode TEXT NOT NULL DEFAULT '', task TEXT NOT NULL DEFAULT '',
            api_call_count INTEGER NOT NULL DEFAULT 0,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            estimated_cost_usd REAL NOT NULL DEFAULT 0,
            actual_cost_usd REAL NOT NULL DEFAULT 0,
            cost_status TEXT, cost_source TEXT, first_seen REAL, last_seen REAL);
        """, nil, nil, nil)
        for (index, row) in rows.enumerated() {
            let seen = row.lastSeen.timeIntervalSince1970
            sqlite3_exec(db, """
            INSERT INTO session_model_usage VALUES (
                's\(index)', 'gemini-2.5-pro', '\(row.provider)',
                'https://generativelanguage.googleapis.com/v1beta', 'api-key', '',
                \(row.calls), \(row.input), \(row.output), \(row.cacheRead),
                \(row.cacheWrite), \(row.reasoning), 0, 0, 'estimated', 'table',
                \(seen), \(seen));
            """, nil, nil, nil)
        }
        sqlite3_close(db)
        return url
    }

    /// Hermes counts reasoning inside `output_tokens`, so the row's own
    /// `reasoning_tokens` must not be added on top: 100 + 50 + 5 + 20 = 175,
    /// not 182. `api_call_count` is the row's own tally, because one row is a
    /// whole session rather than a single call.
    func testASessionTodayCountsInBothWindowsAndExcludesReasoning() throws {
        let url = try makeDatabase(rows: [
            Row(lastSeen: now, input: 100, output: 20, cacheRead: 50,
                cacheWrite: 5, reasoning: 7, calls: 3)
        ])
        XCTAssertEqual(HermesGeminiUsage.read(database: url, now: now), GeminiTokenUsage(
            tokensThisMonth: 175, tokensToday: 175, callsThisMonth: 3))
    }

    func testASessionEarlierThisMonthCountsInTheMonthOnly() throws {
        let url = try makeDatabase(rows: [Row(lastSeen: localDate(2026, 9, 3), input: 200)])
        XCTAssertEqual(HermesGeminiUsage.read(database: url, now: now), GeminiTokenUsage(
            tokensThisMonth: 200, tokensToday: 0, callsThisMonth: 1))
    }

    /// The SQL pre-filter on `last_seen` is what makes the read cheap, so last
    /// month has to be gone before the sum is ever computed.
    func testASessionLastMonthIsNotCounted() throws {
        let url = try makeDatabase(rows: [Row(lastSeen: localDate(2026, 8, 28), input: 400)])
        XCTAssertEqual(HermesGeminiUsage.read(database: url, now: now), GeminiTokenUsage.zero)
    }

    /// Hermes routes to several providers out of one table, and only `gemini`
    /// is Google AI Studio, which is the API key this ring is about.
    func testAnotherProvidersSessionIsNotCounted() throws {
        let url = try makeDatabase(rows: [
            Row(lastSeen: now, provider: "lmstudio", input: 100, output: 20)
        ])
        XCTAssertEqual(HermesGeminiUsage.read(database: url, now: now), GeminiTokenUsage.zero)
    }

    /// "Never installed" is not "spent nothing".
    func testAMissingDatabaseReadsAsNil() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hermes-\(UUID().uuidString).db")
        XCTAssertNil(HermesGeminiUsage.read(database: missing, now: now))
    }

    /// Installed but never pointed at Gemini: a real reading of nothing, which
    /// the provider shows as a zero row rather than dropping.
    func testAnEmptyTableReadsAsZero() throws {
        let url = try makeDatabase(rows: [])
        XCTAssertEqual(HermesGeminiUsage.read(database: url, now: now), GeminiTokenUsage.zero)
    }
}

/// What the ring means and what the tooltip lists, which is the whole visible
/// surface of a provider that never calls anything.
final class GeminiAPISnapshotTests: XCTestCase {
    private let now = localDate(2026, 9, 15)

    private func source(
        _ id: String, _ name: String, month: Int, today: Int = 0
    ) -> GeminiTokenSource {
        GeminiTokenSource(id: id, name: name, usage: GeminiTokenUsage(
            tokensThisMonth: month, tokensToday: today, callsThisMonth: 1))
    }

    /// Every tool's row is listed after the two totals, in the order the
    /// provider reads them, so the tooltip does not reshuffle between refreshes.
    func testTwoSourcesAddUpIntoTheMonthAndTodayWindows() {
        let snapshot = GeminiAPIProvider.snapshot(
            sources: [
                source("cli", "Gemini CLI", month: 400_000, today: 12_000),
                source("opencode", "OpenCode", month: 251_061, today: 3_000)
            ],
            budget: nil,
            now: now
        )
        XCTAssertEqual(snapshot.windows.map(\.id), ["month", "today", "cli", "opencode"])
        XCTAssertEqual(snapshot.headlineID, "month")
        // The sparkle, not Antigravity's arch, which the neighbouring row wears.
        XCTAssertEqual(snapshot.glyph, .geminiSpark)
        XCTAssertEqual(snapshot.headline?.used, 651_061)
        XCTAssertEqual(snapshot.windows[1].used, 15_000)
        XCTAssertEqual(snapshot.windows[2].label, "Gemini CLI · this month")
        XCTAssertEqual(snapshot.windows[2].used, 400_000)
        XCTAssertEqual(snapshot.windows[3].used, 251_061)
    }

    /// Without a budget there is no denominator to draw a ring against, and
    /// inventing one would put a limit on a key Google does not limit.
    func testWithoutABudgetTheMonthWindowHasNoFraction() {
        let snapshot = GeminiAPIProvider.snapshot(
            sources: [source("cli", "Gemini CLI", month: 651_061)], budget: nil, now: now)
        XCTAssertEqual(snapshot.fidelity, .derived)
        XCTAssertNil(snapshot.headline?.usedFraction)
        XCTAssertTrue(snapshot.windows[0].label.contains("no limit"))
        XCTAssertEqual(snapshot.headlineText, "651k")
    }

    /// The ceiling is the user's, not Google's, which is what `.manual` says.
    func testABudgetFillsTheRingAndTurnsTheReadingManual() throws {
        let snapshot = GeminiAPIProvider.snapshot(
            sources: [source("cli", "Gemini CLI", month: 651_061)],
            budget: 2_000_000,
            now: now
        )
        XCTAssertEqual(snapshot.fidelity, .manual)
        XCTAssertEqual(try XCTUnwrap(snapshot.headline?.usedFraction), 0.3255, accuracy: 0.0001)
        XCTAssertTrue(snapshot.windows[0].label.contains("2.0M"),
                      "budget label was \(snapshot.windows[0].label)")
    }

    /// Zero is how the settings field reads "none", and dividing by it would
    /// draw an infinite ring.
    func testABudgetOfZeroReadsAsNoBudget() {
        let snapshot = GeminiAPIProvider.snapshot(
            sources: [source("cli", "Gemini CLI", month: 651_061)], budget: 0, now: now)
        XCTAssertEqual(snapshot.fidelity, .derived)
        XCTAssertNil(snapshot.headline?.usedFraction)
    }

    /// The month rolls over at the end of the month it is counting, not at the
    /// start of it.
    func testTheMonthWindowResetsAfterNow() throws {
        let snapshot = GeminiAPIProvider.snapshot(
            sources: [source("cli", "Gemini CLI", month: 10)], budget: nil, now: now)
        XCTAssertEqual(try XCTUnwrap(snapshot.headline?.resetsAt),
                       localDate(2026, 10, 1, hour: 0))
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[1].resetsAt),
                       localDate(2026, 9, 16, hour: 0))
    }

    func testTheAccountNamesTheKeyAndTheToolsItWasReadFrom() {
        let account = GeminiAPICredentials.account(
            tools: ["Gemini CLI", "OpenCode"], authType: "gemini-api-key")
        XCTAssertEqual(account?.label, "API key")
        XCTAssertEqual(account?.plan, "metered")
        XCTAssertEqual(account?.source, "Gemini CLI, OpenCode")
    }

    /// The free login is a quota, not a bill; calling it metered would put a
    /// price on it.
    func testAGoogleAccountLoginIsNotMetered() {
        let account = GeminiAPICredentials.account(
            tools: ["Gemini CLI"], authType: "oauth-personal")
        XCTAssertEqual(account?.label, "Google account")
        XCTAssertNil(account?.plan)
    }

    /// No log means no account to describe, not an empty one.
    func testNoToolsMeansNoAccount() {
        XCTAssertNil(GeminiAPICredentials.account(tools: [], authType: "gemini-api-key"))
    }

    func testTheAuthTypeIsReadFromTheCLISettings() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gemini-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try #"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GeminiAPICredentials.authType(at: file), "gemini-api-key")
    }

    /// The label is a courtesy; a guessed one would be worse than none.
    func testAMissingSettingsFileHasNoAuthType() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gemini-settings-\(UUID().uuidString).json")
        XCTAssertNil(GeminiAPICredentials.authType(at: missing))
    }

    private func missingPath(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    /// None of the three tools installed is not an error and not a missing
    /// sign-in — there is nothing being metered, and the row says so.
    func testNoToolAtAllIsReportedAsNothingMetered() async {
        let provider = GeminiAPIProvider(
            cliRoot: missingPath("gemini-cli"),
            openCodeDatabase: missingPath("opencode.db"),
            hermesDatabase: missingPath("hermes.db"),
            settingsFile: missingPath("settings.json"),
            budget: { nil }
        )
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected nothingMetered")
        } catch UsageProviderError.nothingMetered(let why) {
            XCTAssertTrue(why.contains("Gemini CLI"), "message was \(why)")
        } catch {
            XCTFail("expected nothingMetered, got \(error)")
        }
    }

    /// One tool installed gets one row. A zero for OpenCode and Hermes would
    /// claim they had been asked and had spent nothing.
    func testOnlyTheInstalledToolGetsARow() async throws {
        let root = missingPath("gemini-cli")
        let chats = root.appendingPathComponent("9d2c/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // `fetchSnapshot` reads the real clock, so the record is stamped now
        // rather than at the fixed date the pure tests use.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")!
        let line = #"{"id":"c7f2","timestamp":"\#(formatter.string(from: Date()))","type":"gemini","#
            + #""tokens":{"input":11,"output":7,"cached":4,"thoughts":2,"tool":0,"total":1200}}"#
        try line.write(to: chats.appendingPathComponent("session-a.jsonl"),
                       atomically: true, encoding: .utf8)

        let provider = GeminiAPIProvider(
            cliRoot: root,
            openCodeDatabase: missingPath("opencode.db"),
            hermesDatabase: missingPath("hermes.db"),
            settingsFile: missingPath("settings.json"),
            budget: { nil }
        )
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.id, "gemini-api")
        XCTAssertEqual(snapshot.windows.map(\.id), ["month", "today", "cli"])
        XCTAssertEqual(snapshot.headline?.used, 1200)
        // Set only once a fetch has found something, so the settings row can
        // name the tools rather than an account nobody signed in to.
        XCTAssertEqual(provider.account()?.source, "Gemini CLI")
    }
}

/// Nothing in a chat recording names the process that wrote it, so how recently
/// the file was appended to is the whole of the busy signal. Every fixture sets
/// its own modification date: the machine's clock must not decide whether a
/// test passes.
@MainActor
final class GeminiCLIActivityMonitorTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gemini-cli-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func session(
        project: String,
        name: String = "session-a",
        projectRoot: String? = nil,
        modified: Date
    ) throws -> URL {
        let directory = root.appendingPathComponent(project)
        let chats = directory.appendingPathComponent("chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        if let projectRoot {
            try projectRoot.write(to: directory.appendingPathComponent(".project_root"),
                                  atomically: true, encoding: .utf8)
        }
        let file = chats.appendingPathComponent("\(name).jsonl")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: file.path)
        return file
    }

    func testAJustWrittenSessionReadsAsWorking() throws {
        try session(project: "9d2c", projectRoot: "/Users/x/Projects/codenotch", modified: now)
        let sessions = GeminiCLIActivityMonitor.read(root: root, staleAfter: 45, now: now)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .busy)
        XCTAssertEqual(sessions.first?.name, "Gemini CLI")
        XCTAssertEqual(sessions.first?.detail, "Working in codenotch")
        XCTAssertEqual(sessions.first?.id, "gemini-api.session-a")
    }

    /// A finished turn is not work in progress.
    func testAnOldSessionIsNotWorking() throws {
        try session(project: "9d2c", modified: now.addingTimeInterval(-60))
        XCTAssertTrue(GeminiCLIActivityMonitor.read(root: root, staleAfter: 45, now: now).isEmpty)
    }

    func testNoSessionsIsQuietRatherThanAnError() {
        let absent = root.appendingPathComponent("nowhere")
        XCTAssertTrue(GeminiCLIActivityMonitor.read(root: absent, staleAfter: 45, now: now).isEmpty)
    }

    /// Projects accumulate under `~/.gemini/tmp`; only the newest file says what
    /// is happening now.
    func testTheNewestSessionWins() throws {
        try session(project: "old", name: "session-old", projectRoot: "/Users/x/old-thing",
                    modified: now.addingTimeInterval(-600))
        try session(project: "live", name: "session-live", projectRoot: "/Users/x/live-thing",
                    modified: now)
        let sessions = GeminiCLIActivityMonitor.read(root: root, staleAfter: 45, now: now)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "gemini-api.session-live")
        XCTAssertEqual(sessions.first?.detail, "Working in live-thing")
    }

    /// Older recordings have no `.project_root` beside them. The hash is a poor
    /// name, but it is a true one, and a missing marker must not cost the
    /// session its row.
    func testAMissingProjectRootFallsBackToTheDirectoryName() throws {
        try session(project: "9d2c", modified: now)
        let sessions = GeminiCLIActivityMonitor.read(root: root, staleAfter: 45, now: now)
        XCTAssertEqual(sessions.first?.detail, "Working in 9d2c")
    }
}
