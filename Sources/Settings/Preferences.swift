import Combine
import Foundation
import ServiceManagement
import os

/// What the user has chosen, kept in `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    static let showUsagePaceKey = "showUsagePace"

    /// Provider IDs that currently have a ring. Stored as the ones that are
    /// on, so a provider added later stays off until someone switches it on —
    /// Claude and Codex excepted, which still default on as a family.
    @Published var connectedProviders: Set<String> {
        didSet { defaults.set(Array(connectedProviders), forKey: Keys.connected) }
    }

    /// Every provider id this copy has already decided on, so a later version's
    /// new provider is recognised as new rather than as "never chosen".
    @Published private(set) var seenProviders: Set<String> {
        didSet { defaults.set(Array(seenProviders), forKey: Keys.seen) }
    }

    /// Loaded-model cells hide without stopping the shared runtime. Stored as
    /// the ones that are off: a model Ollama or LM Studio loads later stays
    /// visible until someone hides it. Providers cannot share this list —
    /// their on-list treats absence as off.
    @Published private(set) var disabledModels: Set<String> {
        didSet { defaults.set(Array(disabledModels), forKey: Keys.disabledModels) }
    }

    /// The old hidden-providers list, kept only until `reconcile` can invert it
    /// against the ids actually on this Mac.
    private var pendingHidden: Set<String>?

    @Published var ollamaMetricsEnabled: Bool {
        didSet { defaults.set(ollamaMetricsEnabled, forKey: Keys.ollamaMetricsEnabled) }
    }

    @Published var ollamaEndpoint: String {
        didSet { defaults.set(ollamaEndpoint, forKey: Keys.ollamaEndpoint) }
    }

    /// Where LM Studio's server answers. Defaults to the port LM Studio's own
    /// settings name, so a server moved off 1234 is found without typing.
    @Published var phoneLinkEnabled: Bool {
        didSet { defaults.set(phoneLinkEnabled, forKey: Keys.phoneLinkEnabled) }
    }

    @Published var phoneLinkPort: Int {
        didSet { defaults.set(phoneLinkPort, forKey: Keys.phoneLinkPort) }
    }


    @Published var lmstudioEndpoint: String {
        didSet { defaults.set(lmstudioEndpoint, forKey: Keys.lmstudioEndpoint) }
    }

    /// User-configured custom OpenAI-compatible endpoints.
    @Published var customEndpoints: [CustomEndpoint] {
        didSet {
            if let data = try? JSONEncoder().encode(customEndpoints) {
                defaults.set(data, forKey: Keys.customEndpoints)
            }
        }
    }

    /// Providers whose threshold alerts are muted. Stored as the muted set so
    /// a provider added later alerts by default. Connection is stored the
    /// other way: the ones that are on.
    @Published var mutedAlertProviders: Set<String> {
        didSet { defaults.set(Array(mutedAlertProviders), forKey: Keys.mutedAlerts) }
    }

    /// Names given to accounts in Settings, by provider id. Only the ones
    /// set: an account with no entry keeps the name its provider gives.
    @Published var accountNicknames: [String: String] {
        didSet { defaults.set(accountNicknames, forKey: Keys.accountNicknames) }
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

    /// Whether a frontmost full-screen app folds the notch away.
    @Published var foldsForFullScreen: Bool {
        didSet { defaults.set(foldsForFullScreen, forKey: Keys.foldsForFullScreen) }
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

    /// Whether Claude's big ring shows the day's share of the weekly limit
    /// instead of the session. See `DailyPace`.
    @Published var claudeDailyPaceRing: Bool {
        didSet { defaults.set(claudeDailyPaceRing, forKey: Keys.claudeDailyPaceRing) }
    }

    /// Whether the big ring shows the weekly limit instead of the shorter
    /// window, for every provider that has both. See `WeeklyHeadline`.
    @Published var weeklyHeadline: Bool {
        didSet { defaults.set(weeklyHeadline, forKey: Keys.weeklyHeadline) }
    }

    /// Whether Spark and code-review Codex windows appear in the hover card.
    /// On by default so a first launch shows them; the ring still follows
    /// the main Codex window either way.
    @Published var showCodexExtraLimits: Bool {
        didSet { defaults.set(showCodexExtraLimits, forKey: Keys.showCodexExtraLimits) }
    }

    /// Whether DeepSeek's current peak/off-peak billing phase is shown in its
    /// usage card. Enabled by default because the card's pricing rows are
    /// useful only when the rule is visible and understood.
    @Published var deepSeekPricingEnabled: Bool {
        didSet { defaults.set(deepSeekPricingEnabled, forKey: Keys.deepSeekPricingEnabled) }
    }

    /// The locally maintained DeepSeek billing rule. It is stored as one
    /// Codable value so adding another rule field does not scatter more keys
    /// through the preferences store.
    @Published var deepSeekPricingSchedule: DeepSeekPricing.Schedule {
        didSet {
            let normalized = deepSeekPricingSchedule.normalized
            if normalized != deepSeekPricingSchedule {
                deepSeekPricingSchedule = normalized
                return
            }
            guard let data = try? JSONEncoder().encode(deepSeekPricingSchedule) else { return }
            defaults.set(data, forKey: Keys.deepSeekPricingSchedule)
        }
    }

    func resetDeepSeekPricingSchedule() {
        deepSeekPricingSchedule = .current
    }

    /// Whether the weekly limit gets a ring of its own, and where it sits.
    /// Whether each ring carries its percentage under it, on every edge.
    ///
    /// On by default, which is what the notch has always drawn everywhere but
    /// the strip beside a Mac's own cutout. There it costs ring size, because
    /// the bar is the cutout's depth and one ring already fills it — see
    /// `NotchViewModel.showsCellReading`.
    @Published var showsNotchReadings: Bool {
        didSet { defaults.set(showsNotchReadings, forKey: Keys.showsNotchReadings) }
    }

    @Published var weeklyRingDashed: Bool {
        didSet { defaults.set(weeklyRingDashed, forKey: Keys.weeklyRingDashed) }
    }

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

    @Published var watchLimit: Double {
        didSet {
            let clamped = min(max(watchLimit, 0.01), criticalLimit - 0.01)
            if clamped != watchLimit { watchLimit = clamped; return }
            defaults.set(watchLimit, forKey: Keys.watchLimit)
        }
    }

    @Published var criticalLimit: Double {
        didSet {
            let clamped = min(max(criticalLimit, watchLimit + 0.01), 1.0)
            if clamped != criticalLimit { criticalLimit = clamped; return }
            defaults.set(criticalLimit, forKey: Keys.criticalLimit)
        }
    }

    /// Hard step or continuous ramp — see `ColorTransitionStyle`.
    @Published var colorTransitionStyle: ColorTransitionStyle {
        didSet { defaults.set(colorTransitionStyle.rawValue, forKey: Keys.colorTransitionStyle) }
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

    /// Whether the menu bar item shows five-hour limits instead of its icon.
    ///
    /// Off unless switched on. The item is the way into an app that has left
    /// the Dock, and an update that swapped it for a readout several times as
    /// wide — pushing everything beside it along, and on a notched MacBook
    /// perhaps off the bar altogether — would be a change nobody asked for.
    @Published var showsLimitsInMenuBar: Bool {
        didSet { defaults.set(showsLimitsInMenuBar, forKey: Keys.showsLimitsInMenuBar) }
    }

    /// Whether providers with a weekly allowance add its compact ring to the
    /// existing limit readout. Off by default so upgrades keep the exact menu
    /// bar width and appearance they had before this setting existed.
    @Published var showsWeeklyLimitInMenuBar: Bool {
        didSet { defaults.set(showsWeeklyLimitInMenuBar, forKey: Keys.showsWeeklyLimitInMenuBar) }
    }

    /// The providers the menu bar summarises when it does, as ids. Nil until
    /// the first choice — see `MenuBarLimits` for what that reads as. From
    /// then on it is the ones that are on, so a provider that turns up later
    /// stays out of the bar until someone puts it there.
    ///
    /// Never written alongside `connectedProviders`: one is what the menu bar
    /// shows, the other what Codenotch reads, and `MenuBarLimits` says why the
    /// two stay apart.
    @Published private(set) var menuBarProviders: Set<String>? {
        didSet {
            if let menuBarProviders {
                defaults.set(menuBarProviders.sorted(), forKey: Keys.menuBarProviders)
            } else {
                defaults.removeObject(forKey: Keys.menuBarProviders)
            }
        }
    }

    /// Both halves of the menu bar choice, the way the status item takes them.
    var menuBarLimits: MenuBarLimits {
        MenuBarLimits(isOn: showsLimitsInMenuBar, chosen: menuBarProviders)
    }

    /// The providers whose card in the menu is opened out, as ids.
    ///
    /// Closed is the base state, and closed is not nothing: the card still
    /// carries what the limits say — the windows, their bars, the percentages,
    /// the resets, and a block if there is one. What the switch adds is
    /// everything the notch's tooltip carries besides: the live sessions, a
    /// local model's readings, Codex's unused resets and account activity,
    /// DeepSeek's usage breakdown.
    ///
    /// Presentation only, and per provider. Nothing here decides what is read
    /// or how often — the same distinction `menuBarProviders` keeps.
    @Published private(set) var expandedDetailProviders: Set<String> {
        didSet {
            guard expandedDetailProviders != oldValue else { return }
            defaults.set(expandedDetailProviders.sorted(), forKey: Keys.expandedDetailProviders)
        }
    }

    func isDetailExpanded(_ providerID: String) -> Bool {
        expandedDetailProviders.contains(providerID)
    }

    func setDetailExpanded(_ expanded: Bool, for providerID: String) {
        if expanded {
            expandedDetailProviders.insert(providerID)
        } else {
            expandedDetailProviders.remove(providerID)
        }
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

    /// Which MiniMax console the Coding Plan is read from.
    ///
    /// International and China mainland are different hosts, and a key issued
    /// on one is refused by the other. Absent means never chosen, which is
    /// international.
    @Published var minimaxRegion: MiniMaxRegion {
        didSet { defaults.set(minimaxRegion.rawValue, forKey: Keys.minimaxRegion) }
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
        /// The old off-list. Kept so a 1.9 install can invert it once.
        static let disconnected = "hiddenProviders"
        static let connected = "connectedProviders"
        static let seen = "seenProviders"
        static let disabledModels = "disabledModels"
        static let ollamaEndpoint = "ollamaEndpoint"
        static let phoneLinkEnabled = "phoneLinkEnabled"
        static let phoneLinkPort = "phoneLinkPort"

        static let lmstudioEndpoint = "lmstudioEndpoint"
        static let introducedOllama = "introducedOllama"
        static let migratedOllamaID = "migratedOllamaLocalID"
        static let ollamaMetricsEnabled = "ollamaMetricsEnabled"
        static let mutedAlerts = "mutedAlertProviders"
        static let accountNicknames = "accountNicknames"
        static let hasLaunched = "hasLaunchedBefore"
        static let visibility = "notchVisibility"
        static let foldsForFullScreen = "foldsForFullScreen"
        static let presence = "appPresence"
        static let showsLimitsInMenuBar = "showsLimitsInMenuBar"
        static let showsWeeklyLimitInMenuBar = "showsWeeklyLimitInMenuBar"
        static let menuBarProviders = "menuBarProviders"
        static let expandedDetailProviders = "expandedDetailProviders"
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
        static let weeklyRingDashed = "weeklyRingDashed"
        static let showsNotchReadings = "showsNotchReadings"
        static let claudeDailyPaceRing = "claudeDailyPaceRing"
        static let weeklyHeadline = "weeklyHeadline"
        static let showsMoveHandle = "showsMoveHandle"
        static let notchSurfaceStyle = "notchSurfaceStyle"
        static let watchLimit = "watchLimit"
        static let criticalLimit = "criticalLimit"
        static let colorTransitionStyle = "colorTransitionStyle"
        static let customEndpoints = "customEndpoints"
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
        static let minimaxRegion = "minimaxRegion"
        static let antigravityHeadlineLimit = "antigravityHeadlineLimit"
        static let antigravityHeadlineModel = "antigravityHeadlineModel"
        static let deepSeekPricingEnabled = "deepSeekPricingEnabled"
        static let deepSeekPricingSchedule = "deepSeekPricingSchedule"
        static let showCodexExtraLimits = "showCodexExtraLimits"
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

    /// Whether extra Codex windows (Spark, code review) are shown, read off
    /// the main actor.
    ///
    /// The Codex provider is an actor and asks for this on every fetch, and
    /// `@Published` state is main-actor-isolated where `UserDefaults` is
    /// thread-safe — so the provider reads the store, not the object. Absent
    /// means on: a first launch should show them. `bool(forKey:)` cannot stand
    /// in for that default — it answers false for a key that was never written.
    nonisolated static func storedShowCodexExtraLimits(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: Keys.showCodexExtraLimits) as? Bool ?? true
    }

    /// The MiniMax region read straight from disk, off the main actor.
    ///
    /// Custom endpoints read straight from disk, off the main actor.
    ///
    /// Moves any key an earlier build left in the defaults plist into the keychain,
    /// once, and writes the list back without it.
    ///
    /// The rewrite is the point. `customEndpoints` is assigned during `init`, where
    /// `didSet` does not run, so without this the plaintext key stayed in the plist —
    /// readable by any process running as the user, and swept into backups — until
    /// the user happened to edit that endpoint. Returns the list with the carried
    /// keys cleared, so a later encode cannot put them back.
    nonisolated static func movingLegacyKeysToKeychain(
        _ list: [CustomEndpoint],
        defaults: UserDefaults
    ) -> [CustomEndpoint] {
        guard list.contains(where: { $0.legacyAPIKey != nil }) else { return list }
        var migrated = list
        for index in migrated.indices {
            guard let legacy = migrated[index].legacyAPIKey else { continue }
            // Only if the keychain has nothing: a key already moved is the newer one.
            if migrated[index].apiKey == nil {
                migrated[index].saveAPIKey(legacy)
            }
            migrated[index].legacyAPIKey = nil
        }
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: Keys.customEndpoints)
        }
        return migrated
    }

    /// Custom endpoint providers are actors and ask for this on every fetch, and
    /// `@Published` state is main-actor-isolated where `UserDefaults` is
    /// thread-safe — so providers read the store, not the object.
    nonisolated static func storedCustomEndpoints(
        defaults: UserDefaults = .standard
    ) -> [CustomEndpoint] {
        guard let data = defaults.data(forKey: Keys.customEndpoints),
              let endpoints = try? JSONDecoder().decode([CustomEndpoint].self, from: data)
        else { return [] }
        return endpoints
    }

    /// The MiniMax region read straight from disk, off the main actor.
    ///
    /// The provider is an actor and asks for this on every fetch, and
    /// `@Published` state is main-actor-isolated where `UserDefaults` is
    /// thread-safe — so the provider reads the store, not the object.
    nonisolated static func storedMinimaxRegion(
        defaults: UserDefaults = .standard
    ) -> MiniMaxRegion {
        guard let value = defaults.string(forKey: Keys.minimaxRegion),
              let region = MiniMaxRegion(rawValue: value)
        else { return .international }
        return region
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
        let storedConnected = defaults.stringArray(forKey: Keys.connected)
        let storedSeen = Set(defaults.stringArray(forKey: Keys.seen) ?? [])
        let connected: Set<String>
        let seen: Set<String>
        let hidden: Set<String>?
        if let storedConnected {
            connected = Set(storedConnected)
            seen = storedSeen.isEmpty ? connected : storedSeen
            hidden = nil
        } else if defaults.object(forKey: Keys.disconnected) != nil {
            // An empty off-list is still a choice: everyone was on.
            hidden = Set(defaults.stringArray(forKey: Keys.disconnected) ?? [])
            connected = []
            seen = storedSeen
        } else if !self.isFirstLaunch || defaults.bool(forKey: Keys.introducedOllama) {
            // Launched before this key existed, and never hid anyone.
            hidden = []
            connected = []
            seen = storedSeen
        } else {
            hidden = nil
            connected = []
            seen = storedSeen
        }
        self.connectedProviders = connected.filter { !Self.isModelCell($0) }
        self.seenProviders = seen.filter { !Self.isModelCell($0) }
        self.pendingHidden = hidden
        let models: Set<String>
        if let storedDisabled = defaults.stringArray(forKey: Keys.disabledModels) {
            models = Set(storedDisabled)
        } else {
            // Model cells that lived on the old off-list stay off. Read the
            // leftover even after `connectedProviders` exists: an earlier
            // invert left those ids in `hiddenProviders` and then ignored them.
            let leftover = hidden ?? Set(defaults.stringArray(forKey: Keys.disconnected) ?? [])
            models = leftover.filter(Self.isModelCell)
        }
        self.disabledModels = models
        defaults.set(Array(models), forKey: Keys.disabledModels)
        let ollamaOn: Bool
        if storedConnected != nil {
            ollamaOn = connected.contains("ollama-local")
        } else if let hidden {
            ollamaOn = !hidden.contains("ollama-local")
        } else {
            ollamaOn = false
        }
        self.ollamaMetricsEnabled = defaults.object(forKey: Keys.ollamaMetricsEnabled) as? Bool
            ?? (defaults.bool(forKey: Keys.introducedOllama) && ollamaOn)
        self.ollamaEndpoint = (try? OllamaEndpoint.parse(
            defaults.string(forKey: Keys.ollamaEndpoint) ?? OllamaEndpoint.defaultAddress
        ).absoluteString) ?? OllamaEndpoint.defaultAddress
        // A stored choice wins; otherwise LM Studio's own configuration file
        // says where it listens, and 1234 is what it ships with.
        self.phoneLinkEnabled = defaults.object(forKey: Keys.phoneLinkEnabled) as? Bool ?? false
        self.phoneLinkPort = defaults.object(forKey: Keys.phoneLinkPort) as? Int ?? 8788

        self.lmstudioEndpoint = (try? LMStudioEndpoint.parse(
            defaults.string(forKey: Keys.lmstudioEndpoint)
                ?? LMStudioEndpoint.configuredAddress() ?? LMStudioEndpoint.defaultAddress
        ).absoluteString) ?? LMStudioEndpoint.defaultAddress
        self.mutedAlertProviders = Set(defaults.stringArray(forKey: Keys.mutedAlerts) ?? [])
        self.accountNicknames = defaults.dictionary(forKey: Keys.accountNicknames) as? [String: String] ?? [:]
        // Absent means never chosen, which is the hover behaviour the app was
        // designed around — not hidden, which would make a fresh install look
        // like it failed to start.
        self.notchVisibility = defaults.string(forKey: Keys.visibility)
            .flatMap(NotchVisibility.init(rawValue:)) ?? .onHover
        // Absent means the fold that has shipped since full-screen detection
        // exists — the setting silences it, it does not introduce it.
        self.foldsForFullScreen = defaults.object(forKey: Keys.foldsForFullScreen) as? Bool ?? true
        // Absent means never chosen. The Dock is the default because it is the
        // findable one — a new user who cannot see the app anywhere has no way
        // to learn it is running.
        self.appPresence = defaults.string(forKey: Keys.presence)
            .flatMap(AppPresence.init(rawValue:)) ?? .dock
        // Absent means never chosen, which is the icon every earlier version
        // drew — see `showsLimitsInMenuBar`.
        self.showsLimitsInMenuBar = defaults.bool(forKey: Keys.showsLimitsInMenuBar)
        // Absent means an install from before this option, which must retain
        // its existing compact status-item presentation.
        self.showsWeeklyLimitInMenuBar = defaults.bool(forKey: Keys.showsWeeklyLimitInMenuBar)
        // Absent is kept distinct from empty: never chosen is not choosing none.
        self.menuBarProviders = defaults.stringArray(forKey: Keys.menuBarProviders).map(Set.init)
        self.expandedDetailProviders = Set(
            defaults.stringArray(forKey: Keys.expandedDetailProviders) ?? []
        )
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
        // Off by default: it swaps what Claude's ring means, and that is a
        // choice for whoever budgets their week that way.
        self.claudeDailyPaceRing = defaults.bool(forKey: Keys.claudeDailyPaceRing)
        // Off by default for the same reason: it changes what every ring means.
        self.weeklyHeadline = defaults.bool(forKey: Keys.weeklyHeadline)
        self.showCodexExtraLimits = Self.storedShowCodexExtraLimits(defaults: defaults)
        self.deepSeekPricingEnabled = defaults.object(forKey: Keys.deepSeekPricingEnabled) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.deepSeekPricingSchedule),
           let schedule = try? JSONDecoder().decode(DeepSeekPricing.Schedule.self, from: data) {
            self.deepSeekPricingSchedule = schedule.normalized
        } else {
            self.deepSeekPricingSchedule = .current
        }
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
        self.weeklyRingDashed = defaults.object(forKey: Keys.weeklyRingDashed) as? Bool ?? false
        self.showsNotchReadings = defaults.object(forKey: Keys.showsNotchReadings) as? Bool ?? true

        self.weeklyRing = defaults.string(forKey: Keys.weeklyRing)
            .flatMap(WeeklyRing.init(rawValue:)) ?? .off
        // On unless turned off: it is how the notch is carried to another edge,
        // and a control that is missing by default is one nobody finds.
        self.showsMoveHandle = defaults.object(forKey: Keys.showsMoveHandle) as? Bool ?? true
        self.accentColor = defaults.string(forKey: Keys.accentColor)
            .flatMap(AccentColorChoice.init(rawValue:)) ?? .system
        self.notchSurfaceStyle = defaults.string(forKey: Keys.notchSurfaceStyle)
            .flatMap(NotchSurfaceStyle.init(rawValue:)) ?? .glass
        let storedWatchLimit = defaults.object(forKey: Keys.watchLimit) as? Double ?? 0.50
        let storedCriticalLimit = defaults.object(forKey: Keys.criticalLimit) as? Double ?? 0.70
        // `didSet` does the clamping, and it does not run for these assignments,
        // so a stored pair that crossed over is repaired here instead.
        let critical = min(max(storedCriticalLimit, 0.02), 1.0)
        self.criticalLimit = critical
        self.watchLimit = min(max(storedWatchLimit, 0.01), critical - 0.01)
        self.colorTransitionStyle = defaults.string(forKey: Keys.colorTransitionStyle)
            .flatMap(ColorTransitionStyle.init(rawValue:)) ?? .hardStep
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
        self.minimaxRegion = Self.storedMinimaxRegion(defaults: defaults)
        if let data = defaults.data(forKey: Keys.customEndpoints),
           let list = try? JSONDecoder().decode([CustomEndpoint].self, from: data) {
            self.customEndpoints = Self.movingLegacyKeysToKeychain(list, defaults: defaults)
        } else {
            self.customEndpoints = []
        }
        // Read from the system rather than from our own store: the user can turn
        // this off in System Settings, and a remembered `true` would then be a lie.
        self.launchAtLogin = Self.isRegisteredForLogin
    }

    // MARK: Custom Endpoints

    func addCustomEndpoint(_ endpoint: CustomEndpoint) {
        customEndpoints.append(endpoint)
        if endpoint.isEnabled {
            setConnected(true, for: endpoint.providerID)
        }
    }

    func updateCustomEndpoint(_ endpoint: CustomEndpoint) {
        if let idx = customEndpoints.firstIndex(where: { $0.id == endpoint.id }) {
            customEndpoints[idx] = endpoint
            setConnected(endpoint.isEnabled, for: endpoint.providerID)
        }
    }

    func removeCustomEndpoint(id: String) {
        if let endpoint = customEndpoints.first(where: { $0.id == id }) {
            setConnected(false, for: endpoint.providerID)
            if let filename = endpoint.customIconFilename {
                CustomIconStore.deleteIcon(filename: filename)
            }
        }
        customEndpoints.removeAll { $0.id == id }
    }

    // MARK: Account names

    func nickname(for providerID: String) -> String? {
        accountNicknames[providerID]
    }

    /// Blank, or only spaces, goes back to the provider's own name.
    func setNickname(_ name: String, for providerID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            accountNicknames.removeValue(forKey: providerID)
        } else {
            accountNicknames[providerID] = trimmed
        }
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

    // MARK: Menu bar

    /// Whether this provider is chosen for the menu bar. Says nothing about
    /// whether it is read — that is `isConnected`.
    func isInMenuBar(_ providerID: String) -> Bool {
        menuBarLimits.isChosen(providerID)
    }

    /// Put one provider in the menu bar or take it out. `listed` is every
    /// provider Settings is showing, which the first choice writes down.
    func setInMenuBar(_ shown: Bool, for providerID: String, among listed: [String]) {
        menuBarProviders = menuBarLimits.choosing(shown, providerID, among: listed).chosen
    }

    /// Claude and Codex stay on for a first install and for a newly discovered
    /// profile. Everyone else starts off.
    nonisolated static func isDefaultOnFamily(_ providerID: String) -> Bool {
        ClaudeProfile.isClaude(providerID: providerID)
            || CodexProfile.isCodex(providerID: providerID)
    }

    /// Model cells are `providerID:model:…`. A new loaded model is not a new
    /// provider, and absence on the provider on-list cannot mean on for these.
    static func isModelCell(_ id: String) -> Bool {
        id.contains(":model:")
    }

    func isConnected(_ providerID: String) -> Bool {
        if Self.isModelCell(providerID) {
            return !disabledModels.contains(providerID)
        }
        if defaults.object(forKey: Keys.connected) != nil {
            return connectedProviders.contains(providerID)
        }
        if let hidden = pendingHidden {
            // Absence from the old off-list means on — for providers that
            // off-list could have named. MiniMax did not exist then, so
            // missing from it is not a choice to show it.
            if providerID == "minimax" { return false }
            return !hidden.contains(providerID)
        }
        return Self.isDefaultOnFamily(providerID)
    }

    func setConnected(_ connected: Bool, for providerID: String) {
        if Self.isModelCell(providerID) {
            if connected {
                disabledModels.remove(providerID)
            } else {
                disabledModels.insert(providerID)
            }
            return
        }
        if defaults.object(forKey: Keys.connected) == nil, let hidden = pendingHidden {
            let next = connected ? hidden.subtracting([providerID]) : hidden.union([providerID])
            pendingHidden = next
            defaults.set(Array(next), forKey: Keys.disconnected)
            seenProviders.insert(providerID)
            return
        }
        if defaults.object(forKey: Keys.connected) == nil {
            // First install: persist Claude and Codex as on, then apply this toggle.
            connectedProviders = ["claude", "codex"]
        }
        if connected {
            connectedProviders.insert(providerID)
        } else {
            connectedProviders.remove(providerID)
        }
        seenProviders.insert(providerID)
    }

    /// Fold this Mac's current provider ids into the stored on-list.
    ///
    /// First launch writes Claude and Codex. An upgrade from `hiddenProviders`
    /// inverts that off-list against `discoveredIDs`. After that, only a
    /// never-seen Claude or Codex id is added automatically. Model cells stay
    /// on `disabledModels` and are not inverted.
    func reconcile(discoveredIDs: [String]) {
        let discovered = Set(discoveredIDs.filter { !Self.isModelCell($0) })
        if defaults.object(forKey: Keys.connected) != nil {
            connectedProviders.subtract(connectedProviders.filter(Self.isModelCell))
            seenProviders.subtract(seenProviders.filter(Self.isModelCell))
            let novel = discovered.subtracting(seenProviders)
            for id in novel where Self.isDefaultOnFamily(id) {
                connectedProviders.insert(id)
            }
            seenProviders.formUnion(discovered)
            return
        }
        if let hidden = pendingHidden {
            // Invert the old off-list, then drop MiniMax: it did not exist
            // when that list was written, so absence from it is not "on".
            connectedProviders = discovered
                .subtracting(hidden.filter { !Self.isModelCell($0) })
                .subtracting(["minimax"])
            seenProviders = discovered
            pendingHidden = nil
            return
        }
        connectedProviders = Set(discovered.filter(Self.isDefaultOnFamily))
        seenProviders = discovered
    }

    /// What `UsageStore` still treats as the off-list, among ids it knows.
    func disconnectedIDs(among discovered: [String]) -> Set<String> {
        Set(discovered.filter { !isConnected($0) })
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
