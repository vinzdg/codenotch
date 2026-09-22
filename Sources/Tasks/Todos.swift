import Foundation
import AppKit
import SwiftUI
import Combine
import ApplicationServices

// MARK: - Things 3 bridge (AppleScript)

struct Todo: Identifiable, Equatable {
    var id: String
    var name: String
    var due: String?          // "YYYY-MM-DD"
    var when: String?         // activation date, "YYYY-MM-DD"
    var project: String?
    var tags: String?
    var overdue: Bool {
        guard let due else { return false }
        return due < ThingsBridge.today()
    }
}

enum ThingsBridge {
    static let bundleID = "com.culturedcode.ThingsMac"
    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    private static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let out = script.executeAndReturnError(&err)
        if err != nil { return nil }
        return out.stringValue ?? ""
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Open to-dos of a built-in list ("Today", "Tomorrow", "Anytime"…), an area or a project.
    static func todos(in list: String) -> [Todo]? {
        let target: String
        if ["Inbox", "Today", "Tomorrow", "Anytime", "Upcoming", "Someday"].contains(list) {
            target = "to dos of list \"\(esc(list))\""
        } else {
            // A project or an area by name; only open items.
            target = "(to dos of (first item of (projects whose name is \"\(esc(list))\" & areas whose name is \"\(esc(list))\")) whose status is open)"
        }
        let script = """
        on ymd(d)
            if d is missing value then return ""
            set y to year of d as text
            set m to text -2 thru -1 of ("0" & ((month of d as integer) as text))
            set dd to text -2 thru -1 of ("0" & (day of d as text))
            return y & "-" & m & "-" & dd
        end ymd
        tell application "Things3"
            set us to ASCII character 31
            set rs to ASCII character 30
            set out to ""
            repeat with t in \(target)
                set pn to ""
                try
                    set pn to name of project of t
                end try
                if pn is "" then
                    try
                        set pn to name of area of t
                    end try
                end if
                set tg to ""
                try
                    set tg to tag names of t
                end try
                set out to out & (id of t) & us & (name of t) & us & (my ymd(due date of t)) & us & (my ymd(activation date of t)) & us & pn & us & tg & rs
            end repeat
            return out
        end tell
        """
        guard let text = run(script) else { return nil }
        return text.split(separator: "\u{1E}").compactMap { rec in
            let f = rec.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, !f[0].isEmpty else { return nil }
            return Todo(id: f[0], name: f[1], due: f[2].isEmpty ? nil : f[2], when: f[3].isEmpty ? nil : f[3],
                        project: f[4].isEmpty ? nil : f[4], tags: f[5].isEmpty ? nil : f[5])
        }
    }

    /// How many to-dos were completed today (they live in the Logbook).
    static func completedToday() -> Int {
        let script = """
        tell application "Things3"
            set startOfDay to (current date) - (time of (current date))
            return count of (to dos of list "Logbook" whose completion date ≥ startOfDay)
        end tell
        """
        return Int(run(script) ?? "") ?? 0
    }

    static func complete(_ id: String) -> Bool {
        run("tell application \"Things3\" to set status of to do id \"\(esc(id))\" to completed") != nil
    }

    static func reopen(_ id: String) -> Bool {
        run("tell application \"Things3\" to set status of to do id \"\(esc(id))\" to open") != nil
    }

