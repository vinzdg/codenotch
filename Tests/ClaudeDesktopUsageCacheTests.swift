import XCTest
@testable import Codenotch

/// Reading Claude's limits out of Claude Desktop's HTTP cache.
///
/// Hermetic throughout, which for this source has to be said explicitly: it
/// exists to read a real directory belonging to another application, and the one
/// thing that must never decide whether these pass is whether the developer
/// running them happens to have Claude Desktop open. So nothing here touches the
/// real cache, the network, the keychain, OAuth, or Claude Code. Entries are
/// built byte by byte from `Entry` below, and the zstd bodies are fixed
/// fixtures — synthetic payloads with invented percentages and a made-up
/// organization, compressed once and pasted in, because the vendored zstd is
/// decode-only and there is nothing here that could compress at runtime.
final class ClaudeDesktopUsageCacheTests: XCTestCase {

    // MARK: - Fixtures

    /// Pre-compressed bodies. Each is one zstd frame, exactly as Cloudflare
    /// serves the real endpoint's response.
    enum Body {
        private static func decode(_ parts: String...) -> Data {
            Data(base64Encoded: parts.joined())!
        }

        /// `five_hour`, `seven_day` and a matching `limits` array — the shape the
        /// live response has.
        static let full = decode(
            "KLUv/WROAH0EACIIGxlQdw4862yq1vdy7GtBVDUou1+jNaOqbCoEwOcgypwRcnPq3g5+rfrB",
            "+rpAadPzoUpO9xo+rZKSc5dJEIWLEKxaa3rhe7DELifLFDssyxrn1whpbdrYhSX24FeWrLGT",
            "U9bsHh/LLAm2JqN7AQwAuSzCVXCUogCzLBIqWA3UBBZsCvNhCnOvBgBYAm4PaQlsxA==")

        /// A model-scoped weekly window, which is the one place the response
        /// names the model rather than the window.
        static let scoped = decode(
            "KLUv/STD7QMAQsgZGIBtDny04V1v41lqIIABkjCVWZYFG1ReGMBM5pzvCBbfs7M8ZVoc7MYu",
            "947Z41zur1SNtRZj+DCtTK5hltT8obpLDUEDgtDh+7goHbkZuhqEfXzMQAyv/p7Wzf09e625",
            "RPYdm9PcZQcAXAkMCAI1xgT/RigIAIoLOCjfVG2h")

        /// Only `five_hour`: no `limits`, no `seven_day`. Every field but the one
        /// window is absent.
        static let fiveHourOnly = decode(
            "KLUv/SRE/QEAQsQOEZB9iINISak2sSueKNrs+gcle7v6R/+ofBofxodznjhyy1a1rTbq4IVB",
            "Lie0LMMI7XWNnN75VsPQuQ4AzoD8gQ==")

        /// Only `seven_day`.
        static let sevenDayOnly = decode(
            "KLUv/SRFDQIAAkQOEZB9EA8kEKu9M2+JSPnM2BUle7tC/6l8GB/OeeLIK1u0OuqmgxfGII/y",
            "VZYffNW6Ro5ZW9FdR10HAQCs4KCNotqF")

        /// Valid JSON, valid zstd, and nothing a usage response would contain.
        static let notAUsageResponse = decode(
            "KLUv/SQRiQAAeyJoZWxsbyI6IndvcmxkIn2OI6ZS")

        /// ~330 kB decompressed, with the size declared in the frame header, so
        /// it can be refused before anything is allocated.
        static let oversizedDeclared = decode(
            "KLUv/aTVIAUADAMAgkQRGHCrDoBU3Hh7qUirw4MA+FGlCzovUVXnBSi9uYHEfs8tzwtmNjCh",
            "GFiLhVfXaIUUzqPEgYqyq3Na6Wp/Efu0MmmQ6eM3CABU/1fIB+PQcRRgkgIGAIoO4GoC9QEm",
            "HlQAAAABAP3/j/+5BgJVAAAQXX0BANAgOQACcYQ9gQ==")

