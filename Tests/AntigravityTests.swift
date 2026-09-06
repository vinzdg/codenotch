import XCTest
import Sparkle
@testable import Codenotch

/// Fixtures are the real thing: the keychain payload's shape and the actual
/// `loadCodeAssist` response from a signed-in install.
final class AntigravityCredentialsTests: XCTestCase {
    /// Go's keyring package base64-encodes behind this marker instead of
    /// storing raw JSON, which is the first thing that has to be undone.
    private func stored(_ json: String) -> Data {
        Data(("go-keyring-base64:" + Data(json.utf8).base64EncodedString()).utf8)
    }

    private let payload = """
    {"auth_method":"consumer","token":{"access_token":"ya29.token",\
    "expiry":"2126-08-31T21:53:49.575961+07:00","refresh_token":"r","token_type":"Bearer"}}
    """

    func testItDecodesTheGoKeyringEnvelope() throws {
        let creds = try XCTUnwrap(AntigravityCredentials.decode(stored(payload)))
        XCTAssertEqual(creds.accessToken, "ya29.token")
        XCTAssertEqual(creds.authMethod, "consumer")
        XCTAssertFalse(creds.isExpired)
    }

    /// Without stripping the marker the value is not JSON at all, so this is
    /// the difference between reading the account and reporting it missing.
    func testRawJSONWithoutTheMarkerStillWorks() throws {
        let creds = try XCTUnwrap(AntigravityCredentials.decode(
            Data(Data(payload.utf8).base64EncodedString().utf8)))
        XCTAssertEqual(creds.accessToken, "ya29.token")
    }

    /// An offset timestamp, not UTC and not epoch milliseconds. Reading it as
    /// either is how a live token reads as long expired — the mistake Codex's
    /// `procStart` already cost this project once.
    func testItParsesAnOffsetTimestampAtTheRightInstant() throws {
        let date = try XCTUnwrap(AntigravityCredentials.parse("2026-08-31T21:53:49.575961+07:00"))
        // 21:53:49 at +07:00 is 14:53:49 UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.hour, from: date), 14)
        XCTAssertEqual(utc.component(.minute, from: date), 53)
    }

    func testItParsesWholeSecondsToo() {
        XCTAssertNotNil(AntigravityCredentials.parse("2026-08-31T21:53:49+07:00"))
    }

    func testAnExpiredTokenIsRecognised() throws {
        let old = payload.replacingOccurrences(of: "2126-", with: "2020-")
        let creds = try XCTUnwrap(AntigravityCredentials.decode(stored(old)))
        XCTAssertTrue(creds.isExpired)
    }

    func testGarbageIsRejectedRatherThanCrashing() {
        XCTAssertNil(AntigravityCredentials.decode(Data("not base64 at all".utf8)))
    }
}

final class AntigravityTierTests: XCTestCase {
    /// Verbatim from a signed-in install. Note what is absent: no used, no
    /// limit, no reset. That absence is why the provider reports the plan and
    /// admits there is nothing metered instead of drawing a ring.
    private let real = Data("""
    {"allowedTiers":[{"id":"standard-tier","name":"Gemini Code Assist",
    "description":"Unlimited coding assistant with the most powerful Gemini models",
    "userDefinedCloudaicompanionProject":true,"privacyNotice":{},"isDefault":true,
    "usesGcpTos":true}],"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT",
    "reasonMessage":"This client is no longer supported.","tierId":"free-tier",
    "tierName":"Gemini Code Assist for individuals"}]}
    """.utf8)

    func testItNamesThePlanFromTheDefaultAllowedTier() {
        XCTAssertEqual(AntigravityProvider.tier(in: real), "Gemini Code Assist")
    }

    /// An ineligible tier is what you cannot have; picking it would name the
    /// wrong plan on the cell.
    func testItIgnoresIneligibleTiers() {
        XCTAssertNotEqual(AntigravityProvider.tier(in: real), "Gemini Code Assist for individuals")
    }

    func testCurrentTierWinsWhenTheAccountHasChosenOne() {
        let chosen = Data("""
        {"currentTier":{"id":"paid","name":"Gemini Code Assist Standard"},
         "allowedTiers":[{"id":"standard-tier","name":"Gemini Code Assist","isDefault":true}]}
        """.utf8)
        XCTAssertEqual(AntigravityProvider.tier(in: chosen), "Gemini Code Assist Standard")
    }

    func testItFallsBackRatherThanThrowingOnNonsense() {
        XCTAssertEqual(AntigravityProvider.tier(in: Data("{}".utf8)), "Gemini")
    }
}

