import Foundation
import os

/// Reads Kiro usage from `kiro-cli /usage`, then optionally asks GetUsageLimits
/// for the plan and overage ceilings the CLI cannot state.
///
/// The CLI owns the token and its refresh. This never writes sqlite and never
/// mints a new session: an expired or missing token just skips the enrichment
/// and keeps the numbers `/usage` already printed. The numbers are Kiro's, so
/// this is `.official`.
actor KiroProvider: UsageProvider {
    nonisolated let id = "kiro"
    nonisolated let displayName = "Kiro"
    nonisolated let glyph = ProviderGlyph.kiro

    private let session: URLSession
    private let archive: UsageArchive
    /// Injected `/usage` text. Nil in production: the binary is located and
    /// asked at fetch time, so installing kiro-cli without a relaunch still
    /// works.
    nonisolated private let cli: (@Sendable () throws -> String)?
    nonisolated private let database: URL
    /// Tests stub GetUsageLimits here. Production derives the host from the
    /// profile ARN in sqlite.
    nonisolated private let authURL: URL?
    /// Where kiro-cli lives. Injected so a test can say "not installed"
    /// without this spawning whatever the developer happens to have.
    nonisolated private let locateBinary: @Sendable () -> URL?

    /// Set when GetUsageLimits returns 429. Until it passes, enrichment is
    /// skipped — the CLI reading is still good, and polling into the limit is
    /// how you stay limited.
    private var retryNoEarlierThan: Date?
    private var consecutiveRateLimits = 0

    /// The plan `/usage` last named, for the settings row.
    nonisolated(unsafe) private var lastKnownPlan: String?

    init(session: URLSession = .shared,
         cli: (@Sendable () throws -> String)? = nil,
         database: URL = KiroLimits.stateDatabaseURL(),
         archive: UsageArchive = UsageArchive(),
         authURL: URL? = nil,
         locateBinary: @escaping @Sendable () -> URL? = { KiroCLI.locateBinary() }) {
        self.session = session
        self.cli = cli
        self.database = database
        self.archive = archive
        self.authURL = authURL
        self.locateBinary = locateBinary
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: id)
    }

    /// kiro-cli is optional in the same way Devin's sources are: a Mac that
    /// never installed it should not grow a sign-in ring. Once the binary or
    /// its session is present, a logged-out `/usage` is a real `needsAuth`.
    nonisolated var isVisibleWhenAbsent: Bool {
        KiroCredentials.account(binary: presenceBinary(), database: database) != nil
    }

    nonisolated var signInRoute: SignInRoute {
        .command("kiro-cli login", name: "Kiro", install: URL(string: "https://kiro.dev/cli/"))
    }

    nonisolated func forgetCachedCredential() {
        // Nothing is cached: the session is re-read from disk on every fetch,
        // which is prompt-free, unlike a keychain read.
    }

    nonisolated func account() -> ProviderAccount? {
        guard KiroCredentials.account(binary: presenceBinary(), database: database) != nil else {
            return nil
        }
        return ProviderAccount(
            label: nil,
            plan: lastKnownPlan,
            source: "Kiro CLI",
            manageURL: URL(string: "https://app.kiro.dev/account/usage")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let text = try await readUsage()
        var reading = try KiroUsage.parseCLIOutput(text)
        // Enrichment is optional. A 5xx, a 429, a parse failure — none of
        // those may throw away the `/usage` windows already in hand. The CLI
        // does not share GetUsageLimits' rate limit, so a 429 in particular
        // must not surface as `rateLimited` and darken a ring the CLI filled.
        do {
            if let limits = try await enrich() {
                apply(limits, to: &reading)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.usage.debug("kiro: keeping CLI windows after enrichment failure: \(error.localizedDescription, privacy: .public)")
        }
        lastKnownPlan = reading.plan

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: reading.windows,
            // Credits only. Bonus is a wallet in the tooltip, not a weekly
            // window — wiring it to `weeklyID` would draw a second ring for a
            // number that is not a week.
            headlineID: "credits",
            plan: reading.plan?.nonEmptyPlan
        )
    }

    /// Locate kiro-cli and ask `/usage`, or use the injected output a test
    /// supplied so this never has to spawn.
    private func readUsage() async throws -> String {
        let work: @Sendable () throws -> String
        if let cli {
            work = cli
        } else {
            guard let binary = locateBinary() else {
                // Not installed is not signed out. `needsAuth` would put a
                // login prompt on a Mac that has never had kiro-cli.
                throw UsageProviderError.nothingMetered(L10n.t("Kiro CLI is not installed"))
            }
            let runner = KiroCLI(binary: binary, output: { try KiroCLI.run(binary: binary) })
            work = { try runner.output() }
        }
        // Reading a pipe blocks the thread it is on; this actor also does the
        // HTTP enrichment and must not sit behind that.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Best-effort GetUsageLimits. Failure — missing token, 401, 5xx, parse —
    /// leaves the CLI windows standing. A 429 backs off the enrichment only.
    private func enrich() async throws -> KiroLimits.CreditLimits? {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            return nil
        }
        guard let request = limitsRequest() else { return nil }

        let data: Data
        let response: URLResponse
        do {
            Log.usage.debug("POST GetUsageLimits")
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.usage.debug("GetUsageLimits failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("GetUsageLimits answered \(status)")
        if status == 429 {
            consecutiveRateLimits += 1
            let wait = Self.backoff(
                forAttempt: consecutiveRateLimits - 1,
                retryAfter: Self.retryAfter(from: response)
            )
            retryNoEarlierThan = Date().addingTimeInterval(wait)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            Log.usage.notice("kiro: GetUsageLimits rate limited, next enrichment in \(wait, format: .fixed(precision: 0))s")
            // Nil, not `rateLimited`: that error would discard the CLI
            // snapshot `fetchSnapshot` already parsed.
            return nil
        }
        guard (200..<300).contains(status) else { return nil }

        consecutiveRateLimits = 0
        retryNoEarlierThan = nil
        archive.saveBackoffUntil(nil, providerID: id)
        return try? KiroLimits.parse(data)
    }

    private func limitsRequest() -> URLRequest? {
        let token = KiroLimits.loadAccessToken(from: database)
        let arn = KiroLimits.loadProfileARN(from: database)

        let url: URL
        if let authURL {
            // Injected endpoint: skip only when there is no sqlite file at all,
            // which is the "CLI is enough, do not touch the network" case.
            guard FileManager.default.fileExists(atPath: database.path) else { return nil }
            url = authURL
        } else {
            // Expired or missing token: skip enrichment, keep the CLI numbers.
            guard let token, !token.isEmpty,
                  let arn,
                  let endpoint = KiroLimits.endpoint(forARN: arn)
            else { return nil }
            url = endpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("AmazonCodeWhispererService.GetUsageLimits",
                         forHTTPHeaderField: "X-Amz-Target")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["profileArn": arn ?? ""])
        request.timeoutInterval = 10
        return request
    }

    /// Plan credits come from the API when it can split them from bonus spend;
    /// bonus stays the CLI's; overage is API-only because the CLI never states
    /// the cap. Windows are patched by id so a credits rewrite cannot drop
    /// the bonus wallet GetUsageLimits never names.
    private func apply(_ limits: KiroLimits.CreditLimits, to reading: inout KiroUsage.Reading) {
        let bonus = reading.windows.filter { $0.id == "bonus" }

        if limits.planLimit > 0, !limits.hasUnseparatedBonus {
            let existing = reading.windows.first { $0.id == "credits" }
            let reset = limits.resetAt ?? existing?.resetsAt
            let credits = LimitWindow(
                id: "credits",
                label: existing?.label ?? L10n.t("Credits"),
                usedFraction: limits.planUsed / limits.planLimit,
                used: Int(limits.planUsed.rounded()),
                resetsAt: reset,
                duration: existing?.duration ?? (reset == nil ? nil : 30 * 86400)
            )
            if let index = reading.windows.firstIndex(where: { $0.id == "credits" }) {
                reading.windows[index] = credits
            } else {
                reading.windows.insert(credits, at: 0)
            }
            reading.hasUsageMetrics = true
        }

        if let cap = limits.overageCap, cap > 0 {
            let overage = LimitWindow(
                id: "overage",
                label: L10n.t("Overage"),
                usedFraction: limits.overageUsed / cap,
                used: Int(limits.overageUsed.rounded()),
                resetsAt: limits.resetAt
            )
            if let index = reading.windows.firstIndex(where: { $0.id == "overage" }) {
                reading.windows[index] = overage
            } else {
                reading.windows.append(overage)
            }
        }

        // GetUsageLimits folds bonus spend into CREDIT.currentUsage and has
        // no wallet of its own. If a rewrite dropped the CLI's bonus window,
        // put it back after credits — the order `/usage` prints.
        if !bonus.isEmpty, !reading.windows.contains(where: { $0.id == "bonus" }) {
            let index = reading.windows.firstIndex(where: { $0.id == "credits" }).map { $0 + 1 }
                ?? 0
            reading.windows.insert(contentsOf: bonus, at: min(index, reading.windows.count))
        }
    }

    /// Injected CLI counts as installed so tests never consult the machine's
    /// own kiro-cli. Production locates it.
    nonisolated private func presenceBinary() -> URL? {
        if cli != nil { return URL(fileURLWithPath: "/injected-kiro-cli") }
        return locateBinary()
    }

    /// How long to wait after a 429 — a minute, doubling per consecutive
    /// limit, capped so it always recovers on its own. The server's own hint
    /// is honoured only as a floor-raiser.
    static func backoff(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let floor: TimeInterval = 60
        let ceiling: TimeInterval = 15 * 60
        let doubled = floor * pow(2, Double(min(attempt, 4)))
        return min(ceiling, max(doubled, retryAfter ?? 0))
    }

    /// `Retry-After` is either a number of seconds or an HTTP date.
    static func retryAfter(from response: URLResponse?) -> TimeInterval? {
        guard let header = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces)
        else { return nil }

        if let seconds = TimeInterval(header) { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