    /// Creates a to-do in the given tab: Today / Tomorrow (dated), or inside a project/area.
    /// With `project`, the to-do goes into that project/area and keeps the tab's date.
    static func create(_ name: String, in list: String, project: String? = nil) -> Bool {
        let n = esc(name)
        if let project, !project.isEmpty {
            let dated: String
            switch list {
            case "Today": dated = "move t to list \"Today\""
            case "Tomorrow": dated = "set activation date of t to (current date) + 1 * days"
            default: dated = ""
            }
            let script = """
            tell application "Things3"
                set holders to (projects whose name is "\(esc(project))") & (areas whose name is "\(esc(project))")
                if (count of holders) > 0 then
                    set t to make new to do with properties {name:"\(n)"} at beginning of (first item of holders)
                else
                    set t to make new to do with properties {name:"\(n)"}
                end if
                \(dated)
            end tell
            """
            return run(script) != nil
        }
        let script: String
        switch list {
        case "Today":
            script = "tell application \"Things3\"\nset t to make new to do with properties {name:\"\(n)\"}\nmove t to list \"Today\"\nend tell"
        case "Tomorrow":
            script = "tell application \"Things3\"\nset t to make new to do with properties {name:\"\(n)\"}\nset activation date of t to (current date) + 1 * days\nend tell"
        case "Inbox", "Anytime", "Someday":
            script = "tell application \"Things3\"\nset t to make new to do with properties {name:\"\(n)\"}\nmove t to list \"\(esc(list))\"\nend tell"
        default:
            script = """
            tell application "Things3"
                set holders to (projects whose name is "\(esc(list))") & (areas whose name is "\(esc(list))")
                if (count of holders) > 0 then
                    make new to do with properties {name:"\(n)"} at beginning of (first item of holders)
                else
                    make new to do with properties {name:"\(n)"}
                end if
            end tell
            """
        }
        return run(script) != nil
    }

    /// Select a to-do inside `list` (the tab it was clicked in), in the window
    /// Things already has open. Things' own `show` always jumps to the item's
    /// home list (and opens a tab for it), so the row is selected through the
    /// Accessibility tree instead; without that permission the list is shown.
    static func show(_ id: String, in list: String = "Today", name: String = "") {
        guard !id.isEmpty else { return }
        let target: String
        if ["Inbox", "Today", "Tomorrow", "Anytime", "Upcoming", "Someday"].contains(list) {
            target = "show list \"\(esc(list))\""
        } else {
            target = "try\n show (first item of ((projects whose name is \"\(esc(list))\") & (areas whose name is \"\(esc(list))\")))\nend try"
        }
        _ = run("tell application \"Things3\"\nactivate\n\(target)\nend tell")
        guard !name.isEmpty else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { selectRow(named: name) }
    }

