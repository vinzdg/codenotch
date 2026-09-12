import Combine
import Foundation
import ServiceManagement
import os

/// What the user has chosen, kept in `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    static let showUsagePaceKey = "showUsagePace"

    /// Disabled model IDs hide cells without stopping their shared runtime.
    @Published var disconnectedProviders: Set<String> {
        didSet { defaults.set(Array(disconnectedProviders), forKey: Keys.disconnected) }
    }

    /// Display choices are separate from connections: hidden providers keep
    /// polling, and hidden local models keep running.
    @Published var hiddenNotchProviders: Set<String> {
        didSet { defaults.set(Array(hiddenNotchProviders), forKey: Keys.hiddenNotchProviders) }
    }

    @Published var ollamaMetricsEnabled: Bool {
        didSet { defaults.set(ollamaMetricsEnabled, forKey: Keys.ollamaMetricsEnabled) }
    }

    @Published var ollamaEndpoint: String {
        didSet { defaults.set(ollamaEndpoint, forKey: Keys.ollamaEndpoint) }
    }

    /// Where LM Studio's server answers. Defaults to the port LM Studio's own
    /// settings name, so a server moved off 1234 is found without typing.
    @Published var lmstudioEndpoint: String {
        didSet { defaults.set(lmstudioEndpoint, forKey: Keys.lmstudioEndpoint) }
    }

    /// Providers whose threshold alerts are muted. Stored as the muted set so
    /// a provider added later alerts by default — the same reasoning as
    /// `disconnectedProviders`.
    @Published var mutedAlertProviders: Set<String> {
        didSet { defaults.set(Array(mutedAlertProviders), forKey: Keys.mutedAlerts) }
    }

    /// The order the user has dragged the rings into, as provider ids.
    ///
    /// Stored as the ids actually placed rather than as every id known at the
    /// time: providers are discovered at launch — Claude Code contributes one
    /// per `~/.claude-<slug>` — so an exhaustive list written today is wrong
    /// the moment a profile appears. `ProviderOrder` reconciles the two,
    /// forgivingly in both directions.
    ///
    /// Empty means never chosen, which is not the same as having chosen the
    /// order the app ships with: keeping them distinct is what lets a later
    /// version change the built-in order for everyone who never had an opinion.
    @Published var providerOrder: [String] {
        didSet { defaults.set(providerOrder, forKey: Keys.order) }
    }

    /// How much of itself the notch shows at rest.
    @Published var notchVisibility: NotchVisibility {
        didSet { defaults.set(notchVisibility.rawValue, forKey: Keys.visibility) }
    }

    /// Which screen edge the notch is welded to.
    @Published var notchEdge: NotchEdge {
        didSet { defaults.set(notchEdge.rawValue, forKey: Keys.edge) }
    }

    /// How large the notch is drawn, as one of three named sizes.
    ///
    /// Ignored while `usesCustomNotchScale` is on — the two are kept apart
    /// rather than collapsed into one number so that switching back to the
    /// presets returns to the preset you last chose, instead of to whichever
    /// preset happens to sit nearest the slider.
    @Published var notchSize: NotchSize {
        didSet { defaults.set(notchSize.rawValue, forKey: Keys.size) }
    }

    /// Whether the slider decides the size rather than the three presets.
    @Published var usesCustomNotchScale: Bool {
        didSet { defaults.set(usesCustomNotchScale, forKey: Keys.usesCustomSize) }
    }

    /// The slider's own multiplier, honoured only when the slider is in
    /// charge. Clamped on the way in: a value typed straight into `defaults`
    /// could otherwise shrink the notch to nothing or blow it off the screen.
    @Published var customNotchScale: Double {
        didSet {
            let clamped = min(max(customNotchScale, Self.customScaleRange.lowerBound),
                              Self.customScaleRange.upperBound)
            if clamped != customNotchScale { customNotchScale = clamped; return }
            defaults.set(customNotchScale, forKey: Keys.customSize)
        }
    }

    /// Where the slider may go. Wider than the presets at both ends, but not
    /// unbounded: below about three quarters the percentage under each ring
    /// stops being readable, which is the one thing the notch exists for.
    static let customScaleRange: ClosedRange<Double> = 0.75...1.5

    /// What the notch is actually drawn at, whichever control is in charge.
    var notchScale: CGFloat {
        usesCustomNotchScale ? CGFloat(customNotchScale) : notchSize.scale
    }

    /// The display the notch stays on, or the original focus-following behaviour.
    ///
    /// Only meaningful in `NotchScreenScope.main` — pinning a display and
    /// drawing on every display are two different questions, and this answers
    /// the first one. `all` ignores it entirely: there is no "the" display to
    /// pin when every one of them gets its own notch.
    @Published var displayPreference: DisplayPreference {
        didSet {
            switch displayPreference {
            case .followActiveWindow:
                defaults.removeObject(forKey: Keys.display)
            case .display(let id):
                defaults.set(id, forKey: Keys.display)
            }
        }
    }

    /// Which displays get a notch when more than one is connected.
    @Published var notchScope: NotchScreenScope {
        didSet { defaults.set(notchScope.rawValue, forKey: Keys.scope) }
    }

    /// The preferred limit window to show for Antigravity provider (automatic, 5h, or weekly).
    @Published var antigravityHeadlineLimit: AntigravityHeadlineLimit {
        didSet { defaults.set(antigravityHeadlineLimit.rawValue, forKey: Keys.antigravityHeadlineLimit) }
    }

    /// The preferred model group to show for Antigravity provider (Gemini or Claude and GPT models).
    @Published var antigravityHeadlineModel: AntigravityHeadlineModel {
        didSet { defaults.set(antigravityHeadlineModel.rawValue, forKey: Keys.antigravityHeadlineModel) }
    }

    /// Where along that edge the notch sits, nudged from the centred default
    /// by ⌥-dragging the pill. One value per edge — moving it on the right
    /// should not silently relocate it on the top too — so this is read and
    /// written through `offset(for:)`/`setOffset(_:for:)` rather than exposed
    /// as a single published value the way the other settings are.
    func offset(for edge: NotchEdge) -> CGFloat {
        CGFloat(defaults.double(forKey: Self.offsetKey(for: edge)))
    }

    func setOffset(_ offset: CGFloat, for edge: NotchEdge) {
        defaults.set(Double(offset), forKey: Self.offsetKey(for: edge))
    }

    private static func offsetKey(for edge: NotchEdge) -> String { "notchOffset.\(edge.rawValue)" }

    @Published var resetTimeFormat: ResetTimeFormat {
        didSet { defaults.set(resetTimeFormat.rawValue, forKey: Keys.resetTimeFormat) }
    }

    @Published var showUsagePace: Bool {
        didSet { defaults.set(showUsagePace, forKey: Self.showUsagePaceKey) }
    }

    /// Whether the weekly limit gets a ring of its own, and where it sits.
    @Published var weeklyRing: WeeklyRing {
        didSet { defaults.set(weeklyRing.rawValue, forKey: Keys.weeklyRing) }
    }

    /// Whether the move handle's arc is drawn above the notch.
    @Published var showsMoveHandle: Bool {
        didSet { defaults.set(showsMoveHandle, forKey: Keys.showsMoveHandle) }
    }

    /// The colour used for positive usage and active-work indicators.
    @Published var accentColor: AccentColorChoice {
        didSet { defaults.set(accentColor.rawValue, forKey: Keys.accentColor) }
    }

    /// The material the expanded notch, tooltip and settings orb are painted with.
    @Published var notchSurfaceStyle: NotchSurfaceStyle {
        didSet { defaults.set(notchSurfaceStyle.rawValue, forKey: Keys.notchSurfaceStyle) }
    }

    /// The language the app itself speaks.
    ///
    /// `.system` follows the Mac. Written through `L10n.apply` so the store
    /// and the change notification stay a single write.
    @Published var language: AppLanguage {
        didSet { L10n.apply(language) }
    }

    /// Where the app itself shows up: Dock, menu bar, or nowhere.
    @Published var appPresence: AppPresence {
        didSet { defaults.set(appPresence.rawValue, forKey: Keys.presence) }
    }

    /// Open the notch for a few seconds when an agent stops working.
    ///
    /// On by default: the app already knows the moment a session ends, and a
    /// user who installed a thing that watches sessions is unlikely to want
    /// that particular fact kept from them. It is a peek, not a notification —
    /// nothing to dismiss, and it takes no focus.
    @Published var announceSessionEnd: Bool {
        didSet { defaults.set(announceSessionEnd, forKey: Keys.announceSessionEnd) }
    }

    /// How long that peek lasts.
    @Published var peekDuration: PeekDuration {
        didSet { defaults.set(peekDuration.rawValue, forKey: Keys.peekDuration) }
    }

    /// Sound the system alert alongside the peek.
    ///
    /// Separate from the peek because they fail differently: the peek is no use
    /// on another Space or behind a full-screen window, and the sound is no use
    /// in a meeting. Kept switchable on its own so neither one forces the
    /// other.
    @Published var sessionEndSound: Bool {
        didSet { defaults.set(sessionEndSound, forKey: Keys.sessionEndSound) }
    }

    /// Which sound a finished turn makes.
    @Published var sessionEndSoundName: String {
        didSet { defaults.set(sessionEndSoundName, forKey: Keys.sessionEndSoundName) }
    }

    /// And which one a session blocked on you makes.
    ///
    /// A separate choice because the two say different things — one is "that's
    /// done", the other is "you are the hold-up" — and a single sound for both
    /// makes the second one easy to ignore.
    @Published var sessionBlockedSoundName: String {
        didSet { defaults.set(sessionBlockedSoundName, forKey: Keys.sessionBlockedSoundName) }
    }

    /// Show a notification modal from the notch when a provider's limit resets.
    @Published var announceUsageReset: Bool {
        didSet { defaults.set(announceUsageReset, forKey: Keys.announceUsageReset) }
    }

    /// Sound an alert alongside the usage reset notification modal.
    @Published var usageResetSound: Bool {
        didSet { defaults.set(usageResetSound, forKey: Keys.usageResetSound) }
    }

    /// Which sound a usage reset notification makes.
    @Published var usageResetSoundName: String {
        didSet { defaults.set(usageResetSoundName, forKey: Keys.usageResetSoundName) }
    }

    /// Show a notification modal from the notch when a provider's session limit is reached.
    @Published var announceSessionLimitReached: Bool {
        didSet { defaults.set(announceSessionLimitReached, forKey: Keys.announceSessionLimitReached) }
    }

    /// Show a notification modal from the notch when a provider's weekly limit is reached.
    @Published var announceWeeklyLimitReached: Bool {
        didSet { defaults.set(announceWeeklyLimitReached, forKey: Keys.announceWeeklyLimitReached) }
    }

    /// Sound an alert alongside the limit reached notification modal.
    @Published var limitReachedSound: Bool {
        didSet { defaults.set(limitReachedSound, forKey: Keys.limitReachedSound) }
    }

    /// Which sound a limit reached notification makes.
    @Published var limitReachedSoundName: String {
        didSet { defaults.set(limitReachedSoundName, forKey: Keys.limitReachedSoundName) }
    }

    /// The ceiling the Gemini API ring fills against, counted in tokens.
    ///
    /// In tokens rather than money because a bare `GEMINI_API_KEY` publishes no
    /// limit of any kind — there is nothing to read, so the ceiling has to come
    /// from the user — and because prices change under the app while a token
    /// stays a token. `nil` means no ceiling, which is the honest default: the
    /// key is billed per token with no cap.
    @Published var geminiAPIMonthlyTokenBudget: Int? {
        didSet {
            if let budget = geminiAPIMonthlyTokenBudget, budget > 0 {
                defaults.set(budget, forKey: Keys.geminiAPIMonthlyTokenBudget)
            } else {
                defaults.removeObject(forKey: Keys.geminiAPIMonthlyTokenBudget)
            }
        }
    }

    /// The version whose changes have already been shown.
    ///
    /// Written when the What's New dialogue is dismissed rather than when it
    /// opens, so a crash in between cannot swallow the one launch it was going
    /// to appear on.
    @Published var lastSeenVersion: String? {
        didSet { defaults.set(lastSeenVersion, forKey: Keys.lastSeenVersion) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != Self.isRegisteredForLogin else { return }
            applyLaunchAtLogin()
        }
    }

    /// Set when the login-item request was refused, so the UI can say so rather
    /// than quietly flipping the switch back.
    @Published private(set) var launchAtLoginProblem: String?

    private let defaults: UserDefaults
    private enum Keys {
        /// The old name. Kept so existing choices survive the rename.
        static let disconnected = "hiddenProviders"
        static let hiddenNotchProviders = "hiddenNotchProviders"
        static let ollamaEndpoint = "ollamaEndpoint"
        static let lmstudioEndpoint = "lmstudioEndpoint"
        static let introducedOllama = "introducedOllama"
        static let migratedOllamaID = "migratedOllamaLocalID"
        static let ollamaMetricsEnabled = "ollamaMetricsEnabled"
        static let mutedAlerts = "mutedAlertProviders"
        static let hasLaunched = "hasLaunchedBefore"
        static let visibility = "notchVisibility"
        static let presence = "appPresence"
        static let edge = "notchEdge"
        // A new key, so there is nothing under the old app name to migrate.
        static let size = "notchSize"
        static let usesCustomSize = "usesCustomNotchScale"
        static let customSize = "customNotchScale"
        static let display = "notchDisplay"
        static let resetTimeFormat = "resetTimeFormat"
        static let scope = "notchScope"
        static let accentColor = "accentColor"
        // A new key, so there is nothing under the old app name to migrate.
        static let weeklyRing = "weeklyRing"
        static let showsMoveHandle = "showsMoveHandle"
        static let notchSurfaceStyle = "notchSurfaceStyle"
        static let lastSeenVersion = "lastSeenVersion"
        static let order = "providerOrder"
        static let announceSessionEnd = "announceSessionEnd"
        static let sessionEndSound = "sessionEndSound"
        static let peekDuration = "peekDuration"
        static let sessionEndSoundName = "sessionEndSoundName"
        static let sessionBlockedSoundName = "sessionBlockedSoundName"
        static let announceUsageReset = "announceUsageReset"
        static let usageResetSound = "usageResetSound"
        static let usageResetSoundName = "usageResetSoundName"
        static let announceSessionLimitReached = "announceSessionLimitReached"
        static let announceWeeklyLimitReached = "announceWeeklyLimitReached"
        static let limitReachedSound = "limitReachedSound"
        static let limitReachedSoundName = "limitReachedSoundName"
        /// A new key, so there is nothing under the old app name to migrate.
        static let geminiAPIMonthlyTokenBudget = "geminiAPIMonthlyTokenBudget"
        static let antigravityHeadlineLimit = "antigravityHeadlineLimit"
        static let antigravityHeadlineModel = "antigravityHeadlineModel"
    }

    /// The budget read straight from disk, off the main actor.
    ///
    /// The Gemini API provider is an actor and asks for this on every fetch, and
    /// `@Published` state is main-actor-isolated where `UserDefaults` is
    /// thread-safe — so the provider reads the store, not the object.
    nonisolated static func storedGeminiAPIMonthlyTokenBudget(
        defaults: UserDefaults = .standard
    ) -> Int? {
        guard let budget = defaults.object(forKey: Keys.geminiAPIMonthlyTokenBudget) as? Int,
              budget > 0
        else { return nil }
        return budget
    }
    
    nonisolated static func storedAntigravityHeadlineLimit(
        defaults: UserDefaults = .standard
    ) -> AntigravityHeadlineLimit {
        guard let value = defaults.string(forKey: Keys.antigravityHeadlineLimit),
              let limit = AntigravityHeadlineLimit(rawValue: value)
        else { return .automatic }
        return limit
    }

    nonisolated static func storedAntigravityHeadlineModel(
        defaults: UserDefaults = .standard
    ) -> AntigravityHeadlineModel {
        guard let value = defaults.string(forKey: Keys.antigravityHeadlineModel),
              let model = AntigravityHeadlineModel(rawValue: value)
        else { return .gemini }
        return model
    }

    /// True the very first time this copy runs, and never again.
    ///
    /// Deliberately *not* inferred from "there are no readings yet" — that is
    /// also true of someone who switched every provider off, and re-introducing
    /// them to the app every launch would be worse than never introducing them
    /// at all.
    let isFirstLaunch: Bool

    /// The bundle identifier before the app was renamed to Codenotch.
    ///
    /// A bundle id is the name of the defaults domain, so renaming the app
    /// silently moved every setting to a new, empty one — connection choices,
    /// the notch's mode, the archived readings, all apparently lost. Copying
    /// the old domain across once is the difference between a rename and what
    /// looks like a reset.
    private static let previousDomain = "com.vinz.usagenotch"

    static func migrateFromPreviousName(into defaults: UserDefaults = .standard,
                                        from domain: String = previousDomain) {
        // The emptiness test has to be about the object being written to, not
        // about `Bundle.main` — under test those are different domains, and the
        // first version happily copied real settings into a test's scratch
        // suite. `hasLaunched` is the sentinel: `Preferences.init` sets it, so
        // its absence means nothing has ever used this domain.
        guard defaults.object(forKey: Keys.hasLaunched) == nil,
              let old = defaults.persistentDomain(forName: domain), !old.isEmpty
        else { return }

        for (key, value) in old { defaults.set(value, forKey: key) }
        Log.usage.info("migrated \(old.count) settings from the previous app name")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isFirstLaunch = !defaults.bool(forKey: Keys.hasLaunched)
        defaults.set(true, forKey: Keys.hasLaunched)
        // Only the earlier local integration used this sentinel. Keep unrelated
        // provider IDs untouched when upgrading from upstream.
        if defaults.bool(forKey: Keys.introducedOllama),
           !defaults.bool(forKey: Keys.migratedOllamaID) {
            for key in [Keys.disconnected, Keys.order, Keys.mutedAlerts] {
                var seen = Set<String>()
                let migrated = (defaults.stringArray(forKey: key) ?? []).map { id in
                    if id == "ollama" { return "ollama-local" }
                    if id.hasPrefix("ollama:model:") {
                        return "ollama-local:model:" + id.dropFirst("ollama:model:".count)
                    }
                    return id
                }.filter { seen.insert($0).inserted }
                defaults.set(migrated, forKey: key)
            }
            defaults.set(true, forKey: Keys.migratedOllamaID)
        }
        let disconnected = Set(defaults.stringArray(forKey: Keys.disconnected) ?? [])
        self.disconnectedProviders = disconnected
        self.hiddenNotchProviders = Set(defaults.stringArray(forKey: Keys.hiddenNotchProviders) ?? [])
        self.ollamaMetricsEnabled = defaults.object(forKey: Keys.ollamaMetricsEnabled) as? Bool
            ?? (defaults.bool(forKey: Keys.introducedOllama)
                && !disconnected.contains("ollama-local"))
        self.ollamaEndpoint = (try? OllamaEndpoint.parse(
            defaults.string(forKey: Keys.ollamaEndpoint) ?? OllamaEndpoint.defaultAddress
        ).absoluteString) ?? OllamaEndpoint.defaultAddress
        // A stored choice wins; otherwise LM Studio's own configuration file
        // says where it listens, and 1234 is what it ships with.
        self.lmstudioEndpoint = (try? LMStudioEndpoint.parse(
            defaults.string(forKey: Keys.lmstudioEndpoint)
                ?? LMStudioEndpoint.configuredAddress() ?? LMStudioEndpoint.defaultAddress
        ).absoluteString) ?? LMStudioEndpoint.defaultAddress
        self.mutedAlertProviders = Set(defaults.stringArray(forKey: Keys.mutedAlerts) ?? [])
        // Absent means never chosen, which is the hover behaviour the app was
        // designed around — not hidden, which would make a fresh install look
        // like it failed to start.
        self.notchVisibility = defaults.string(forKey: Keys.visibility)
            .flatMap(NotchVisibility.init(rawValue:)) ?? .onHover
        // Absent means never chosen. The Dock is the default because it is the
        // findable one — a new user who cannot see the app anywhere has no way
        // to learn it is running.
        self.appPresence = defaults.string(forKey: Keys.presence)
            .flatMap(AppPresence.init(rawValue:)) ?? .dock
        // The right edge is where the notch has always been, and it is the one
        // side of a Mac that no system chrome claims by default.
        self.notchEdge = defaults.string(forKey: Keys.edge)
            .flatMap(NotchEdge.init(rawValue:)) ?? .right
        // Medium is the design frame at 1:1, so an install that predates this
        // choice keeps exactly the notch it already had.
        self.notchSize = defaults.string(forKey: Keys.size)
            .flatMap(NotchSize.init(rawValue:)) ?? .medium
        // Absent means never chosen, and the presets are what every earlier
        // version had — so the slider is opt-in rather than the default.
        self.usesCustomNotchScale = defaults.bool(forKey: Keys.usesCustomSize)
        let stored = defaults.object(forKey: Keys.customSize) as? Double
        self.customNotchScale = stored.map {
            min(max($0, Self.customScaleRange.lowerBound), Self.customScaleRange.upperBound)
        } ?? 1
        self.displayPreference = defaults.string(forKey: Keys.display)
            .map(DisplayPreference.display) ?? .followActiveWindow
        self.resetTimeFormat = defaults.string(forKey: Keys.resetTimeFormat)
            .flatMap(ResetTimeFormat.init(rawValue:)) ?? .automatic
        self.showUsagePace = defaults.bool(forKey: Self.showUsagePaceKey)
        // Absent means never chosen. Main display only, because that is what a
        // single-panel setup always did — all-displays on a fresh install
        // would put notches where none were expected.
        self.notchScope = defaults.string(forKey: Keys.scope)
            .flatMap(NotchScreenScope.init(rawValue:)) ?? .mainDisplay
        self.antigravityHeadlineLimit = defaults.string(forKey: Keys.antigravityHeadlineLimit)
            .flatMap(AntigravityHeadlineLimit.init(rawValue:)) ?? .automatic
        self.antigravityHeadlineModel = defaults.string(forKey: Keys.antigravityHeadlineModel)
            .flatMap(AntigravityHeadlineModel.init(rawValue:)) ?? .gemini
        // Follow the Mac unless the user explicitly chooses a Codenotch colour.
        // Off by default: an extra arc in a 44pt circle is a change to how
        // every reading looks, and nobody asked for it on their behalf.
        self.weeklyRing = defaults.string(forKey: Keys.weeklyRing)
            .flatMap(WeeklyRing.init(rawValue:)) ?? .off
        // On unless turned off: it is how the notch is carried to another edge,
        // and a control that is missing by default is one nobody finds.
        self.showsMoveHandle = defaults.object(forKey: Keys.showsMoveHandle) as? Bool ?? true
        self.accentColor = defaults.string(forKey: Keys.accentColor)
            .flatMap(AccentColorChoice.init(rawValue:)) ?? .system
        self.notchSurfaceStyle = defaults.string(forKey: Keys.notchSurfaceStyle)
            .flatMap(NotchSurfaceStyle.init(rawValue:)) ?? .glass
        // Absent means never chosen, which is follow-the-Mac.
        self.language = defaults.string(forKey: L10n.languageDefaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        // Absent means nothing has been shown yet, which is true of a fresh
        // install — so the current release reads as new to it.
        self.lastSeenVersion = defaults.string(forKey: Keys.lastSeenVersion)
        // Absent means never chosen, so the rings keep the order the app ships
        // with until someone drags one.
        self.providerOrder = defaults.stringArray(forKey: Keys.order) ?? []
        // Both default to on, so `bool(forKey:)` — which answers false for a
        // key that was never written — cannot stand in for the default.
        self.announceSessionEnd = defaults.object(forKey: Keys.announceSessionEnd) as? Bool ?? true
        self.sessionEndSound = defaults.object(forKey: Keys.sessionEndSound) as? Bool ?? true
        self.peekDuration = defaults.string(forKey: Keys.peekDuration)
            .flatMap(PeekDuration.init(rawValue:)) ?? .standard
        self.sessionEndSoundName = defaults.string(forKey: Keys.sessionEndSoundName)
            ?? SessionChime.defaultFinished
        self.sessionBlockedSoundName = defaults.string(forKey: Keys.sessionBlockedSoundName)
            ?? SessionChime.defaultBlocked
        self.announceUsageReset = defaults.object(forKey: Keys.announceUsageReset) as? Bool ?? true
        self.usageResetSound = defaults.object(forKey: Keys.usageResetSound) as? Bool ?? true
        self.usageResetSoundName = defaults.string(forKey: Keys.usageResetSoundName)
            ?? SessionChime.defaultFinished
        self.announceSessionLimitReached = defaults.object(forKey: Keys.announceSessionLimitReached) as? Bool ?? true
        self.announceWeeklyLimitReached = defaults.object(forKey: Keys.announceWeeklyLimitReached) as? Bool ?? true
        self.limitReachedSound = defaults.object(forKey: Keys.limitReachedSound) as? Bool ?? true
        self.limitReachedSoundName = defaults.string(forKey: Keys.limitReachedSoundName)
            ?? SessionChime.defaultBlocked
        self.geminiAPIMonthlyTokenBudget = Self.storedGeminiAPIMonthlyTokenBudget(defaults: defaults)
        // Read from the system rather than from our own store: the user can turn
        // this off in System Settings, and a remembered `true` would then be a lie.
        self.launchAtLogin = Self.isRegisteredForLogin
    }

    // MARK: Threshold alerts

    func isMutedAlerts(for providerID: String) -> Bool {
        mutedAlertProviders.contains(providerID)
    }

    func setAlertsMuted(_ muted: Bool, for providerID: String) {
        if muted {
            mutedAlertProviders.insert(providerID)
        } else {
            mutedAlertProviders.remove(providerID)
        }
    }

    func isConnected(_ providerID: String) -> Bool {
        !disconnectedProviders.contains(providerID)
    }

    func setConnected(_ connected: Bool, for providerID: String) {
        if connected {
            disconnectedProviders.remove(providerID)
        } else {
            disconnectedProviders.insert(providerID)
        }
    }

    func isShownInNotch(_ providerID: String) -> Bool {
        !hiddenNotchProviders.contains(providerID)
            && !(Self.isLocalModelID(providerID) && disconnectedProviders.contains(providerID))
    }

    func setShownInNotch(_ shown: Bool, for providerID: String) {
        if shown {
            hiddenNotchProviders.remove(providerID)
            // Earlier versions stored local model visibility with connection
            // choices. Restore those cells without reconnecting any provider.
            if Self.isLocalModelID(providerID) {
                disconnectedProviders.remove(providerID)
            }
        } else {
            hiddenNotchProviders.insert(providerID)
        }
    }

    /// Matched on the shape every runtime builds its cells with
    /// (`<runtime>:model:<model>`), not on a list of runtime names — the next
    /// local runtime added should inherit this without touching Preferences.
    private static func isLocalModelID(_ id: String) -> Bool {
        id.contains(":model:")
    }

    /// Record a new order, keeping the ids that are not on this Mac today.
    ///
    /// Settings can only show what was discovered at launch, so writing its
    /// list verbatim would quietly forget where a Claude profile sat the moment
    /// its directory was moved away — and put it back at the end when it
    /// returned, for something the user never did.
    func setProviderOrder(_ ids: [String]) {
        providerOrder = ProviderOrder.remember(ids, keeping: providerOrder)
    }

    /// Forget everything this app has stored and quit.
    ///
    /// Deleting an app on macOS leaves `~/Library` untouched, so reinstalling
    /// brings back the old readings, the old connection choices and the old
    /// first-launch flag — which is exactly what makes a reinstall look broken.
    /// Nothing but the app itself can clean that up, so the app has to offer it.
    ///
    /// Not tied to uninstalling: a reinstall is indistinguishable from an
    /// update, and wiping data on every Sparkle update would be catastrophic.
    /// It has to be something the user asks for.
    static func eraseAllData() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.vinz.codenotch"
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        for relative in ["Caches/\(bundleID)",
                         "WebKit/\(bundleID)",
                         "HTTPStorages/\(bundleID)",
                         "HTTPStorages/\(bundleID).binarycookies",
                         "Saved Application State/\(bundleID).savedState"] {
            if let url = library?.appendingPathComponent(relative) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Login item

    static var isRegisteredForLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginProblem = nil
        } catch {
            // Commonly refused for an app running from a build directory rather
            // than /Applications, which is worth saying plainly.
            Log.usage.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginProblem = L10n.t("macOS refused this — try moving Codenotch to /Applications.")
            launchAtLogin = Self.isRegisteredForLogin
        }
    }
}