        /// The same body, written from a stream so the header declares no size —
        /// which is what a chunked response actually looks like. Nothing but the
        /// output cap can refuse this one.
        static let oversizedUndeclared = decode(
            "KLUv/QRoDAMAgkQRGHCrDoBU3Hh7qUirw4MA+FGlCzovUVXnBSi9uYHEfs8tzwtmNjChGFiL",
            "hVfXaIUUzqPEgYqyq3Na6Wp/Efu0MmmQ6eM3CABU/1fIB+PQcRRgkgIGAIoO4GoC9QEmHlQA",
            "AAABAP3/j/+5BgJVAAAQXX0BANAgOQACcYQ9gQ==")
    }

    /// The organization the fixture keys name. Invented — see the note above.
    static let organization = "11111111-2222-3333-4444-555555555555"

    /// Builds one Chromium Simple Cache entry file's bytes.
    ///
    /// Written out here rather than copied from a real cache so that the format
    /// assumptions are *stated*: the 8-byte magic, the three 32-bit fields, and
    /// the four bytes of struct padding that a reader which counts to 20 instead
    /// of 24 lands inside the key.
    struct Entry {
        var magic: UInt64 = 0xfcfb_6d1b_a772_5c30
        var version: UInt32 = 5
        /// Nil means "whatever the key actually is". Set it to lie about the
        /// length.
        var declaredKeyLength: UInt32?
        var key = "1/0/https://claude.ai/api/organizations/"
            + ClaudeDesktopUsageCacheTests.organization + "/usage?skip_spend=1"
        var body: Data = Body.full
        /// Chromium writes the header block after the body; this is the part of
        /// it the reader looks at.
        var responseDate: String? = "Wed, 09 Sep 2026 16:12:08 GMT"

        func data() -> Data {
            var out = Data()
            withUnsafeBytes(of: magic.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: version.littleEndian) { out.append(contentsOf: $0) }
            let keyBytes = Data(key.utf8)
            withUnsafeBytes(of: (declaredKeyLength ?? UInt32(keyBytes.count)).littleEndian) {
                out.append(contentsOf: $0)
            }
            withUnsafeBytes(of: UInt32(0xdead_beef).littleEndian) { out.append(contentsOf: $0) }
            // The padding Chromium's C++ struct carries.
            out.append(Data(repeating: 0, count: 4))
            out.append(keyBytes)
            out.append(body)
            out.append(trailer())
            return out
        }

        /// A stand-in for the pickled `HttpResponseInfo`: the NUL-separated
        /// header block, which is the only part of it that is read.
        private func trailer() -> Data {
            var out = Data([0x01, 0x00, 0x00, 0x00])
            out.append(Data("HTTP/1.1 200".utf8))
            out.append(0)
            if let responseDate {
                out.append(Data("date:\(responseDate)".utf8))
                out.append(0)
            }
            out.append(Data("content-encoding:zstd".utf8))
            out.append(contentsOf: [0, 0])
            return out
        }
    }

    /// `Wed, 09 Sep 2026 16:12:08 GMT`, as a `Date`.
    static let fixtureDate: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 9
        components.hour = 16; components.minute = 12; components.second = 8
        components.timeZone = TimeZone(identifier: "GMT")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    // MARK: - A valid entry

    func testAValidEntryYieldsTheSessionAndWeeklyWindows() throws {
        let parsed = try XCTUnwrap(ClaudeDesktopUsageCache.parse(entry: Entry().data()))
        XCTAssertEqual(parsed.organization, Self.organization)

        let response = try UsageResponse.decoder.decode(UsageResponse.self, from: parsed.body)
        let windows = response.limitWindows()
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(windows.map(\.label), ["Current session", "All models"])
        XCTAssertEqual(windows[0].usedFraction, 0.30)
        XCTAssertEqual(windows[1].usedFraction, 0.74)
        // Absolute reset times survive the round trip, which is what lets them
        // keep being used after the reading itself has gone stale.
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertNotNil(windows[1].resetsAt)
    }

    func testTheResponseDateBecomesTheTimestamp() throws {
        let parsed = try XCTUnwrap(ClaudeDesktopUsageCache.parse(entry: Entry().data()))
        XCTAssertEqual(parsed.date, Self.fixtureDate)
    }