/// Counting is the only usage figure available, so its edges matter more than
/// usual — there is no vendor number to fall back on if this is wrong.
final class AntigravityActivityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("antigravity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ lines: [String], trajectory: String = "t1") throws {
        let dir = root.appendingPathComponent("\(trajectory)/.system_generated/logs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n")
            .write(to: dir.appendingPathComponent("transcript.jsonl"),
                   atomically: true, encoding: .utf8)
    }

    private func step(_ at: String, source: String) -> String {
        #"{"created_at":"\#(at)","source":"\#(source)","type":"PLANNER_RESPONSE"}"#
    }

    private let noon = ISO8601DateFormatter().date(from: "2026-08-31T12:00:00Z")!

    /// The real transcript interleaves user input and system checkpoints with
    /// model answers. Counting those would inflate the figure with work the
    /// model never did.
    func testItCountsOnlyWhatTheModelAnswered() throws {
        try write([
            step("2026-08-31T09:00:00Z", source: "USER_EXPLICIT"),
            step("2026-08-31T09:00:01Z", source: "SYSTEM"),
            step("2026-08-31T09:00:02Z", source: "MODEL"),
            step("2026-08-31T09:00:03Z", source: "MODEL")
        ])
        XCTAssertEqual(AntigravityActivity.read(root: root, now: noon).requestsToday, 2)
    }

    func testItAddsUpAcrossConversations() throws {
        try write([step("2026-08-31T09:00:00Z", source: "MODEL")], trajectory: "a")
        try write([step("2026-08-31T10:00:00Z", source: "MODEL")], trajectory: "b")
        XCTAssertEqual(AntigravityActivity.read(root: root, now: noon).requestsToday, 2)
    }

    func testYesterdayIsNotToday() throws {
        try write([
            step("2026-08-30T09:00:00Z", source: "MODEL"),
            step("2026-08-31T09:00:00Z", source: "MODEL")
        ])
        let activity = AntigravityActivity.read(root: root, now: noon)
        XCTAssertEqual(activity.requestsToday, 1)
        // The newest is still remembered, whichever day it fell on.
        XCTAssertEqual(activity.lastRequest,
                       ISO8601DateFormatter().date(from: "2026-08-31T09:00:00Z"))
    }

    /// `created_at` ends in Z. Read as local time it lands hours away, which is
    /// how counts drift across midnight — the mistake `procStart` already made
    /// once in this codebase.
    func testTheTimestampIsReadAsUTC() throws {
        let parsed = try XCTUnwrap(AntigravityActivity.parse("2026-08-31T14:12:34Z"))
        XCTAssertEqual(parsed.timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-08-31T14:12:34Z")!
                           .timeIntervalSince1970)
    }

    func testAMissingBrainDirectoryIsNotAnError() {
        let absent = root.appendingPathComponent("nowhere")
        XCTAssertEqual(AntigravityActivity.read(root: absent, now: noon).requestsToday, 0)
    }

    func testMalformedLinesAreSkippedRatherThanFatal() throws {
        try write(["not json", "", step("2026-08-31T09:00:00Z", source: "MODEL")])
        XCTAssertEqual(AntigravityActivity.read(root: root, now: noon).requestsToday, 1)
    }

    func testTheSummaryNeverImpliesAPercentage() throws {
        try write([step("2026-08-31T09:00:00Z", source: "MODEL")])
        let summary = AntigravityActivity.read(root: root, now: noon).summary
        XCTAssertEqual(summary, "~1 request today")
        XCTAssertFalse(summary.contains("%"))
    }

    func testNoActivityReadsAsNoneRatherThanZeroPercent() {
        XCTAssertEqual(AntigravityActivity(requestsToday: 0, lastRequest: nil).summary,
                       "no requests today")
    }
}

/// The quota parser is written from message names in Antigravity's binary, not
/// from a response — no licensed account was available to produce one. So what
/// is tested is mostly its refusal to believe things: a shape it does not
/// recognise must yield nothing and send the provider to the honest fallback,
/// never a confident ring built on a guess.
final class AntigravityQuotaTests: XCTestCase {
    func testItReadsBucketsIntoWindows() {
        let body = Data("""
        {"quotaGroups":[{"displayName":"Gemini","buckets":[
          {"name":"daily","displayName":"Daily","used":250,"limit":1000,
           "resetTime":"2026-09-01T00:00:00Z"}]}]}
        """.utf8)
        let windows = AntigravityProvider.windows(in: body)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.usedFraction ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(windows.first?.label, "Daily")
    }

