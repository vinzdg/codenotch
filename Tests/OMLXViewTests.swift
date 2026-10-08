import XCTest
import SwiftUI
@testable import Codenotch

/// What oMLX's cells show on the notch and in the menu bar's menu: speed
/// measured by the runtime, the context ring, today's ledger, and the phase
/// and queue its admin endpoint reports.
@MainActor
final class OMLXViewTests: XCTestCase {
    private let qwen = OMLXMetrics.cellID(instance: "Qwen3.8-27B-oQ8e-mtp")
    private let flash = OMLXMetrics.cellID(instance: "Qwen3.8-flash-oQ4e")

    private func model(_ id: String, context: Int) -> [String: Any] {
        ["id": id, "loaded": true, "is_loading": false, "estimated_size": 1_000_000, "actual_size": 900_000,
         "engine_type": "vlm", "model_context_length": context, "max_context_window": context,
         "is_helper": false, "is_hidden": false]
    }

    private func runtime() throws -> ProviderSnapshot {
        OMLXFixtures.snapshot(try OMLXUsage.parse(OMLXFixtures.listing([
            model("Qwen3.8-27B-oQ8e-mtp", context: 32_768), model("Qwen3.8-flash-oQ4e", context: 8192)
        ])))
    }

    private func ollama(_ names: [String]) throws -> ProviderSnapshot {
        let data = try JSONSerialization.data(withJSONObject: ["models": names.map { ["name": $0, "size": 4_831_838_208] }])
        return ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal, fidelity: .official,
                                status: .ok, windows: [], kind: .localRuntime, localRuntime: try OllamaLocalUsage.parse(data))
    }

    func testOMLXShowsSpeedWithoutTheOllamaCaptureSwitch() throws {
        let vm = NotchViewModel()
        vm.updateSnapshots([try ollama(["qwen3:latest"]), try runtime()])
        XCTAssertEqual(vm.snapshots.map(\.showsLocalPerformance), [false, true, true])
        XCTAssertEqual(vm.snapshots[0].headlineText, expectedGigabytes(4.5))
        XCTAssertEqual(vm.snapshots[1].headlineText, "— tok/s", "measured by the runtime, nothing measured yet")

        let speed = try XCTUnwrap(LocalModelPerformance(outputTokens: 300, tokensPerSecond: 42.8))
        vm.updatePerformances([qwen: speed], source: OMLXMetrics.providerID)
        XCTAssertEqual(vm.snapshots.first { $0.id == qwen }?.localPerformance, speed)
        XCTAssertNil(vm.snapshots[0].localPerformance, "keyed per source; an Ollama cell never reads oMLX's")

        // Ollama's relay coming and going leaves oMLX's reading alone.
        let relayed = try XCTUnwrap(LocalModelPerformance(outputTokens: 30, durationNanoseconds: 1_000_000_000))
        vm.setLocalMetricsEnabled(true)
        vm.updatePerformances(["qwen3:latest": relayed])
        XCTAssertEqual(vm.snapshots[0].localPerformance, relayed)
        vm.setLocalMetricsEnabled(false)
        XCTAssertNil(vm.snapshots[0].localPerformance)
        XCTAssertEqual(vm.snapshots.first { $0.id == qwen }?.localPerformance, speed)
        XCTAssertEqual(vm.snapshots.first { $0.id == qwen }?.headlineText,
                       "\(42.8.formatted(.number.precision(.fractionLength(0...1)))) tok/s")
    }

    func testTheRingIsTheContextAndTheTooltipGetsTheLedger() throws {
        let vm = NotchViewModel()
        vm.now = OMLXLogFixtures.date(8, 12, 0, 0, 0)
        vm.updateSnapshots([try runtime()])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = OMLXLogFixtures.zone
        var ledger = LocalTokenLedger(calendar: calendar)
        ledger.record(LocalPrediction(instance: "Qwen3.8-27B-oQ8e-mtp", at: vm.now.addingTimeInterval(-60), inputTokens: 8192,
                                      outputTokens: 400, reasoningTokens: 100, draftTokens: 10, acceptedDraftTokens: 4),
                      as: qwen)
        vm.updateLedger(ledger, source: OMLXMetrics.providerID)
        let cell = try XCTUnwrap(vm.snapshots.first { $0.id == qwen })
        XCTAssertEqual(try XCTUnwrap(cell.localContextFraction), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(cell.ringFraction), 0.25, accuracy: 0.0001, "the arc is the context filling up")
        XCTAssertEqual(cell.localLedgerRowCount, 5)
        XCTAssertEqual(cell.localLedger?.tokensTodayText, "8192 in · 400 out")
        XCTAssertEqual(cell.localLedger?.reasoningShareText, "25%")
        XCTAssertEqual(cell.localLedger?.draftAcceptanceText, "40%")
        let other = try XCTUnwrap(vm.snapshots.first { $0.id != qwen })
        XCTAssertNil(other.localLedger)
        XCTAssertNil(other.ringFraction)
        XCTAssertEqual(other.localLedgerRowCount, 0)

        // Midnight passes with no new line: today is empty, the arc stays.
        vm.now = OMLXLogFixtures.date(9, 0, 0, 1, 0)
        vm.updateSnapshots([try runtime()])
        let tomorrow = try XCTUnwrap(vm.snapshots.first { $0.id == qwen })
        XCTAssertEqual(tomorrow.localLedger?.tokensTodayText, "0 in · 0 out")
        XCTAssertEqual(try XCTUnwrap(tomorrow.localContextFraction), 0.25, accuracy: 0.0001)
    }

    func testThePhaseAndQueueReachTheRingAndTheCard() throws {
        let vm = NotchViewModel()
        vm.updateSnapshots([try runtime(), try ollama(["gemma4:e4b"])])
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        vm.localActivities = [qwen: LocalModelActivity(phase: .generating, queued: 2, since: since)]
        vm.thinkingModels = ["gemma4:e4b": since]
        let generating = try XCTUnwrap(vm.activity(for: vm.snapshots.first { $0.id == qwen }!))
        XCTAssertEqual(generating.state, .working)
        XCTAssertEqual(generating.queued, 2)
        XCTAssertEqual(generating.sessions.map(\.name), ["Generating"])
        XCTAssertEqual(generating.sessions.first?.detail, "oMLX")
        XCTAssertEqual(generating.sessions.first?.since, since)
        XCTAssertNil(vm.activity(for: vm.snapshots.first { $0.id == flash }!))
        let thinking = try XCTUnwrap(vm.activity(for: vm.snapshots.last!))
        XCTAssertEqual(thinking.queued, 0)
        XCTAssertEqual(thinking.sessions.map(\.name), ["Thinking"])

        let cell = vm.snapshots.first { $0.id == qwen }!
        let renderer = ImageRenderer(content: ProviderCell(snapshot: cell, activity: generating).frame(width: 140))
        renderer.scale = 2
        XCTAssertNotNil(renderer.nsImage)
        let label = ProviderCell(snapshot: cell, activity: generating).accessibilityText
        XCTAssertTrue(label.contains("Generating, 2 queued"), label)
    }

    func testTheFleetHandsANewDisplayBothRuntimesEverythingItKnows() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires a display") }
        let lmstudio = LMStudioMetrics.cellID(instance: "qwen3.8-27b")
        let lmstudioSnapshot = LMStudioFixtures.snapshot(try LMStudioUsage.parse(LMStudioFixtures.listing(instances: [
            ("qwen3.8-27b", "qwen/qwen3.8-27b", 32_768)
        ])))
        let fleet = NotchFleet(scope: .allDisplays, edge: .right)
        let lmstudioSpeed = try XCTUnwrap(LocalModelPerformance(outputTokens: 100, tokensPerSecond: 50))
        let omlxSpeed = try XCTUnwrap(LocalModelPerformance(outputTokens: 200, tokensPerSecond: 42.8))
        var lmstudioLedger = LocalTokenLedger()
        lmstudioLedger.record(LocalPrediction(instance: "qwen3.8-27b", at: Date(), inputTokens: 100, outputTokens: 10), as: lmstudio)
        var omlxLedger = LocalTokenLedger()
        omlxLedger.record(LocalPrediction(instance: "Qwen3.8-27B-oQ8e-mtp", at: Date(), inputTokens: 200, outputTokens: 20), as: qwen)
        fleet.setSnapshots([lmstudioSnapshot, try runtime()])
        fleet.setPerformances([lmstudio: lmstudioSpeed], source: LMStudioMetrics.providerID)
        fleet.setPerformances([qwen: omlxSpeed], source: OMLXMetrics.providerID)
        fleet.setLocalActivities([lmstudio: LocalModelActivity(phase: .generating, queued: 0, since: Date())],
                                 source: LMStudioMetrics.providerID)
        fleet.setLocalActivities([qwen: LocalModelActivity(phase: .processingPrompt, queued: 1, since: Date())],
                                 source: OMLXMetrics.providerID)
        fleet.setLedger(lmstudioLedger, source: LMStudioMetrics.providerID)
        fleet.setLedger(omlxLedger, source: OMLXMetrics.providerID)
        fleet.onRefreshProvider = { _ in }
        // The displays are created after everything above was reported.
        fleet.show()
        defer { fleet.stop() }
        XCTAssertFalse(fleet.controllersForTesting.isEmpty)
        for controller in fleet.controllersForTesting {
            let model = controller.model
            let lm = try XCTUnwrap(model.snapshots.first { $0.id == lmstudio })
            let mlx = try XCTUnwrap(model.snapshots.first { $0.id == qwen })
            XCTAssertEqual(lm.localPerformance, lmstudioSpeed)
            XCTAssertEqual(mlx.localPerformance, omlxSpeed)
            XCTAssertEqual(model.activity(for: lm)?.sessions.first?.name, "Generating")
            XCTAssertEqual(model.activity(for: mlx)?.queued, 1, "oMLX's activity did not replace LM Studio's")
            XCTAssertEqual(lm.localLedger?.tokensTodayText, "100 in · 10 out")
            XCTAssertEqual(mlx.localLedger?.tokensTodayText, "200 in · 20 out")
        }
    }

    func testTheMenuListsOMLXModelsWithWhatTheirCellsShow() throws {
        let runtime = OMLXFixtures.snapshot(try OMLXUsage.parse(OMLXFixtures.listing([
            model("Qwen3.8-27B-oQ8e-mtp", context: 32_768)
        ])))
        let cloud = Fixtures.snapshots()[0]

        // No `show()`: the fleet has no panels, and the menu's model is fed anyway.
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        fleet.setSnapshots([cloud, runtime])
        var ledger = LocalTokenLedger()
        ledger.record(LocalPrediction(instance: "Qwen3.8-27B-oQ8e-mtp", at: Date().addingTimeInterval(-60),
                                      inputTokens: 20_000, outputTokens: 1_200), as: qwen)
        fleet.setLedger(ledger, source: OMLXMetrics.providerID)
        fleet.setPerformances([qwen: try XCTUnwrap(LocalModelPerformance(outputTokens: 1200, tokensPerSecond: 24.1))],
                              source: OMLXMetrics.providerID)
        fleet.setLocalActivities([qwen: LocalModelActivity(phase: .processingPrompt, queued: 1, since: Date())],
                                 source: OMLXMetrics.providerID)

        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = [cloud, runtime]
        controller.cells = { fleet.menuModel.snapshots }
        controller.activity = { fleet.menuModel.activity(for: $0) }
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: Date())
        let titles = menu.items.map(\.title)
        let joined = titles.joined(separator: "\n")

        let cell = try XCTUnwrap(fleet.menuModel.snapshots.first { $0.id == qwen })
        XCTAssertTrue(titles.contains("oMLX — 1 model loaded"), joined)
        XCTAssertTrue(titles.contains("Qwen3.8-27B-oQ8e-mtp: \(cell.headlineText) · Prompt · 1 queued · Context 61% · Today 20k in · 1200 out"), joined)
        let header = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("oMLX") })
        XCTAssertEqual(header.representedObject as? String, "omlx")
        XCTAssertNotNil(header.action)
        XCTAssertNil(try XCTUnwrap(menu.items.first { $0.title.hasPrefix("Qwen3.8-27B") }).action)
    }

    func testTheSettingsRowRendersOnAndOff() async throws {
        let domain = "OMLXSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        let store = UsageStore(providers: [OMLXLocalProvider(endpoint: URL(string: OMLXEndpoint.defaultAddress)!,
                                                              session: URLSession(configuration: .ephemeral), key: { nil })],
                               archive: UsageArchive(defaults: defaults), disconnected: [OMLXMetrics.providerID])
        let metrics = OMLXMetrics(makeLink: { _ in OMLXLinkStub() },
                                  logsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(domain))
        for enabled in [false, true] {
            preferences.setConnected(enabled, for: OMLXMetrics.providerID)
            store.disconnected = preferences.disconnectedIDs(among: store.knownIDs)
            let content = OMLXSettingsRow(preferences: preferences, store: store, metrics: metrics)
                .padding(20).frame(width: 460).background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hosting.fittingSize.height, 100)
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let image = NSImage(size: hosting.bounds.size)
            image.addRepresentation(rep)
            try save(image, name: "omlx-settings-\(enabled ? "on" : "off").png")
        }
        metrics.stop()
    }

    private func save(_ image: NSImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OMLX_RENDER_DIRECTORY"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