    /// The header block is lower-cased over HTTP/2 and HTTP/3 and left alone over
    /// HTTP/1.1, and Claude Desktop negotiates all three.
    func testTheDateIsFoundInEitherCase() throws {
        for name in ["date", "Date"] {
            var trailer = Data([0x00])
            trailer.append(Data("\(name):Wed, 09 Sep 2026 16:12:08 GMT".utf8))
            trailer.append(0)
            XCTAssertEqual(ClaudeDesktopUsageCache.httpDate(inTrailer: [UInt8](trailer)),
                           Self.fixtureDate, "\(name): was not read")
        }
    }

    func testAnEntryWithNoDateHeaderStillParses() throws {
        var entry = Entry(); entry.responseDate = nil
        let parsed = try XCTUnwrap(ClaudeDesktopUsageCache.parse(entry: entry.data()))
        // Nil here, not a guess. The caller substitutes the file's own
        // modification time, which is tested against the filesystem below.
        XCTAssertNil(parsed.date)
        XCTAssertFalse(parsed.body.isEmpty)
    }

    func testAnUnparseableDateHeaderIsIgnoredRatherThanFatal() throws {
        var entry = Entry(); entry.responseDate = "not a date at all"
        let parsed = try XCTUnwrap(ClaudeDesktopUsageCache.parse(entry: entry.data()))
        XCTAssertNil(parsed.date)
    }

    // MARK: - Windows the response may or may not carry

    func testFiveHourAloneIsASessionWindow() throws {
        var entry = Entry(); entry.body = Body.fiveHourOnly
        let parsed = try XCTUnwrap(ClaudeDesktopUsageCache.parse(entry: entry.data()))
        let windows = try UsageResponse.decoder
            .decode(UsageResponse.self, from: parsed.body).limitWindows()
        XCTAssertEqual(windows.map(\.id), ["session"])
        XCTAssertEqual(windows[0].usedFraction, 0.07)
    }

    func testSevenDayAloneIsTheAllModelsWindow() throws {
        var entry = Entry(); entry.body = Body.sevenDayOnly
        let parsed = try XCTUnwrap(ClaudeDesktopUsageCache.parse(entry: entry.data()))
        let windows = try UsageResponse.decoder
            .decode(UsageResponse.self, from: parsed.body).limitWindows()
        XCTAssertEqual(windows.map(\.id), ["weekly_all"])
        XCTAssertEqual(windows[0].usedFraction, 0.88)
    }

    /// `weekly_scoped` comes back for whichever model the plan scopes, so the
    /// kind alone can only say "Scoped" — the name is in `scope.model`.
    func testAScopedWeeklyWindowKeepsTheModelName() throws {
        var entry = Entry(); entry.body = Body.scoped
        let parsed = try XCTUnwrap(ClaudeDesktopUsageCache.parse(entry: entry.data()))
        let windows = try UsageResponse.decoder
            .decode(UsageResponse.self, from: parsed.body).limitWindows()
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_scoped"])
        XCTAssertEqual(windows.map(\.label), ["Current session", "Opus"])
        XCTAssertEqual(windows[1].usedFraction, 0.55)
    }

    // MARK: - Keys

    func testTheUsageKeyIsRecognisedWithAndWithoutAQuery() {
        let base = "1/0/https://claude.ai/api/organizations/\(Self.organization)/usage"
        for key in [base, base + "?skip_spend=1", base + "?a=1&b=2", base + "#fragment"] {
            XCTAssertEqual(ClaudeDesktopUsageCache.usageOrganization(inKey: key),
                           Self.organization, "did not recognise \(key)")
        }
    }

    func testKeysThatAreNotTheUsageEndpointAreIgnored() {
        let cases = [
            // Another endpoint under the same organization.
            "1/0/https://claude.ai/api/organizations/\(Self.organization)/projects",
            // The usage endpoint with something after it.
            "1/0/https://claude.ai/api/organizations/\(Self.organization)/usage/detail",
            // No organization segment at all.
            "1/0/https://claude.ai/api/usage",
            // The right shape on the wrong host. Without this check the reader
            // would decompress any site's body that matched the path.
            "1/0/https://example.com/api/organizations/\(Self.organization)/usage",
            "",
            "not a url"
        ]
        for key in cases {
            XCTAssertNil(ClaudeDesktopUsageCache.usageOrganization(inKey: key),
                         "wrongly accepted \(key)")
        }
    }

