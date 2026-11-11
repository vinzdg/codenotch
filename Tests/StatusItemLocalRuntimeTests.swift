import XCTest
import AppKit
@testable import Codenotch

/// The menu bar's menu has to say about a local model what its cell says,
/// which the store's own snapshot of the runtime cannot: speed, phase, context
/// and today's tokens are put on the cells by the view model.
///
/// The menu draws cards now, so those facts are on the card and, in words, on
/// the item AppKit hands to accessibility. Both are checked here: a card that
/// drew from the raw provider snapshot instead of the cell would lose all of
/// them, and a card VoiceOver cannot read is a picture of a reading.
@MainActor
final class StatusItemLocalRuntimeTests: XCTestCase {
    private let qwen = LMStudioMetrics.cellID(instance: "qwen3.8-27b")

    private func lmstudio(_ instances: [(id: String, key: String, context: Int?)]) throws -> ProviderSnapshot {
        LMStudioFixtures.snapshot(try LMStudioUsage.parse(LMStudioFixtures.listing(instances: instances)))
    }

    private func spoken(_ menu: NSMenu) -> [String] {
        menu.items.compactMap { $0.accessibilityLabel() }
    }

    func testTheMenuDrawsACardPerLoadedModelWithWhatItsCellShows() throws {
        let runtime = try lmstudio([("qwen3.8-27b", "qwen/qwen3.8-27b", 32_768),
                                    ("flash-next-test", "qwen/qwen3.8-flash-next", 8192)])
        let ollamaData = try JSONSerialization.data(withJSONObject: ["models": [["name": "gemma4:e4b", "size": 4_831_838_208]]])
        let ollama = ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal, fidelity: .official,
                                      status: .ok, windows: [], kind: .localRuntime,
                                      localRuntime: try OllamaLocalUsage.parse(ollamaData))
        let cloud = Fixtures.snapshots()[0]

        // No `show()`: the fleet has no panels, and the menu's model is fed anyway.
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        fleet.setSnapshots([cloud, runtime, ollama])
        var ledger = LocalTokenLedger()
        ledger.record(LocalPrediction(instance: "qwen3.8-27b", at: Date().addingTimeInterval(-60),
                                      inputTokens: 20_000, outputTokens: 1_200), as: qwen)
        fleet.setLedger(ledger)
        fleet.setPerformances([qwen: try XCTUnwrap(LocalModelPerformance(outputTokens: 1200, tokensPerSecond: 24.1))],
                              source: "lmstudio")
        fleet.setLocalActivities([qwen: LocalModelActivity(phase: .processingPrompt, queued: 1, since: Date())])
        fleet.setThinkingModels(["gemma4:e4b": Date()])

        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = [cloud, runtime, ollama]
        controller.cells = { fleet.menuModel.snapshots }
        controller.activity = { fleet.menuModel.activity(for: $0) }
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())
        let titles = menu.items.map(\.title)
        let joined = titles.joined(separator: "\n")

        // One card per loaded model, plus the cloud provider's own.
        XCTAssertTrue(titles.contains("LM Studio — qwen3.8-27b"), joined)
        XCTAssertTrue(titles.contains("LM Studio — flash-next-test"), joined)
        XCTAssertTrue(titles.contains("Ollama — gemma4:e4b"), joined)
        XCTAssertTrue(titles.contains { $0.hasPrefix("Claude — 73%") }, joined)
        // The runtime itself has no card while its models have.
        XCTAssertFalse(titles.contains("LM Studio — 2 models loaded"), joined)

        // Every one of them is a card, not a line of text.
        let cards = menu.items.filter { $0.representedObject is String }
        XCTAssertEqual(cards.count, 4, joined)
        XCTAssertTrue(cards.allSatisfy { $0.view != nil }, "a provider row was left as plain text")
        XCTAssertTrue(cards.allSatisfy { $0.action == nil }, "a card is a reading, not a command")

        // And what the cell knows is in the words VoiceOver gets.
        let cell = try XCTUnwrap(fleet.menuModel.snapshots.first { $0.id == qwen })
        let heard = spoken(menu).joined(separator: "\n")
        XCTAssertTrue(
            heard.contains("qwen3.8-27b: \(cell.headlineText) · Prompt · 1 queued · Context 61% · Today 20k in · 1200 out"),
            heard)
        XCTAssertTrue(heard.contains("gemma4:e4b: \(expectedGigabytes(4.5)) · Thinking"), heard)

        // A hidden model has no cell, so it has no card.
        fleet.setSnapshots([cloud, ollama, runtime])
        fleet.menuModel.updateSnapshots(runtime.notchSnapshots.filter { $0.id == qwen } + [cloud])
        controller.rebuild(menu: menu, now: Date())
        XCTAssertFalse(menu.items.map(\.title).contains { $0.contains("flash-next-test") })
    }

    /// Nothing loaded means nothing to draw a limit row from, so the runtime
    /// keeps a card of its own and says why it is empty rather than vanishing.
    func testAnEmptyOrUnreachableRuntimeSaysSoOnce() throws {
        let controller = StatusItemController(onOpenSettings: {})
        let menu = NSMenu()
        controller.snapshots = [LMStudioFixtures.snapshot(LocalRuntimeReading(models: [], measuresSpeed: true))]
        controller.rebuild(menu: menu, now: Date())
        XCTAssertEqual(menu.items.map(\.title).first, "LM Studio — Server reachable · No models loaded")
        XCTAssertNotNil(menu.items.first?.view, "the runtime lost its card")
        XCTAssertEqual(menu.items[1].isSeparatorItem, true, "the summary is not repeated under the header")

        var down = LMStudioFixtures.snapshot(LocalRuntimeReading(models: [], measuresSpeed: true))
        down = ProviderSnapshot(id: down.id, displayName: down.displayName, glyph: down.glyph, fidelity: .official,
                                status: .error(LMStudioError.needsToken.localizedDescription), windows: [],
                                kind: .localRuntime)
        controller.snapshots = [down]
        controller.rebuild(menu: menu, now: Date())
        XCTAssertEqual(menu.items.map(\.title).first, "LM Studio — —")
        XCTAssertEqual(menu.items[1].isSeparatorItem, true)
        let heard = try XCTUnwrap(menu.items.first?.accessibilityLabel())
        XCTAssertTrue(heard.contains("API token"), heard)
    }
}
