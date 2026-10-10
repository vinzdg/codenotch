import Foundation

/// The weekly reading Grok Bot keeps for itself.
///
/// Grok Bot (Anysphere's `com.anysphere.sand`, the desktop bot built with
/// Cursor) fetches `GetCurrentPeriodUsage` from its own backend and caches the
/// mapped result as plain JSON in `sand-client-persistence`, one blob per
/// account. The blob's filename is the lower-case base32 of its key with no
/// padding, so the weekly cache for an account slot looks like
/// `sand.client.slice.account.grok|user_….weekly-usage.cache` spelled in
/// base32. Codenotch only reads it — no credential is involved, and nothing
/// here can sign in or refresh: while Grok Bot runs it keeps the cache fresh
/// itself, and when it does not the reading ages in place.
struct GrokBotReading {
    /// 0–100+, where 100 means the weekly allowance is spent. Over 100 is a
    /// real state — the app's own copy for it is "Weekly usage limit reached."
    let percentUsed: Double
    let resetsAt: Date?
    /// When Grok Bot took this reading (`readAtMs`).
    let asOf: Date
    /// When Grok Bot itself stops trusting it — a day after the reading. Past
    /// this the ring still shows the number, but dimmed as stale.
    let expiresAt: Date?
    /// The plan, named the way the backend names it ("SuperGrok Plus").
    let planLabel: String?
    let onDemand: OnDemand?

    struct OnDemand {
        let usedCents: Double
        let limitCents: Double
    }

    var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }
}