    /// The key is read out of a prefix of the file before anything else is
    /// read, so that the thousands of unrelated entries in the directory are
    /// rejected on their URL and never pulled into memory whole.
    func testTheKeyIsReadableFromAPrefixOfTheEntry() throws {
        let whole = Entry().data()
        let prefix = whole.prefix(ClaudeDesktopUsageCache.headerBytes
                                  + ClaudeDesktopUsageCache.maxKeyBytes)
        XCTAssertEqual(ClaudeDesktopUsageCache.key(in: [UInt8](prefix)), Entry().key)
    }

    func testKeyReadingRefusesAnythingItCannotTrust() {
        // Too short, wrong magic, and a length that runs past the buffer.
        XCTAssertNil(ClaudeDesktopUsageCache.key(in: []))
        XCTAssertNil(ClaudeDesktopUsageCache.key(
            in: [UInt8](Data(repeating: 0, count: ClaudeDesktopUsageCache.headerBytes))))
        var wrongMagic = Entry(); wrongMagic.magic = 0
        XCTAssertNil(ClaudeDesktopUsageCache.key(in: [UInt8](wrongMagic.data())))
        var overlong = Entry(); overlong.declaredKeyLength = 1 << 20
        XCTAssertNil(ClaudeDesktopUsageCache.key(in: [UInt8](overlong.data())))
    }

    func testAnEntryWhoseKeyIsNotAUsageRequestIsIgnored() {
        var entry = Entry()
        entry.key = "1/0/https://claude.ai/api/organizations/\(Self.organization)/projects"
        XCTAssertNil(ClaudeDesktopUsageCache.parse(entry: entry.data()))
    }

    // MARK: - Malformed entries

    func testAFileWithoutTheSimpleCacheMagicIsIgnored() {
        var entry = Entry(); entry.magic = 0x0123_4567_89ab_cdef
        XCTAssertNil(ClaudeDesktopUsageCache.parse(entry: entry.data()))
    }

    func testAnEmptyOrTinyFileIsIgnored() {
        XCTAssertNil(ClaudeDesktopUsageCache.parse(entry: Data()))
        XCTAssertNil(ClaudeDesktopUsageCache.parse(entry: Data(repeating: 0, count: 4)))
        XCTAssertNil(ClaudeDesktopUsageCache.parse(
            entry: Data(repeating: 0, count: ClaudeDesktopUsageCache.headerBytes)))
    }

    /// The key length is read out of the file, so it is an attacker-or-corruption
    /// controlled length. It must never be believed far enough to read past the
    /// buffer.
    func testAKeyLengthBeyondTheEntryIsIgnored() {
        for declared: UInt32 in [0, 1 << 20, .max,
                                UInt32(ClaudeDesktopUsageCache.maxKeyBytes + 1)] {
            var entry = Entry(); entry.declaredKeyLength = declared
            XCTAssertNil(ClaudeDesktopUsageCache.parse(entry: entry.data()),
                         "believed a key length of \(declared)")
        }
    }

    func testAnEntryWithNoBodyIsIgnored() {
        var entry = Entry(); entry.body = Data(); entry.responseDate = nil
        XCTAssertNil(ClaudeDesktopUsageCache.parse(entry: entry.data()))
    }

