import Foundation

/// How much to trust a provider's numbers. The UI never presents a derived or
/// manual figure as if a vendor had published it.
extension String {
    /// Nil when this would be an empty plan line on the card.
    var nonEmptyPlan: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum Fidelity: String, Codable, Equatable {
    case official
    case derived
    case manual

    /// Prefix shown in front of a percentage that we worked out ourselves.
    var qualifier: String { self == .official ? "" : "~" }
}

/// A provider-reported money balance. The percentage is derived from these
/// exact account amounts; the amounts themselves come from the provider.
struct UsageMoneyBreakdown: Codable, Equatable, Sendable {
    let currency: String
    let spent: Double
    let remaining: Double

    var funded: Double { spent + remaining }

    var spentFraction: Double {
        guard funded > 0 else { return 0 }
        return min(max(spent / funded, 0), 1)
    }

    /// The bar's headline: spent by default, what is left when the notch is
    /// set that way. The left half derives from the *rounded* spent figure,
    /// the same rule as the window rows, so the two never disagree by a
    /// point. The Spent/Remaining/Funded stats below stay labeled either way.
    func headlineText(showingRemaining: Bool) -> String {
        showingRemaining
            ? "\(Percent.halves(for: spentFraction).left)% left"
            : "\(Percent.text(for: spentFraction))% used"
    }
}

enum ProviderStatus: Equatable {
    case ok
    case stale(since: Date)
    case needsAuth
    /// The owning app emptied its own credential. Distinct from `needsAuth`
    /// because the last reading is kept — see `UsageProviderError`.
    case signedOutByOwner
    /// macOS was asked for a credential that exists, and refused.
    case accessDenied
    case unsupported(String)
    case error(String)

    var isStale: Bool { if case .stale = self { return true }; return false }

    /// When the reading behind this status was actually taken.
    var staleSince: Date? { if case .stale(let since) = self { return since }; return nil }
}

/// How percentages read.
///
/// Whole percents above one — "12%", "104%" — because decimals there are
/// noise. Below one, whole percents collapse a real reading into "0%", the one
/// number that looks most like "nothing used", so both halves gain a tenth of
/// a percent and still add up: 0.3% used is 99.7% left. A tenth of nothing
/// says so rather than pretending to be zero.
enum Percent {
    /// The two halves of a used-fraction, as display text.
    static func halves(for fraction: Double) -> (used: String, left: String) {
        let value = fraction * 100
        let fractional = (value > 0 && value < 1) || (value > 99 && value < 100)
        guard fractional else {
            // The left half derives from the *rounded* used half, not from the
            // raw value — 9.5% used is "10% Used · 90% left", because that is
            // how the dashboard the user is comparing against does the maths.
            let used = Int(value.rounded())
            return ("\(used)", "\(max(0, 100 - used))")
        }
        let left = max(0, 100 - value)
        // "<0.1" has no number to subtract from a hundred, so the far half
        // makes the same claim from its own end: ">99.9".
        return (small(value), left > 99.9 ? ">99.9" : small(left))
    }

    /// One percentage, as display text — the ring's label.
    static func text(for fraction: Double) -> String {
        let value = fraction * 100
        guard value > 0, value < 1 else { return "\(Int(value.rounded()))" }
        return small(value)
    }

    /// One percentage with no decimals, for the menu bar, where a tenth is
    /// noise at a glance. Rounding never lands on the two figures that would
    /// say something else happened: "0" when a little has been used, or "100"
    /// while there is still room.
    static func whole(for fraction: Double) -> String {
        let value = max(0, fraction * 100)
        if value > 0, value < 1 { return "<1" }
        if value > 99, value < 100 { return "99" }
        return "\(Int(value.rounded()))"
    }