enum GrokBotCache {
    static var persistenceURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence")
    }

    /// Minted by Anysphere, who build Grok Bot — stable across updates, but
    /// not across Grok Bot leaving that bundle id. Kept here beside the store
    /// path so the two facts about an installation change together: the
    /// provider's sign-in route reads this one.
    static let bundleID = "com.anysphere.sand"

    /// The slot Grok Bot currently has selected (`grok|user_…`), or nil when
    /// it never wrote one. Non-secret: it names the account the way the blob
    /// keys do, and carries no credential.
    static let accountSlotKey = "sand.client.slice.client-meta.account-slot"
    static let weeklyUsageSuffix = ".weekly-usage.cache"

    /// Identity, read from the same cache as the reading. There is no email
    /// on disk — the account secret is encrypted, and the transcripts that
    /// might mention an address are the user's own words, not to be read for
    /// a settings line — so the plan label is the whole of it.
    static func account(persistenceDir: URL = persistenceURL) -> ProviderAccount? {
        guard let reading = try? load(persistenceDir: persistenceDir) else { return nil }
        return ProviderAccount(
            label: nil,
            plan: reading.planLabel,
            source: "Grok Bot",
            manageURL: URL(string: "https://cursor.com/dashboard?tab=billing")
        )
    }

    /// The weekly cache for the active account — or, when the selected slot
    /// is unknown, the freshest one any account left behind.
    static func load(persistenceDir: URL = persistenceURL) throws -> GrokBotReading {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: persistenceDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { throw UsageProviderError.needsAuth }

        let caches = files.compactMap { url -> (slot: String, url: URL)? in
            guard let key = decodeBlobName(url.lastPathComponent),
                  key.hasSuffix(weeklyUsageSuffix),
                  key.hasPrefix("sand.client.slice.account.")
            else { return nil }
            let slot = key.dropFirst("sand.client.slice.account.".count)
                .dropLast(weeklyUsageSuffix.count)
            return (String(slot), url)
        }
        guard !caches.isEmpty else { throw UsageProviderError.needsAuth }

        let activeSlot = activeAccountSlot(in: persistenceDir)
        let ordered = caches.sorted { lhs, rhs in
            switch (lhs.slot == activeSlot, rhs.slot == activeSlot) {
            case (true, false): return true
            case (false, true): return false
            default: return modifiedAt(lhs.url) > modifiedAt(rhs.url)
            }
        }

        var sawUnreadable = false
        for candidate in ordered {
            guard let data = try? Data(contentsOf: candidate.url) else { continue }
            do {
                return try reading(from: data, fallbackDate: modifiedAt(candidate.url))
            } catch UsageProviderError.nothingMetered {
                // One account's empty cache must not hide another's reading.
                sawUnreadable = true
                continue
            }
        }
        if sawUnreadable {
            throw UsageProviderError.nothingMetered(L10n.t("Grok Bot has nothing metered on this account yet"))
        }
        throw UsageProviderError.badResponse(status: 0)
    }

    /// Recorded from a live SuperGrok Plus session (the slot anonymised):
    ///
    /// ```json
    /// {"schemaVersion":2,"value":{"kind":"present","selectedTeamId":null,
    ///  "reading":{"usage":{"percentUsed":85.898948,
    ///   "nextResetMs":1791876398146,"isSandTrial":false,
    ///   "hasNonZeroIncludedLimit":true,"isTeamSeat":false,"onDemand":null,
    ///   "grokPlanLabel":"SuperGrok Plus"},
    ///  "readAtMs":1791657386366},"expiresAtMs":1791743786366}}
    /// ```
    ///
    /// A spend cap adds `"onDemand":{"usedCents":…,"limitCents":…}`. Anything
    /// but `kind: "present"` with a usage in it is not a reading: the fetch
    /// behind the cache answers null for pooled enterprise allowances and for
    /// accounts whose percent never arrived.
    static func reading(from data: Data, fallbackDate: Date) throws -> GrokBotReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["value"] as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }
        guard (value["kind"] as? String) == "present",
              let reading = value["reading"] as? [String: Any],
              let usage = reading["usage"] as? [String: Any],
              let percent = (usage["percentUsed"] as? NSNumber)?.doubleValue,
              percent.isFinite
        else {
            throw UsageProviderError.nothingMetered(
                L10n.t("Grok Bot has nothing metered on this account yet"))
        }

        return GrokBotReading(
            // The app clamps the same way: `Math.max(usagePercent, 0)`.
            percentUsed: max(percent, 0),
            resetsAt: resetDate(usage["nextResetMs"]),
            asOf: milliseconds(reading["readAtMs"]).map { Date(timeIntervalSince1970: $0) } ?? fallbackDate,
            expiresAt: milliseconds(value["expiresAtMs"]).map { Date(timeIntervalSince1970: $0) },
            planLabel: nonEmpty(usage["grokPlanLabel"]),
            onDemand: onDemand(usage["onDemand"])
        )
    }

    private static func onDemand(_ any: Any?) -> GrokBotReading.OnDemand? {
        guard let dict = any as? [String: Any],
              let used = (dict["usedCents"] as? NSNumber)?.doubleValue,
              let limit = (dict["limitCents"] as? NSNumber)?.doubleValue
        else { return nil }
        return GrokBotReading.OnDemand(usedCents: used, limitCents: limit)
    }

    /// A reset of zero or less is the app's own null: its mapper only keeps a
    /// timestamp that is finite and positive.
    private static func resetDate(_ any: Any?) -> Date? {
        milliseconds(any).map { Date(timeIntervalSince1970: $0) }
    }

    private static func milliseconds(_ any: Any?) -> TimeInterval? {
        guard let ms = (any as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return ms / 1000
    }

    private static func nonEmpty(_ any: Any?) -> String? {
        guard let text = any as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func activeAccountSlot(in dir: URL) -> String? {
        let url = dir.appendingPathComponent(blobFilename(forKey: accountSlotKey))
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["value"]
        else { return nil }
        // The slot blob's value is the bare string; anything else is a shape
        // from another version, not the account.
        return value as? String
    }

    private static func modifiedAt(_ url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate) ?? .distantPast
    }

    // MARK: - Blob names

    /// `sand.client.slice.client-meta.account-slot` →
    /// `onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a.blob`.
    static func blobFilename(forKey key: String) -> String {
        base32Encode(Data(key.utf8)).lowercased() + ".blob"
    }

    static func decodeBlobName(_ filename: String) -> String? {
        guard filename.hasSuffix(".blob") else { return nil }
        let body = String(filename.dropLast(".blob".count)).uppercased()
        guard let data = base32Decode(body) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static func base32Encode(_ data: Data) -> String {
        var result = ""
        var buffer = 0
        var bitsLeft = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                result.append(alphabet[(buffer >> bitsLeft) & 31])
            }
        }
        if bitsLeft > 0 {
            result.append(alphabet[(buffer << (5 - bitsLeft)) & 31])
        }
        return result
    }

    private static func base32Decode(_ text: String) -> Data? {
        var padded = text
        padded += String(repeating: "=", count: (8 - padded.count % 8) % 8)
        var result = Data()
        var buffer = 0
        var bitsLeft = 0
        for character in padded {
            if character == "=" { break }
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | index
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                result.append(UInt8((buffer >> bitsLeft) & 255))
            }
        }
        return result
    }
}