    func testABodyThatIsNotZstdIsIgnored() {
        var entry = Entry()
        // Plausible, uncompressed JSON — what a `content-encoding: identity`
        // response would leave here.
        entry.body = Data(#"{"five_hour":{"utilization":30.0}}"#.utf8)
        XCTAssertNil(ClaudeDesktopUsageCache.parse(entry: entry.data()))
    }

    func testACorruptZstdFrameIsIgnored() {
        var body = [UInt8](Body.full)
        // Keep the magic — so the reader gets as far as the decoder — and wreck
        // everything after it.
        for index in 4..<body.count { body[index] = body[index] ^ 0xff }
        var entry = Entry(); entry.body = Data(body)
        XCTAssertNil(ClaudeDesktopUsageCache.parse(entry: entry.data()))
    }

    /// A prefix that stops inside the compressed frame cannot decode, and must
    /// say so rather than returning a half body.
    func testAnEntryTruncatedInsideTheFrameIsIgnored() {
        let whole = Entry().data()
        let bodyStart = ClaudeDesktopUsageCache.headerBytes + Entry().key.utf8.count
        // Just the frame magic, and a little way past it: in both cases there is
        // no complete frame to find.
        for length in [bodyStart, bodyStart + 4, bodyStart + 16, bodyStart + 40] {
            XCTAssertNil(ClaudeDesktopUsageCache.parse(entry: whole.prefix(length)),
                         "a \(length)-byte prefix decoded a frame that is not all there")
        }
    }

    /// Every prefix of a real entry — what a half-written or evicted file looks
    /// like. Once the frame is complete a prefix legitimately parses, because the
    /// header block after it is not needed; what must never happen is a trap, or a
    /// body that differs from the whole entry's.
    func testNoPrefixOfAnEntryTrapsOrParsesToSomethingElse() throws {
        let whole = Entry().data()
        let expected = try XCTUnwrap(ClaudeDesktopUsageCache.parse(entry: whole)).body
        for length in 0...whole.count {
            guard let parsed = ClaudeDesktopUsageCache.parse(entry: whole.prefix(length))
            else { continue }
            XCTAssertEqual(parsed.body, expected,
                           "a \(length)-byte prefix produced a different body")
            XCTAssertEqual(parsed.organization, Self.organization)
        }
    }

    /// A `Data` sliced out of another does not start at index 0. Subscripting it
    /// as though it did traps rather than reading the wrong byte, so the reader
    /// copies first — this is the test that would catch that copy being removed.
    func testASlicedEntryParsesTheSameAsAWholeOne() throws {
        var padded = Data(repeating: 0xab, count: 64)
        padded.append(Entry().data())
        let parsed = try XCTUnwrap(ClaudeDesktopUsageCache.parse(entry: padded.dropFirst(64)))
        XCTAssertEqual(parsed.organization, Self.organization)
        XCTAssertEqual(parsed.date, Self.fixtureDate)
    }

    func testValidZstdCarryingSomethingOtherThanUsageIsIgnored() {
        var entry = Entry(); entry.body = Body.notAUsageResponse
        // Parsing gets as far as a body — the frame is genuinely valid — and the
        // reader rejects it a step later, for naming no window.
        XCTAssertNotNil(ClaudeDesktopUsageCache.parse(entry: entry.data()))

        let directory = makeCacheDirectory(["a_0": entry.data()])
        XCTAssertNil(ClaudeDesktopUsageCache(directory: directory)
            .read(organization: Self.organization))
    }

    // MARK: - Size caps

    func testADeclaredOversizedBodyIsRefusedBeforeItIsDecompressed() {
        var entry = Entry(); entry.body = Body.oversizedDeclared
        XCTAssertNil(ClaudeDesktopUsageCache.parse(entry: entry.data()))
    }

    /// The case that matters, because a chunked response declares no size at
    /// all: the only thing standing between a 330 kB body and the cap is the
    /// output buffer the decoder is given.
    func testAnUndeclaredOversizedBodyIsRefusedByTheOutputCap() {
        var entry = Entry(); entry.body = Body.oversizedUndeclared
        XCTAssertNil(ClaudeDesktopUsageCache.parse(entry: entry.data()))
    }

    func testAnOversizedEntryFileIsNeverOpened() throws {
        // Bigger than the per-entry cap, and otherwise a perfectly good entry.
        var entry = Entry()
        entry.key += String(repeating: "&pad=x", count: 1)
        var bytes = entry.data()
        bytes.append(Data(repeating: 0x00,
                          count: ClaudeDesktopUsageCache.maxEntryBytes + 1 - bytes.count))
        let directory = makeCacheDirectory(["big_0": bytes])
        XCTAssertNil(ClaudeDesktopUsageCache(directory: directory)
            .read(organization: Self.organization))
    }

    // MARK: - Scanning a directory

    /// Whatever else is wrong, an absent Claude Desktop is not an error.
    func testAMissingCacheDirectoryReadsAsNothing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-tests-absent-\(UUID().uuidString)")
        XCTAssertNil(ClaudeDesktopUsageCache(directory: missing)
            .read(organization: Self.organization))
    }

    func testAnEmptyCacheDirectoryReadsAsNothing() {
        let directory = makeCacheDirectory([:])
        XCTAssertNil(ClaudeDesktopUsageCache(directory: directory)
            .read(organization: Self.organization))
    }