    /// The share of the allowance the meters draw: spent by default, what is
    /// left when the notch is set that way. The one rule behind the ring's
    /// sweep, the card's bars, and every flipped figure — callers clamp to
    /// what they draw, so an overspent limit reads empty rather than
    /// negative. Bands and pace never come through here: how bad a reading
    /// is, and whether it is ahead of the clock, are questions about what
    /// was spent, whichever end the meters draw from.
    static func metered(_ fraction: Double, showingRemaining: Bool) -> Double {
        showingRemaining ? 1 - fraction : fraction
    }

    private static func small(_ value: Double) -> String {
        if value <= 0 { return "0" }
        let tenths = (value * 10).rounded() / 10
        if tenths < 0.1 { return "<0.1" }
        if tenths > 99.9 { return ">99.9" }
        // Fixed locale: the decimal point is not up to the system settings,
        // any more than "%" is.
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), tenths)
    }
}

/// One metered window a provider exposes — Claude has two (the rolling session
/// and the longer all-models window), others have one.
struct LimitWindow: Identifiable, Codable, Equatable {
    let id: String
    let group: String?
    let label: String
    /// 0...1+, where 1 means the limit is spent. Nil when the provider reports
    /// what is left but never says what the limit was — Perplexity does exactly
    /// this, and a percentage would have to invent the denominator.
    let usedFraction: Double?
    /// How many are left, when that is what the provider reports.
    let remaining: Int?
    /// How many have been spent, when the provider counts up rather than down
    /// and never states the ceiling. Cursor does this.
    let used: Int?
    /// Optional provider-specific value for count-only rows.
    let detail: String?
    /// Structured money data for providers whose account is metered in money.
    let money: UsageMoneyBreakdown?
    /// Optional display override for `used` — used when the raw count would
    /// be the wrong unit (e.g. a dollar balance formatted as "$14.28").
    let usedText: String?
    /// Nil when the provider does not say when the window rolls over.
    let resetsAt: Date?

    /// Exact cycle length when known; optional to keep older archives readable.
    let duration: TimeInterval?
    var bandOverride: UsageBand? = nil
    var prefersUsedText: Bool = false

    init(id: String, group: String? = nil, label: String, usedFraction: Double? = nil,
         remaining: Int? = nil, used: Int? = nil, usedText: String? = nil, detail: String? = nil,
         money: UsageMoneyBreakdown? = nil, resetsAt: Date? = nil,
         duration: TimeInterval? = nil, bandOverride: UsageBand? = nil,
         prefersUsedText: Bool = false) {
        self.id = id
        self.group = group
        self.label = label
        self.usedFraction = usedFraction
        self.remaining = remaining
        self.used = used
        self.usedText = usedText
        self.detail = detail
        self.money = money
        self.resetsAt = resetsAt
        self.duration = duration
        self.bandOverride = bandOverride
        self.prefersUsedText = prefersUsedText
    }

    enum CodingKeys: String, CodingKey {
        case id, group, label, usedFraction, remaining, used, detail, money, usedText, resetsAt, duration, bandOverride, prefersUsedText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.group = try container.decodeIfPresent(String.self, forKey: .group)
        self.label = try container.decode(String.self, forKey: .label)
        self.usedFraction = try container.decodeIfPresent(Double.self, forKey: .usedFraction)
        self.remaining = try container.decodeIfPresent(Int.self, forKey: .remaining)
        self.used = try container.decodeIfPresent(Int.self, forKey: .used)
        self.detail = try container.decodeIfPresent(String.self, forKey: .detail)
        self.money = try container.decodeIfPresent(UsageMoneyBreakdown.self, forKey: .money)
        self.usedText = try container.decodeIfPresent(String.self, forKey: .usedText)
        self.resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        self.bandOverride = try container.decodeIfPresent(UsageBand.self, forKey: .bandOverride)
        self.prefersUsedText = try container.decodeIfPresent(Bool.self, forKey: .prefersUsedText) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(usedFraction, forKey: .usedFraction)
        try container.encodeIfPresent(remaining, forKey: .remaining)
        try container.encodeIfPresent(used, forKey: .used)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(money, forKey: .money)
        try container.encodeIfPresent(usedText, forKey: .usedText)
        try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(bandOverride, forKey: .bandOverride)
        if prefersUsedText {
            try container.encode(prefersUsedText, forKey: .prefersUsedText)
        }
    }

