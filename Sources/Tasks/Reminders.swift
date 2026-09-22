import Foundation
import AppKit
import EventKit

/// Apple Reminders through EventKit. Same shape as the Things bridge so the
/// store can switch sources.
enum RemindersBridge {
    static let store = EKEventStore()
    private static var accessAsked = false

    /// Asks once; later calls just report the state.
    static func ensureAccess() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14, *), status == .fullAccess { return true }
        if status == .authorized { return true }
        guard status == .notDetermined, !accessAsked else { return false }
        accessAsked = true
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        if #available(macOS 14, *) {
            store.requestFullAccessToReminders { ok, _ in granted = ok; sem.signal() }
        } else {
            store.requestAccess(to: .reminder) { ok, _ in granted = ok; sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 120)
        return granted
    }

    static var hasAccess: Bool {
        let s = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14, *), s == .fullAccess { return true }
        return s == .authorized
    }

    private static func fetch(_ predicate: NSPredicate) -> [EKReminder] {
        let sem = DispatchSemaphore(value: 0)
        var out: [EKReminder] = []
        store.fetchReminders(matching: predicate) { list in out = list ?? []; sem.signal() }
        _ = sem.wait(timeout: .now() + 20)
        return out
    }

    private static func ymd(_ c: DateComponents?) -> String? {
        guard let c, let y = c.year, let m = c.month, let d = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private static func todo(_ r: EKReminder) -> Todo {
        let due = ymd(r.dueDateComponents)
        return Todo(id: r.calendarItemIdentifier, name: r.title ?? "", due: due, when: due,
                    project: r.calendar?.title, tags: nil)
    }

    /// "Today" = due today or overdue; "Tomorrow" = due tomorrow; any other name = a list.
    static func todos(in list: String) -> [Todo]? {
        guard ensureAccess() else { return nil }
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: Date())
        let endToday = cal.date(byAdding: .day, value: 1, to: startToday)!
        let endTomorrow = cal.date(byAdding: .day, value: 2, to: startToday)!
        switch list {
        case "Today":
            let items = fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endToday, calendars: nil))
            return items.sorted { ($0.dueDateComponents?.date ?? .distantPast) < ($1.dueDateComponents?.date ?? .distantPast) }.map(todo)
        case "Tomorrow":
            let items = fetch(store.predicateForIncompleteReminders(withDueDateStarting: endToday, ending: endTomorrow, calendars: nil))
            return items.map(todo)
        default:
            guard let c = store.calendars(for: .reminder).first(where: { $0.title == list }) else { return [] }
            let items = fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [c]))
            return items.sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }.map(todo)
        }
    }

    static func completedToday() -> Int {
        guard hasAccess else { return 0 }
        let start = Calendar.current.startOfDay(for: Date())
        return fetch(store.predicateForCompletedReminders(withCompletionDateStarting: start, ending: nil, calendars: nil)).count
    }

    static func complete(_ id: String) -> Bool {
        guard hasAccess, let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        r.isCompleted = true
        return (try? store.save(r, commit: true)) != nil
    }

    static func create(_ name: String, in list: String, project: String? = nil) -> Bool {
        guard ensureAccess() else { return false }
        let r = EKReminder(eventStore: store)
        r.title = name
        let cal = Calendar.current
        let chosen = project.flatMap { p in store.calendars(for: .reminder).first { $0.title == p } }
        switch list {
        case "Today":
            r.dueDateComponents = cal.dateComponents([.year, .month, .day], from: Date())
            r.calendar = chosen ?? store.defaultCalendarForNewReminders()
        case "Tomorrow":
            r.dueDateComponents = cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: 1, to: Date())!)
            r.calendar = chosen ?? store.defaultCalendarForNewReminders()
        default:
            r.calendar = chosen ?? store.calendars(for: .reminder).first { $0.title == list } ?? store.defaultCalendarForNewReminders()
        }
        guard r.calendar != nil else { return false }
        return (try? store.save(r, commit: true)) != nil
    }

    static func show(_ id: String) {
        if !id.isEmpty, let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(id)") { NSWorkspace.shared.open(url); return }
        open()
    }

    static func open() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    static func pickableLists() -> [String] {
        guard hasAccess else { return [] }
        return store.calendars(for: .reminder).map(\.title).sorted()
    }
}