    func testFilesThatAreNotCacheEntriesAreIgnored() {
        let directory = makeCacheDirectory([
            "the-real-index": Data(repeating: 0x7f, count: 4096),
            "notanentry": Data("hello".utf8),
            "somefile_1": Entry().data()   // a stream file that is not `_0`
        ])
        XCTAssertNil(ClaudeDesktopUsageCache(directory: directory)
            .read(organization: Self.organization))
    }

    func testAnEntryForAnotherOrganizationIsIgnored() {
        let directory = makeCacheDirectory(["a_0": Entry().data()])
        // The reading exists, and it is not this profile's. Claude Desktop is
        // signed into one account while Codenotch may draw a ring per profile,
        // so the wrong account's session percentage must not reach the wrong ring.
        XCTAssertNil(ClaudeDesktopUsageCache(directory: directory)
            .read(organization: "99999999-8888-7777-6666-555555555555"))
    }

    func testTheMostRecentOfSeveralUsageEntriesWins() throws {
        // Both keys really do occur at once: Claude Desktop asks for `…/usage`
        // and `…/usage?skip_spend=1`, and they hash to two different files.
        var older = Entry()
        older.key = "1/0/https://claude.ai/api/organizations/\(Self.organization)/usage"
        older.body = Body.fiveHourOnly          // 7%
        older.responseDate = nil

        var newer = Entry()
        newer.body = Body.full                  // 30%
        newer.responseDate = nil

        let directory = makeCacheDirectory(["older_0": older.data(), "newer_0": newer.data()])
        setModificationDate(Date(timeIntervalSince1970: 1_000_000),
                            of: directory.appendingPathComponent("older_0"))
        setModificationDate(Date(timeIntervalSince1970: 2_000_000),
                            of: directory.appendingPathComponent("newer_0"))

        let reading = try XCTUnwrap(ClaudeDesktopUsageCache(directory: directory)
            .read(organization: Self.organization))
        XCTAssertEqual(reading.windows.first?.usedFraction, 0.30)
        XCTAssertEqual(reading.entry.lastPathComponent, "newer_0")
    }

    /// With no `Date:` header the entry's own modification time stands in — and
    /// it has to be the file's, not "now", or a cache Desktop stopped writing
    /// hours ago would read as current forever.
    func testWithNoDateHeaderTheFilesModificationTimeIsUsed() throws {
        var entry = Entry(); entry.responseDate = nil
        let directory = makeCacheDirectory(["a_0": entry.data()])
        let written = Date(timeIntervalSince1970: 1_700_000_000)
        setModificationDate(written, of: directory.appendingPathComponent("a_0"))

        let reading = try XCTUnwrap(ClaudeDesktopUsageCache(directory: directory)
            .read(organization: Self.organization))
        XCTAssertEqual(reading.capturedAt.timeIntervalSince1970,
                       written.timeIntervalSince1970, accuracy: 1)
    }

