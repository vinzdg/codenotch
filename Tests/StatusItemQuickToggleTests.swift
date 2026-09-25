import XCTest
import AppKit
@testable import Codenotch

/// The menu's own "Show limit information in menu bar" — the Settings switch,
/// reachable from the bar it changes.
///
/// What is pinned here is that it is *the same switch*: the tick is drawn from
/// the preference rather than from anything the menu remembers, and clicking it
/// writes that preference and nothing else. A second boolean anywhere would
/// break one of these.
@MainActor
final class StatusItemQuickToggleTests: XCTestCase {
    private func session(_ state: AgentSession.State, id: String) -> AgentSession {
        AgentSession(id: id, name: id, detail: "Terminal", state: state,
                     waitingFor: nil, since: Date())
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "StatusItemQuickToggleTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    private let title = "Show limit information in menu bar"

    private func toggleItem(in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title }, menu.items.map(\.title).joined(separator: "\n"))
    }

    /// Settings says on, the menu opens ticked; Settings says off, it opens
    /// clear. No refresh, no relaunch — the item is asked at open time.
    func testTheTickFollowsThePreference() throws {
        let controller = StatusItemController(onOpenSettings: {})
        let menu = NSMenu()

        controller.rebuild(menu: menu, now: Date())
        XCTAssertEqual(try toggleItem(in: menu).state, .off)

        controller.limits = MenuBarLimits(isOn: true, chosen: ["claude"])
        controller.rebuild(menu: menu, now: Date())
        XCTAssertEqual(try toggleItem(in: menu).state, .on)

        controller.limits = MenuBarLimits(isOn: false, chosen: ["claude"])
        controller.rebuild(menu: menu, now: Date())
        XCTAssertEqual(try toggleItem(in: menu).state, .off)
    }

    /// It asks for the opposite of what is showing, and asks once.
    func testClickingAsksForTheOpposite() throws {
        let controller = StatusItemController(onOpenSettings: {})
        var asked: [Bool] = []
        controller.onToggleLimits = { asked.append($0) }
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())

        let item = try toggleItem(in: menu)
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(item.target === controller)
        _ = controller.perform(action, with: item)
        XCTAssertEqual(asked, [true])

        controller.limits = MenuBarLimits(isOn: true, chosen: nil)
        _ = controller.perform(action, with: item)
        XCTAssertEqual(asked, [true, false])
    }

    /// Wired to the preference, the menu's switch is Settings' switch: it
    /// persists the same way, and off and on again gives back the same
    /// providers — the choice is untouched, and so is everything else on the
    /// Menu Bar page.
    func testItWritesTheSamePreferenceAndLeavesTheRestAlone() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        preferences.showsLimitsInMenuBar = true
        preferences.setInMenuBar(true, for: "gemini", among: ["claude", "codex", "gemini"])
        preferences.setInMenuBar(false, for: "codex", among: ["claude", "codex", "gemini"])
        preferences.resetTimeFormat = .remaining
        let chosen = preferences.menuBarProviders
        let read = preferences.connectedProviders

        let controller = StatusItemController(onOpenSettings: {})
        controller.onToggleLimits = { preferences.showsLimitsInMenuBar = $0 }
        controller.limits = preferences.menuBarLimits
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())
        let item = try toggleItem(in: menu)
        let action = try XCTUnwrap(item.action)

        _ = controller.perform(action, with: item)
        XCTAssertFalse(preferences.showsLimitsInMenuBar)
        XCTAssertEqual(preferences.menuBarProviders, chosen, "off is not a reset")
        XCTAssertEqual(preferences.connectedProviders, read)
        XCTAssertEqual(preferences.resetTimeFormat, .remaining)

        // What Settings would have shown, from the one place that holds it.
        let reopened = Preferences(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        XCTAssertFalse(reopened.showsLimitsInMenuBar, "the menu's choice survives a relaunch")

        controller.limits = preferences.menuBarLimits
        _ = controller.perform(action, with: item)
        XCTAssertTrue(preferences.showsLimitsInMenuBar)
        XCTAssertEqual(preferences.menuBarLimits, MenuBarLimits(isOn: true, chosen: chosen))
        XCTAssertTrue(preferences.isInMenuBar("gemini"))
        XCTAssertTrue(preferences.isInMenuBar("claude"))
        XCTAssertFalse(preferences.isInMenuBar("codex"))
    }

    /// It belongs with the utilities, not among the readings: a separator
    /// above it, and Refresh all, Settings and Quit still below.
    func testItSitsWithTheUtilitiesAndRegressesNothing() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = Fixtures.snapshots()
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())

        let titles = menu.items.map(\.title)
        let joined = titles.joined(separator: "\n")
        let index = try XCTUnwrap(titles.firstIndex(of: title), joined)
        XCTAssertTrue(menu.items[index - 1].isSeparatorItem, joined)
        let refresh = try XCTUnwrap(titles.firstIndex(of: L10n.t("Refresh all")), joined)
        let settings = try XCTUnwrap(titles.firstIndex(of: L10n.t("Settings…")), joined)
        let quit = try XCTUnwrap(titles.firstIndex(of: L10n.t("Quit Codenotch")), joined)
        XCTAssertTrue(index < refresh && refresh < settings && settings < quit, joined)
        XCTAssertTrue(titles.contains { $0.hasPrefix("Claude — ") }, "the readings are still there: \(joined)")
    }

    func testOnlyBusyProvidersBecomeActiveIndependently() {
        let controller = StatusItemController(onOpenSettings: {})

        controller.setActivity(providerID: "claude", sessions: [session(.idle, id: "claude-idle")])
        controller.setActivity(providerID: "codex", sessions: [session(.busy, id: "codex-busy")])
        XCTAssertEqual(controller.activeProviderIDs, ["codex"])

        controller.setActivity(providerID: "claude", sessions: [session(.busy, id: "claude-busy")])
        XCTAssertEqual(controller.activeProviderIDs, ["claude", "codex"])

        controller.setActivity(providerID: "codex", sessions: [session(.success, id: "codex-done")])
        XCTAssertEqual(controller.activeProviderIDs, ["claude"])
        controller.setActivity(providerID: "claude", sessions: [])
        XCTAssertTrue(controller.activeProviderIDs.isEmpty)
    }
}