    /// Whether this is a rolling five-hour window — the limit a coding session
    /// runs into first. Read from the length the provider reported rather than
    /// from an id, because every vendor names it differently: Claude's
    /// `session`, Codex's `primary`, Kimi's `rolling`.
    var isFiveHour: Bool {
        guard let duration else { return false }
        // A minute's slack: some vendors send the window as a start and an
        // end, and the difference is not always a whole number of seconds.
        return abs(duration - 5 * 3600) < 60
    }

    /// A count short enough to sit inside a 44 pt ring.
    ///
    /// Requests and credits are three or four digits and print verbatim; token
    /// counts run to seven, and "651061" under the ring is unreadable at that
    /// width. The threshold is 10 000 so no existing provider's number changes.
    static func compact(_ count: Int) -> String {
        if count < 10_000 { return "\(count)" }
        if count < 1_000_000 { return "\(count / 1_000)k" }
        return String(format: "%.1fM", Double(count) / 1_000_000)
    }

    /// What the tooltip says on the line under the bar.
    var summary: String { summary() }

    /// Both ends stay on the line either way — the card is the detailed view,
    /// and dropping a figure there would hide information. The setting only
    /// decides which end leads: the remaining figure first when the notch is
    /// set that way, so the bar, the line, and the figure under the ring all
    /// read from the same end.
    func summary(locale: Locale = L10n.locale, showingRemaining: Bool = false) -> String {
        if let usedFraction {
            // Both ends of the same figure. Vendors do not agree on which to
            // show — Codex writes "87% remaining", Claude writes "% used" — so
            // a notch that picks one side leaves the user converting in their
            // head, and "12% Used" beside Codex's "87% remaining" reads as two
            // different numbers rather than one seen from either end. That is
            // what made a correct reading look wrong.
            let halves = Percent.halves(for: usedFraction)
            if showingRemaining {
                return L10n.t("\(halves.left)% left · \(halves.used)% Used", locale: locale)
            }
            return L10n.t("\(halves.used)% Used · \(halves.left)% left", locale: locale)
        }
        if let remaining {
            return remaining < 10_000
                ? L10n.t("\(remaining) left", locale: locale)
                : L10n.t("\(Self.compact(remaining)) left", locale: locale)
        }
        if let used {
            if let usedText { return usedText }
            return used < 10_000
                ? L10n.t("\(used) used", locale: locale)
                : L10n.t("\(Self.compact(used)) used", locale: locale)
        }
        return L10n.t("No reading", locale: locale)
    }
}

/// A limit that has been *reached*, even where the headline still shows room.
///
/// Vendors meter some capabilities separately from the plan's main allowance,
/// so "84% left" and "paused until 4:13 PM" are both true at once. A ring that
/// only knows the headline reports the first and hides the second, which is
/// the reading that actually stops you working.
struct UsageBlock: Equatable {
    /// What is paused, in the vendor's own terms.
    let reason: String
    /// When it lifts, where the vendor says.
    let resetsAt: Date?
    /// Set when the store derived this block from a spent weekly allowance
    /// rather than a provider reporting a pause. The ring and the card treat
    /// both the same; the limit watcher tells them apart, because a spent
    /// week has its own alert and must not also fire the session one.
    var isWeeklyExhaustion = false