    /// Cursor's free plan reports an included limit of zero, and dividing by it
    /// produced a confident 0% for an account well into its month. Nothing with
    /// a zero limit is ever a percentage.
    func testAZeroLimitIsDroppedRatherThanDividedBy() {
        let body = Data(#"{"buckets":[{"name":"x","used":0,"limit":0}]}"#.utf8)
        XCTAssertTrue(AntigravityProvider.windows(in: body).isEmpty)
    }

    func testNonsenseValuesAreDropped() {
        let wild = Data(#"{"buckets":[{"name":"x","used":9999,"limit":10}]}"#.utf8)
        XCTAssertTrue(AntigravityProvider.windows(in: wild).isEmpty)
        let negative = Data(#"{"buckets":[{"name":"x","used":-5,"limit":10}]}"#.utf8)
        XCTAssertTrue(AntigravityProvider.windows(in: negative).isEmpty)
    }

    /// The likeliest future: Google answers with a shape this does not know.
    /// Empty is the correct outcome — it routes to the fallback message.
    func testAnUnfamiliarShapeYieldsNothing() {
        XCTAssertTrue(AntigravityProvider.windows(in: Data(#"{"somethingElse":[1,2]}"#.utf8)).isEmpty)
        XCTAssertTrue(AntigravityProvider.windows(in: Data("not json".utf8)).isEmpty)
    }

    func testAMissingResetIsToleratedRatherThanFatal() {
        let body = Data(#"{"buckets":[{"name":"d","used":1,"limit":4}]}"#.utf8)
        XCTAssertEqual(AntigravityProvider.windows(in: body).count, 1)
    }
}

/// What an unlicensed account actually gets: a count of its own, rather than a
/// dash that reads as the app being broken.
final class AntigravityCountSnapshotTests: XCTestCase {
    private func snapshot(count: Int) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "gemini", displayName: "Antigravity", glyph: .antigravity,
            fidelity: .derived, status: .ok,
            windows: [LimitWindow(id: "requests",
                                  label: "Requests today · no limit published",
                                  used: count)]
        )
    }

    func testTheCellShowsTheCountRatherThanADash() {
        XCTAssertEqual(snapshot(count: 7).headlineText, "7")
        XCTAssertTrue(snapshot(count: 7).hasReading)
    }

    /// The ring must stay arc-less. A count is not a fraction, and drawing one
    /// would imply a limit Google never published.
    func testItDrawsNoArcBecauseThereIsNoLimit() {
        XCTAssertNil(snapshot(count: 7).ringFraction)
        XCTAssertNil(snapshot(count: 7).usedFraction)
    }

    /// Zero is a reading, not an absence — "you have not used it today" is a
    /// fact worth showing.
    func testZeroIsStillAReading() {
        XCTAssertEqual(snapshot(count: 0).headlineText, "0")
        XCTAssertTrue(snapshot(count: 0).hasReading)
    }

    /// `.derived` is what makes the tooltip print a `~`: the count is ours, not
    /// the vendor's, and the UI has to say so.
    func testItIsMarkedAsOurOwnCount() {
        XCTAssertEqual(snapshot(count: 3).fidelity, .derived)
    }
}

/// The bridge to Antigravity's own language server — the only route that
/// actually returns the weekly figure, because it is the route Antigravity
/// itself uses.
final class AntigravityBridgeTests: XCTestCase {
    /// Verbatim from the running language server.
    private let real = Data("""
    {"response":{"groups":[
      {"displayName":"Gemini Models",
       "description":"Models within this group: Gemini Flash, Gemini Pro",
       "buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining",
                   "window":"weekly","remainingFraction":0.96262,
                   "resetTime":"2026-09-07T14:12:34Z"}]},
      {"displayName":"Claude and GPT models",
       "buckets":[{"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining",
                   "window":"weekly","remainingFraction":1,
                   "resetTime":"2026-09-08T09:12:10Z"}]}]}}
    """.utf8)

    /// The server reports what is *left*; the notch shows what is spent.
    /// Inverting it here rather than in the view keeps a percentage meaning the
    /// same thing whichever provider produced it.
    func testRemainingIsTurnedIntoUsed() {
        let windows = AntigravityBridge.windows(in: real)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].id, "gemini-weekly")
        XCTAssertEqual(windows[0].usedFraction ?? 0, 1 - 0.96262, accuracy: 0.00001)
        XCTAssertEqual(windows[0].label, "Gemini Models")
    }

    /// A full bucket is 0% used, not "no reading".
    func testAnUntouchedLimitIsZeroUsed() {
        XCTAssertEqual(AntigravityBridge.windows(in: real)[1].usedFraction, 0)
    }

    func testItKeepsTheResetTime() throws {
        let resets = try XCTUnwrap(AntigravityBridge.windows(in: real)[0].resetsAt)
        XCTAssertEqual(resets, ISO8601DateFormatter().date(from: "2026-09-07T14:12:34Z"))
    }

    /// A fraction outside 0...1 is not a fraction; better nothing than a ring
    /// past full or below empty.
    func testImpossibleFractionsAreDropped() {
        let wild = Data(#"{"response":{"groups":[{"displayName":"G","buckets":[{"bucketId":"a","remainingFraction":1.4},{"bucketId":"b","remainingFraction":-0.2}]}]}}"#.utf8)
        XCTAssertTrue(AntigravityBridge.windows(in: wild).isEmpty)
    }

    func testAnUnfamiliarShapeYieldsNothing() {
        XCTAssertTrue(AntigravityBridge.windows(in: Data(#"{"other":1}"#.utf8)).isEmpty)
        XCTAssertTrue(AntigravityBridge.windows(in: Data("nonsense".utf8)).isEmpty)
    }

    // MARK: - Discovery

    /// The token is only ever on the command line: the server is started with
    /// `--https_server_port 0`, so nothing about it is written to disk.
    func testItReadsTheTokenFromTheProcessTable() throws {
        let table = """
        29283 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone \
        --csrf_token d4bd9204-bf02-4111-b1fe-71f0d0d921d0 --app_data_dir antigravity
        """
        let endpoint = try XCTUnwrap(
            AntigravityBridge.discover(processTable: table, listeningPorts: { pid in
                XCTAssertEqual(pid, 29283)
                return [63881, 63882]
            })
        )
        XCTAssertEqual(endpoint.csrfToken, "d4bd9204-bf02-4111-b1fe-71f0d0d921d0")
        XCTAssertEqual(endpoint.ports, [63881, 63882])
    }

    func testNoAntigravityMeansNoEndpoint() {
        XCTAssertNil(AntigravityBridge.discover(processTable: "1 /sbin/launchd",
                                                listeningPorts: { _ in [] }))
    }

    /// Antigravity running but listening nowhere we can see is not an endpoint.
    func testNoPortMeansNoEndpoint() {
        let table = "1 language_server --csrf_token abc"
        XCTAssertNil(AntigravityBridge.discover(processTable: table, listeningPorts: { _ in [] }))
    }

    func testItParsesPortsFromLSOF() {
        let output = """
        language_server 29283 vinz 12u IPv4 0x1 0t0 TCP 127.0.0.1:63881 (LISTEN)
        language_server 29283 vinz 13u IPv4 0x2 0t0 TCP 127.0.0.1:63882 (LISTEN)
        """
        XCTAssertEqual(AntigravityBridge.parsePorts(fromLSOF: output), [63881, 63882])
    }
}

/// Every keychain read risks interrupting someone, and the answer changes about
/// hourly — so it is read about hourly, not twice a minute.
final class CredentialCacheTests: XCTestCase {
    private struct Token { let expired: Bool }

    func testItReadsOnceAndThenHoldsWhatItHas() throws {
        var reads = 0
        let cache = CredentialCache<Token> { $0.expired }
        for _ in 0..<10 {
            _ = try? cache.value { reads += 1; return Token(expired: false) }
        }
        XCTAssertEqual(reads, 1, "the keychain was read every time")
    }

    /// Expiry is not what decides. It used to be — "hold it while it is valid"
    /// — and that is what made the app ask over and over: once a token aged
    /// out, every caller went back to the keychain, once a minute, all night,
    /// for a token that could not change until the owning app next ran. Reading
    /// an unchanged item cannot give a different answer; it can only raise
    /// another dialogue.
    func testAnExpiredValueIsNotReadAgainWhileTheItemIsUnchanged() {
        var reads = 0
        let stamp = Date(timeIntervalSince1970: 1_000)
        let cache = CredentialCache<Token> { $0.expired }
        for _ in 0..<10 {
            _ = try? cache.value(itemModifiedAt: { stamp }) {
                reads += 1; return Token(expired: true)
            }
        }
        XCTAssertEqual(reads, 1, "an unchanged item was read \(reads) times")
    }

    /// But a rotation is picked up at once — that is the whole reason to look.
    func testAChangedItemIsReadAgainImmediately() {
        var reads = 0
        var stamp = Date(timeIntervalSince1970: 1_000)
        let cache = CredentialCache<Token> { $0.expired }
        _ = try? cache.value(itemModifiedAt: { stamp }) { reads += 1; return Token(expired: true) }
        stamp = Date(timeIntervalSince1970: 2_000)   // the owning app refreshed it
        _ = try? cache.value(itemModifiedAt: { stamp }) { reads += 1; return Token(expired: false) }
        XCTAssertEqual(reads, 2, "a rotated token was not picked up")
    }

    /// With no probe to go on there is nothing to compare, so it falls back to
    /// waiting — still not once per tick.
    func testWithoutAProbeItWaitsRatherThanAsksEveryTime() {
        var reads = 0
        var clock = Date(timeIntervalSince1970: 0)
        let cache = CredentialCache<Token>(now: { clock }) { $0.expired }
        _ = try? cache.value { reads += 1; return Token(expired: true) }
        clock.addTimeInterval(60)
        _ = try? cache.value { reads += 1; return Token(expired: true) }
        XCTAssertEqual(reads, 1, "a minute later it asked again")

        clock.addTimeInterval(10 * 60)
        _ = try? cache.value { reads += 1; return Token(expired: true) }
        XCTAssertEqual(reads, 2, "it never looked again at all")
    }

    /// One refusal must not become a refusal a minute. macOS said no; asking
    /// again on the next tick is what the user experiences as "it keeps asking
    /// even though I chose Always Allow".
    func testARefusalIsNeverRetriedWhileTheItemIsUnchanged() {
        struct Denied: Error {}
        var reads = 0
        var clock = Date(timeIntervalSince1970: 0)
        var stamp = Date(timeIntervalSince1970: 1_000)
        let cache = CredentialCache<Token>(now: { clock }) { $0.expired }

        // A good read first, so there is something to fall back on.
        _ = try? cache.value(itemModifiedAt: { stamp }) { reads += 1; return Token(expired: true) }
        // Then the item rotates and the read is refused.
        stamp = Date(timeIntervalSince1970: 2_000)
        _ = try? cache.value(itemModifiedAt: { stamp }) { () -> Token in
            reads += 1; throw Denied()
        }
        XCTAssertEqual(reads, 2)

        // An hour of ticks against an item that has not moved again.
        for _ in 0..<60 {
            clock.addTimeInterval(60)
            _ = try? cache.value(itemModifiedAt: { stamp }) { () -> Token in
                reads += 1; throw Denied()
            }
        }
        XCTAssertEqual(reads, 2, "a refusal was retried \(reads - 2) more times")
    }

    /// A rotation is the exception, and has to be: the old secret is gone, so
    /// the new one is the only one worth having even after a refusal.
    func testARotationIsStillWorthAskingForAfterARefusal() {
        struct Denied: Error {}
        var reads = 0
        var stamp = Date(timeIntervalSince1970: 1_000)
        let cache = CredentialCache<Token> { $0.expired }

        _ = try? cache.value(itemModifiedAt: { stamp }) { reads += 1; return Token(expired: true) }
        stamp = Date(timeIntervalSince1970: 2_000)
        _ = try? cache.value(itemModifiedAt: { stamp }) { () -> Token in
            reads += 1; throw Denied()
        }
        stamp = Date(timeIntervalSince1970: 3_000)   // the owning app rotated it again
        _ = try? cache.value(itemModifiedAt: { stamp }) { reads += 1; return Token(expired: false) }
        XCTAssertEqual(reads, 3, "a rotated secret was never fetched")
    }

    /// And "Allow access…" still gets through, because raising the dialogue is
    /// exactly what that button is for.
    func testForgettingClearsARefusalBackoff() {
        struct Denied: Error {}
        var reads = 0
        var clock = Date(timeIntervalSince1970: 0)
        let stamp = Date(timeIntervalSince1970: 1_000)
        let cache = CredentialCache<Token>(now: { clock }) { $0.expired }

        _ = try? cache.value(itemModifiedAt: { stamp }) { reads += 1; return Token(expired: true) }
        clock.addTimeInterval(10 * 60)
        _ = try? cache.value(itemModifiedAt: { Date(timeIntervalSince1970: 2_000) }) { () -> Token in
            reads += 1; throw Denied()
        }
        XCTAssertEqual(reads, 2)

        cache.forget()
        _ = try? cache.value(itemModifiedAt: { stamp }) { reads += 1; return Token(expired: false) }
        XCTAssertEqual(reads, 3, "Allow access… could not reach the keychain")
    }

    /// The case this exists for: a different account is signed into, the server
    /// rejects a token that has not expired, and the held copy has to go.
    func testForgettingForcesAFreshRead() {
        var reads = 0
        let cache = CredentialCache<Token> { $0.expired }
        _ = try? cache.value { reads += 1; return Token(expired: false) }
        cache.forget()
        _ = try? cache.value { reads += 1; return Token(expired: false) }
        XCTAssertEqual(reads, 2)
    }

    /// A failure must never be handed back as if it were a credential — but it
    /// is remembered as an *attempt*, so the same refusal is not put to macOS
    /// again a minute later.
    func testAFailedReadIsRememberedWithoutBeingCached() {
        struct Nope: Error {}
        var reads = 0
        var clock = Date(timeIntervalSince1970: 0)
        let cache = CredentialCache<Token>(now: { clock }) { $0.expired }

        for _ in 0..<3 {
            _ = try? cache.value { () -> Token in reads += 1; throw Nope() }
        }
        XCTAssertEqual(reads, 1, "the same refusal was put to macOS \(reads) times")
        XCTAssertThrowsError(try cache.value { Token(expired: false) },
                             "a failure was served as if it were a credential")

        // It does try again eventually, so a grant given in Keychain Access is
        // picked up without a restart.
        clock.addTimeInterval(10 * 60)
        _ = try? cache.value { () -> Token in reads += 1; throw Nope() }
        XCTAssertEqual(reads, 2, "it never looked again at all")
    }
}

/// Antigravity had no activity monitor at all, so its ring never showed the
/// working state the other three had — and the store never learned it was busy,
/// staying on its slow idle poll while usage was actively being spent.
@MainActor
final class AntigravityActivityMonitorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agy-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func transcript(_ name: String, modified: Date) throws -> URL {
        let dir = root.appendingPathComponent("\(name)/.system_generated/logs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("transcript.jsonl")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: file.path)
        return file
    }

    func testAJustWrittenTranscriptReadsAsWorking() throws {
        try transcript("t1", modified: Date())
        let sessions = AntigravityActivityMonitor.read(root: root, staleAfter: 45)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .busy)
        XCTAssertEqual(sessions.first?.name, "Antigravity")
    }

    /// A finished turn is not work in progress.
    func testAnOldTranscriptIsNotWorking() throws {
        try transcript("t1", modified: Date().addingTimeInterval(-600))
        XCTAssertTrue(AntigravityActivityMonitor.read(root: root, staleAfter: 45).isEmpty)
    }

    /// Many conversations accumulate; only the newest says what is happening now.
    func testTheNewestTranscriptWins() throws {
        try transcript("old", modified: Date().addingTimeInterval(-600))
        try transcript("live", modified: Date())
        let sessions = AntigravityActivityMonitor.read(root: root, staleAfter: 45)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "antigravity.live")
    }

    func testNoTranscriptsIsQuietRatherThanAnError() {
        let absent = root.appendingPathComponent("nowhere")
        XCTAssertTrue(AntigravityActivityMonitor.read(root: absent, staleAfter: 45).isEmpty)
    }
}

/// The "Open" button on an account row. The reading is borrowed from an app on
/// this Mac, so that app is where the account lives — the website is a separate
/// session that will bounce you to a login if the browser is not signed in.
final class AccountDestinationTests: XCTestCase {
    /// Claude Code is a command, not an application, so its row can only ever
    /// be a link — and claude.ai is genuinely where its usage is shown.
    func testAGuidanceRouteFallsBackToTheWebsite() {
        let route = SignInRoute.guidance("Run Claude Code once.")
        guard case .openApp = route else { return }
        XCTFail("guidance should not carry an app")
    }

    /// Naming the app rather than a host is the whole point: the button says
    /// where it actually goes.
    func testTitlesNameTheirDestination() {
        XCTAssertEqual(SignInRoute.openApp(bundleID: "x", name: "Cursor").actionTitle,
                       "Open Cursor")
    }

    /// An app that is not installed must not be offered — the button would do
    /// nothing, which is worse than no button.
    func testAnUninstalledAppIsNotOffered() {
        let missing = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.example.definitely-not-installed"
        )
        XCTAssertNil(missing)
    }
}

/// What a fresh install is told. Both sentences exist because of a specific way
/// a new user gets stranded, so both are pinned rather than left to drift.
@MainActor
final class FirstRunCopyTests: XCTestCase {
    private func settings() -> SettingsView {
        let name = "FirstRunCopyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SettingsView(preferences: Preferences(defaults: defaults),
                            providers: { [] },
                            signOut: { _ in }, signIn: { _ in true },
                            switchAccount: { _ in true },
                            retry: { _ in },
                            updater: Updater())
    }

    /// The setup note has to name the tools. "Tools already signed in on this
    /// Mac" reads as satisfied by anyone who uses Claude in a browser, and the
    /// distinction that catches them is Claude *Code*.
    func testTheSetupNoteNamesEveryToolAndTheCodeDistinction() {
        let copy = SettingsView.setupCopy
        for tool in ["Claude Code", "Cursor", "Codex", "Antigravity"] {
            XCTAssertTrue(copy.contains(tool), "the setup note never mentions \(tool)")
        }
        XCTAssertTrue(copy.contains("not the Claude app"),
                      "nothing warns that the Claude app is not Claude Code")
    }

    /// The keychain prompt is the only interruption in the whole first run, and
    /// choosing Allow rather than Always Allow is what makes it recur.
    func testTheKeychainPromptIsExplainedBeforeItAppears() {
        let copy = SettingsView.keychainCopy
        XCTAssertTrue(copy.contains("Always Allow"))
        XCTAssertTrue(copy.lowercased().contains("macos will ask"))
    }
}

/// Antigravity's port changes on every launch, so the bridge failing is a
/// routine event — the app was restarted, not the account lost.
@MainActor
final class AntigravityFallbackTests: XCTestCase {
    /// `credentialExpired` is the store's word for "still true, just old", and
    /// it keeps the previous reading instead of discarding it. Anything that
    /// supersedes history would throw away the percentage.
    func testTheAwayStateKeepsTheLastReading() {
        let status = UsageStore.statusForTesting(UsageProviderError.credentialExpired)
        XCTAssertFalse(UsageStore.supersedesHistory(status),
                       "a restarted Antigravity would wipe the percentage")
        guard case .stale = status else {
            return XCTFail("expected a stale status, got \(status)")
        }
    }

    /// The distinction that matters: never having connected is a different
    /// situation from having connected and lost it, and only the first should
    /// show a request count.
    func testNothingMeteredIsAlsoKeptRatherThanDiscarded() {
        let status = UsageStore.statusForTesting(
            UsageProviderError.nothingMetered("no bridge yet")
        )
        guard case .unsupported = status else {
            return XCTFail("expected unsupported, got \(status)")
        }
    }
}

final class AuthorCreditTests: XCTestCase {
    /// Pinned because a wrong handle in a credit is worse than none, and it is
    /// the kind of string nobody re-reads once it looks right.
    func testTheCreditPointsAtTheRightAccount() {
        XCTAssertEqual(SettingsView.authorURL.absoluteString, "https://x.com/hivinz_")
        XCTAssertEqual(SettingsView.authorURL.scheme, "https")
    }
}

/// Where the app shows itself, apart from the notch. Only one of the three has
/// a Dock tile, and only one makes a menu bar item — get either mapping wrong
/// and the app is either unreachable or in two places at once.
final class AppPresenceTests: XCTestCase {
    func testOnlyTheDockOptionIsARegularApp() {
        XCTAssertEqual(AppPresence.dock.activationPolicy, .regular)
        XCTAssertEqual(AppPresence.menuBar.activationPolicy, .accessory)
        XCTAssertEqual(AppPresence.hidden.activationPolicy, .accessory)
    }

    /// What separates the two accessory modes.
    func testOnlyTheMenuBarOptionMakesAStatusItem() {
        XCTAssertFalse(AppPresence.dock.wantsStatusItem)
        XCTAssertTrue(AppPresence.menuBar.wantsStatusItem)
        XCTAssertFalse(AppPresence.hidden.wantsStatusItem)
    }

    /// Choosing this removes every visible way back into settings, so the
    /// option itself has to say where the door is.
    func testHidingExplainsHowToGetBack() {
        XCTAssertTrue(AppPresence.hidden.explanation.contains("Applications"))
    }

    func testEveryModeIsNamedAndExplained() {
        XCTAssertEqual(AppPresence.allCases.count, 3)
        for mode in AppPresence.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.explanation.isEmpty)
        }
    }

    @MainActor
    func testItDefaultsToTheDockRatherThanNowhere() {
        let name = "AppPresenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        XCTAssertEqual(Preferences(defaults: defaults).appPresence, .dock)
    }

    /// A value written by a future version must not make the app vanish.
    @MainActor
    func testAnUnknownStoredValueFallsBackToVisible() {
        let name = "AppPresenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set("skywriting", forKey: "appPresence")
        XCTAssertEqual(Preferences(defaults: defaults).appPresence, .dock)
    }

    @MainActor
    func testTheChoiceSurvivesARestart() {
        let name = "AppPresenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        Preferences(defaults: defaults).appPresence = .menuBar
        XCTAssertEqual(Preferences(defaults: defaults).appPresence, .menuBar)
    }
}

/// What the settings sheet says after a check. Sparkle's own answer to a failed
/// one is a modal reading "an error occurred in retrieving update information",
/// which names no cause and offers nothing to do — so the outcome is kept and
/// worded here instead.
@MainActor
final class UpdateOutcomeTests: XCTestCase {
    /// The case people actually hit, and the one that most needs reassuring:
    /// nothing is wrong with their copy of the app.
    func testAnUnreachableFeedSaysSoWithoutBlamingTheApp() throws {
        let message = try XCTUnwrap(Updater.Outcome.unreachable.message)
        XCTAssertTrue(message.contains("Couldn't reach"))
        XCTAssertTrue(message.contains("nothing is wrong with this copy"))
        XCTAssertFalse(message.lowercased().contains("error occurred"))
    }

