import Foundation

/// Tokens spent against a bare `GEMINI_API_KEY`, added up from the logs the
/// tools that made the calls keep for themselves.
///
/// There is no endpoint behind this one. Google meters an API key on the
/// billing account and publishes nothing an app could read, so the only record
/// of a call is the one Gemini CLI, OpenCode, Hermes or Antigravity CLI wrote
/// after making it. Each of those keeps its own count, each counts a slightly
/// different thing, and the four readers next door reconcile that; what is left
/// here is adding them up and saying which log each row came from, because a
/// single unattributable total is impossible to check against anything.
///
/// Nothing is cached: every fetch re-reads four local paths, which is
/// prompt-free — no keychain is involved, and no network is either.
actor GeminiAPIProvider: UsageProvider {
    /// Spelled once, because the pure snapshot builder below is static and
    /// cannot reach the instance. An id that drifted from the one the archive
    /// and the disconnected set are keyed by would lose the user's state.
    fileprivate static let providerID = "gemini-api"
    fileprivate static let providerName = "Gemini API"

    nonisolated let id = GeminiAPIProvider.providerID
    nonisolated let displayName = GeminiAPIProvider.providerName
    // The Gemini sparkle, not Antigravity's arch: this row is the model API,
    // and the arch is the editor's own mark, which the neighbouring provider
    // already wears.
    nonisolated let glyph = ProviderGlyph.geminiSpark

    nonisolated private let cliRoot: URL
    nonisolated private let openCodeDatabase: URL
    nonisolated private let hermesDatabase: URL
    nonisolated private let antigravityStores: [URL]
    nonisolated private let settingsFile: URL
    /// Read fresh on every fetch rather than captured once: the user can change
    /// it in Settings while the app runs, and the ring has to follow.
    private let budget: @Sendable () -> Int?

    /// The tools the last fetch actually found, for the settings row.
    /// `nonisolated(unsafe)` because `account()` reads it off the actor, the
    /// same bargain `GLMProvider.lastKnownPlan` makes; the worst a race can do
    /// is name yesterday's tools for one row-draw.
    nonisolated(unsafe) private var lastTools: [String] = []

    init(
        cliRoot: URL = GeminiCLIUsage.sessionsRoot,
        openCodeDatabase: URL = OpenCodeGeminiUsage.database,
        hermesDatabase: URL = HermesGeminiUsage.database,
        antigravityStores: [URL] = AntigravityCLIGeminiUsage.stores,
        settingsFile: URL = GeminiAPICredentials.settingsFile,
        budget: @escaping @Sendable () -> Int?
    ) {
        self.cliRoot = cliRoot
        self.openCodeDatabase = openCodeDatabase
        self.hermesDatabase = hermesDatabase
        self.antigravityStores = antigravityStores
        self.settingsFile = settingsFile
        self.budget = budget
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("There is nothing to sign in to: the count is added up from what Gemini CLI, OpenCode, Hermes and Antigravity CLI recorded about their own calls. Your API key is never read."))
    }

    nonisolated func account() -> ProviderAccount? {
        GeminiAPICredentials.account(
            tools: lastTools,
            authType: GeminiAPICredentials.authType(at: settingsFile)
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let now = Date()
        let sources = sources(now: now)
        // Not an error and not a missing sign-in: none of the four tools has
        // ever run here, so there is genuinely nothing being metered.
        guard !sources.isEmpty else {
            throw UsageProviderError.nothingMetered(
                L10n.t("No Gemini CLI, OpenCode, Hermes or Antigravity CLI sessions found"))
        }
        lastTools = sources.map(\.name)
        return Self.snapshot(sources: sources, budget: budget(), now: now)
    }

    /// One entry per tool that has state on disk, in a fixed order so the
    /// tooltip's rows do not shuffle between refreshes. A reader answering
    /// `nil` means its tool was never installed, which is not the same as a
    /// zero and must not be shown as one.
    private func sources(now: Date) -> [GeminiTokenSource] {
        let readings: [(id: String, name: String, usage: GeminiTokenUsage?)] = [
            ("cli", "Gemini CLI", GeminiCLIUsage.read(root: cliRoot, now: now)),
            ("opencode", "OpenCode", OpenCodeGeminiUsage.read(database: openCodeDatabase, now: now)),
            ("hermes", "Hermes", HermesGeminiUsage.read(database: hermesDatabase, now: now)),
            ("antigravity-cli", "Antigravity CLI",
             AntigravityCLIGeminiUsage.read(stores: antigravityStores, now: now))
        ]
        return readings.compactMap { reading in
            reading.usage.map {
                GeminiTokenSource(id: reading.id, name: reading.name, usage: $0)
            }
        }
    }

    /// The whole visible surface, kept pure so it can be tested without a disk.
    static func snapshot(
        sources: [GeminiTokenSource],
        budget: Int?,
        now: Date = Date()
    ) -> ProviderSnapshot {
        // A budget of zero or less is the same statement as no budget, and
        // dividing by it would draw an infinite ring.
        let budget = budget.flatMap { $0 > 0 ? $0 : nil }
        let total = sources.reduce(GeminiTokenUsage.zero) { $0.adding($1.usage) }
        let calendar = GeminiTokenUsage.calendar
        let month = calendar.dateInterval(of: .month, for: now)

        // The figures use the token card's formatter so this card reads like
        // Claude's, and they travel as `usedText` rather than `detail` so the
        // ring prints the same figure as the row.
        var windows = [
            LimitWindow(
                id: "month",
                label: budget == nil
                    ? "Tokens this month · billed per token, no limit" : "Tokens this month",
                usedFraction: budget.map { Double(total.tokensThisMonth) / Double($0) },
                used: total.tokensThisMonth,
                usedText: UsageFormat.tokens(total.tokensThisMonth),
                detail: budget.map {
                    String(format: L10n.t("%@ / %@ tokens"),
                           UsageFormat.tokens(total.tokensThisMonth), UsageFormat.tokens($0))
                },
                resetsAt: month?.end,
                duration: month?.duration
            ),
            LimitWindow(
                id: "today",
                label: "Tokens today",
                used: total.tokensToday,
                usedText: UsageFormat.tokens(total.tokensToday),
                resetsAt: calendar.dateInterval(of: .day, for: now)?.end
            )
        ]
        // The rows that make the headline checkable: which tool spent what.
        windows += sources.map {
            LimitWindow(
                id: $0.id,
                label: "\($0.name) · this month",
                used: $0.usage.tokensThisMonth,
                usedText: UsageFormat.tokens($0.usage.tokensThisMonth)
            )
        }

        return ProviderSnapshot(
            id: providerID,
            displayName: providerName,
            glyph: .geminiSpark,
            // `.manual` once there is a budget, because the ceiling the ring
            // fills against is the user's own guess, not a limit Google set.
            // Either way the number is ours, so the tooltip keeps its `~`.
            fidelity: budget == nil ? .derived : .manual,
            status: .ok,
            windows: windows,
            headlineID: "month",
            block: nil
        )
    }
}
