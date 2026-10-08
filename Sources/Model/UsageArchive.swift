import Foundation

/// The last good reading for each provider, remembered across launches.
///
/// Without this, a cold start that cannot reach the endpoint — rate limited,
/// offline, token expired — shows nothing at all, which is the least useful
/// thing the notch could do. A remembered reading is dimmed and dated, but a
/// dated number you can see beats a blank ring.
struct UsageArchive {
    private struct Entry: Codable {
        let id: String
        let displayName: String
        let glyph: ProviderGlyph
        let fidelity: Fidelity
        let windows: [LimitWindow]
        let fetchedAt: Date
        /// Optional so archives written before this field still decode.
        let headlineID: String?
        /// Optional for the same reason: an archive written before the weekly
        /// ring existed has no second window to name, and must still open.
        let weeklyID: String?
        /// Optional so archives written before Codex token activity existed
        /// continue to open and show their last quota reading.
        let tokenUsage: CodexTokenUsage?
        let usageDetail: ProviderUsageDetail?
        /// Whose reading this was. Optional for the same reason, and kept so a
        /// remembered one still says it — a reading restored from the archive
        /// is exactly when "which account is this?" is hardest to answer.
        let plan: String?
    }

    private let defaults: UserDefaults
    private let key = "lastGoodReadings"
    private let backoffKey = "backoffUntil"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Back-off

    /// When the endpoint may next be called, remembered across launches.
    ///
    /// Without this, every relaunch starts with a clean slate and fires a
    /// request immediately — so a development loop of `make run` walks straight
    /// into the rate limit it is being punished by, and keeps the punishment
    /// alive. Which is exactly what happened.
    ///
    /// Kept per provider: the limit is per account, so a work profile being
    /// told to slow down says nothing about the personal one. The default
    /// profile keeps the key it always had, so a penalty in progress survives
    /// the update.
    func loadBackoffUntil(providerID: String = ClaudeProfile.defaultID) -> Date? {
        guard let date = defaults.object(forKey: backoffKey(for: providerID)) as? Date,
              date > Date() else {
            return nil
        }
        return date
    }

    func saveBackoffUntil(_ date: Date?, providerID: String = ClaudeProfile.defaultID) {
        let key = backoffKey(for: providerID)
        if let date {
            defaults.set(date, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func backoffKey(for providerID: String) -> String {
        providerID == ClaudeProfile.defaultID ? backoffKey : "\(backoffKey).\(providerID)"
    }

    func load() -> [String: (snapshot: ProviderSnapshot, fetchedAt: Date)] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [:] }

        var result: [String: (snapshot: ProviderSnapshot, fetchedAt: Date)] = [:]
        var prunedObsolete = false
        for entry in entries {
            if entry.id == "perplexity" {
                prunedObsolete = true
                continue
            }
            // Spark and code-review are live windows. Older Codex readings also
            // carried rollout quotas the provider no longer displays. Strip
            // those leftovers rather than discarding a Spark snapshot — and
            // do it for every Codex profile, not only the default.
            let windows: [LimitWindow]
            if CodexProfile.isCodex(providerID: entry.id) {
                windows = entry.windows.filter { Self.isLiveCodexWindow($0.id) }
                if windows.isEmpty { continue }
            } else {
                windows = entry.windows
            }
            var snapshot = ProviderSnapshot(
                id: entry.id,
                displayName: entry.displayName,
                glyph: entry.id == "devin" && entry.glyph == .third ? .devin : entry.glyph,
                fidelity: entry.fidelity,
                status: .stale(since: entry.fetchedAt),
                windows: windows,
                headlineID: entry.headlineID,
                weeklyID: entry.weeklyID,
                tokenUsage: entry.tokenUsage,
                usageDetail: entry.usageDetail
            )
            snapshot.plan = entry.plan
            result[entry.id] = (snapshot, entry.fetchedAt)
        }
        if prunedObsolete {
            save(result)
        }
        return result
    }

    /// Window ids the live Codex provider still displays.
    private static func isLiveCodexWindow(_ id: String) -> Bool {
        id == "primary" || id == "secondary"
            || id.hasPrefix("spark")
            || id.hasPrefix("code-review")
    }

    func save(_ readings: [String: (snapshot: ProviderSnapshot, fetchedAt: Date)]) {
        let entries = readings.values
            .filter { $0.snapshot.id != "perplexity" }
            .map {
            Entry(
                id: $0.snapshot.id,
                displayName: $0.snapshot.displayName,
                glyph: $0.snapshot.glyph,
                fidelity: $0.snapshot.fidelity,
                windows: $0.snapshot.windows,
                fetchedAt: $0.fetchedAt,
                headlineID: $0.snapshot.headlineID,
                weeklyID: $0.snapshot.weeklyID,
                tokenUsage: $0.snapshot.tokenUsage,
                usageDetail: $0.snapshot.usageDetail,
                plan: $0.snapshot.plan
            )
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    /// Drop what we remember about one provider.
    ///
    /// Signing out has to reach this, or the notch keeps showing the last
    /// reading — dimmed and dated, but still that account's numbers, still on
    /// screen after the next launch.
    func forget(_ providerID: String) {
        var readings = load()
        readings.removeValue(forKey: providerID)
        save(readings)
    }
}