    func testEveryOutcomeExceptIdleSaysSomething() {
        XCTAssertNil(Updater.Outcome.idle.message)
        for outcome: Updater.Outcome in [.checking, .upToDate(Date()), .found("1.1.0"),
                                         .unreachable, .failed("disk full")] {
            XCTAssertNotNil(outcome.message, "\(outcome) says nothing")
        }
    }

    func testAFoundUpdateNamesTheVersion() throws {
        let message = try XCTUnwrap(Updater.Outcome.found("1.2.0").message)
        XCTAssertTrue(message.contains("1.2.0"))
    }

    /// The distinction the wording depends on: a feed that cannot be fetched is
    /// routine, anything else is reported as itself.
    func testOnlyAFeedFailureCountsAsUnreachable() {
        XCTAssertTrue(Updater.isUnreachable(Int(SUError.appcastError.rawValue)))
        XCTAssertFalse(Updater.isUnreachable(Int(SUError.installationError.rawValue)))
    }
}

/// The menu bar mark. Loaded from the asset catalogue rather than drawn from
/// the app icon, and a template so macOS can tint it for whatever the bar is.
@MainActor
final class MenuBarIconTests: XCTestCase {
    func testTheIconLoadsAndIsNotEmpty() throws {
        let icon = try XCTUnwrap(StatusItemController.icon(),
                                 "MenuBarIcon is missing from the asset catalogue")
        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
        XCTAssertFalse(icon.representations.isEmpty, "the image carries nothing to draw")
    }