    /// The line the tooltip leads with.
    func summary(now: Date = Date(), calendar: Calendar = .current,
                 locale: Locale = L10n.locale) -> String {
        guard let resetsAt, resetsAt > now else { return reason }
        let formatter = ResetCopy.formatter(for: calendar)
        formatter.locale = locale
        // The same clock the vendor's own banner uses — "4:13 PM" — rather
        // than a countdown, because that is what you are waiting for. `j`
        // rather than `h` so the hour cycle is the region's, as in
        // `ResetCopy`; a 12-hour region still reads "4:13 PM".
        let template = ResetCopy.daysApart(from: now, to: resetsAt,
                                           calendar: calendar) >= 1
            ? "E j:mm" : "j:mm"
        formatter.setLocalizedDateFormatFromTemplate(template)
        return L10n.t("\(reason) until \(formatter.string(from: resetsAt))", locale: locale)
    }
}

struct ProviderSnapshot: Identifiable, Equatable {
    let id: String
    /// The provider's own name, or the one chosen for the account in
    /// Settings; the store swaps it in before anything reads the snapshot.
    var displayName: String
    let glyph: ProviderGlyph
    let fidelity: Fidelity
    var status: ProviderStatus
    var windows: [LimitWindow]
    /// Which window the ring means, declared by the provider rather than left to
    /// position. Without it the headline is "whichever window happens to be
    /// first", and a window dropping out of the response silently promotes
    /// another one — the ring keeps its shape and quietly changes its subject.
    var headlineID: String?
    /// Which window the weekly ring draws, when it is switched on. Declared
    /// rather than derived — see `weeklyWindow`.
    var weeklyID: String?
    /// Set when something is blocked right now. Deliberately separate from the
    /// windows: it is not a measurement, it is a door being shut.
    var block: UsageBlock?
    var kind: ProviderKind = .usage
    var localRuntime: LocalRuntimeReading?
    var localModel: LocalRuntimeReading.Model?
    var localPerformance: LocalModelPerformance?
    var showsLocalPerformance = false
    /// How full the loaded context was on the last request, from the runtime's
    /// own log. The local ring's arc: a window filling up is the one fraction
    /// a local model has, where a cloud ring has a quota.
    var localContextFraction: Double?
    /// Today's tokens and requests and the shape of the last response, when
    /// the runtime logs them. Read by the tooltip; absent for runtimes that
    /// do not.
    var localLedger: LocalTokenLedger.Summary?
    /// The runtime measures responses itself, so speed is shown without the
    /// Ollama relay switch.
    var localRuntimeMeasuresSpeed = false
    /// A model cell has its own display preference, but polling belongs to the
    /// runtime that supplied it.
    var sourceProviderID: String?
    var customIconFilename: String?

    var providerID: String { sourceProviderID ?? id }

    var notchSnapshots: [ProviderSnapshot] {
        guard kind == .localRuntime, localModel == nil else { return [self] }
        return (localRuntime?.models ?? []).map { model in
            ProviderSnapshot(id: "\(id):model:\(model.id)", displayName: displayName,
                             glyph: model.brand?.glyph ?? glyph,
                             fidelity: fidelity, status: status, windows: [],
                             kind: kind, localModel: model,
                             localRuntimeMeasuresSpeed: localRuntime?.measuresSpeed ?? false,
                             sourceProviderID: id)
        }
    }
    /// Codex's account-wide token activity, when its profile endpoint returned
    /// it. The optional top model is an enrichment from the desktop breakdown
    /// endpoint; it never changes the profile token buckets. Other providers
    /// leave this nil because they do not expose the same account-level data.
    var tokenUsage: CodexTokenUsage? = nil
    /// The account's named tier, when the provider publishes one. Shown under
    /// the tooltip title. Nil when there is nothing to name.
    var plan: String? = nil

    /// Unused rate-limit resets reported for this account.
    var resetCredits: UsageResetCredits? = nil

    /// Whether the tooltip has a reset-credit section to draw.
    ///
    /// The endpoint can successfully return an empty result. That is data,
    /// but it is not useful card content and must not reserve layout space.
    var hasAvailableResetCredits: Bool {
        availableResetCredits(at: Date()) != nil
    }
    func availableResetCredits(at now: Date) -> UsageResetCredits? {
        guard let credits = resetCredits?.unexpired(at: now), credits.availableCount > 0 else { return nil }
        return credits
    }

