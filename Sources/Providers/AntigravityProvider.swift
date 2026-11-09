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
    private let prodQuotaEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
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
    private var completionPausedUntil: Date = .distantPast
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
            let source = held.sourceName ?? profile.sourceName
            return ProviderAccount(
                label: email,
                plan: plan,
                source: source,
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
            if let bridged = await localQuota(), !bridged.isEmpty {
                everBridged = true
                UserDefaults.standard.set(true, forKey: "AntigravityEverBridged")

                // The language server's quota summary covers the groups it
                // serves, which is not the whole account. Measured against one
                // account: the server answered with the third-party group only,
                // while Cloud Code PA answered with the Gemini group as well —
                // and the Gemini group was where the usage actually was. Taking
                // the server's answer as the account's would report a different
                // allowance than the one asked for.
                //
                // So ask Cloud Code PA as well, but only when the answer so far
                // cannot serve the family that was chosen. Where the server
                // does report that family, nothing changes and the keychain is
                // still never read.
                let windows = await completedWindows(bridged) ?? bridged

                let chosen = selection(for: windows)
                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                        fidelity: .official, status: .ok, windows: chosen.windows,
                                        headlineID: chosen.headlineID,
                                        weeklyID: chosen.weeklyID)
            }

            if localQuotaOverride != nil && everBridged {
                throw UsageProviderError.credentialExpired
            }
        }

        if profile.slug != nil {
            var credentials = try? AntigravityCredentials.load(for: profile)
            if let creds = credentials, (creds.isExpired || creds.accessToken.isEmpty), creds.refreshToken != nil {
                if let refreshed = try? await AntigravityCredentials.refresh(credentials: creds, session: session) {
                    credentials = refreshed
                    AntigravityCredentials.updateHeld(refreshed, for: profile)
                }
            }
            if let credentials,
               let windows = try? await quota(token: credentials.accessToken,
                                              project: credentials.projectId,
                                              isACP: false),
               !windows.isEmpty {
                return officialSnapshot(windows)
            }
        } else {
            let processTable = AntigravityBridge.run("/bin/ps", ["-Ao", "pid,command"])
            let runningFlavors = AntigravityFlavor.runningFlavors(processTable: processTable)

            // 1. Query token / credentials for each flavor: IDE, CLI, ACP
            var candidates: [FlavorCandidate] = []
            for flavor in AntigravityFlavor.allCases {
                let isRunning = runningFlavors.contains(flavor)
                let creds = try? AntigravityCredentials.load(for: flavor, profile: profile)
                let lastActivity = flavor.lastActivityDate()
                let canProvide = isRunning || (creds != nil && (!creds!.isExpired || creds!.refreshToken != nil))
                let isActive = isRunning || (canProvide && (lastActivity != nil || (creds != nil && !creds!.isExpired)))
                candidates.append(FlavorCandidate(
                    flavor: flavor,
                    credentials: creds,
                    isRunning: isRunning,
                    lastActivity: lastActivity,
                    canProvideQuota: canProvide,
                    isActive: isActive
                ))
            }

            // 2. Only active ones get fetched from
            let activeCandidates = candidates.filter { $0.isActive && $0.canProvideQuota }

            // 3. If 2 or more are active, rank them to decide which one to fetch from
            let ranked = AntigravityFlavor.rankCandidates(activeCandidates)

            for candidate in ranked {
                if let snapshot = await tryFetchQuota(for: candidate, processTable: processTable) {
                    return snapshot
                }
            }
        }

        // 4. Fallback to OMP SQLite store if offline or direct call fails
        if profile.slug == nil {
            let omp = Self.ompUsage(forEmail: AntigravityCredentials.held(for: profile)?.email)
            if !omp.windows.isEmpty {
                let chosen = selection(for: omp.windows)
                var status = ProviderStatus.ok
                if let recordedAt = omp.recordedAt, Date().timeIntervalSince(recordedAt) > Self.ompFreshness {
                    status = .stale(since: recordedAt)
                }
                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                        fidelity: .official, status: status, windows: chosen.windows,
                                        headlineID: chosen.headlineID,
                                        weeklyID: chosen.weeklyID)
            }
        }

        if everBridged { throw UsageProviderError.credentialExpired }

        // 5. Final fallback: request count activity from transcripts
        let roots = profile.slug == nil ? AntigravityActivity.transcriptRoots : [profile.brainDirectory]
        let activity = AntigravityActivity.read(roots: roots)
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
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

    private func tryFetchQuota(for candidate: FlavorCandidate, processTable: String) async -> ProviderSnapshot? {
        switch candidate.flavor {
        case .ide:
            // The IDE's language server was asked first, before any of this,
            // and did not answer; asking it again here would only wait twice.
            if let creds = candidate.credentials {
                var activeCreds = creds
                if (activeCreds.isExpired || activeCreds.accessToken.isEmpty) && activeCreds.refreshToken != nil {
                    if let refreshed = try? await AntigravityCredentials.refresh(credentials: activeCreds, session: session) {
                        activeCreds = refreshed
                        AntigravityCredentials.updateHeld(refreshed, for: .ide, profile: profile)
                    }
                }
                if !activeCreds.isExpired,
                   let windows = try? await quota(token: activeCreds.accessToken, project: activeCreds.projectId, isACP: false),
                   !windows.isEmpty {
                    AntigravityCredentials.updateHeld(activeCreds, for: .ide, profile: profile)
                    return officialSnapshot(windows)
                }
            }
            return nil

        case .cli:
            if candidate.isRunning, let bridge = AntigravityBridge.discover(processTable: processTable) {
                if let windows = try? await AntigravityBridge.quota(from: bridge, session: localSession), !windows.isEmpty {
                    everBridged = true
                    UserDefaults.standard.set(true, forKey: "AntigravityEverBridged")
                    return officialSnapshot(windows)
                }
            }
            if let creds = candidate.credentials {
                var activeCreds = creds
                if (activeCreds.isExpired || activeCreds.accessToken.isEmpty) && activeCreds.refreshToken != nil {
                    if let refreshed = try? await AntigravityCredentials.refresh(credentials: activeCreds, session: session) {
                        activeCreds = refreshed
                        AntigravityCredentials.updateHeld(refreshed, for: .cli, profile: profile)
                    }
                }
                if !activeCreds.isExpired,
                   let windows = try? await quota(token: activeCreds.accessToken, project: activeCreds.projectId, isACP: false),
                   !windows.isEmpty {
                    AntigravityCredentials.updateHeld(activeCreds, for: .cli, profile: profile)
                    return officialSnapshot(windows)
                }
            }
            return nil

        case .acp:
            if let creds = candidate.credentials {
                var activeCreds = creds
                if (activeCreds.isExpired || activeCreds.accessToken.isEmpty) && activeCreds.refreshToken != nil {
                    if let refreshed = try? await AntigravityCredentials.refresh(credentials: activeCreds, session: session) {
                        activeCreds = refreshed
                        AntigravityCredentials.updateHeld(refreshed, for: .acp, profile: profile)
                    }
                }
                if !activeCreds.isExpired,
                   let windows = try? await quota(token: activeCreds.accessToken, project: activeCreds.projectId, isACP: true),
                   !windows.isEmpty {
                    AntigravityCredentials.updateHeld(activeCreds, for: .acp, profile: profile)
                    return officialSnapshot(windows)
                }
            }
            return nil
        }
    }

    nonisolated func resolveHeadlineID(for windows: [LimitWindow]) -> String {
        let preferredLimit = Preferences.storedAntigravityHeadlineLimit()
        let preferredModel = Preferences.storedAntigravityHeadlineModel()
        // Only the chosen family. It used to fall back to every window when
        // this came up empty, which reported a different allowance under the
        // name of the one that was asked for — the reader chose Gemini, the
        // account had no Gemini group, and the ring showed the third-party
        // group's number as if it were the answer. A family that reported
        // nothing is an absent reading, not another family's reading.
        let candidates = windows.filter { $0.id.hasPrefix(preferredModel.rawValue) }
        guard !candidates.isEmpty else { return Self.unavailableWindowID }

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
        // The chosen family only, for the same reason as the headline: the
        // weekly allowance of one family is not the weekly allowance of
        // another. No weekly window in the family means no second ring.
        let candidates = windows.filter { $0.id.hasPrefix(preferredModel.rawValue) }
        let weekly = candidates.filter { window in
            window.duration == 7 * 86400 ||
                window.id.lowercased().hasSuffix("-weekly") ||
                window.label.lowercased().contains("weekly")
        }
        return weekly.max(by: constrainedBefore)?.id
    }

    /// The id of the window that stands in for a family which reported nothing.
    ///
    /// Deliberately outside every family's id namespace, so that adding it to
    /// the windows does not make that family look present.
    static let unavailableWindowID = "quota-group-unavailable"

    /// The reading shown for a family that reported nothing.
    ///
    /// The reader asked for that family, so the cell says the family is not
    /// reporting rather than going quiet or, worse, showing another family's
    /// number. The other families stay in the list, so the account's other
    /// allowances remain visible.
    nonisolated static func unavailableWindow(for model: AntigravityHeadlineModel) -> LimitWindow {
        LimitWindow(id: unavailableWindowID,
                    group: model.explanation,
                    label: L10n.t("No reading"),
                    usedFraction: nil)
    }

    /// The windows to show, and which of them is the reading.
    ///
    /// A family that reported nothing gets an explicit reading of its own, so
    /// that its absence is shown rather than covered by another family.
    private nonisolated func selection(
        for windows: [LimitWindow]
    ) -> (windows: [LimitWindow], headlineID: String, weeklyID: String?) {
        let preferred = Preferences.storedAntigravityHeadlineModel()
        let reported = windows.contains { $0.id.hasPrefix(preferred.rawValue) }
        let shown = reported ? windows : windows + [Self.unavailableWindow(for: preferred)]
        return (shown, resolveHeadlineID(for: shown), resolveWeeklyID(for: shown))
    }

    /// Ask Antigravity's language server, if it is running.
    ///
    /// Returns nil rather than throwing when it is not: Antigravity being
    /// closed is the ordinary case, not a fault, and the caller has an honest
    /// answer to fall back to.
    private func localQuota(processTable: String? = nil) async -> [LimitWindow]? {
        if let localQuotaOverride { return await localQuotaOverride() }
        if let bridge {
            do {
                let windows = try await AntigravityBridge.quota(from: bridge, session: localSession)
                if !windows.isEmpty { return windows }
            } catch {
                Log.usage.debug("Antigravity cached bridge endpoint gone: \(String(describing: error), privacy: .public)")
                self.bridge = nil
            }
        }
        guard let fresh = await resolveEndpoint(processTable: processTable) else {
            Log.usage.debug("Antigravity localQuota discover failed to find process")
            return nil
        }
        self.bridge = fresh
        do {
            return try await AntigravityBridge.quota(from: fresh, session: localSession)
        } catch {
            Log.usage.debug("Antigravity localQuota fresh bridge error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Where to ask: the IDE's own server while it runs, otherwise one we start.
    private func resolveEndpoint(processTable: String? = nil) async -> AntigravityBridge.Endpoint? {
        if let running = AntigravityBridge.discover(processTable: processTable) { return running }

        guard let binary = AntigravityBridge.serverBinaryURL(),
              AntigravityBridge.owned.endpointOrStart(binary: binary) != nil,
              let pid = AntigravityBridge.owned.pid
        else { return nil }

        for _ in 0..<40 {
            let ports = AntigravityBridge.listeningPorts(ofPID: Int(pid))
            if !ports.isEmpty {
                AntigravityBridge.owned.resolvePorts(ports)
                return AntigravityBridge.owned.current
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        Log.usage.debug("Antigravity: started server never bound a port")
        return nil
    }

    /// A reading from any official source, with the chosen family answered
    /// from itself — see `selection(for:)`.
    private func officialSnapshot(_ windows: [LimitWindow]) -> ProviderSnapshot {
        let chosen = selection(for: windows)
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok, windows: chosen.windows,
                                headlineID: chosen.headlineID,
                                weeklyID: chosen.weeklyID)
    }

    /// Completes a language-server answer with the account's other quota
    /// groups, when it is missing the one that was chosen.
    ///
    /// The server's summary is a subset: it reports the groups it serves, and
    /// the family the reader picked can be among the ones it does not. The
    /// direct Cloud Code PA answer is the whole account, so it is asked for
    /// only when the subset cannot serve the chosen family — otherwise the
    /// reading would fall through to a different allowance and say so by
    /// displaying that allowance's name, which reads as an answer rather than
    /// as a missing one.
    ///
    /// Returns nil when there is nothing to add or the direct answer cannot be
    /// had, so the caller keeps what it already has.
    private func completedWindows(_ bridged: [LimitWindow]) async -> [LimitWindow]? {
        let preferred = Preferences.storedAntigravityHeadlineModel().rawValue
        guard !bridged.contains(where: { $0.id.hasPrefix(preferred) }) else { return nil }
        // An account that has no such group answers the same way every poll,
        // and each try is a keychain read and a round trip to Google. So a try
        // that could not help waits half an hour before the next.
        let now = Date()
        guard now >= completionPausedUntil else { return nil }
        completionPausedUntil = now.addingTimeInterval(Self.completionPause)
        guard let credentials = try? AntigravityCredentials.load(for: profile) else { return nil }
        guard let direct = try? await quota(token: credentials.accessToken,
                                            project: credentials.projectId),
              !direct.isEmpty else { return nil }
        if direct.contains(where: { $0.id.hasPrefix(preferred) }) {
            completionPausedUntil = .distantPast
        }
        return Self.union(bridged, direct)
    }

    /// How long a completion that could not help waits before the next try.
    static let completionPause: TimeInterval = 30 * 60

    /// Union by id, the second answer winning. Measured, the direct answer is a
    /// superset of the language server's, but a union loses nothing if that
    /// stops being true.
    static func union(_ first: [LimitWindow], _ second: [LimitWindow]) -> [LimitWindow] {
        var merged: [LimitWindow] = []
        var indexByID: [String: Int] = [:]
        for window in first + second {
            if let existing = indexByID[window.id] {
                merged[existing] = window
            } else {
                indexByID[window.id] = merged.count
                merged.append(window)
            }
        }
        return merged
    }

    /// Ask for the account's quota, returning nil when it is not allowed to.
    private func quota(token: String, project: String? = nil, isACP: Bool = false) async throws -> [LimitWindow]? {
        let candidateEndpoints = isACP ? [prodQuotaEndpoint, quotaEndpoint] : [quotaEndpoint, prodQuotaEndpoint]
        for url in candidateEndpoints {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let ua = isACP
                ? "antigravity/acp/1.4.1 (aidev_client; os_type=darwin; arch=arm64; proxy_client=antigravity/sdk)"
                : "antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)"
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
            request.setValue("ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI", forHTTPHeaderField: "Client-Metadata")
            let bodyObj: [String: Any] = (project != nil && !project!.isEmpty) ? ["project": project!] : [:]
            request.httpBody = try? JSONSerialization.data(withJSONObject: bodyObj)
            request.timeoutInterval = 15

            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                let parsed = Self.windows(in: data)
                if !parsed.isEmpty { return parsed }
            }
        }
        return nil
    }

    /// Turns a quota summary into standard limit windows.
    nonisolated static func windows(in data: Data, now: Date = Date()) -> [LimitWindow] {
        AntigravityQuotaParser.parse(data, now: now)
    }

    /// Where oh-my-pi (omp) keeps its credentials and its usage history.
    static let ompDatabaseURL = URL(fileURLWithPath: ("~/.omp/agent/agent.db" as NSString).expandingTildeInPath)

    /// The last quota omp read for this account, for when nothing live answers.
    ///
    /// omp records every usage fetch in `usage_history` (`recorded_at, provider,
    /// account_key, email, account_id, limit_id, label, window_label,
    /// used_fraction, status, resets_at`, times in milliseconds). The query has
    /// to name those columns: asking for any other one fails to prepare, and the
    /// fallback then returns nothing on every Mac.
    ///
    /// `recordedAt` is when omp took the newest reading used, so the caller can
    /// say how old it is instead of passing history off as a live answer.
    ///
    /// Left out, each because it would report a number that is not this
    /// family's current one:
    /// - a row whose window has reset since omp read it, and a row with no
    ///   reset time that is more than a week old;
    /// - omp's `gemini-argon-` buckets, since Argon's weekly allowance is its
    ///   own and folding it into the Gemini slot would show Argon's number as
    ///   Gemini's;
    /// - the `default` counter, which omp uses for a quota it could not place
    ///   in any family.
    static func ompUsage(forEmail email: String? = nil,
                         databaseURL: URL = ompDatabaseURL,
                         now: Date = Date()) -> (windows: [LimitWindow], recordedAt: Date?) {
        guard let db = SQLiteStore.open(databaseURL) else { return ([], nil) }
        defer { sqlite3_close(db) }

        var targetEmail = email
        if targetEmail == nil {
            targetEmail = SQLiteStore.rows(in: db, sql: """
                SELECT email FROM usage_history
                WHERE provider = 'google-antigravity' AND email IS NOT NULL AND email != ''
                ORDER BY recorded_at DESC, id DESC LIMIT 1;
                """).first
        }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let weekAgoMs = nowMs - 7 * 86_400_000
        let filtered = !(targetEmail ?? "").isEmpty
        let sql = """
        SELECT limit_id, label, window_label, used_fraction, resets_at, recorded_at
        FROM usage_history
        WHERE provider = 'google-antigravity'
          AND used_fraction IS NOT NULL
          AND (resets_at > ?1 OR (resets_at IS NULL AND recorded_at > ?2))
          AND limit_id NOT LIKE '%:gemini-argon-%'\(filtered ? "\n  AND email = ?3 COLLATE NOCASE" : "")
        ORDER BY recorded_at DESC, id DESC
        LIMIT 30;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ([], nil) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, nowMs)
        sqlite3_bind_int64(stmt, 2, weekAgoMs)
        if filtered, let targetEmail {
            sqlite3_bind_text(stmt, 3, targetEmail, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        var latestByID: [String: (window: LimitWindow, recordedAt: Int64)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let limitText = sqlite3_column_text(stmt, 0) else { continue }
            let limitID = String(cString: limitText)
            let rawLabel = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let windowLabel = sqlite3_column_text(stmt, 2).map { String(cString: $0).lowercased() } ?? ""
            let usedFraction = max(0, min(1, sqlite3_column_double(stmt, 3)))
            let resetsAtMs = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? sqlite3_column_double(stmt, 4) : 0
            let resetsAt = resetsAtMs > 0 ? Date(timeIntervalSince1970: resetsAtMs / 1000) : nil
            let recordedAt = sqlite3_column_int64(stmt, 5)

            // `google-antigravity:<counter>:<tier>:<bucket or window>`
            let parts = limitID.split(separator: ":", omittingEmptySubsequences: false)
            let counter = parts.count > 1 ? String(parts[1]) : ""
            let isGemini: Bool
            switch counter {
            case "google": isGemini = true
            case "anthropic", "openai": isGemini = false
            case "default": continue
            default:
                guard rawLabel.contains("Google") else { continue }
                isGemini = true
            }
            let isWeekly = windowLabel.contains("week")
            let id = isGemini ? (isWeekly ? "gemini-weekly" : "gemini-hourly") : (isWeekly ? "3p-weekly" : "3p-hourly")

            // Rows come newest first. One fetch can write several rows for a
            // slot (one per tier); like the live reader, the most used of
            // those is the slot's reading. An older fetch never replaces it.
            if let kept = latestByID[id] {
                guard kept.recordedAt == recordedAt, usedFraction > (kept.window.usedFraction ?? 0) else { continue }
            }
            latestByID[id] = (LimitWindow(
                id: id,
                group: isGemini ? L10n.t("Gemini Models") : L10n.t("Claude and GPT models"),
                label: isWeekly ? L10n.t("Weekly Limit") : L10n.t("5-hour Limit"),
                usedFraction: usedFraction,
                resetsAt: resetsAt,
                // omp also files its Daily windows here, so the short slot
                // claims no length rather than a 5 hours it may not have.
                duration: isWeekly ? 7 * 86400 : nil), recordedAt)
        }

        let windows = ["gemini-hourly", "gemini-weekly", "3p-hourly", "3p-weekly"].compactMap { latestByID[$0]?.window }
        let newest = latestByID.values.map(\.recordedAt).max()
        return (windows, newest.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
    }

    /// How old an omp reading may be before it is shown as stale. omp reads
    /// usage on its own schedule, so anything older than a few refreshes is
    /// history rather than the current state.
    static let ompFreshness: TimeInterval = 10 * 60

    /// Read the plan name from `loadCodeAssist`.
    static func tier(in data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Gemini"
        }
        if let current = json["currentTier"] as? [String: Any],
           let name = current["name"] as? String, !name.isEmpty {
            return name
        }
        if let allowed = json["allowedTiers"] as? [[String: Any]] {
            if let def = allowed.first(where: { ($0["isDefault"] as? Bool) == true }),
               let name = def["name"] as? String, !name.isEmpty {
                return name
            }
            if let first = allowed.first,
               let name = first["name"] as? String, !name.isEmpty {
                return name
            }
        }
        return "Gemini"
    }
}