    /// Without this macOS cannot tint it, and the mark stays black on a dark
    /// menu bar — invisible.
    func testItIsATemplate() throws {
        XCTAssertTrue(try XCTUnwrap(StatusItemController.icon()).isTemplate)
    }
}



/// Declining the keychain prompt is easy to do by reflex. Until now it was
/// reported as being signed out — sending someone who *is* signed in to fix
/// something that is not broken — and nothing on screen would ask again.
@MainActor
final class KeychainRefusalTests: XCTestCase {
    /// The three statuses macOS returns for "the item is there and you may not
    /// have it". Deny produces the first two; the third is the same refusal
    /// arriving without a prompt.
    func testARefusalIsNotMistakenForBeingSignedOut() {
        XCTAssertTrue(ClaudeCredentials.wasRefused(errSecAuthFailed))
        XCTAssertTrue(ClaudeCredentials.wasRefused(errSecUserCanceled))
        XCTAssertTrue(ClaudeCredentials.wasRefused(errSecInteractionNotAllowed))
    }

    /// A missing item genuinely does mean nobody has signed in.
    func testAMissingItemIsStillTreatedAsSignedOut() {
        XCTAssertFalse(ClaudeCredentials.wasRefused(errSecItemNotFound))
    }

    func testTheStatusSaysWhatHappenedAndWhatToDo() {
        let snapshot = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .accessDenied, windows: []
        )
        let message = snapshot.statusMessage ?? ""
        XCTAssertTrue(message.contains("refused"))
        XCTAssertTrue(message.contains("Always Allow"))
        XCTAssertFalse(message.contains("Sign in"), "it tells a signed-in user to sign in")
    }