    /// Finds the first row in Things' front window whose text matches `name`
    /// and selects it.
    private static func selectRow(named name: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
        guard let windows = attr(appEl, kAXWindowsAttribute) as? [AXUIElement], let win = windows.first else { return }

        func text(of e: AXUIElement, depth: Int) -> String {
            var out = ""
            if let v = attr(e, kAXValueAttribute) as? String { out += v + " " }
            if let t = attr(e, kAXTitleAttribute) as? String { out += t + " " }
            if depth < 4, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
                for k in kids { out += text(of: k, depth: depth + 1) }
            }
            return out
        }
        var found: (row: AXUIElement, parent: AXUIElement)?
        func walk(_ e: AXUIElement, depth: Int) {
            guard found == nil, depth < 14 else { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if role == kAXOutlineRole as String || role == kAXTableRole as String || role == kAXListRole as String {
                let rows = (attr(e, kAXRowsAttribute) as? [AXUIElement]) ?? (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
                for r in rows where text(of: r, depth: 0).contains(name) { found = (r, e); return }
            }
            for k in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(k, depth: depth + 1) }
        }
        walk(win, depth: 0)
        guard let (row, parent) = found else { return }
        if AXUIElementSetAttributeValue(parent, kAXSelectedRowsAttribute as CFString, [row] as CFArray) != .success {
            AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// Open a list in Things: the built-in ones by id, others by name.
    static func showList(_ list: String) {
        let builtin = ["Inbox": "inbox", "Today": "today", "Tomorrow": "upcoming", "Anytime": "anytime",
                       "Upcoming": "upcoming", "Someday": "someday", "Logbook": "logbook"]
        let url: URL?
        if let id = builtin[list] { url = URL(string: "things:///show?id=\(id)") }
        else { url = URL(string: "things:///show?query=\(list.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? list)") }
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Names a user can pick for the third tab: areas first, then projects.
    static func pickableLists() -> [String] {
        let script = """
        tell application "Things3"
            set out to ""
            repeat with a in areas
                set out to out & (name of a) & linefeed
            end repeat
            repeat with p in projects
                set out to out & (name of p) & linefeed
            end repeat
            return out
        end tell
        """
        return (run(script) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

// MARK: - Store

/// Where tasks come from.
enum TaskSource: String, CaseIterable, Identifiable {
    case things, reminders, todoist
    var id: String { rawValue }
    var title: String {
        switch self {
        case .things: return "Things 3"
        case .reminders: return L10n.t("Reminders")
        case .todoist: return "Todoist"
        }
    }
    /// Every source is offered in Settings, installed or not: a choice that
    /// vanished when the app was missing read as the option having been
    /// removed. `isReady` says whether it can answer right now.
    var isAvailable: Bool { true }
    var isReady: Bool {
        switch self {
        case .things: return ThingsBridge.isInstalled
        case .reminders: return true
        case .todoist: return TodoistBridge.hasToken
        }
    }
    /// The picker's label, with the reason when it cannot answer yet.
    var menuTitle: String {
        switch self {
        case .things where !ThingsBridge.isInstalled: return L10n.t("Things 3 (not installed)")
        case .todoist where !TodoistBridge.hasToken: return L10n.t("Todoist (needs a token)")
        default: return title
        }
    }
    /// What the card says while the source cannot answer.
    var notReadyMessage: String {
        switch self {
        case .things: return L10n.t("Install Things 3 and open it once.")
        case .todoist: return L10n.t("Paste your Todoist API token in Settings › Tasks.")
        case .reminders: return L10n.t("Allow access to Reminders in System Settings.")
        }
    }
    static let key = "todoSource"
    static var current: TaskSource {
        if let s = TaskSource(rawValue: UserDefaults.standard.string(forKey: key) ?? "") { return s }
        return ThingsBridge.isInstalled ? .things : .reminders
    }

    func todos(in list: String) -> [Todo]? {
        switch self {
        case .things: return ThingsBridge.todos(in: list)
        case .reminders: return RemindersBridge.todos(in: list)
        case .todoist: return TodoistBridge.todos(in: list)
        }
    }
    func completedToday() -> Int {
        switch self {
        case .things: return ThingsBridge.completedToday()
        case .reminders: return RemindersBridge.completedToday()
        case .todoist: return TodoistBridge.completedToday()
        }
    }
    func complete(_ id: String) -> Bool {
        switch self {
        case .things: return ThingsBridge.complete(id)
        case .reminders: return RemindersBridge.complete(id)
        case .todoist: return TodoistBridge.complete(id)
        }
    }
    func create(_ name: String, in list: String, project: String? = nil) -> Bool {
        switch self {
        case .things: return ThingsBridge.create(name, in: list, project: project)
        case .reminders: return RemindersBridge.create(name, in: list, project: project)
        case .todoist: return TodoistBridge.create(name, in: list, project: project)
        }
    }
    func show(_ id: String, in list: String, name: String) {
        switch self {
        case .things: ThingsBridge.show(id, in: list, name: name)
        case .reminders: RemindersBridge.show(id)
        case .todoist: TodoistBridge.show(id)
        }
    }
    func showList(_ list: String) {
        switch self {
        case .things: ThingsBridge.showList(list)
        case .reminders: RemindersBridge.open()
        case .todoist: TodoistBridge.showList(list)
        }
    }
    func pickableLists() -> [String] {
        switch self {
        case .things: return ThingsBridge.pickableLists()
        case .reminders: return RemindersBridge.pickableLists()
        case .todoist: return TodoistBridge.pickableLists()
        }
    }
    /// Built-in lists offered for the third tab.
    var builtinLists: [String] { self == .things ? ["Anytime", "Inbox", "Someday"] : [] }
}

@MainActor
final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    enum Tab: String, CaseIterable, Identifiable {
        case today, tomorrow, custom
        var id: String { rawValue }
    }

    @Published private(set) var todos: [Tab: [Todo]] = [:]
    @Published private(set) var completedToday = 0
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var available = true
    var source: TaskSource {
        get { TaskSource.current }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: TaskSource.key); objectWillChange.send(); todos = [:]; refreshedAt = nil; refresh() }
    }
    @Published var tab: Tab = .today
    /// True while the quick-add field has the keyboard: the card must stay open.
    @Published var editing = false
    /// The field last typed in, so the card gives the keyboard back to it
    /// when it reopens.
    @Published var focusedField: String?
    /// Bumped when the card's own layout changes (e.g. "@" suggestions appear),
    /// so the panel re-measures the card.
    @Published var layoutTick = 0
    /// Rows of "@" suggestions currently shown (the card reserves their height).
    @Published var suggestionCount = 0
    /// Drafts of the two fields, kept here so hovering another ring does not wipe them.
    @Published var draft = ""
    @Published var draftProject = ""
    @Published var freeFocus = ""
    @Published var freeProject = ""
    @Published private(set) var busy: Set<String> = []       // ids being completed (animate out)
    @Published private(set) var lists: [String] = []

    var customKey: String { "todoCustomList-\(source.rawValue)" }
    var customList: String {
        get { UserDefaults.standard.string(forKey: customKey) ?? (source == .things ? "Anytime" : (lists.first ?? "")) }
        set { UserDefaults.standard.set(newValue, forKey: customKey); objectWillChange.send(); refresh() }
    }

    func listName(for tab: Tab) -> String {
        switch tab {
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .custom: return customList
        }
    }

    func title(for tab: Tab) -> String {
        switch tab {
        case .today: return L10n.t("Today")
        case .tomorrow: return L10n.t("Tomorrow")
        case .custom: return customList
        }
    }

    var openToday: Int { todos[.today]?.count ?? 0 }
    /// Ring progress: done ÷ (done + open) for today.
    var fraction: Double {
        let total = completedToday + openToday
        return total == 0 ? 0 : Double(completedToday) / Double(total)
    }

    private var timer: Timer?
    private var refreshing = false

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func start() { refresh() }

    func refresh() {
        guard available, !refreshing else { return }
        // A source that cannot answer yet says so in the card instead of
        // reading forever.
        guard source.isReady else {
            todos = [:]; lists = []; completedToday = 0; refreshedAt = Date()
            return
        }
        refreshing = true
        let custom = customList
        let src = source
        Task.detached(priority: .utility) {
            let today = src.todos(in: "Today") ?? []
            let tomorrow = src.todos(in: "Tomorrow") ?? []
            let other = custom.isEmpty ? [] : (src.todos(in: custom) ?? [])
            let done = src.completedToday()
            let lists = src.pickableLists()
            await MainActor.run {
                self.todos = [.today: today, .tomorrow: tomorrow, .custom: other]
                self.completedToday = done
                self.lists = lists
                self.refreshedAt = Date()
                self.refreshing = false
            }
        }
    }

    func complete(_ todo: Todo) {
        busy.insert(todo.id)
        let src = source
        Task.detached(priority: .userInitiated) {
            let ok = src.complete(todo.id)
            try? await Task.sleep(nanoseconds: 350_000_000)
            await MainActor.run {
                self.busy.remove(todo.id)
                guard ok else { return }
                for k in self.todos.keys { self.todos[k]?.removeAll { $0.id == todo.id } }
                if todo.when == ThingsBridge.today() || self.todos[.today]?.contains(where: { $0.id == todo.id }) == false {
                    self.completedToday += 1
                }
            }
        }
    }

    func create(_ name: String, project: String? = nil) {
        let list = listName(for: tab)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let src = source
        Task.detached(priority: .userInitiated) {
            _ = src.create(trimmed, in: list, project: project)
            await MainActor.run { self.refresh() }
        }
    }
}