    /// Chromium evicts entries while we are looking at them. A file that goes
    /// away between the listing and the read is not an error, and must not stop
    /// the scan finding the one that is still there.
    func testAnEntryThatVanishesDuringTheScanIsSkipped() throws {
        var doomed = Entry(); doomed.responseDate = nil
        var survivor = Entry(); survivor.body = Body.fiveHourOnly; survivor.responseDate = nil

        let directory = makeCacheDirectory(["doomed_0": doomed.data(),
                                           "survivor_0": survivor.data()])
        // The doomed one is newer, so the scan reaches it first — and it is gone
        // by then.
        setModificationDate(Date(timeIntervalSince1970: 2_000_000),
                            of: directory.appendingPathComponent("doomed_0"))
        setModificationDate(Date(timeIntervalSince1970: 1_000_000),
                            of: directory.appendingPathComponent("survivor_0"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("doomed_0"))

        let reading = try XCTUnwrap(ClaudeDesktopUsageCache(directory: directory)
            .read(organization: Self.organization))
        XCTAssertEqual(reading.entry.lastPathComponent, "survivor_0")
    }

    // MARK: - Fresh, stale, unavailable

    func testARecentSnapshotIsFresh() throws {
        let reading = try XCTUnwrap(readFixture(date: nil, modified: Date()))
        XCTAssertTrue(reading.isFresh(within: 30 * 60))
    }

    func testASnapshotOlderThanTheWindowIsNotFresh() throws {
        let captured = Date().addingTimeInterval(-90 * 60)
        let reading = try XCTUnwrap(readFixture(date: nil, modified: captured))
        XCTAssertFalse(reading.isFresh(within: 30 * 60))
        // Still a reading, with its real age and its absolute reset times: the
        // caller may still say "as of an hour ago", it just may not say "now".
        XCTAssertEqual(reading.capturedAt.timeIntervalSince1970,
                       captured.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(reading.windows.first?.resetsAt)
    }

    /// The `Date:` header is the server's clock, so it can read slightly ahead of
    /// ours. A reading from "the future" is two clocks disagreeing, not a reason
    /// to call it infinitely stale.
    func testASnapshotSlightlyInTheFutureIsStillFresh() throws {
        let reading = try XCTUnwrap(
            readFixture(date: nil, modified: Date().addingTimeInterval(60)))
        XCTAssertTrue(reading.isFresh(within: 30 * 60))
    }

    // MARK: - The two alternating keys

    func testResetMetadataSurvivesANewerPlainUsageReadingWithoutChangingItsWindows() throws {
        var reset = Entry()
        reset.key += "&cedar_ember=1"
        reset.body = ClaudeResetFixture.availableCacheBody
        reset.responseDate = nil
        var plain = Entry()
        plain.responseDate = nil
        let directory = makeCacheDirectory(["reset_0": reset.data(), "plain_0": plain.data()])
        let now = Date()
        setModificationDate(now.addingTimeInterval(-60), of: directory.appendingPathComponent("reset_0"))
        setModificationDate(now, of: directory.appendingPathComponent("plain_0"))

        let reading = try XCTUnwrap(ClaudeDesktopUsageCache(directory: directory).read(organization: Self.organization))
        XCTAssertEqual(reading.entry.lastPathComponent, "plain_0")
        XCTAssertEqual(reading.windows.first?.usedFraction, 0.30)
        XCTAssertEqual(reading.resets?.credits(at: now)?.availableCount, 1)
        let later = try XCTUnwrap(reading.resets?.credits(at: now.addingTimeInterval(3 * 3600)))
        XCTAssertEqual(later.availableCount, 1)
        XCTAssertEqual(try XCTUnwrap(later.checkedAt).timeIntervalSince1970,
                       now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 1,
                       "newer usage must not re-date the cached reset observation")
        XCTAssertEqual(later.unexpired(at: now).checkedAt, later.checkedAt)
        XCTAssertNil(ClaudeDesktopUsageCache(directory: directory).read(organization: "other-account"))
    }

    func testSpentOrMalformedResetMetadataSupersedesOlderAvailableGrants() throws {
        for body in [ClaudeResetFixture.spentCacheBody, ClaudeResetFixture.malformedCacheBody,
                     Body.full] {
            var older = Entry()
            older.body = ClaudeResetFixture.availableCacheBody
            older.responseDate = nil
            var newer = Entry()
            newer.key += "&cedar_ember=1"
            newer.body = body
            newer.responseDate = nil
            let directory = makeCacheDirectory(["older_0": older.data(), "newer_0": newer.data()])
            setModificationDate(Date().addingTimeInterval(-60), of: directory.appendingPathComponent("older_0"))
            setModificationDate(Date(), of: directory.appendingPathComponent("newer_0"))
            let reading = try XCTUnwrap(ClaudeDesktopUsageCache(directory: directory).read(organization: Self.organization))
            XCTAssertNotNil(reading.resets)
            XCTAssertEqual(reading.resets?.credits(at: Date())?.availableCount ?? 0, 0)
        }
    }

    /// The regression this reader actually hit on a real cache. Desktop asks for
    /// both `…/usage` and `…/usage?skip_spend=1` — two keys, two files — and
    /// refreshes them independently. An earlier version of this reader
    /// remembered whichever file last answered and kept trusting it as long as
    /// *that file* had not gone stale, which is not the same question as "is
    /// this still the newest answer" — caught live: the remembered file sat at
    /// 83%, itself only minutes old, while its sibling had already moved to 86%
    /// five minutes earlier. Every call must find the true newest across both
    /// keys, not just revalidate whichever one it saw last.
    func testTheNewerOfTheTwoAlternatingKeysWinsEvenWhenBothAreFresh() throws {
        var bare = Entry()
        bare.key = "1/0/https://claude.ai/api/organizations/\(Self.organization)/usage"
        bare.body = Body.full                    // 30%
        bare.responseDate = nil

        var scoped = Entry()   // the default key already carries ?skip_spend=1
        scoped.body = Body.fiveHourOnly           // 7%
        scoped.responseDate = nil

        let directory = makeCacheDirectory(["bare_0": bare.data(), "scoped_0": scoped.data()])
        // Both comfortably "fresh" by any reasonable window — the point is that
        // one being fresh must not stop the other, newer one from being found.
        setModificationDate(Date().addingTimeInterval(-5 * 60),
                            of: directory.appendingPathComponent("scoped_0"))
        setModificationDate(Date(), of: directory.appendingPathComponent("bare_0"))

        let reading = try XCTUnwrap(ClaudeDesktopUsageCache(directory: directory)
            .read(organization: Self.organization))
        XCTAssertEqual(reading.entry.lastPathComponent, "bare_0")
        XCTAssertEqual(reading.windows.first?.usedFraction, 0.30)
    }

    /// And a call made shortly after must find the *new* newest once the keys
    /// swap — nothing may be remembered between calls that could pin the answer
    /// to whichever file happened to win last time.
    func testASecondCallFindsANewlyUpdatedKey() throws {
        var bare = Entry()
        bare.key = "1/0/https://claude.ai/api/organizations/\(Self.organization)/usage"
        bare.body = Body.fiveHourOnly              // 7%, older
        bare.responseDate = nil

        var scoped = Entry()
        scoped.body = Body.full                    // 30%, older too
        scoped.responseDate = nil

        let directory = makeCacheDirectory(["bare_0": bare.data(), "scoped_0": scoped.data()])
        setModificationDate(Date().addingTimeInterval(-120), of: directory.appendingPathComponent("bare_0"))
        setModificationDate(Date().addingTimeInterval(-120), of: directory.appendingPathComponent("scoped_0"))

        let cache = ClaudeDesktopUsageCache(directory: directory)
        let first = try XCTUnwrap(cache.read(organization: Self.organization))
        XCTAssertEqual(first.entry.lastPathComponent, "scoped_0")

        // "bare" is refreshed with a new value and becomes the newest entry.
        var updatedBare = Entry()
        updatedBare.key = bare.key
        updatedBare.body = Body.scoped              // a third, distinct value
        updatedBare.responseDate = nil
        try updatedBare.data().write(to: directory.appendingPathComponent("bare_0"))
        setModificationDate(Date(), of: directory.appendingPathComponent("bare_0"))

        let second = try XCTUnwrap(cache.read(organization: Self.organization))
        XCTAssertEqual(second.entry.lastPathComponent, "bare_0")
        // Body.scoped's session window, distinct from either older value (7%, 30%).
        XCTAssertEqual(second.windows.first?.usedFraction, 0.12)
    }

    // MARK: - Helpers

    private func readFixture(date: String?, modified: Date) -> ClaudeDesktopUsageCache.Reading? {
        var entry = Entry(); entry.responseDate = date
        let directory = makeCacheDirectory(["a_0": entry.data()])
        setModificationDate(modified, of: directory.appendingPathComponent("a_0"))
        return ClaudeDesktopUsageCache(directory: directory)
            .read(organization: Self.organization)
    }

    /// A throwaway directory shaped like `Cache_Data`, removed when the test ends.
    private func makeCacheDirectory(_ files: [String: Data],
                                    file: StaticString = #filePath,
                                    line: UInt = #line) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-desktop-cache-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, bytes) in files {
                try bytes.write(to: directory.appendingPathComponent(name))
            }
        } catch {
            XCTFail("could not build a cache directory: \(error)", file: file, line: line)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func setModificationDate(_ date: Date, of url: URL,
                                     file: StaticString = #filePath, line: UInt = #line) {
        do {
            try FileManager.default.setAttributes([.modificationDate: date],
                                                 ofItemAtPath: url.path)
        } catch {
            XCTFail("could not date \(url.lastPathComponent): \(error)", file: file, line: line)
        }
    }
}