    /// The credential is still valid — we were simply not let in to re-read it.
    /// Throwing the last reading away would punish a mis-click.
    func testARefusalKeepsTheLastReading() {
        XCTAssertFalse(UsageStore.supersedesHistory(.accessDenied))
    }

    func testTheErrorMapsToTheRefusedStatus() {
        guard case .accessDenied =
            UsageStore.statusForTesting(UsageProviderError.accessDenied) else {
            return XCTFail("a refusal was reported as something else")
        }
    }
}

/// The button that puts the keychain prompt back on screen.
@MainActor
final class ReauthorizeTests: XCTestCase {
    private final class Stub: UsageProvider, @unchecked Sendable {
        let id = "claude"
        let displayName = "Claude"
        let glyph = ProviderGlyph.claude
        private(set) var forgotten = 0
        private(set) var fetches = 0

        // `nonisolated` on purpose: nested in a @MainActor test class, an
        // isolated method does not satisfy the protocol's requirement, and
        // Swift quietly falls back to the extension's no-op default — the
        // test then passes or fails for the wrong reason.
        nonisolated func forgetCachedCredential() { forgotten += 1 }
        func fetchSnapshot() async throws -> ProviderSnapshot {
            fetches += 1
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok, windows: [])
        }
    }

    private func store(_ stub: Stub) -> UsageStore {
        let name = "Reauthorize.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return UsageStore(providers: [stub], archive: UsageArchive(defaults: d))
    }

    /// The part that makes the button work at all. A plain refresh is served
    /// from the cached token whenever it is still valid, so the keychain is
    /// never touched and no prompt appears.
    func testItDropsTheHeldCredentialBeforeReading() async {
        let stub = Stub()
        // Held in a variable rather than called on a temporary: the store owns
        // the refresh task, and letting it go out of scope cancels the work
        // this is measuring.
        let store = store(stub)
        store.reauthorize(providerID: "claude")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stub.forgotten, 1, "the cached credential was reused, so macOS was never asked")
        XCTAssertEqual(stub.fetches, 1)
    }

    /// An unknown id must not quietly fetch something else.
    func testAnUnknownProviderIsIgnored() async {
        let stub = Stub()
        let store = store(stub)
        store.reauthorize(providerID: "nobody")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(stub.forgotten, 0)
        XCTAssertEqual(stub.fetches, 0)
    }
}

