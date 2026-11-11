import Foundation

/// Claude's own limits, read out of Claude Desktop's HTTP cache.
///
/// A third source for the same numbers, and on some machines the only one that
/// answers. The other two both go through Claude Code: `claude "/usage"` prints
/// the windows *when its build still prints them* — some print only a cost
/// summary, which parses to nothing — and the endpoint path needs an OAuth token
/// out of the login keychain, which stays stale until Claude Code next runs and
/// re-mints it. Someone who works in Claude Desktop rather than in the terminal
/// can therefore have a perfectly current subscription, a Desktop window showing
/// 30% of the session used, and a dark ring in the notch.
///
/// Claude Desktop is Chromium, so its `GET /api/organizations/<id>/usage` — the
/// very response its own usage panel draws — lands in a Simple Cache entry on
/// disk, and this reads that entry. No token, no cookie, no keychain, no request
/// to Anthropic, no subprocess, and no write of any kind. If Desktop is absent,
/// closed, has no cache, or the entry is unreadable, this returns nil and the
/// caller falls back to the paths it already had.
///
/// Finding the entry means looking at its neighbours, and the *amount* looked at
/// is the point: of every other file in that directory this reads the first few
/// bytes — enough for the cached URL and no further. A body is only ever
/// decompressed for an entry whose URL is this account's usage endpoint. Nothing
/// else in Claude Desktop's cache is opened, read, or decoded.
///
/// ## Why this can be small
///
/// A general Simple Cache reader would parse the index, both stream trailers and
/// the pickled `HttpResponseInfo`. None of that is needed to answer one question
/// about one entry, and every part of it is a way to break when Chromium's
/// private format shifts. So this reads only what it must: the file header (for
/// the key), the body at the offset that header implies, and — for the timestamp
/// — the `date:` line, found by looking for it rather than by walking a pickle.
/// Every step is bounded, and every failure is nil.
struct ClaudeDesktopUsageCache: Sendable {
    /// One reading, and where it came from.
    struct Reading: Equatable, Sendable {
        /// The same windows the other two Claude paths produce, so a reading
        /// archived under one source still lines up when another takes over.
        let windows: [LimitWindow]
        /// When the numbers were true: the response's own `Date:`, or the
        /// entry's modification time where that header is missing. Not "now" —
        /// a cache entry is by nature already old, and how old is the whole
        /// question of whether it may be shown as live.
        let capturedAt: Date
        /// The entry it was read from. Logged by the caller: which of the two
        /// alternating keys answered is the first thing worth knowing when a
        /// reading looks wrong.
        let entry: URL
        var resets: ResetReading? = nil

        /// Whether these numbers may still be presented as live.
        func isFresh(at now: Date = Date(), within window: TimeInterval) -> Bool {
            let age = now.timeIntervalSince(capturedAt)
            // A negative age is two clocks disagreeing — the header's is the
            // server's — not a reading from the future. Treat a small one as
            // current rather than as infinitely stale.
            return age < window && age > -window
        }
    }

    struct ResetReading: Equatable, Sendable {
        let value: ClaudeResetCredits?
        let capturedAt: Date

        func credits(at now: Date) -> UsageResetCredits? {
            // Desktop only refreshes grants while its Usage settings are open.
            // Preserve the last observation, dated in the card, until a newer
            // response supersedes it or the grant itself expires.
            // Deliberately not a staleness bound, despite the shape: the
            // comparison is `capturedAt - now`, so it rejects only a capture
            // dated in the future — a clock that has jumped — and lets an old
            // one through to be shown with its date. Keeping it is the point;
            // `testUnsupportedOAuthSurfaceKeepsDatedDesktopResetsWhenUsageIsStale`
            // pins a three-hour-old grant still being drawn.
            guard capturedAt.timeIntervalSince(now) < 30 * 60,
                  var credits = value?.credits(at: now) else { return nil }
            credits.checkedAt = capturedAt
            return credits
        }
    }

    /// Where Claude Desktop keeps its HTTP cache.
    let directory: URL

