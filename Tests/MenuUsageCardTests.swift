import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

/// The menu bar's menu *is* the detailed presentation.
///
/// What is pinned here is that there is nowhere else to go: the cards are in
/// the menu that opens, they are the same view the notch's tooltip starts
/// from, and nothing in the menu offers a second surface to see them on.
@MainActor
final class MenuUsageCardTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "MenuUsageCardTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    private func session(_ name: String, _ state: AgentSession.State) -> AgentSession {
        AgentSession(id: name, name: name, detail: "Terminal", state: state,
                     waitingFor: nil, since: Date().addingTimeInterval(-90))
    }

    private func claude(session used: Double = 0.62, weekly: Double? = 0.81) -> ProviderSnapshot {
        var windows = [LimitWindow(id: "session", label: "Current session", usedFraction: used,
                                   resetsAt: Date().addingTimeInterval(2 * 3600))]
        if let weekly {
            windows.append(LimitWindow(id: "weekly", label: "All models", usedFraction: weekly,
                                       resetsAt: Date().addingTimeInterval(3 * 86400)))
        }
        return ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                                fidelity: .official, status: .ok, windows: windows)
    }

    private func render(_ view: some View) throws -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage)
    }

    // MARK: - One screen, no second one

    /// Opening the menu is the whole interaction: the cards are already there,
    /// and there is nothing to click to reach them.
    func testTheMenuOpensStraightOntoTheCards() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = Fixtures.snapshots()
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())

        let cards = menu.items.filter { $0.representedObject is String }
        XCTAssertEqual(cards.map { $0.representedObject as? String },
                       ["claude", "openai", "third"])
        XCTAssertTrue(cards.allSatisfy { $0.view != nil }, "a provider was drawn as text")

        // The cards come first, before anything that acts on them.
        let firstUtility = try XCTUnwrap(menu.items.firstIndex { $0.isSeparatorItem })
        XCTAssertTrue(menu.items.prefix(firstUtility).allSatisfy { $0.representedObject is String })
    }

    /// The cards are the whole of it: nothing in the menu is a way *to* a
    /// provider's readings, because they are already on screen. The switch
    /// that opens one out lives on its card, not among the menu's items.
    func testNothingInTheMenuOpensASecondSurface() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = Fixtures.snapshots()
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())

        let titles = menu.items.map(\.title)
        let joined = titles.joined(separator: "\n")
        XCTAssertFalse(titles.contains(L10n.t("Detail")), joined)

        // Only the utilities are commands; every provider row is inert.
        let commands = menu.items.filter { $0.action != nil }.map(\.title)
        XCTAssertEqual(Set(commands).subtracting([
            L10n.t("Show limit information in menu bar"),
            L10n.t("Refresh all"),
            L10n.t("Connect Phone…"),
            L10n.t("Settings…"),
            L10n.t("Quit Codenotch")
        ]), [], commands.joined(separator: "\n"))
    }

    /// The utilities are still there, still in order, still below the cards.
    func testTheUtilitiesSurviveTheChange() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = Fixtures.snapshots()
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())

        let titles = menu.items.map(\.title)
        let joined = titles.joined(separator: "\n")
        let toggle = try XCTUnwrap(titles.firstIndex(of: L10n.t("Show limit information in menu bar")), joined)
        let refresh = try XCTUnwrap(titles.firstIndex(of: L10n.t("Refresh all")), joined)
        let settings = try XCTUnwrap(titles.firstIndex(of: L10n.t("Settings…")), joined)
        let quit = try XCTUnwrap(titles.firstIndex(of: L10n.t("Quit Codenotch")), joined)
        XCTAssertTrue(toggle < refresh && refresh < settings && settings < quit, joined)
        XCTAssertTrue(menu.items[toggle - 1].isSeparatorItem, joined)

        var refreshed = 0
        controller.onRefreshAll = { refreshed += 1; return nil }
        let item = menu.items[refresh]
        _ = controller.perform(try XCTUnwrap(item.action), with: item)
        XCTAssertEqual(refreshed, 1)
    }

    // MARK: - Refresh all, with the menu still open

    private func refreshRow(in menu: NSMenu) throws -> MenuCommandRowView {
        let item = try XCTUnwrap(menu.items.first { $0.title == L10n.t("Refresh all") })
        return try XCTUnwrap(item.view as? MenuCommandRowView,
                             "Refresh all is AppKit's own row again, and AppKit closes the menu on it")
    }

    private func click(_ view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp,
                                         location: NSPoint(x: view.bounds.midX, y: view.bounds.midY),
                                         modifierFlags: [], timestamp: 0, windowNumber: 0,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }

    /// A pass that runs until it is let go.
    private func heldPass() -> (pass: Task<Void, Never>, release: () -> Void) {
        let (gate, opener) = AsyncStream<Void>.makeStream()
        return (Task { for await _ in gate {} }, { opener.finish() })
    }

    /// The row takes the click itself, so the menu — and the cards the refresh
    /// is for — stay on screen while the readings come in. It says it is
    /// working until the pass it started is over, and a second click in the
    /// meantime asks for nothing.
    func testRefreshAllRunsWithTheMenuStillOpenAndSaysSoUntilItIsDone() async throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = Fixtures.snapshots()
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())
        let row = try refreshRow(in: menu)

        let (pass, release) = heldPass()
        var asked = 0
        controller.onRefreshAll = { asked += 1; return pass }

        row.mouseUp(with: try click(row))
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(row.isBusy)

        row.mouseUp(with: try click(row))
        XCTAssertEqual(asked, 1, "a click while it was running asked for another pass")

        release()
        await pass.value
        for _ in 0..<50 where row.isBusy { await Task.yield() }
        XCTAssertFalse(row.isBusy, "the row still says it is refreshing after the pass ended")

        row.mouseUp(with: try click(row))
        XCTAssertEqual(asked, 2)
    }

    /// Reaching the row with the arrow keys and pressing Return refreshes too.
    /// AppKit hands that key to a row with a view instead of acting on it, and
    /// hands it over only while the row is the one highlighted — anything else
    /// is passed on, so Return on Settings… still opens Settings.
    func testReturnOnTheHighlightedRowRefreshesAndIsPassedOnOtherwise() throws {
        final class NextResponder: NSResponder {
            var keys = 0
            override func keyDown(with event: NSEvent) { keys += 1 }
        }
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = Fixtures.snapshots()
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())
        let row = try refreshRow(in: menu)
        let next = NextResponder()
        row.nextResponder = next

        var asked = 0
        controller.onRefreshAll = { asked += 1; return nil }
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                       timestamp: 0, windowNumber: 0, context: nil,
                                                       characters: "\r", charactersIgnoringModifiers: "\r",
                                                       isARepeat: false, keyCode: 36))

        // Not highlighted, it does not take the keyboard at all — a menu that
        // has just opened must not draw it highlighted.
        XCTAssertFalse(row.acceptsFirstResponder)
        row.keyDown(with: returnKey)
        XCTAssertEqual(asked, 0, "Return refreshed from a row that was not highlighted")
        XCTAssertEqual(next.keys, 1)

        controller.menu(menu, willHighlight: menu.items.first { $0.view === row })
        XCTAssertTrue(row.acceptsFirstResponder)
        row.keyDown(with: returnKey)
        XCTAssertEqual(asked, 1)
    }

    /// Taking the keyboard to answer Return must not cost the menu its Escape.
    func testEscapeOnTheRowStillClosesTheMenu() throws {
        final class RecordingMenu: NSMenu {
            var cancelled = 0
            override func cancelTracking() { cancelled += 1 }
        }
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = Fixtures.snapshots()
        let menu = RecordingMenu(title: "")
        controller.rebuild(menu: menu, now: Date())
        let row = try refreshRow(in: menu)
        controller.menu(menu, willHighlight: menu.items.first { $0.view === row })

        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil,
                                                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                    isARepeat: false, keyCode: 53))
        row.keyDown(with: escape)
        XCTAssertEqual(menu.cancelled, 1)
    }

    /// ⌘R still finds the item: a row with a view keeps its key equivalent.
    func testCommandRStillRefreshes() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = Fixtures.snapshots()
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())

        var asked = 0
        controller.onRefreshAll = { asked += 1; return nil }
        let commandR = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                      timestamp: 0, windowNumber: 0, context: nil,
                                                      characters: "r", charactersIgnoringModifiers: "r",
                                                      isARepeat: false, keyCode: 15))
        XCTAssertTrue(menu.performKeyEquivalent(with: commandR))
        XCTAssertEqual(asked, 1)
    }

    /// A pass can hang — a keychain prompt nobody has answered — and outlast
    /// the store's own deadline. The row stops waiting with the menu, so the
    /// next menu offers the command again instead of saying "Refreshing…" for
    /// as long as that prompt sits there.
    func testANextMenuDoesNotInheritAPassThatNeverEnded() async throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = Fixtures.snapshots()
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())

        let (pass, release) = heldPass()
        defer { release() }
        controller.onRefreshAll = { pass }
        let row = try refreshRow(in: menu)
        row.mouseUp(with: try click(row))
        XCTAssertTrue(row.isBusy)

        controller.menuDidClose(menu)
        controller.rebuild(menu: menu, now: Date())
        XCTAssertFalse(try refreshRow(in: menu).isBusy)
    }

    /// Nothing read yet is still a sentence rather than an empty menu.
    func testItSaysSoBeforeTheFirstReading() {
        let controller = StatusItemController(onOpenSettings: {})
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())
        XCTAssertEqual(menu.items.first?.title, L10n.t("Waiting for the first reading…"))
        XCTAssertNil(menu.items.first?.view)
    }

    // MARK: - What gets a card

    func testEveryProviderGetsACardAndALocalRuntimeGetsOnePerModel() {
        let cloud = Fixtures.snapshots()[0]
        let runtime = ProviderSnapshot(
            id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal,
            fidelity: .official, status: .ok, windows: [], kind: .localRuntime,
            localRuntime: LocalRuntimeReading(models: [
                LocalRuntimeReading.Model(name: "qwen3:8b", memoryBytes: 8_000_000_000,
                                          contextLength: 32_768, quantizationLevel: "Q4_K_M"),
                LocalRuntimeReading.Model(name: "gemma3:12b", memoryBytes: 12_000_000_000,
                                          contextLength: 8_192, quantizationLevel: "Q4_0")
            ]))

        let cells = ProviderOrder.cells(from: [cloud, runtime], keeping: [])
        let drawn = StatusItemController.cardsToDraw(for: [cloud, runtime], cells: cells)
        XCTAssertEqual(drawn.count, 3, "one for the cloud provider, one per loaded model")
        XCTAssertEqual(drawn.first?.id, cloud.id)
        XCTAssertTrue(drawn.dropFirst().allSatisfy { $0.localModel != nil })

        // Nothing loaded: the runtime keeps its own card rather than vanishing.
        let empty = ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal,
                                     fidelity: .official, status: .ok, windows: [], kind: .localRuntime,
                                     localRuntime: LocalRuntimeReading(models: []))
        XCTAssertEqual(StatusItemController.cardsToDraw(for: [empty], cells: []).map(\.id),
                       ["ollama-local"])
    }

    /// A card is as tall as the provider has limits — never a reserved row for
    /// one it does not publish.
    func testTheCardGrowsWithWhatTheProviderPublishes() throws {
        let now = Date()
        let one = try render(MenuUsageCard(snapshot: claude(weekly: nil), now: now).fixedSize())
        let two = try render(MenuUsageCard(snapshot: claude(), now: now).fixedSize())
        XCTAssertGreaterThan(two.size.height, one.size.height)
        XCTAssertEqual(one.size.width, two.size.width, "the card's width is the menu's")
    }

    /// The menu's card is the notch's limits, and only those: what the notch
    /// adds on top of them — its live sessions — belongs to the notch.
    func testTheCardIsTheNotchsLimitsAndTheNotchStillAddsToThem() throws {
        let snapshot = claude()
        let activity = ActivitySummary(sessions: [session("codenotch", .busy)])
        let now = Date()

        let limits = try render(
            ProviderLimitsContent(snapshot: snapshot, now: now)
                .fixedSize().background(Color.black)
        )
        let notch = try render(
            ProviderDetailContent(snapshot: snapshot, activity: activity, now: now)
                .fixedSize().background(Color.black)
        )
        XCTAssertGreaterThan(notch.size.height, limits.size.height,
                             "the notch stopped adding its sessions")
        XCTAssertGreaterThan(limits.size.height, 0)
    }

    // MARK: - The readings behind the cards

    /// The cards are drawn from the fleet's own model, so Watch and Critical,
    /// the accent and the reset wording are one setting each — not a second
    /// set the menu keeps.
    func testTheCardsFollowTheNotchsSettings() throws {
        let now = Date()
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        fleet.apply(watchLimit: 0.30, criticalLimit: 0.60)
        fleet.apply(resetTimeFormat: .remaining)
        fleet.apply(accentColor: .blue)

        let controller = StatusItemController(onOpenSettings: {})
        controller.model = fleet.menuModel
        controller.snapshots = Fixtures.snapshots(now: now)
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: now)

        // What the card draws, not what the model holds. Claude's session is
        // 73% in the fixtures: ample under the shipped thresholds, critical
        // under these, and the bar is the only thing that says so.
        let underTheseThresholds = try pixels(of: card(from: controller, for: "claude"))
        fleet.apply(watchLimit: 0.80, criticalLimit: 0.95)
        controller.rebuild(menu: menu, now: now)
        let underComfortableOnes = try pixels(of: card(from: controller, for: "claude"))
        XCTAssertNotEqual(underTheseThresholds, underComfortableOnes,
                          "the card ignored the Watch and Critical limits")

        // And the reset wording follows the same model: "Resets in 51 min"
        // rather than a date, because the fleet was told `.remaining`.
        XCTAssertTrue(try XCTUnwrap(menu.items.first { $0.representedObject as? String == "claude" }?
            .accessibilityLabel()).contains("Resets in"))
    }

    /// One card's hosting view, as the menu holds it.
    private func card(from controller: StatusItemController, for providerID: String) throws -> NSView {
        let menu = try XCTUnwrap(controller.builtMenuForTesting)
        return try XCTUnwrap(menu.items.first { $0.representedObject as? String == providerID }?.view)
    }

    /// What that view actually draws — the only thing that can tell whether a
    /// setting reached the bar rather than merely the model behind it.
    private func pixels(of view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Building the menu reads nothing: it draws the snapshots that already
    /// arrived, and asks no provider for anything.
    func testOpeningTheMenuFetchesNothing() {
        let controller = StatusItemController(onOpenSettings: { XCTFail("no settings") })
        controller.onRefreshAll = { XCTFail("the menu refreshed on open"); return nil }
        controller.snapshots = Fixtures.snapshots()
        let before = controller.snapshots

        let menu = NSMenu()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        XCTAssertEqual(controller.snapshots.map(\.id), before.map(\.id))
        XCTAssertEqual(controller.snapshots.map(\.usedFraction), before.map(\.usedFraction))
    }

    /// A reading that lands while the menu is up reaches the cards without the
    /// menu being torn down and rebuilt under AppKit.
    func testAReadingThatLandsWhileOpenRedrawsTheCards() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = Fixtures.snapshots()
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())
        let card = try XCTUnwrap(menu.items.first { $0.representedObject as? String == "claude" })
        let view = try XCTUnwrap(card.view)

        var moved = Fixtures.snapshots()
        moved[0].windows[0] = LimitWindow(id: moved[0].windows[0].id,
                                          label: moved[0].windows[0].label,
                                          usedFraction: 0.99)
        controller.snapshots = moved

        XCTAssertTrue(menu.items.first { $0.representedObject as? String == "claude" }?.view === view,
                      "the menu was rebuilt rather than redrawn")
    }

    /// Every card is told which appearance to draw in, and told the Mac's.
    ///
    /// Left untold, a hosting view built before it is installed resolves its
    /// colours against nothing in particular. Told the *menu bar's* tone — the
    /// status item button's, which macOS tints to the desktop behind it — the
    /// cards came out black under light menu items on a Mac in Light mode.
    func testEveryCardIsDrawnInTheMacsOwnAppearance() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = Fixtures.snapshots()
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())

        let expected = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let cards = menu.items.filter { $0.representedObject is String }
        XCTAssertFalse(cards.isEmpty)
        for card in cards {
            let view = try XCTUnwrap(card.view)
            XCTAssertNotNil(view.appearance, "a card was left to resolve its own colours")
            XCTAssertEqual(view.appearance?.name, expected,
                           "a card is drawn in an appearance the menu around it does not use")
        }
    }

    // MARK: - Light and dark

    private func render(_ view: some View, under name: NSAppearance.Name) throws -> NSBitmapImageRep {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var rep: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(
                content: view.environment(\.colorScheme, name == .darkAqua ? .dark : .light)
            )
            renderer.scale = 1
            rep = renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        }
        return try XCTUnwrap(rep)
    }

    private func luminance(_ rep: NSBitmapImageRep) -> (mean: Double, min: Double, max: Double) {
        var total = 0.0, low = 1.0, high = 0.0, count = 0.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let value = 0.2126 * Double(colour.redComponent)
                    + 0.7152 * Double(colour.greenComponent)
                    + 0.0722 * Double(colour.blueComponent)
                total += value
                low = Swift.min(low, value)
                high = Swift.max(high, value)
                count += 1
            }
        }
        return count == 0 ? (0, 0, 0) : (total / count, low, high)
    }

    /// The card belongs to whichever appearance the Mac is in: the surface
    /// follows it, and the ink stays off the surface either way.
    func testTheCardFollowsLightAndDarkAppearance() throws {
        let now = Date()
        let stack = VStack(spacing: 0) {
            MenuUsageCard(snapshot: claude(), now: now, resetTimeFormat: .remaining)
            MenuUsageCard(snapshot: Fixtures.snapshots()[1], now: now, resetTimeFormat: .remaining)
        }
        .background(Color(nsColor: .windowBackgroundColor))

        let lightRender = try render(stack, under: .aqua)
        let darkRender = try render(stack, under: .darkAqua)
        // Set MENU_CARD_RENDER_PATH and both are written there, so the menu
        // can be looked at rather than only measured.
        if let directory = ProcessInfo.processInfo.environment["MENU_CARD_RENDER_PATH"] {
            for (name, rep) in [("light", lightRender), ("dark", darkRender)] {
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                try png.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("menu-card-\(name).png"))
            }
        }

        let light = luminance(lightRender)
        let dark = luminance(darkRender)
        XCTAssertGreaterThan(light.mean, dark.mean, "the card did not follow the appearance")
        for (name, reading) in [("light", light), ("dark", dark)] {
            XCTAssertGreaterThan(reading.max - reading.min, 0.4,
                                 "\(name) left the ink and the surface too close together")
        }
    }

    // MARK: - The Detail switch

    /// Closed is the base state, and it is remembered per provider — never one
    /// switch for the lot, and never forgotten when the menu closes.
    func testTheSwitchIsPerProviderAndSurvivesARelaunch() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)

        XCTAssertFalse(preferences.isDetailExpanded("claude"), "closed is the base state")
        preferences.setDetailExpanded(true, for: "claude")
        XCTAssertTrue(preferences.isDetailExpanded("claude"))
        XCTAssertFalse(preferences.isDetailExpanded("codex"), "one provider, not all of them")

        let reopened = Preferences(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        XCTAssertTrue(reopened.isDetailExpanded("claude"), "the choice survives a relaunch")
        XCTAssertFalse(reopened.isDetailExpanded("codex"))
    }

    /// A click asks for the opposite of what its card is showing, and asks
    /// once. The controller decides nothing itself — the answer comes back
    /// through `expandedDetail`.
    func testTheSwitchAsksForTheOppositeAndKeepsNoAnswerOfItsOwn() throws {
        let controller = StatusItemController(onOpenSettings: {})
        var asked: [(String, Bool)] = []
        controller.onToggleDetail = { asked.append(($0, $1)) }
        controller.snapshots = Fixtures.snapshots()
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())

        let card = try XCTUnwrap(menu.items.first { $0.representedObject as? String == "claude" })
        let hosting = try XCTUnwrap(card.view as? MenuCardHostingView<AnyView>)
        hosting.onInteract?()
        XCTAssertEqual(asked.map(\.0), ["claude"])
        XCTAssertEqual(asked.map(\.1), [true])

        // Nothing moved until the preference came back.
        XCTAssertTrue(controller.expandedDetail.isEmpty)
        controller.expandedDetail = ["claude"]
        hosting.onInteract?()
        XCTAssertEqual(asked.map(\.1), [true, false], "it did not ask to close what is open")
    }

    /// Opening a card makes it taller, and the item it is in is re-measured —
    /// otherwise the menu would keep the height it laid out with and clip
    /// everything the switch just revealed.
    func testOpeningACardMakesItsItemTaller() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = Fixtures.snapshots()
        controller.activity = { _ in
            ActivitySummary(sessions: [self.session("codenotch", .busy),
                                       self.session("hivinz", .idle)])
        }
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())
        let card = try XCTUnwrap(menu.items.first { $0.representedObject as? String == "claude" })
        let closed = try XCTUnwrap(card.view).frame.height

        controller.expandedDetail = ["claude"]
        let opened = try XCTUnwrap(card.view).frame.height
        XCTAssertGreaterThan(opened, closed, "the card did not grow into its detail")

        controller.expandedDetail = []
        XCTAssertEqual(try XCTUnwrap(card.view).frame.height, closed, accuracy: 0.5,
                       "the card did not come back to its limits")
    }

    /// Closed, the card is the limits. Open, it is what the notch draws.
    func testClosedIsTheLimitsAndOpenIsTheNotchsCard() throws {
        let snapshot = claude()
        let activity = ActivitySummary(sessions: [session("codenotch", .busy),
                                                  session("hivinz", .idle)])
        let now = Date()

        let closed = try render(MenuUsageCard(snapshot: snapshot, activity: activity, now: now,
                                              isExpanded: false).fixedSize())
        let open = try render(MenuUsageCard(snapshot: snapshot, activity: activity, now: now,
                                            isExpanded: true).fixedSize())
        XCTAssertGreaterThan(open.size.height, closed.size.height)
        XCTAssertEqual(open.size.width, closed.size.width, "the switch changed the card's width")

        // And what it grew by is the notch's own extra — the same view, from
        // the same snapshot.
        let limits = try render(ProviderLimitsContent(snapshot: snapshot, now: now)
            .frame(width: MenuUsageCard.contentWidth).fixedSize())
        let notch = try render(ProviderDetailContent(snapshot: snapshot, activity: activity, now: now)
            .frame(width: MenuUsageCard.contentWidth).fixedSize())
        XCTAssertEqual(open.size.height - closed.size.height,
                       notch.size.height - limits.size.height, accuracy: 1,
                       "the menu grew by something other than the notch's sections")
    }

    /// The notch asks for nothing and gets everything: its card has no switch
    /// on it, and the default has to keep it that way.
    func testTheNotchIsUnaffectedByTheSwitch() throws {
        let snapshot = claude()
        let activity = ActivitySummary(sessions: [session("codenotch", .busy)])
        let now = Date()

        let byDefault = try render(
            ProviderDetailContent(snapshot: snapshot, activity: activity, now: now)
                .fixedSize().background(Color.black))
        let explicit = try render(
            ProviderDetailContent(snapshot: snapshot, activity: activity, now: now,
                                  showsExtendedDetail: true)
                .fixedSize().background(Color.black))
        XCTAssertEqual(byDefault.size, explicit.size)
    }

    // MARK: - A switch that stays put

    /// Where a card's switch lands inside its menu item, laid out the way the
    /// menu lays it out.
    private func switchFrame(for snapshot: ProviderSnapshot, expanded: Bool, now: Date) throws -> CGRect {
        var frame: CGRect?
        let hosting = MenuCardHostingView(rootView: MenuUsageCardItem.root(
            snapshot: snapshot, activity: ActivitySummary(sessions: [session("codenotch", .busy)]),
            now: now, resetTimeFormat: .automatic, deepSeekPricingEnabled: true,
            deepSeekPricingSchedule: .current, sessionCap: 5, accentColor: .blue,
            watchLimit: 0.7, criticalLimit: 0.9, isExpanded: expanded, onToggle: {},
            onSwitchFrame: { frame = $0 }))
        MenuUsageCardItem.resize(hosting)
        hosting.layoutSubtreeIfNeeded()
        return try XCTUnwrap(frame, "the card never reported its switch")
    }

    /// Flipping Detail changes what is under the header, never where the
    /// header's switch is — with or without a tier named under the title.
    ///
    /// The item is its card's fitting height rounded up to a whole point, and
    /// a card centred in that leftover moved by a different fraction open
    /// than closed.
    func testTheSwitchDoesNotMoveWhenItIsFlipped() throws {
        let now = Date()
        var tiered = claude(session: 0, weekly: 0.59)
        tiered.plan = "plus"
        for snapshot in [claude(session: 0.09, weekly: 0.5), tiered] {
            let closed = try switchFrame(for: snapshot, expanded: false, now: now)
            let open = try switchFrame(for: snapshot, expanded: true, now: now)
            XCTAssertEqual(closed.minY, open.minY, accuracy: 0.001, "the switch moved vertically")
            XCTAssertEqual(closed.minX, open.minX, accuracy: 0.001, "the switch moved horizontally")
            XCTAssertEqual(closed.size, open.size)
        }
        // And a tier line under the title does not push the switch down onto it.
        let plain = try switchFrame(for: claude(), expanded: false, now: now)
        let withTier = try switchFrame(for: tiered, expanded: false, now: now)
        XCTAssertEqual(plain.midY, withTier.midY, accuracy: 1,
                       "the switch followed the tier line instead of the title")
    }

    /// The top of an item's view, drawn as the menu would draw it.
    private func header(of hosting: NSView, height: CGFloat) throws -> NSBitmapImageRep {
        hosting.layoutSubtreeIfNeeded()
        let top = hosting.isFlipped ? 0 : hosting.bounds.height - height
        let rect = NSRect(x: 0, y: top, width: hosting.bounds.width, height: height)
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: rect))
        hosting.cacheDisplay(in: rect, to: rep)
        return rep
    }

    /// Flipping the switch hands the item a new card before the item has been
    /// re-measured, so for a moment an open card is laid out in a closed
    /// card's frame. Its header has to be where it will end up even then.
    ///
    /// It was not: a card taller than its frame kept its own height and was
    /// centred on the frame, which put the header half the growth too high —
    /// and the switch, animated, slid down into place from there.
    func testAnOpenedCardInTheClosedFrameKeepsItsHeaderInPlace() throws {
        let now = Date()
        var snapshot = claude(session: 0, weekly: 0.59)
        snapshot.plan = "plus"
        // Idle rows only: a busy ring turns with the clock, and two renders a
        // moment apart would differ for that alone.
        let activity = ActivitySummary(sessions: [session("codenotch", .idle),
                                                  session("hivinz", .idle)])
        func root(expanded: Bool) -> AnyView {
            MenuUsageCardItem.root(snapshot: snapshot, activity: activity, now: now,
                                   resetTimeFormat: .automatic, deepSeekPricingEnabled: true,
                                   deepSeekPricingSchedule: .current, sessionCap: 5,
                                   accentColor: .blue, watchLimit: 0.7, criticalLimit: 0.9,
                                   isExpanded: expanded, onToggle: {})
        }
        func host(_ root: AnyView) -> MenuCardHostingView<AnyView> {
            let hosting = MenuCardHostingView(rootView: root)
            hosting.appearance = NSAppearance(named: .aqua)
            MenuUsageCardItem.resize(hosting)
            return hosting
        }

        let settled = host(root(expanded: true))
        let midway = host(root(expanded: false))
        midway.rootView = root(expanded: true)
        XCTAssertLessThan(midway.frame.height, settled.frame.height,
                          "the item was re-measured before the check could see the old frame")

        let expected = try header(of: settled, height: 60)
        let actual = try header(of: midway, height: 60)
        XCTAssertEqual(actual.pixelsWide, expected.pixelsWide)
        XCTAssertEqual(actual.pixelsHigh, expected.pixelsHigh)
        var differing = 0
        for y in 0..<expected.pixelsHigh {
            for x in 0..<expected.pixelsWide {
                guard let a = actual.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let b = expected.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let delta = max(abs(a.redComponent - b.redComponent),
                                abs(a.greenComponent - b.greenComponent),
                                abs(a.blueComponent - b.blueComponent))
                if delta > 0.1 { differing += 1 }
            }
        }
        XCTAssertEqual(differing, 0, "the header is drawn somewhere else until the item is re-measured")
    }
}