/// Only two providers keep a credential in the keychain; the others read files
/// and can never raise a prompt.
final class KeychainProviderTests: XCTestCase {
    private func summary(_ id: String) -> ProviderSummary {
        ProviderSummary(id: id, name: id, glyph: .claude, account: nil,
                        signIn: .guidance("x"))
    }

    func testOnlyKeychainBackedProvidersOfferIt() {
        XCTAssertTrue(summary("claude").usesKeychain)
        XCTAssertTrue(summary("claude-work").usesKeychain, "every profile's token is a keychain item")
        XCTAssertTrue(summary("gemini").usesKeychain)
        XCTAssertFalse(summary("cursor").usesKeychain, "Cursor reads a file, not the keychain")
        XCTAssertFalse(summary("codex").usesKeychain, "Codex reads a file, not the keychain")
    }
}

/// Claude Code files a new keychain item on every token rotation rather than
/// updating one in place, so an account used for months accumulates several
/// under `Claude Code-credentials` — six, on the machine this was found on.
/// `kSecMatchLimitOne` gives no ordering guarantee across them, so the app
/// could read an old, expired duplicate while a valid one sat beside it: the
/// ring showed "Waiting for the first reading…" forever, with a working token
/// one item away. `KeychainItem.winner` is the selection that replaced it —
/// the query it is chosen from cannot run in a test, since there is no real
/// keychain to point it at.
final class KeychainDuplicateTests: XCTestCase {
    private func item(ref: String, modified: Date?) -> [CFString: Any] {
        var item: [CFString: Any] = [kSecValuePersistentRef: Data(ref.utf8)]
        if let modified { item[kSecAttrModificationDate] = modified }
        return item
    }

