import Foundation

/// How a manual provider's quota window rolls over.
enum ManualResetSchedule: Codable, Equatable, Sendable {
    /// Resets every `interval` seconds from the start of the current window.
    case interval(TimeInterval)
    /// Resets daily at the specified hour and minute.
    case daily(hour: Int = 0, minute: Int = 0)
    /// Resets weekly on the specified weekday (1 = Sunday, 2 = Monday, etc.) at hour:minute.
    case weekly(weekday: Int = 2, hour: Int = 0, minute: Int = 0)
    /// Resets monthly on the specified day of month (1...31) at hour:minute.
    case monthly(day: Int = 1, hour: Int = 0, minute: Int = 0)
    /// Never resets automatically. The counter only rolls over when explicitly reset.
    case manualOnly

    var duration: TimeInterval? {
        switch self {
        case .interval(let seconds):
            return seconds > 0 ? seconds : nil
        case .daily:
            return 86400
        case .weekly:
            return 7 * 86400
        case .monthly, .manualOnly:
            return nil
        }
    }

    var identifier: String {
        switch self {
        case .interval(let seconds):
            if seconds == 3 * 3600 { return "3h" }
            if seconds == 4 * 3600 { return "4h" }
            if seconds == 5 * 3600 { return "5h" }
            if seconds == 12 * 3600 { return "12h" }
            if seconds == 24 * 3600 { return "24h" }
            return "interval_\(Int(seconds))"
        case .daily(let h, let m):
            return (h == 0 && m == 0) ? "daily" : "daily_\(h)_\(m)"
        case .weekly(let w, let h, let m):
            return (w == 2 && h == 0 && m == 0) ? "weekly" : "weekly_\(w)_\(h)_\(m)"
        case .monthly(let d, let h, let m):
            return (d == 1 && h == 0 && m == 0) ? "monthly" : "monthly_\(d)_\(h)_\(m)"
        case .manualOnly:
            return "manual"
        }
    }

    static func from(identifier: String) -> ManualResetSchedule? {
        switch identifier {
        case "3h": return .interval(3 * 3600)
        case "4h": return .interval(4 * 3600)
        case "5h": return .interval(5 * 3600)
        case "12h": return .interval(12 * 3600)
        case "24h": return .interval(24 * 3600)
        case "daily": return .daily(hour: 0, minute: 0)
        case "weekly": return .weekly(weekday: 2, hour: 0, minute: 0)
        case "monthly": return .monthly(day: 1, hour: 0, minute: 0)
        case "manual": return .manualOnly
        default:
            if identifier.hasPrefix("interval_"),
               let seconds = Double(identifier.dropFirst("interval_".count)), seconds > 0 {
                return .interval(seconds)
            }
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .interval(let seconds):
            let hours = seconds / 3600
            if hours == hours.rounded() && hours >= 1 {
                return L10n.t("Every \(Int(hours)) hours")
            } else {
                return L10n.t("Every \(Int(seconds / 60)) minutes")
            }
        case .daily:
            return L10n.t("Daily (midnight)")
        case .weekly:
            return L10n.t("Weekly (Monday)")
        case .monthly:
            return L10n.t("Monthly (1st)")
        case .manualOnly:
            return L10n.t("Manual reset only")
        }
    }

    static let standardOptions: [ManualResetSchedule] = [
        .interval(3 * 3600),
        .interval(5 * 3600),
        .daily(hour: 0, minute: 0),
        .weekly(weekday: 2, hour: 0, minute: 0),
        .monthly(day: 1, hour: 0, minute: 0),
        .manualOnly
    ]

