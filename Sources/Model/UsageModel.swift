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

    init(id: String, group: String? = nil, label: String, usedFraction: Double? = nil,
         remaining: Int? = nil, used: Int? = nil, usedText: String? = nil, detail: String? = nil,
         money: UsageMoneyBreakdown? = nil, resetsAt: Date? = nil,
         duration: TimeInterval? = nil) {
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
    var summary: String { summary(locale: L10n.locale) }

    func summary(locale: Locale = L10n.locale) -> String {
        if let usedFraction {
            // Both ends of the same figure. Vendors do not agree on which to
            // show — Codex writes "87% remaining", Claude writes "% used" — so
            // a notch that picks one side leaves the user converting in their
            // head, and "12% Used" beside Codex's "87% remaining" reads as two
            // different numbers rather than one seen from either end. That is
            // what made a correct reading look wrong.
            let halves = Percent.halves(for: usedFraction)
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
    let displayName: String
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

    /// Unused rate-limit resets on this Codex account, listed by the same
    /// backend as usage.
    var resetCredits: CodexResetCredits? = nil

    /// Whether the Codex tooltip has a reset-credit section to draw.
    ///
    /// The endpoint can successfully return an empty result. That is data,
    /// but it is not useful card content and must not reserve layout space.
    var hasAvailableResetCredits: Bool {
        (resetCredits?.availableCount ?? 0) > 0
    }
    /// Provider-owned online usage detail, such as DeepSeek's API key/model
    /// breakdown and daily token/cost series.
    var usageDetail: ProviderUsageDetail? = nil

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
        guard let weeklyID else { return nil }
        // Never the window the headline is already drawing. Providers that pick
        // their headline by which limit is tightest — Antigravity does — will
        // sometimes land on the weekly one, and two rings reporting the same
        // number is worse than one: it reads as a second fact that happens to
        // agree, rather than as the same fact twice.
        guard weeklyID != headlineID else { return nil }
        return windows.first { $0.id == weeklyID }
    }

    /// Nil when there is no weekly window, or when the provider reports one
    /// without a denominator — the same rule the headline ring follows.
    var weeklyFraction: Double? { weeklyWindow?.usedFraction }

    /// What the cell prints under the ring.
    var headlineText: String {
        if kind == .localRuntime {
            return showsLocalPerformance ? (localPerformance?.headlineText ?? "— tok/s")
                : (localModel?.memoryText ?? "—")
        }
        if let usedFraction { return Percent.text(for: usedFraction) + "%" }
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
        // A profile is signed in by running Claude Code against its directory,
        // which is worth saying: plain `claude` signs the default one in.
        case _ where ClaudeProfile.isClaude(providerID: id):
            let slug = ClaudeProfile.slug(fromProviderID: id) ?? ""
            return L10n.t("Sign in to Claude Code in ~/.claude-\(slug) to read your usage", locale: locale)
        case "cursor":     return L10n.t("Sign in to Cursor in the editor", locale: locale)
        case "codex":      return L10n.t("Sign in to Codex to read your usage", locale: locale)
        case "deepseek":   return L10n.t("Sign in to DeepSeek Platform to read your usage", locale: locale)
        case "qianwenai":  return L10n.t("Sign in to QianwenAI to read your Token Plan usage", locale: locale)
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
