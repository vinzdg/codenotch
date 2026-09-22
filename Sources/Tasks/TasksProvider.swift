import AppKit
import Foundation

/// A ring for the day's tasks (Things 3 or Reminders): done ÷ (done + open),
/// or the focus timer's progress while a task is in focus. Modelled as a
/// provider so it lives in the same list, order and display settings as the
/// usage rings — Codenotch never has to know it is not a vendor.
struct TasksProvider: UsageProvider {
    static let providerID = "tasks"
    let id = "tasks"
    var displayName: String { L10n.t("Tasks") }
    var glyph: ProviderGlyph { .tasks }

    @MainActor func fetchSnapshot() async throws -> ProviderSnapshot {
        let todos = TodoStore.shared
        let focus = FocusStore.shared
        if todos.refreshedAt == nil { todos.refresh() }
        var windows: [LimitWindow] = []
        if focus.isActive {
            windows.append(LimitWindow(id: "focus", label: L10n.t("Focus"),
                                       usedFraction: focus.fraction,
                                       usedText: FocusStore.clock(focus.elapsed),
                                       detail: focus.taskName, prefersUsedText: true))
        }
        let done = todos.completedToday, open = todos.openToday
        let total = done + open
        windows.append(LimitWindow(id: "today", label: L10n.t("Today"),
                                   usedFraction: total == 0 ? 0 : Double(done) / Double(total),
                                   remaining: open, used: done,
                                   usedText: "\(done)/\(total)", prefersUsedText: true))
        let ringGlyph: ProviderGlyph = focus.isActive ? (focus.isRunning ? .focus : .focusPaused) : .tasks
        var snapshot = ProviderSnapshot(id: id, displayName: displayName, glyph: ringGlyph,
                                        fidelity: .official, status: .ok, windows: windows)
        snapshot.headlineID = focus.isActive ? "focus" : "today"
        return snapshot
    }

    func account() -> ProviderAccount? {
        ProviderAccount(label: nil, plan: nil, source: TaskSource.current.title, manageURL: nil)
    }
    var signInRoute: SignInRoute {
        switch TaskSource.current {
        case .things: return .openApp(bundleID: ThingsBridge.bundleID, name: "Things 3")
        case .reminders: return .openApp(bundleID: "com.apple.reminders", name: L10n.t("Reminders"))
        case .todoist:
            return TodoistBridge.isInstalled
                ? .openApp(bundleID: TodoistBridge.bundleID, name: "Todoist")
                : .openApp(bundleID: "com.apple.Safari", name: "Todoist")
        }
    }
    func signOut() async {}
    func presentSignIn() { TaskSource.current.showList("Today") }
    func forgetCachedCredential() {}
    /// Off until someone switches it on in Accounts: not everyone keeps a task list.
    var isVisibleWhenAbsent: Bool { true }
}