    /// Returns the window start and next reset time for the window covering `date`.
    func windowBounds(around date: Date, windowStart: Date, calendar: Calendar = .current) -> (start: Date, resetsAt: Date?) {
        switch self {
        case .interval(let seconds):
            guard seconds > 0 else { return (date, nil) }
            let elapsed = date.timeIntervalSince(windowStart)
            if elapsed < 0 {
                return (date, date.addingTimeInterval(seconds))
            }
            let periods = floor(elapsed / seconds)
            let currentStart = windowStart.addingTimeInterval(periods * seconds)
            let nextReset = currentStart.addingTimeInterval(seconds)
            return (currentStart, nextReset)

        case .daily(let hour, let minute):
            var comp = calendar.dateComponents([.year, .month, .day], from: date)
            comp.hour = hour
            comp.minute = minute
            comp.second = 0
            guard let targetToday = calendar.date(from: comp) else { return (date, nil) }
            if date >= targetToday {
                let nextDay = calendar.date(byAdding: .day, value: 1, to: targetToday)
                return (targetToday, nextDay)
            } else {
                let prevDay = calendar.date(byAdding: .day, value: -1, to: targetToday) ?? date
                return (prevDay, targetToday)
            }

        case .weekly(let weekday, let hour, let minute):
            var comp = DateComponents()
            comp.weekday = weekday
            comp.hour = hour
            comp.minute = minute
            comp.second = 0
            let start = calendar.nextDate(after: date, matching: comp, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .backward) ?? date
            let next = calendar.nextDate(after: date, matching: comp, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            return (start, next)

        case .monthly(let day, let hour, let minute):
            var comp = DateComponents()
            comp.day = day
            comp.hour = hour
            comp.minute = minute
            comp.second = 0
            let start = calendar.nextDate(after: date, matching: comp, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .backward) ?? date
            let next = calendar.nextDate(after: date, matching: comp, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            return (start, next)

        case .manualOnly:
            return (windowStart, nil)
        }
    }
}

/// Persistent state for a manual provider.
struct ManualUsageState: Codable, Equatable, Sendable {
    var used: Int
    var windowStart: Date
    var lastResetAt: Date
    var limit: Int?
    var schedule: ManualResetSchedule
    var unit: String
    var label: String?
}

/// Abstract storage for manual provider persistence.
protocol ManualStorage: Sendable {
    func loadState(for providerID: String) -> ManualUsageState?
    func saveState(_ state: ManualUsageState, for providerID: String)
}

final class UserDefaultsManualStorage: ManualStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String

    init(defaults: UserDefaults = .standard, prefix: String = "manualProvider_") {
        self.defaults = defaults
        self.prefix = prefix
    }

    func loadState(for providerID: String) -> ManualUsageState? {
        guard let data = defaults.data(forKey: prefix + providerID) else { return nil }
        return try? JSONDecoder().decode(ManualUsageState.self, from: data)
    }

    func saveState(_ state: ManualUsageState, for providerID: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: prefix + providerID)
    }
}

final class InMemoryManualStorage: ManualStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: ManualUsageState] = [:]

    init(initialStates: [String: ManualUsageState] = [:]) {
        self.states = initialStates
    }

    func loadState(for providerID: String) -> ManualUsageState? {
        lock.lock()
        defer { lock.unlock() }
        return states[providerID]
    }

    func saveState(_ state: ManualUsageState, for providerID: String) {
        lock.lock()
        defer { lock.unlock() }
        states[providerID] = state
    }
}