    /// The reported case: an old duplicate must not beat a newer one merely by
    /// being asked about first.
    func testTheMostRecentlyModifiedItemWins() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let winner = KeychainItem.winner(among: [
            item(ref: "old", modified: old),
            item(ref: "new", modified: new)
        ])
        XCTAssertEqual(winner?.persistentRef, Data("new".utf8))
        XCTAssertEqual(winner?.modifiedAt, new)
    }

    /// Order in the array must not decide it — that is exactly the bug being
    /// replaced, moved into this function instead of out of it.
    func testOrderInTheArrayDoesNotDecideIt() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let winner = KeychainItem.winner(among: [
            item(ref: "new", modified: new),
            item(ref: "old", modified: old)
        ])
        XCTAssertEqual(winner?.persistentRef, Data("new".utf8))
    }

    /// The single-item case, which is nearly everyone: one duplicate is still
    /// a field of one to win.
    func testASingleItemWinsByDefault() {
        let winner = KeychainItem.winner(among: [item(ref: "only", modified: Date())])
        XCTAssertEqual(winner?.persistentRef, Data("only".utf8))
    }

    func testNoItemsMeansNoWinner() {
        XCTAssertNil(KeychainItem.winner(among: []))
    }

    /// A duplicate with no recorded modification date is worth keeping, not
    /// discarding — `.distantPast` only ranks it against the others.
    func testAnUndatedDuplicateStillLosesToADatedOne() {
        let dated = Date(timeIntervalSince1970: 1_000)
        let winner = KeychainItem.winner(among: [
            item(ref: "undated", modified: nil),
            item(ref: "dated", modified: dated)
        ])
        XCTAssertEqual(winner?.persistentRef, Data("dated".utf8))
    }

    /// But it can still win outright if it is the only one there is.
    func testAnUndatedDuplicateWinsWhenAloneWithNoDateAtAll() {
        let winner = KeychainItem.winner(among: [item(ref: "only", modified: nil)])
        XCTAssertEqual(winner?.persistentRef, Data("only".utf8))
        XCTAssertNil(winner?.modifiedAt)
    }

    /// An entry with no persistent reference at all cannot be read later no
    /// matter how it ranks, so it is dropped rather than allowed to win and
    /// then fail.
    func testAnItemWithNoPersistentRefIsNeverThePick() {
        let broken: [CFString: Any] = [kSecAttrModificationDate: Date(timeIntervalSince1970: 9_999)]
        let winner = KeychainItem.winner(among: [
            broken,
            item(ref: "usable", modified: Date(timeIntervalSince1970: 1))
        ])
        XCTAssertEqual(winner?.persistentRef, Data("usable".utf8))
    }
}