    /// Provider-owned online usage detail, such as DeepSeek's API key/model
    /// breakdown and daily token/cost series.
    var usageDetail: ProviderUsageDetail? = nil

    /// Locally sampled cumulative token usage for a custom endpoint.
    var customUsageHistory: [CustomEndpointUsageDay]? = nil

    /// The number on the cell: the provider's declared primary window — for
    /// Claude, the current session.
    ///
    /// Not the most-constrained window, which is what the design spec asks for.
    /// Picking whichever limit is highest means the headline silently changes
    /// meaning — session one minute, weekly the next — and disagrees with
    /// Claude's own panel, which always leads with the session.
    ///
    /// If the declared window is missing from the response the cell shows no
    /// reading rather than promoting a different one. A blank is honest; a
    /// weekly percentage wearing the session's place is not.
    var headline: LimitWindow? {
        guard let headlineID else { return windows.first }
        return windows.first { $0.id == headlineID }
    }

    var usedFraction: Double? { headline?.usedFraction }
    var bandOverride: UsageBand? { headline?.bandOverride }

    /// The five-hour window, where the provider has one: the headline when it
    /// is that window, otherwise the account's own.
    ///
    /// Found by length rather than taken from the headline, because the
    /// headline is not always it — the daily pace ring takes Claude's. Never
    /// a grouped window, though: a group is one model's or one feature's
    /// allowance, Codex's Spark for one, kept off the ring for the same reason
    /// it cannot stand for the account here.
    var fiveHourWindow: LimitWindow? {
        if let headline, headline.isFiveHour { return headline }
        return windows.first { $0.isFiveHour && $0.group == nil }
    }

    /// The provider-declared weekly allowance, whether or not another surface
    /// is already using it as its headline.
    ///
    /// Kept separate from `weeklyWindow`: the notch deliberately suppresses a
    /// duplicate second ring when the weekly allowance is already its headline,
    /// while compact summaries still need to know that a valid weekly reading
    /// exists alongside their own five-hour figure.
    var weeklyLimitWindow: LimitWindow? {
        guard let weeklyID else { return nil }
        return windows.first { $0.id == weeklyID }
    }

    /// The window the second ring draws, when one is switched on.
    ///
    /// Declared by the provider, exactly like `headlineID`, and for the same
    /// reason: the weekly window is called something different by everyone who
    /// has one — `weekly_all`, `secondary`, `weekly`, `gemini-weekly` — and a
    /// rule that guessed from durations would silently skip whichever provider
    /// had not filled that field in, with nothing on screen to say why.
    ///
    /// Nil means this provider has no second window worth a ring, which is a
    /// real answer rather than a missing one.
    var weeklyWindow: LimitWindow? {
        guard let weeklyLimitWindow else { return nil }
        // Never the window the headline is already drawing. Providers that pick
        // their headline by which limit is tightest — Antigravity does — will
        // sometimes land on the weekly one, and two rings reporting the same
        // number is worse than one: it reads as a second fact that happens to
        // agree, rather than as the same fact twice.
        guard weeklyID != headlineID else { return nil }
        return weeklyLimitWindow
    }

    /// Nil when there is no weekly window, or when the provider reports one
    /// without a denominator — the same rule the headline ring follows.
    var weeklyFraction: Double? { weeklyWindow?.usedFraction }

    /// The weekly allowance is spent, shutting the headline with it even
    /// where the headline still shows room. Nil unless the provider declared
    /// a weekly window and reported it spent — without a denominator there
    /// is no exhaustion to claim. A block the provider set itself is never
    /// replaced: its own pause outranks a derived one.
    var spentWeeklyBlock: UsageBlock? {
        guard block == nil,
              let weekly = weeklyLimitWindow,
              let used = weekly.usedFraction, used >= 1 else { return nil }
        return UsageBlock(reason: L10n.t("Weekly limit reached"), resetsAt: weekly.resetsAt,
                          isWeeklyExhaustion: true)
    }