    static let defaultDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data",
                                isDirectory: true)

    init(directory: URL = ClaudeDesktopUsageCache.defaultDirectory) {
        self.directory = directory
    }

    // MARK: - Limits
    //
    // Every one of these bounds work on a directory this app does not own and
    // cannot predict the size of — a month-old cache here holds ~8 500 entries.
    // They are deliberately not preferences: nobody could know what to set them
    // to, and a wrong value is a hang.

    /// Entries larger than this are skipped without being read. A usage response
    /// is ~4 kB on disk, so this is orders of magnitude of headroom and still
    /// refuses the multi-megabyte asset entries that share the directory.
    static let maxEntryBytes = 512 * 1024
    /// How many entries a full scan will look inside, newest first. The one we
    /// want is rewritten every time Desktop refreshes its usage, so it is always
    /// among the most recently modified; needing to go past this means the
    /// directory is nothing like what is expected, and giving up beats walking it.
    static let maxEntriesExamined = 400

    /// How far past the newest usable entry to keep looking for a reset block.
    ///
    /// The block lives under its own key and is refreshed separately, so it can
    /// lag the newest usage entry by a few writes. It is not worth the whole cap:
    /// an account that has none would otherwise pay the full scan every poll.
    static let resetSearchDepth = 20
    /// Cap on the decompressed body. Enforced by the decoder itself — a frame
    /// that would exceed it is an error, never an overrun — so a corrupt or
    /// hostile entry cannot be turned into a large allocation.
    static let maxDecompressedBytes = 256 * 1024
    /// A key longer than this is not one of ours, and reading it would be the one
    /// unbounded read in here. Chromium's own limit is far lower.
    static let maxKeyBytes = 8 * 1024

    // MARK: - Reading

    /// The most recent usable reading for one organization, or nil.
    ///
    /// `organization` is not optional and not cosmetic. Claude Desktop is signed
    /// into exactly one account, while Codenotch draws a ring per Claude Code
    /// profile — so handing Desktop's numbers to whichever ring asked first would
    /// put the personal account's session percentage on the work ring. The cache
    /// key carries the organization's UUID and Claude Code records the same UUID
    /// per profile, so the two can simply be required to match.
    ///
    /// Always scans rather than remembering the last winning file. An earlier
    /// version did remember it, trusted it as long as it was not yet stale, and
    /// was wrong: Desktop asks for both `…/usage` and `…/usage?skip_spend=1` —
    /// two keys, two files — and alternates which one it refreshes. Caught live,
    /// on a real cache: the remembered file sat at 83%, unchanged and still
    /// "fresh" by the 30-minute clock, while its sibling had already moved to
    /// 86% five minutes earlier. Trusting one file's own age said nothing about
    /// whether a *different* file had since become the newer answer.
    ///
    /// The fix is simply to stop skipping the scan. `FileManager` fetches the
    /// modification date and size for every entry in one batched call rather
    /// than one syscall each, so scanning this directory whole — measured at
    /// ~8,600 entries — costs on the order of tens of milliseconds, off the
    /// main actor, at most once per poll. There was no measured cost this was
    /// ever saving; there was a real reading it was getting wrong.
    ///
    /// Freshness is deliberately not judged here. This returns the newest
    /// reading there is, with the timestamp it actually has; whether that is
    /// recent enough to show as live is the caller's call, and only the caller
    /// knows what it would fall through to.
    func read(organization: String, now: Date = Date()) -> Reading? {
        // Newest first, so the live entry turns up within a handful of files.
        //
        // The reset block is written under its own key and refreshed separately,
        // so it can be older than the newest usage entry and is worth looking
        // past the first hit for. But only for a while: an account with no
        // cedar_ember block at all — most of them — would otherwise walk every
        // candidate on every poll looking for something that is not there.
        var newest: Reading?
        var resets: ResetReading?
        for (index, entry) in recentEntries().enumerated() {
            guard let reading = reading(from: entry, organization: organization, now: now) else { continue }
            if newest == nil { newest = reading }
            if resets == nil { resets = reading.resets }
            if resets != nil { break }
            if newest != nil, index >= Self.resetSearchDepth { break }
        }
        // Desktop refreshes the plain and cedar_ember usage keys separately.
        // Keep the newest windows while dating the reset block by its own entry.
        newest?.resets = resets
        return newest
    }

    /// Candidate entry files, most recently modified first, capped.
    private func recentEntries() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            // No Claude Desktop, no cache directory, or no permission to list
            // it. All three mean the same thing to the caller.
            return []
        }

        // Dated and sized in the one pass the sort needs anyway, so the size cap
        // costs no extra `stat` — and entries that vanish between the listing and
        // here simply drop out, which happens constantly: Chromium evicts while
        // we look.
        let candidates: [(url: URL, modified: Date)] = names.compactMap { url in
            // `_0` is the stream file that holds the body. Chromium writes `_1`
            // and `_s` beside it for other streams, and the index lives in a
            // subdirectory this listing already skips.
            guard url.lastPathComponent.hasSuffix("_0"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > Self.headerBytes, size <= Self.maxEntryBytes,
                  let modified = values.contentModificationDate
            else { return nil }
            return (url, modified)
        }

        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(Self.maxEntriesExamined)
            .map(\.url)
    }

    /// One entry, read and parsed, or nil for every way that can fail.
    private func reading(from entry: URL, organization: String, now: Date) -> Reading? {
        // The organization is checked twice on purpose. `contents` checks it
        // against a *prefix* to decide whether the entry is worth reading whole;
        // this checks it against the bytes that were actually parsed. Chromium
        // can rewrite the file between those two reads, and the one thing that
        // must never happen is another account's numbers reaching this ring.
        guard let file = contents(of: entry, forOrganization: organization),
              let parsed = Self.parse(entry: file.bytes),
              parsed.organization == organization
        else { return nil }

        guard let response = try? UsageResponse.decoder.decode(UsageResponse.self, from: parsed.body) else {
            Log.usage.debug("claude desktop cache: entry body was not a usage response")
            return nil
        }
        let capturedAt = parsed.date ?? file.modified ?? now
        let windows = response.limitWindows(readAt: capturedAt)
        // A response that parses but names no window is not a reading. Letting
        // it through would hand the caller an empty snapshot, which draws a ring
        // with a hole in it rather than falling through to a source that works.
        guard !windows.isEmpty else { return nil }

        return Reading(
            windows: windows,
            capturedAt: capturedAt,
            entry: entry,
            resets: response.reportsResetCredits || parsed.requestsResetCredits
                ? ResetReading(value: response.cedarEmber, capturedAt: capturedAt) : nil
        )
    }

    /// The entry's bytes and when they were last written, both from one open
    /// handle, bounded.
    ///
    /// Deliberately a read and not a memory map. Chromium owns these files and
    /// rewrites and truncates them underneath us, and a mapped page whose backing
    /// bytes go away is a `SIGBUS` — which no amount of defensive parsing
    /// downstream can catch. A copy of at most `maxEntryBytes` cannot fail that
    /// way; the worst case is a torn snapshot, which parses to nil.
    ///
    /// The timestamp comes off the same descriptor as the bytes, and not from
    /// `URL.resourceValues`, for two separate reasons. It cannot then disagree
    /// with what was actually read — Chromium may rewrite the entry a moment
    /// later, and a `stat` of the path would date bytes it never saw. And a `URL`
    /// *caches* the resource values it has been asked for: the hinted entry's URL
    /// is held across refreshes, so it would go on answering with the
    /// modification time it happened to have the first time, which is a reading
    /// that silently never ages.
    private func contents(of entry: URL,
                          forOrganization organization: String) -> (bytes: Data, modified: Date?)? {
        guard let handle = try? FileHandle(forReadingFrom: entry) else { return nil }
        defer { try? handle.close() }

        // The header and at most a key's worth after it, first. Every candidate
        // is then rejected on its URL alone, which matters twice over: a scan
        // otherwise pulls a few hundred megabytes of unrelated cached responses
        // through memory to find one 4 kB file, and this app would have read the
        // bodies of pages it has no business looking at. Only a key that names
        // *this* account's usage endpoint earns a full read.
        guard let head = try? handle.read(upToCount: Self.headerBytes + Self.maxKeyBytes),
              let key = Self.key(in: [UInt8](head)),
              Self.usageOrganization(inKey: key) == organization
        else { return nil }

        // One read of at most the cap. A short result is normal and fine — a
        // truncated entry simply fails the parse.
        try? handle.seek(toOffset: 0)
        guard let bytes = try? handle.read(upToCount: Self.maxEntryBytes) else { return nil }

        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return (bytes, nil) }
        let modified = Date(timeIntervalSince1970:
            TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return (bytes, modified)
    }

    // MARK: - The entry format
    //
    // Chromium's Simple Cache, and only the three things needed out of it.

    /// `SimpleFileHeader` is a 64-bit magic and three 32-bit fields — and then
    /// four bytes of padding, because Chromium writes the C++ struct out verbatim
    /// and its 64-bit member aligns the whole thing to 8. Getting that padding
    /// wrong lands four bytes inside the key, which is the sort of mistake that
    /// looks like a corrupt cache.
    static let headerBytes = 24
    /// `kSimpleInitialMagicNumber`. Its presence is what says this is a Simple
    /// Cache entry at all, which is why unrelated files in the directory cost
    /// nothing.
    private static let entryMagic: UInt64 = 0xfcfb_6d1b_a772_5c30
    /// The frame magic every zstd stream starts with, checked before the decoder
    /// is handed anything.
    private static let zstdMagic: [UInt8] = [0x28, 0xb5, 0x2f, 0xfd]

    struct Parsed: Equatable {
        let body: Data
        /// Whose usage this is, from the URL in the key.
        let organization: String
        /// From the response's `Date:` header, when it was found.
        let date: Date?
        let requestsResetCredits: Bool
    }

    /// Pulls the usage JSON, its organization and its `Date:` out of one entry.
    ///
    /// Internal rather than private so the tests can drive it on synthetic
    /// entries: every branch below is a shape Chromium can produce, and most are
    /// unreachable from a fixture that has to go through the filesystem first.
    static func parse(entry bytes: Data) -> Parsed? {
        // Copied into an array, and so indexed from zero whatever the `Data` was
        // sliced from. A `Data` taken from a range of another does not start at
        // 0, and subscripting it as though it did traps rather than reading the
        // wrong byte.
        let entry = [UInt8](bytes)

        guard let key = key(in: entry),
              let organization = usageOrganization(inKey: key)
        else { return nil }

        // `keyLength` is a byte count, and the key decoded from exactly that
        // many bytes, so this lands where the key ended.
        let bodyStart = headerBytes + key.utf8.count
        guard entry.count - bodyStart > zstdMagic.count,
              Array(entry[bodyStart..<(bodyStart + zstdMagic.count)]) == zstdMagic
        else {
            // A usage entry that is not zstd. Nothing to do about it here, and
            // worth a line: it is the shape most likely to change, since Chromium
            // negotiates the encoding and could be handed gzip or brotli
            // tomorrow.
            Log.usage.debug("claude desktop cache: usage entry is not zstd-encoded")
            return nil
        }

        let frame = Array(entry[bodyStart...])
        guard let body = decompress(frame: frame) else { return nil }
        return Parsed(body: body.data, organization: organization,
                      // Everything after the frame is the stream Chromium wrote
                      // next, which is where the header block lives. Bounding the
                      // search to it keeps `date:` from being found in the body's
                      // own JSON.
                      date: httpDate(inTrailer: Array(frame[body.frameSize...])),
                      requestsResetCredits: key.split(separator: "?").dropFirst().first?
                        .split(separator: "&").contains("cedar_ember=1") == true)
    }

    /// The cache key an entry begins with, or nil when these bytes are not a
    /// Simple Cache entry.
    ///
    /// Only ever reads inside what it has: the key length is a number *out of the
    /// file*, so it is corruption- and attacker-controlled and is bounded before
    /// it is believed.
    static func key(in entry: [UInt8]) -> String? {
        guard entry.count > headerBytes,
              readUInt64(entry, at: 0) == entryMagic
        else { return nil }
        let keyLength = Int(readUInt32(entry, at: 12))
        guard keyLength > 0, keyLength <= maxKeyBytes,
              headerBytes + keyLength <= entry.count
        else { return nil }
        return String(bytes: entry[headerBytes..<(headerBytes + keyLength)], encoding: .utf8)
    }

    /// Which organization a cache key's usage URL names, or nil when the key is
    /// not a usage request at all.
    ///
    /// Keys carry a cache-partition prefix — `1/0/https://claude.ai/…` — so this
    /// matches the URL inside rather than anchoring at the start. The host check
    /// is not decoration: without it this would decompress the body of any site
    /// that happened to serve a path shaped like Anthropic's.
    static func usageOrganization(inKey key: String) -> String? {
        guard key.contains("claude.ai") || key.contains("anthropic.com") else { return nil }
        guard let organizations = key.range(of: "/api/organizations/") else { return nil }
        // Query and fragment are no part of the shape — the request has carried
        // `?skip_spend=1`, and could carry anything next.
        let path = key[organizations.upperBound...].prefix { $0 != "?" && $0 != "#" }
        // `<id>/usage`: one segment and then the endpoint, so that
        // `/api/organizations/<id>/usage/something-else` is not mistaken for it.
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2, !segments[0].isEmpty, segments[1] == "usage" else { return nil }
        return String(segments[0])
    }

    /// The response's `Date:`, found in the header block Chromium stores after
    /// the body.
    ///
    /// That block is a run of NUL-separated `name:value` strings, which is enough
    /// structure to read one field out of without parsing the pickle around it.
    /// Names arrive lower-cased over HTTP/2 and HTTP/3 and in their original case
    /// over HTTP/1.1, so both are tried.
    static func httpDate(inTrailer trailer: [UInt8]) -> Date? {
        for name in ["date:", "Date:"] {
            let needle = [0x00] + Array(name.utf8)
            guard let start = firstIndex(of: needle, in: trailer) else { continue }
            let valueStart = start + needle.count
            guard let end = trailer[valueStart...].firstIndex(of: 0x00),
                  let text = String(bytes: trailer[valueStart..<end], encoding: .utf8),
                  let date = httpDateFormatter.date(from: text.trimmingCharacters(in: .whitespaces))
            else { continue }
            return date
        }
        return nil
    }

    // MARK: - zstd

    /// A decompressed body, and how much of the input the frame took up.
    private struct Frame {
        let data: Data
        /// So the caller can find whatever Chromium wrote after the frame.
        let frameSize: Int
    }

    /// The frame at the start of `bytes`, decompressed, or nil.
    ///
    /// `bytes` runs to the end of the entry, so it holds the frame *and* whatever
    /// Chromium wrote after it. `ZSTD_decompress` rejects trailing data rather
    /// than stopping at the frame's end, hence the size lookup first.
    private static func decompress(frame bytes: [UInt8]) -> Frame? {
        guard !bytes.isEmpty else { return nil }

        return bytes.withUnsafeBytes { source -> Frame? in
            let compressed = ZSTD_findFrameCompressedSize(source.baseAddress, source.count)
            guard ZSTD_isError(compressed) == 0, compressed > 0, compressed <= source.count
            else {
                Log.usage.debug("claude desktop cache: no complete zstd frame in entry")
                return nil
            }

            // The declared size, for the frames that declare one. Chunked
            // responses do not, which is why the output buffer is capped as
            // well — that cap is the guard which always applies.
            let declared = ZSTD_getFrameContentSize(source.baseAddress, source.count)
            if declared != ZSTD_CONTENTSIZE_UNKNOWN, declared != ZSTD_CONTENTSIZE_ERROR,
               declared > UInt64(maxDecompressedBytes) {
                Log.usage.debug("claude desktop cache: entry declares an oversized body")
                return nil
            }

            var output = [UInt8](repeating: 0, count: maxDecompressedBytes)
            let written = output.withUnsafeMutableBytes { destination in
                ZSTD_decompress(destination.baseAddress, destination.count,
                                source.baseAddress, compressed)
            }
            guard ZSTD_isError(written) == 0, written > 0, written <= output.count else {
                // Corrupt, truncated mid-frame, or bigger than the cap — all the
                // same answer here.
                Log.usage.debug("claude desktop cache: zstd frame did not decode")
                return nil
            }
            return Frame(data: Data(output[0..<written]), frameSize: compressed)
        }
    }

    // MARK: - Bytes

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in (0..<4).reversed() { value = value << 8 | UInt32(bytes[offset + index]) }
        return value
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in (0..<8).reversed() { value = value << 8 | UInt64(bytes[offset + index]) }
        return value
    }

    /// First index of `needle` in `haystack`, or nil.
    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    // MARK: - Decoding

    /// RFC 9110's `IMF-fixdate`, the only form a `Date:` header written this
    /// decade takes.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
