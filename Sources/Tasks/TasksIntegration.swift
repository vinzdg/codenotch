import AppKit
import Combine
import SwiftUI

/// Where the Tasks ring plugs into the app: the ring refreshes when the list
/// or the focus timer changes rather than at the next poll, a double click
/// on it opens the task app, and the Focus window opens from the menus.
@MainActor
enum Tasks {
    private static var focusTick: AnyCancellable?
    private static var todoTick: AnyCancellable?
    private static var focusWindow: NSWindow?

    static func attach(to store: UsageStore) {
        // A few seconds while a focus runs: the ring is the timer then.
        focusTick = FocusStore.shared.$now
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .sink { [weak store] _ in
                guard FocusStore.shared.isActive else { return }
                _ = store?.refresh(providerID: TasksProvider.providerID)
            }
        // At once on a change to the list or the task in focus.
        todoTick = Publishers.Merge3(
            TodoStore.shared.$todos.map { _ in () }.eraseToAnyPublisher(),
            TodoStore.shared.$completedToday.map { _ in () }.eraseToAnyPublisher(),
            FocusStore.shared.$taskID.map { _ in () }.eraseToAnyPublisher())
            .dropFirst(3)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak store] _ in _ = store?.refresh(providerID: TasksProvider.providerID) }
    }

    /// What a double click on the Tasks ring opens: the list the card is on,
    /// in the task app that owns it.
    static func open() {
        let store = TodoStore.shared
        store.source.showList(store.listName(for: store.tab))
    }

    static func showFocus() {
        if focusWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L10n.t("Focus")
            w.minSize = NSSize(width: 900, height: 560)
            w.contentViewController = NSHostingController(rootView: FocusPane().frame(minWidth: 900, minHeight: 560))
            w.isReleasedWhenClosed = false
            w.center()
            focusWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        focusWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Target for the menus' Focus… entry (AppKit needs an object).
final class TasksMenuActions: NSObject {
    @MainActor static let shared = TasksMenuActions()
    @MainActor @objc func openFocus(_ sender: Any?) { Tasks.showFocus() }
}