    /// The snapshot with a spent week attached as a block, so every surface
    /// that reads `block` — ring, card, menu, phone — treats the headline as
    /// shut. Applied by the store on publication, before any derivation
    /// swaps the headline and weekly ids around.
    func blockingSpentWeek() -> ProviderSnapshot {
        guard let spent = spentWeeklyBlock else { return self }
        var snapshot = self
        snapshot.block = spent
        return snapshot
    }

    /// What the cell prints under the ring: the used percentage, unless the
    /// notch is set to show what is left instead.
    var headlineText: String { headlineText(showingRemaining: false) }

    /// The same figure from the other end. Only the percentage line flips —
    /// local runtimes report memory and speed rather than a quota, and an
    /// explicit used-text or count line has no remaining figure to show.
    func headlineText(showingRemaining: Bool) -> String {
        if kind == .localRuntime {
            return showsLocalPerformance ? (localPerformance?.headlineText ?? "— tok/s")
                : (localModel?.memoryText ?? "—")
        }
        if headline?.prefersUsedText == true, let usedText = headline?.usedText { return usedText }
        if let usedFraction {
            // The tooltip's own left half, not one minus the fraction: it
            // derives from the *rounded* used figure, so the notch and the
            // card never disagree by a point. See `Percent.halves`.
            if showingRemaining { return Percent.halves(for: usedFraction).left + "%" }
            return Percent.text(for: usedFraction) + "%"
        }
        if let remaining = headline?.remaining { return LimitWindow.compact(remaining) }
        if let usedText = headline?.usedText { return usedText }
        if let used = headline?.used { return LimitWindow.compact(used) }
        return "—"
    }

    /// An empty local inventory still confirms server connectivity; an absent
    /// reading must not be shown as measured zero usage.
    var hasReading: Bool { localRuntime != nil || localModel != nil || !windows.isEmpty }

    /// Group headings occupy space in both the card and its hover region.
    var windowGroupCount: Int { Set(windows.compactMap(\.group)).count }

    /// How many windows are count-only (no fraction, no bar) — they render as
    /// single-line rows and take less vertical space than full bar rows.
    var compactRowCount: Int {
        windows.filter { $0.usedFraction == nil && ($0.used != nil || $0.detail != nil) }.count
    }

    /// A ring can only be drawn when the provider said what the limit was. A
    /// local model has no limit; its arc is how full the context was.
    var ringFraction: Double? { kind == .localRuntime ? localContextFraction : usedFraction }

    /// Rows the tooltip adds for a logged runtime: context used, tokens and
    /// requests today, reasoning share, draft acceptance. Counted here so the
    /// card's budget and its contents cannot disagree.
    var localLedgerRowCount: Int { localLedger == nil ? 0 : 5 }

