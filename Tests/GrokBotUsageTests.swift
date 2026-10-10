import XCTest
@testable import Codenotch

/// Pinned to the weekly cache Grok Bot keeps in `sand-client-persistence`,
/// recorded from a live SuperGrok Plus session with the account slot
/// anonymised. The file is plain JSON under a base32 blob name; the tests
/// below pin the naming against a filename observed on a real Mac.
final class GrokBotUsageTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokBotUsageTests.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Blob names

    /// Observed on a Mac with Grok Bot signed in: the fixed name of the
    /// account-slot blob. If the encoding ever drifts, discovery finds
    /// nothing — so the algorithm is pinned to reality, not to itself.
    func testTheAccountSlotFilenameIsTheOneGrokBotWrites() {
        XCTAssertEqual(
            GrokBotCache.blobFilename(forKey: "sand.client.slice.client-meta.account-slot"),
            "onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a.blob"
        )
    }

    func testBlobNamesRoundTrip() {
        let key = "sand.client.slice.account.grok|user_test123.weekly-usage.cache"
        let filename = GrokBotCache.blobFilename(forKey: key)
        XCTAssertEqual(GrokBotCache.decodeBlobName(filename), key)
        XCTAssertNil(GrokBotCache.decodeBlobName("not-a-blob.json"))
        XCTAssertNil(GrokBotCache.decodeBlobName("!!!.blob"))
    }

    // MARK: - The reading

    func testTheRingIsTheWeeklyPercent() throws {
        let reading = try GrokBotCache.reading(from: Data(Self.cache().utf8), fallbackDate: .distantPast)
        XCTAssertEqual(reading.percentUsed, 85.898948, accuracy: 0.000001)
        XCTAssertEqual(reading.planLabel, "SuperGrok Plus")
        XCTAssertFalse(reading.isExpired)
    }

    func testTheWeeklyWindowCarriesTheReset() throws {
        let reading = try GrokBotCache.reading(from: Data(Self.cache().utf8), fallbackDate: .distantPast)
        let windows = GrokBotUsage.windows(from: reading)
        let weekly = try XCTUnwrap(windows.first { $0.id == "weekly" })
        XCTAssertEqual(weekly.label, "Weekly usage")
        XCTAssertEqual(weekly.usedFraction ?? -1, 0.85898948, accuracy: 0.000001)
        XCTAssertEqual(weekly.duration, 7 * 86400)
        let reset = try XCTUnwrap(weekly.resetsAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.year, from: reset), 2026)
        XCTAssertEqual(utc.component(.month, from: reset), 10)
        XCTAssertEqual(utc.component(.day, from: reset), 13)
    }

    /// A spend cap rides along as a second row; without one there is just the
    /// weekly bar.
    func testOnDemandIsASecondRowOnlyWhenTheAccountHasACap() throws {
        let capped = try GrokBotCache.reading(
            from: Data(Self.cache(onDemand: #"{"usedCents":450,"limitCents":1000}"#).utf8),
            fallbackDate: .distantPast
        )
        let rows = GrokBotUsage.windows(from: capped)
        XCTAssertEqual(rows.map(\.id), ["weekly", "on_demand"])
        XCTAssertEqual(rows[1].usedFraction ?? -1, 0.45, accuracy: 0.0001)

        let plain = try GrokBotCache.reading(from: Data(Self.cache().utf8), fallbackDate: .distantPast)
        XCTAssertEqual(GrokBotUsage.windows(from: plain).map(\.id), ["weekly"])
    }

    /// The cache only moves while Grok Bot runs. Past its own expiry the
    /// number is still shown, but the provider dims it as stale.
    func testAnExpiredCacheReadsStale() async throws {
        try writeBlobs(cache: Self.cache(readAtMs: 1_000, expiresAtMs: 2_000))
        let snapshot = try await GrokBotProvider(persistenceDir: directory).fetchSnapshot()
        XCTAssertEqual(snapshot.status, .stale(since: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(snapshot.usedFraction ?? -1, 0.85898948, accuracy: 0.000001)
    }

    /// Anything but `kind: "present"` with a usage in it is not a reading —
    /// the fetch behind the cache answers null for pooled enterprise
    /// allowances and for accounts whose percent never arrived.
    func testAnEmptyKindIsNothingMeteredRatherThanZero() {
        for body in [#"{"value":{"kind":"absent"}}"#, #"{"value":{"kind":"present"}}"#,
                    #"{"value":{"kind":"present","reading":{}}}"#] {
            XCTAssertThrowsError(
                try GrokBotCache.reading(from: Data(body.utf8), fallbackDate: .distantPast)
            ) { error in
                guard case UsageProviderError.nothingMetered = error else {
                    return XCTFail("expected nothingMetered for \(body), got \(error)")
                }
            }
        }
    }

    func testGarbageIsABadResponseRatherThanAGuess() {
        XCTAssertThrowsError(
            try GrokBotCache.reading(from: Data("not json".utf8), fallbackDate: .distantPast)
        ) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    // MARK: - Discovery

    func testAFreshCacheIsAnOkSnapshotWithThePlan() async throws {
        try writeBlobs(cache: Self.cache())
        let provider = GrokBotProvider(persistenceDir: directory)
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.headline?.id, "weekly")
        XCTAssertEqual(snapshot.weeklyLimitWindow?.id, "weekly")
        XCTAssertEqual(snapshot.plan, "SuperGrok Plus")
        XCTAssertEqual(snapshot.glyph, .grokbot)
    }

    func testNoCacheIsNeedsAuth() async {
        let provider = GrokBotProvider(
            persistenceDir: directory.appendingPathComponent("missing")
        )
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth")
        } catch UsageProviderError.needsAuth {
        } catch {
            XCTFail("expected needsAuth, got \(error)")
        }
    }

    /// Two signed-in accounts each keep their own cache; the selected slot
    /// wins even when the other's file is newer.
    func testTheActiveSlotWinsOverAFresherNeighbour() async throws {
        try writeBlobs(cache: Self.cache(percentUsed: 10), slot: "grok|user_active")
        try writeBlobs(cache: Self.cache(percentUsed: 90), slot: "grok|user_other")
        try selectSlot("grok|user_active")
        // The neighbour's file is newer on disk; the slot still decides.
        try touch(weeklyURL(slot: "grok|user_other"), daysFromNow: 1)

        let snapshot = try await GrokBotProvider(persistenceDir: directory).fetchSnapshot()
        XCTAssertEqual(snapshot.usedFraction ?? -1, 0.10, accuracy: 0.0001)
    }

    /// Without a selected slot the freshest cache answers — a file Grok Bot
    /// wrote moments ago over one from a version that kept no slot.
    func testTheFreshestCacheWinsWithoutASelectedSlot() async throws {
        try writeBlobs(cache: Self.cache(percentUsed: 10), slot: "grok|user_old")
        try writeBlobs(cache: Self.cache(percentUsed: 90), slot: "grok|user_new")
        try touch(weeklyURL(slot: "grok|user_old"), daysFromNow: -2)

        let snapshot = try await GrokBotProvider(persistenceDir: directory).fetchSnapshot()
        XCTAssertEqual(snapshot.usedFraction ?? -1, 0.90, accuracy: 0.0001)
    }

    func testAccountCarriesThePlanAndTheBillingPage() throws {
        try writeBlobs(cache: Self.cache())
        let account = try XCTUnwrap(GrokBotCache.account(persistenceDir: directory))
        XCTAssertNil(account.label)
        XCTAssertEqual(account.plan, "SuperGrok Plus")
        XCTAssertEqual(account.source, "Grok Bot")
        XCTAssertEqual(account.manageURL?.absoluteString, "https://cursor.com/dashboard?tab=billing")
    }

    // MARK: - Helpers

    private static let slot = "grok|user_test123"

    /// The recorded shape. `readAtMs`/`expiresAtMs` default to a reading taken
    /// now, good for another day — the way a running Grok Bot leaves it.
    private static func cache(percentUsed: Double = 85.898948,
                              onDemand: String? = nil,
                              readAtMs: Int? = nil, expiresAtMs: Int? = nil) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return """
        {"schemaVersion":2,"value":{"kind":"present","selectedTeamId":null,\
        "reading":{"usage":{"percentUsed":\(percentUsed),\
        "nextResetMs":1791876398146,"isSandTrial":false,\
        "hasNonZeroIncludedLimit":true,"isTeamSeat":false,\
        "onDemand":\(onDemand ?? "null"),"grokPlanLabel":"SuperGrok Plus"},\
        "readAtMs":\(readAtMs ?? now)},"expiresAtMs":\(expiresAtMs ?? (now + 86_400_000))}}
        """
    }

    private func weeklyURL(slot: String) -> URL {
        directory.appendingPathComponent(GrokBotCache.blobFilename(
            forKey: "sand.client.slice.account.\(slot).weekly-usage.cache"
        ))
    }

    private func writeBlobs(cache: String, slot: String = GrokBotUsageTests.slot) throws {
        try Data(cache.utf8).write(to: weeklyURL(slot: slot))
    }

    private func selectSlot(_ slot: String) throws {
        let body = #"{"schemaVersion":1,"value":"\#(slot)"}"#
        try Data(body.utf8).write(to: directory.appendingPathComponent(
            GrokBotCache.blobFilename(forKey: GrokBotCache.accountSlotKey)
        ))
    }

    private func touch(_ url: URL, daysFromNow days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(days * 86400)],
            ofItemAtPath: url.path
        )
    }
}