/// Tracks usage against user-declared limits with local app-side counting
/// and reset scheduling for providers that publish no rate-limit APIs.
actor ManualProvider: UsageProvider {
    static let defaultID = "manual"
    static let defaultDisplayName = "Manual"
    static let defaultGlyph = ProviderGlyph.third

    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph: ProviderGlyph

    private let storage: ManualStorage
    private let calendar: Calendar
    private var state: ManualUsageState

    private let isSimulatedTime: Bool
    private var simulatedDate: Date

    private func currentDate(override: Date? = nil) -> Date {
        if let override {
            if isSimulatedTime {
                simulatedDate = max(simulatedDate, override)
            }
            return override
        }
        if isSimulatedTime {
            return simulatedDate
        }
        return Date()
    }

    private let limitClosure: (@Sendable () -> Int?)?
    private let scheduleClosure: (@Sendable () -> ManualResetSchedule?)?

    var onChanged: (@Sendable () -> Void)?

    nonisolated(unsafe) private var cachedAccount: ProviderAccount?

    init(
        id: String = ManualProvider.defaultID,
        displayName: String = ManualProvider.defaultDisplayName,
        glyph: ProviderGlyph = ManualProvider.defaultGlyph,
        limit: Int? = nil,
        schedule: ManualResetSchedule = .interval(3 * 3600),
        unit: String = "requests",
        label: String? = nil,
        limitProvider: (@Sendable () -> Int?)? = nil,
        scheduleProvider: (@Sendable () -> ManualResetSchedule?)? = nil,
        storage: ManualStorage? = nil,
        calendar: Calendar = .current,
        now: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.glyph = glyph
        self.limitClosure = limitProvider
        self.scheduleClosure = scheduleProvider
        let store = storage ?? UserDefaultsManualStorage()
        self.storage = store
        self.calendar = calendar

        if let explicitNow = now {
            self.isSimulatedTime = true
            self.simulatedDate = explicitNow
        } else {
            self.isSimulatedTime = false
            self.simulatedDate = Date()
        }
        let startDate = self.simulatedDate

        if let existing = store.loadState(for: id) {
            self.state = existing
        } else {
            self.state = ManualUsageState(
                used: 0,
                windowStart: startDate,
                lastResetAt: startDate,
                limit: limit,
                schedule: schedule,
                unit: unit,
                label: label
            )
            store.saveState(self.state, for: id)
        }
        self.cachedAccount = Self.makeAccount(displayName: displayName, limit: limit, unit: unit)
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Counts usage locally against limits you declare."))
    }

    nonisolated func account() -> ProviderAccount? {
        cachedAccount
    }

    nonisolated var isVisibleWhenAbsent: Bool { true }

    // MARK: - Limit and Schedule Resolution

    private func effectiveLimit() -> Int? {
        if let closure = limitClosure, let val = closure() {
            return val > 0 ? val : nil
        }
        return state.limit.flatMap { $0 > 0 ? $0 : nil }
    }

    private func effectiveSchedule() -> ManualResetSchedule {
        if let closure = scheduleClosure, let val = closure() {
            return val
        }
        return state.schedule
    }

    // MARK: - Window Management & Rollover

    @discardableResult
    private func advanceWindowIfNeeded(at date: Date) -> Bool {
        let activeSchedule = effectiveSchedule()
        let bounds = activeSchedule.windowBounds(around: date, windowStart: state.windowStart, calendar: calendar)
        if bounds.start > state.windowStart {
            state.used = 0
            state.windowStart = bounds.start
            state.lastResetAt = bounds.start
            storage.saveState(state, for: id)
            updateCachedAccount()
            return true
        }
        return false
    }

    // MARK: - Mutating API

    func recordUsage(count: Int = 1, at date: Date? = nil) {
        let effectiveDate = currentDate(override: date)
        advanceWindowIfNeeded(at: effectiveDate)
        state.used = max(0, state.used + count)
        storage.saveState(state, for: id)
        updateCachedAccount()
        onChanged?()
    }

    func decrementUsage(count: Int = 1, at date: Date? = nil) {
        let effectiveDate = currentDate(override: date)
        advanceWindowIfNeeded(at: effectiveDate)
        state.used = max(0, state.used - count)
        storage.saveState(state, for: id)
        updateCachedAccount()
        onChanged?()
    }

    func setUsed(_ count: Int, at date: Date? = nil) {
        let effectiveDate = currentDate(override: date)
        advanceWindowIfNeeded(at: effectiveDate)
        state.used = max(0, count)
        storage.saveState(state, for: id)
        updateCachedAccount()
        onChanged?()
    }

    func reset(at date: Date? = nil) {
        let effectiveDate = currentDate(override: date)
        let activeSchedule = effectiveSchedule()
        let bounds = activeSchedule.windowBounds(around: effectiveDate, windowStart: effectiveDate, calendar: calendar)
        state.used = 0
        state.windowStart = bounds.start
        state.lastResetAt = effectiveDate
        storage.saveState(state, for: id)
        updateCachedAccount()
        onChanged?()
    }

    func setLimit(_ limit: Int?) {
        state.limit = limit
        storage.saveState(state, for: id)
        updateCachedAccount()
        onChanged?()
    }

    func setSchedule(_ schedule: ManualResetSchedule, at date: Date? = nil) {
        let effectiveDate = currentDate(override: date)
        state.schedule = schedule
        let bounds = schedule.windowBounds(around: effectiveDate, windowStart: effectiveDate, calendar: calendar)
        state.windowStart = bounds.start
        storage.saveState(state, for: id)
        updateCachedAccount()
        onChanged?()
    }

    func setLabel(_ label: String?) {
        state.label = label
        storage.saveState(state, for: id)
        onChanged?()
    }

    func setUnit(_ unit: String) {
        state.unit = unit
        storage.saveState(state, for: id)
        updateCachedAccount()
        onChanged?()
    }

    // MARK: - Query API

    func currentUsed() -> Int {
        advanceWindowIfNeeded(at: currentDate())
        return state.used
    }

    func currentLimit() -> Int? {
        effectiveLimit()
    }

    func currentSchedule() -> ManualResetSchedule {
        effectiveSchedule()
    }

    func currentResetsAt(at date: Date? = nil) -> Date? {
        let effectiveDate = currentDate(override: date)
        let activeSchedule = effectiveSchedule()
        return activeSchedule.windowBounds(around: effectiveDate, windowStart: state.windowStart, calendar: calendar).resetsAt
    }

    // MARK: - Snapshot Generation

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let now = currentDate()
        advanceWindowIfNeeded(at: now)

        let activeLimit = effectiveLimit()
        let activeSchedule = effectiveSchedule()
        let bounds = activeSchedule.windowBounds(around: now, windowStart: state.windowStart, calendar: calendar)

        let resolvedLabel: String
        if let label = state.label, !label.isEmpty {
            resolvedLabel = label
        } else {
            resolvedLabel = Self.defaultLabel(for: activeSchedule, unit: state.unit, limit: activeLimit)
        }

        let usedFraction: Double?
        let remaining: Int?
        if let limit = activeLimit, limit > 0 {
            usedFraction = Double(state.used) / Double(limit)
            remaining = max(0, limit - state.used)
        } else {
            usedFraction = nil
            remaining = nil
        }

        let window = LimitWindow(
            id: "\(id).primary",
            label: resolvedLabel,
            usedFraction: usedFraction,
            remaining: remaining,
            used: state.used,
            resetsAt: bounds.resetsAt,
            duration: activeSchedule.duration
        )

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .manual,
            status: .ok,
            windows: [window],
            headlineID: "\(id).primary"
        )
    }

    // MARK: - Helpers

    private func updateCachedAccount() {
        let activeLimit = effectiveLimit()
        cachedAccount = Self.makeAccount(displayName: displayName, limit: activeLimit, unit: state.unit)
    }

    private static func makeAccount(displayName: String, limit: Int?, unit: String) -> ProviderAccount {
        let plan = limit.map { "\(LimitWindow.compact($0)) \(unit) limit" } ?? L10n.t("No limit set")
        return ProviderAccount(label: displayName, plan: plan, source: "Manual", manageURL: nil)
    }

    static func defaultLabel(for schedule: ManualResetSchedule, unit: String, limit: Int?) -> String {
        switch schedule {
        case .interval(let seconds):
            let hours = Int((seconds / 3600).rounded())
            if hours > 0 {
                return limit.map { "Limit: \(LimitWindow.compact($0)) \(unit) · \(hours)h" }
                    ?? "\(hours)h window"
            } else {
                return limit.map { "Limit: \(LimitWindow.compact($0)) \(unit)" }
                    ?? "\(unit.capitalized) this window"
            }
        case .daily:
            return limit.map { "Daily limit: \(LimitWindow.compact($0)) \(unit)" }
                ?? "Daily \(unit)"
        case .weekly:
            return limit.map { "Weekly limit: \(LimitWindow.compact($0)) \(unit)" }
                ?? "Weekly \(unit)"
        case .monthly:
            return limit.map { "Monthly limit: \(LimitWindow.compact($0)) \(unit)" }
                ?? "Monthly \(unit)"
        case .manualOnly:
            return limit.map { "Limit: \(LimitWindow.compact($0)) \(unit)" }
                ?? "\(unit.capitalized) count"
        }
    }
}