    /// Signing in means something different per provider, so the prompt has to
    /// say which door to knock on.
    private var authPrompt: String {
        let locale = L10n.locale
        switch id {
        case "claude":     return L10n.t("Sign in to Claude Code to read your usage", locale: locale)
        // A remote login is signed in where it lives, over ssh — and only the
        // stored host knows where that is.
        case _ where RemoteHost.isRemoteClaude(providerID: id):
            let destination = RemoteHost.destination(forProviderID: id) ?? "that server"
            return L10n.t("Sign in to Claude Code on \(destination) to read this account's usage", locale: locale)
        // A profile is signed in by running Claude Code against its directory,
        // which is worth saying: plain `claude` signs the default one in.
        case _ where ClaudeProfile.isClaude(providerID: id):
            let slug = ClaudeProfile.slug(fromProviderID: id) ?? ""
            return L10n.t("Sign in to Claude Code in ~/.claude-\(slug) to read your usage", locale: locale)
        case "cursor":     return L10n.t("Sign in to Cursor in the editor", locale: locale)
        case "codex":      return L10n.t("Sign in to Codex to read your usage", locale: locale)
        case "deepseek":   return L10n.t("Sign in to DeepSeek Platform to read your usage", locale: locale)
        case "qianwenai":  return L10n.t("Sign in to QianwenAI to read your Token Plan usage", locale: locale)
        case _ where RemoteHost.isRemoteCodex(providerID: id):
            let destination = RemoteHost.destination(forProviderID: id) ?? "that server"
            return L10n.t("Sign in to Codex on \(destination) to read this account's usage", locale: locale)
        case _ where CodexProfile.slug(fromProviderID: id) != nil:
            let slug = CodexProfile.slug(fromProviderID: id)!
            return L10n.t("Sign in to Codex in ~/.codex-\(slug) to read your usage", locale: locale)
        case "gemini":     return L10n.t("Sign in to Antigravity to read your usage", locale: locale)
        case _ where AntigravityProfile.slug(fromProviderID: id) != nil:
            let slug = AntigravityProfile.slug(fromProviderID: id)!
            return L10n.t("Sign in to Antigravity in ~/.gemini/antigravity-\(slug) to read your usage", locale: locale)
        case "glm":        return L10n.t("Set up a GLM Coding Plan key for a coding tool to read your usage", locale: locale)
        case "copilot":    return L10n.t("Sign in with GitHub CLI to read your Copilot usage", locale: locale)
        case "opencode":   return L10n.t("Connect the Go plan in OpenCode to read your usage", locale: locale)
        case "commandcode": return L10n.t("Sign in with the Command Code app to read your usage", locale: locale)
        case "kiro":       return L10n.t("Sign in with kiro-cli to read your usage", locale: locale)
        case "amp":        return L10n.t("Run amp login in Terminal to read your usage", locale: locale)
        case "apify":      return L10n.t("Run apify login in Terminal, or paste an Apify API token in Settings", locale: locale)
        case "kilo":       return L10n.t("Sign in with the Kilo CLI to read your usage", locale: locale)
        // Two Ollamas, and they are stuck for different reasons: the hosted
        // one wants a key, the local one wants the daemon running.
        case "ollama":       return L10n.t("Enter an Ollama API key in Settings, or export OLLAMA_API_KEY", locale: locale)
        case "ollama-local": return L10n.t("Start Ollama to monitor your local models", locale: locale)
        case "lmstudio":     return L10n.t("Start LM Studio's server to monitor your local models", locale: locale)
        default:           return L10n.t("Sign in to \(displayName) to read your usage", locale: locale)
        }
    }

    /// What the tooltip says instead of limit rows when there is nothing to show.
    var statusMessage: String? {
        if kind == .localRuntime {
            if localModel != nil { return nil }
            if let localRuntime {
                return localRuntime.models.isEmpty ? localRuntime.summary : nil
            }
            if case .error(let why) = status { return why }
            return "Connecting to \(displayName)…"
        }
        if hasReading { return nil }
        let locale = L10n.locale
        switch status {
        case .needsAuth:      return authPrompt
        case .signedOutByOwner:
            // Names the cause, because "sign in again" on its own invites the
            // reasonable conclusion that this app lost the login.
            return L10n.t("Claude Code emptied this profile's saved login — it does that to every profile at once after it updates itself. Sign in again to \(displayName) to read your usage.", locale: locale)
        case .accessDenied:
            // Says what happened and what fixes it. "Sign in to Claude Code"
            // would send someone who *is* signed in to fix the wrong thing.
            // Points at the one control that asks again. Clicking the ring
            // only refreshes, and a refresh never shows the dialogue — polls
            // are not allowed to.
            return L10n.t("macOS refused Codenotch access to \(displayName)'s saved login. Use Allow access… in Settings to ask again.", locale: locale)
        case .unsupported(let why): return why
        case .error(let why): return L10n.t("Couldn't read usage — \(why)", locale: locale)
        case .stale, .ok:     return L10n.t("Waiting for the first reading…", locale: locale)
        }
    }
}
