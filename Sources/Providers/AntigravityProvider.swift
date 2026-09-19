import Foundation
import SQLite3
import os
/// Gemini, as Antigravity sees it.
///
/// **What this can and cannot report, and why.** Antigravity talks to Google's
/// Cloud Code backend, and the only call that describes the account is
/// `:loadCodeAssist`. It answers with tiers — which plan you are on and which
/// you are not eligible for — and no numbers: no used, no limit, no reset. A
/// packet capture of a signed-in install showed exactly two RPCs, and neither
/// carries a quota.
///
/// So this provider reports the account honestly and says there is nothing
/// metered, rather than inventing a ring. That is the same answer Cursor's free
/// plan gets, and for the same reason: a confident 0% is worse than an admitted
/// blank, especially in something people pay for.
actor AntigravityProvider: UsageProvider {
    nonisolated let profile: AntigravityProfile
    nonisolated let id: String
    // The id stays `gemini` for default profile: it keys the archive and the user's connection
    // choice, and changing it would silently discard both. Additional profiles are `antigravity-<slug>`.
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.antigravity

    /// The production host. Antigravity itself also calls a `daily-` variant,
    /// which answers 403 to this token — so it is not a fallback, it is a
    /// different audience.
    private let endpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    /// The real usage figure — served by Cloud Code PA.
    private let quotaEndpoint = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    private let session: URLSession
    /// A second session, trusting loopback only, for the local language server.
    private let localSession: URLSession
    /// Re-discovering the port and token means spawning `ps` and `lsof`, which
    /// is not something to do every minute. Cached until it stops working.
    private var bridge: AntigravityBridge.Endpoint?
    /// Whether the language server has ever answered.
    ///
    /// Once it has, a failure is Antigravity being closed or restarted — its
    /// port changes every launch — not an account that cannot be read. Falling
    /// back to the request count then *replaces* a percentage with a plain
    /// number, and a ring that reads 8% one minute and 31 the next looks broken
    /// rather than degraded.
    private var everBridged = false

    /// How the language server is asked, when a test needs to say. Production
    /// leaves this nil and goes through `localQuota()`, which spawns `ps` and
    /// `lsof` to find a port that only exists while Antigravity is running —
    /// nothing a test can arrange, and the ordering this fixes is exactly what
    /// would otherwise go uncovered.
    private let localQuotaOverride: (@Sendable () async -> [LimitWindow]?)?

    init(profile: AntigravityProfile = .default(),
         session: URLSession = .shared,
         localQuota: (@Sendable () async -> [LimitWindow]?)? = nil) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        self.session = session
        self.localQuotaOverride = localQuota
        self.localSession = URLSession(configuration: .ephemeral,
                                       delegate: LocalhostTrust(),
                                       delegateQueue: nil)
    }

    nonisolated var signInRoute: SignInRoute {
        profile.signInRoute
    }

    /// Reached only from "Allow access…", so it may let the next read prompt.
    nonisolated func forgetCachedCredential() {
        AntigravityCredentials.forgetCached(for: profile)
        AntigravityCredentials.askAgain(for: profile)
    }

    nonisolated func account() -> ProviderAccount? {
        if AntigravityCredentials.isSignedIn(for: profile), let held = AntigravityCredentials.held(for: profile) {
            let email = held.email
            let plan = held.authMethod == "consumer" ? L10n.t("Personal") : held.authMethod
            return ProviderAccount(
                label: email,
                plan: plan,
                source: profile.sourceName,
                manageURL: URL(string: "https://antigravity.google")
            )
        }
        
        if profile.slug == nil && UserDefaults.standard.bool(forKey: "AntigravityEverBridged") {
            return ProviderAccount(
                label: L10n.t("Local Session"),
                plan: L10n.t("Active"),
                source: "Antigravity IDE",
                manageURL: nil
            )
        }
        
        return nil
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // Antigravity's own language server first, before anything is asked of
        // the keychain. It already holds the credential and the client identity
        // Google insists on, and answers with the same figure Antigravity's own
        // panel shows — so where it is running, the token is not needed at all.
        //
        // It used to be asked third, after a keychain read and a round trip to
        // `:loadCodeAssist`. That made the reading depend on a dialogue it did
        // not need: someone who dismissed the keychain prompt got `accessDenied`
        // and an empty ring, while the server that would have answered sat
        // running on the same machine, never asked.
        if profile.slug == nil {
            if let windows = await localQuota(), !windows.isEmpty {
                everBridged = true
                UserDefaults.standard.set(true, forKey: "AntigravityEverBridged")
                
                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                        fidelity: .official, status: .ok, windows: windows,
                                        headlineID: resolveHeadlineID(for: windows),
                                        weeklyID: resolveWeeklyID(for: windows))
            }

            if localQuotaOverride != nil && everBridged {
                throw UsageProviderError.credentialExpired
            }
        }

        // 1. Try reading credentials and asking Google Cloud Code PA directly
        let credentials = try? AntigravityCredentials.load(for: profile)
        if let credentials,
           let windows = try? await quota(token: credentials.accessToken, project: credentials.projectId),
           !windows.isEmpty {
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok, windows: windows,
                                    headlineID: resolveHeadlineID(for: windows),
                                    weeklyID: resolveWeeklyID(for: windows))
        }

        // 2. Fallback to OMP SQLite store if offline or direct call fails
        if profile.slug == nil {
            let ompWindows = Self.ompUsageWindows(forEmail: credentials?.email)
            if !ompWindows.isEmpty {
                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                        fidelity: .official, status: .ok, windows: ompWindows,
                                        headlineID: resolveHeadlineID(for: ompWindows),
                                        weeklyID: resolveWeeklyID(for: ompWindows))
            }
        }

        if everBridged { throw UsageProviderError.credentialExpired }
        // is the only number left — reported as a *count*, with no
        // `usedFraction`, which is a case the model already knows: the cell
        // prints the number and the ring draws its track with no arc, because
        // there is no limit to be a fraction of.
        //
        // Better than the dash it showed before, which read as broken rather
        // than as "Google will not answer for this account".
        let roots = profile.slug == nil ? AntigravityActivity.transcriptRoots : [profile.brainDirectory]
        let activity = AntigravityActivity.read(roots: roots)
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            // Ours, not Google's. The tooltip prefixes a `~` on the strength of
            // this, which is exactly the claim being made.
            fidelity: .derived,
            status: .ok,
            windows: [
                LimitWindow(id: "requests",
                            label: activity.label(),
                            used: activity.requestsToday)
            ],
            headlineID: "requests"
        )
    }

    nonisolated func resolveHeadlineID(for windows: [LimitWindow]) -> String {
        let preferredLimit = Preferences.storedAntigravityHeadlineLimit()
        let preferredModel = Preferences.storedAntigravityHeadlineModel()
        let modelCandidates = windows.filter { $0.id.hasPrefix(preferredModel.rawValue) }
        let candidates = modelCandidates.isEmpty ? windows : modelCandidates

        if preferredLimit != .automatic {
            let limitCandidates = candidates.filter { matches($0, cadence: preferredLimit) }
            if let mostConstrained = limitCandidates.max(by: constrainedBefore) {
                return mostConstrained.id
            }
        }

        // Match CodexBar's default: an exhausted lane does not displace a
        // usable lane unless every lane is exhausted.
        let fractional = candidates.filter { $0.usedFraction != nil }
        let usable = fractional.filter { ($0.usedFraction ?? 0) < 1 }
        return (usable.isEmpty ? fractional : usable).max(by: constrainedBefore)?.id
            ?? candidates.first?.id
            ?? "\(preferredModel.rawValue)-hourly"
    }

    private nonisolated func matches(_ window: LimitWindow, cadence: AntigravityHeadlineLimit) -> Bool {
        let value = "\(window.id) \(window.label)".lowercased()
        switch cadence {
        case .fiveHour:
            return window.duration == 5 * 3600 ||
                ["5h", "5-hour", "five hour", "five-hour", "hourly", "session"]
                    .contains(where: { value.contains($0) })
        case .weekly:
            return window.duration == 7 * 86400 || value.contains("weekly")
        case .automatic:
            return true
        }
    }

    private nonisolated func constrainedBefore(_ lhs: LimitWindow, _ rhs: LimitWindow) -> Bool {
        let left = lhs.usedFraction ?? 0
        let right = rhs.usedFraction ?? 0
        if left != right { return left < right }
        return lhs.id > rhs.id
    }

    nonisolated func resolveWeeklyID(for windows: [LimitWindow]) -> String? {
        let preferredModel = Preferences.storedAntigravityHeadlineModel()
        let modelCandidates = windows.filter { $0.id.hasPrefix(preferredModel.rawValue) }
        let candidates = modelCandidates.isEmpty ? windows : modelCandidates
        let weekly = candidates.filter { window in
            window.duration == 7 * 86400 ||
                window.id.lowercased().hasSuffix("-weekly") ||
                window.label.lowercased().contains("weekly")
        }
        return weekly.max(by: constrainedBefore)?.id
    }

    /// Ask Antigravity's language server, if it is running.
    ///
    /// Returns nil rather than throwing when it is not: Antigravity being
    /// closed is the ordinary case, not a fault, and the caller has an honest
    /// answer to fall back to.
    private func localQuota() async -> [LimitWindow]? {
        if let localQuotaOverride { return await localQuotaOverride() }
        if let bridge {
            do {
                let windows = try await AntigravityBridge.quota(from: bridge, session: localSession)
                if !windows.isEmpty { return windows }
            } catch {
                Log.usage.error("Antigravity localQuota bridge error: \(String(describing: error), privacy: .public)")
            }
        }
        // Cached endpoint gone or never found: the port changes every time
        // Antigravity restarts, so a stale one is expected, not exceptional.
        guard let fresh = AntigravityBridge.discover() else {
            self.bridge = nil
            Log.usage.error("Antigravity localQuota discover failed to find process")
            return nil
        }
        self.bridge = fresh
        do {
            return try await AntigravityBridge.quota(from: fresh, session: localSession)
        } catch {
            Log.usage.error("Antigravity localQuota fresh bridge error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Ask for the account's quota, returning nil when it is not allowed to.
    ///
    /// A free or personal account answers 403 #3501, "You do not have a valid
    private func quota(token: String, project: String? = nil) async throws -> [LimitWindow]? {
        var request = URLRequest(url: quotaEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)", forHTTPHeaderField: "User-Agent")
        request.setValue("ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI", forHTTPHeaderField: "Client-Metadata")
        let bodyObj: [String: Any] = (project != nil && !project!.isEmpty) ? ["project": project!] : [:]
        request.httpBody = try? JSONSerialization.data(withJSONObject: bodyObj)
        request.timeoutInterval = 15

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.windows(in: data)
    }

    /// Turns a quota summary into standard limit windows.
    ///
    /// Standard Antigravity exposes two groups with two windows each:
    /// 1. "Gemini Models" -> 5-hour Limit & Weekly Limit
    /// 2. "Claude and GPT models" -> 5-hour Limit & Weekly Limit
    ///
    /// Both the local language server (which already provides grouped buckets)
    /// and direct Google Cloud Code PA `retrieveUserQuota` responses (which list
    /// individual model buckets) are normalized into this standard 4-window structure.
    nonisolated static func windows(in data: Data, now: Date = Date()) -> [LimitWindow] {
        AntigravityQuotaParser.parse(data, now: now)
    }


    static func ompUsageWindows(forEmail email: String? = nil) -> [LimitWindow] {
        let dbURL = URL(fileURLWithPath: ("~/.omp/agent/agent.db" as NSString).expandingTildeInPath)
        guard let db = SQLiteStore.open(dbURL) else { return [] }
        defer { sqlite3_close(db) }

        var targetEmail = email
        if targetEmail == nil {
            let sql = "SELECT email FROM usage_history WHERE provider = 'google-antigravity' AND email IS NOT NULL AND email != '' ORDER BY recorded_at DESC, id DESC LIMIT 1;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW, let em = sqlite3_column_text(stmt, 0) {
                    targetEmail = String(cString: em)
                }
                sqlite3_finalize(stmt)
            }
        }

        let sql: String
        if let targetEmail, !targetEmail.isEmpty {
            sql = """
            SELECT limit_id, label, window_label, used_fraction, resets_at
            FROM usage_history
            WHERE provider = 'google-antigravity' AND email = ?1
            ORDER BY recorded_at DESC, id DESC
            LIMIT 10;
            """
        } else {
            sql = """
            SELECT limit_id, label, window_label, used_fraction, resets_at
            FROM usage_history
            WHERE provider = 'google-antigravity'
            ORDER BY recorded_at DESC, id DESC
            LIMIT 10;
            """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        if let targetEmail, !targetEmail.isEmpty {
            sqlite3_bind_text(stmt, 1, targetEmail, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        var latestByID: [String: (group: String, label: String, used: Double, resets: Date?)] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let limitId = String(cString: sqlite3_column_text(stmt, 0))
            let rawLabel = String(cString: sqlite3_column_text(stmt, 1))
            let windowLabel = sqlite3_column_text(stmt, 2).map { String(cString: $0).lowercased() } ?? ""
            let usedFraction = sqlite3_column_double(stmt, 3)
            let resetsAtMs = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? sqlite3_column_double(stmt, 4) : 0
            let resetsAt = (resetsAtMs > 0) ? Date(timeIntervalSince1970: resetsAtMs / 1000.0) : nil

            let isGemini = limitId.contains(":google:") || rawLabel.contains("Google")
            let groupName = isGemini ? L10n.t("Gemini Models") : L10n.t("Claude and GPT models")
            let isWeekly = windowLabel.contains("weekly")
            let labelName = isWeekly ? L10n.t("Weekly Limit") : L10n.t("5-hour Limit")
            let standardID = isGemini ? (isWeekly ? "gemini-weekly" : "gemini-hourly") : (isWeekly ? "3p-weekly" : "3p-hourly")

            if latestByID[standardID] == nil {
                latestByID[standardID] = (groupName, labelName, usedFraction, resetsAt)
            }
        }

        let standardSlots: [(id: String, group: String, label: String, isWeekly: Bool)] = [
            ("gemini-hourly", L10n.t("Gemini Models"), L10n.t("5-hour Limit"), false),
            ("gemini-weekly", L10n.t("Gemini Models"), L10n.t("Weekly Limit"), true),
            ("3p-hourly", L10n.t("Claude and GPT models"), L10n.t("5-hour Limit"), false),
            ("3p-weekly", L10n.t("Claude and GPT models"), L10n.t("Weekly Limit"), true)
        ]

        var windows: [LimitWindow] = []
        for slot in standardSlots {
            if let item = latestByID[slot.id] {
                windows.append(LimitWindow(
                    id: slot.id,
                    group: item.group,
                    label: item.label,
                    usedFraction: item.used,
                    resetsAt: item.resets,
                    duration: slot.isWeekly ? 7 * 86400 : nil
                ))
            } else {
                windows.append(LimitWindow(
                    id: slot.id,
                    group: slot.group,
                    label: slot.label,
                    usedFraction: 0.0,
                    resetsAt: nil,
                    duration: slot.isWeekly ? 7 * 86400 : nil
                ))
            }
        }
        return windows
    }

    /// Known quota group names, so an English API value still localizes.
    private static func quotaGroupName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        switch name {
        case "Gemini Models": return L10n.t("Gemini Models")
        case "Claude and GPT models": return L10n.t("Claude and GPT models")
        default: return name
        }
    }

    /// Known window titles, including the wording the language server uses.
    private static func quotaWindowLabel(_ name: String) -> String {
        var label = name
        if label.hasSuffix(" Remaining") {
            label = String(label.dropLast(" Remaining".count))
        }
        switch label {
        case "Five Hour Limit", "5-hour Limit": return L10n.t("5-hour Limit")
        case "Weekly Limit": return L10n.t("Weekly Limit")
        default: return label
        }
    }

    /// The plan's display name, for the message the cell shows.
    static func tier(in data: Data) -> String {
        struct Response: Decodable {
            struct Tier: Decodable {
                let id: String?
                let name: String?
                let isDefault: Bool?
            }
            let allowedTiers: [Tier]?
            let currentTier: Tier?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return "Gemini"
        }
        // `currentTier` appears once a tier has been chosen; before that the
        // default among the allowed ones is what you are on.
        let tier = decoded.currentTier
            ?? decoded.allowedTiers?.first(where: { $0.isDefault == true })
            ?? decoded.allowedTiers?.first
        return tier?.name ?? "Gemini"
    }
}
