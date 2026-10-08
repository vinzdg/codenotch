import XCTest
import SwiftUI
@testable import Codenotch

@MainActor
final class LMStudioViewTests: XCTestCase {
    private let qwen = LMStudioMetrics.cellID(instance: "qwen3.8-27b")

    private func runtime() throws -> ProviderSnapshot {
        LMStudioFixtures.snapshot(try LMStudioUsage.parse(LMStudioFixtures.listing(instances: [
            ("qwen3.8-27b", "qwen/qwen3.8-27b", 32_768), ("flash-next-test", "qwen/qwen3.8-flash-next", 8192)
        ])))
    }

    private func ollama(_ names: [String]) throws -> ProviderSnapshot {
        let data = try JSONSerialization.data(withJSONObject: ["models": names.map { ["name": $0, "size": 4_831_838_208] }])
        return ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal, fidelity: .official,
                                status: .ok, windows: [], kind: .localRuntime, localRuntime: try OllamaLocalUsage.parse(data))
    }

    func testLMStudioShowsSpeedWithoutTheOllamaCaptureSwitch() throws {
        let vm = NotchViewModel()
        vm.updateSnapshots([try ollama(["qwen3:latest"]), try runtime()])
        XCTAssertEqual(vm.snapshots.map(\.showsLocalPerformance), [false, true, true])
        XCTAssertEqual(vm.snapshots[0].headlineText, expectedGigabytes(4.5))
        XCTAssertEqual(vm.snapshots[1].headlineText, "— tok/s", "measured by the runtime, nothing measured yet")

        let speed = try XCTUnwrap(LocalModelPerformance(outputTokens: 300, tokensPerSecond: 17.9))
        vm.updatePerformances([qwen: speed], source: "lmstudio")
        XCTAssertEqual(vm.snapshots.first { $0.id == qwen }?.localPerformance, speed)
        XCTAssertNil(vm.snapshots[0].localPerformance, "keyed per source; an Ollama cell never reads LM Studio's")

        // Ollama's relay coming and going leaves LM Studio's reading alone.
        let relayed = try XCTUnwrap(LocalModelPerformance(outputTokens: 30, durationNanoseconds: 1_000_000_000))
        vm.setLocalMetricsEnabled(true)
        vm.updatePerformances(["qwen3:latest": relayed])
        XCTAssertEqual(vm.snapshots[0].localPerformance, relayed)
        vm.setLocalMetricsEnabled(false)
        XCTAssertNil(vm.snapshots[0].localPerformance)
        XCTAssertEqual(vm.snapshots.first { $0.id == qwen }?.localPerformance, speed)
        XCTAssertEqual(vm.snapshots.first { $0.id == qwen }?.headlineText, "\(17.9.formatted(.number.precision(.fractionLength(0...1)))) tok/s")
    }

    func testTheRingIsTheContextAndTheTooltipGetsTheLedger() throws {
        let vm = NotchViewModel()
        vm.now = LMStudioLogFixtures.date(2026, 9, 10, 12, 0, 0)
        vm.updateSnapshots([try runtime()])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = LMStudioLogFixtures.zone
        var ledger = LocalTokenLedger(calendar: calendar)
        ledger.record(LocalPrediction(instance: "qwen3.8-27b", at: vm.now.addingTimeInterval(-60), inputTokens: 8192,
                                      outputTokens: 400, reasoningTokens: 100, draftTokens: 10, acceptedDraftTokens: 4),
                      as: qwen)
        vm.updateLedger(ledger)
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
        vm.now = LMStudioLogFixtures.date(2026, 9, 11, 0, 0, 1)
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
        XCTAssertEqual(generating.sessions.first?.detail, "LM Studio")
        XCTAssertEqual(generating.sessions.first?.since, since)
        XCTAssertNil(vm.activity(for: vm.snapshots.first { $0.id.hasSuffix("flash-next-test") }!))
        let thinking = try XCTUnwrap(vm.activity(for: vm.snapshots.last!))
        XCTAssertEqual(thinking.queued, 0)
        XCTAssertEqual(thinking.sessions.map(\.name), ["Thinking"])
        XCTAssertNil(ActivitySummary(sessions: [], queued: 3), "a queue with nothing running is nothing")
        XCTAssertEqual(ActivitySummary(sessions: generating.sessions, queued: -1)?.queued, 0)

        let cell = vm.snapshots.first { $0.id == qwen }!
        let renderer = ImageRenderer(content: ProviderCell(snapshot: cell, activity: generating).frame(width: 140))
        renderer.scale = 2
        XCTAssertNotNil(renderer.nsImage)
        let label = ProviderCell(snapshot: cell, activity: generating).accessibilityText
        XCTAssertTrue(label.contains("Generating, 2 queued"), label)
    }

    func testLedgerRowsGrowTheCardAndStillFitEveryEdge() throws {
        let vm = NotchViewModel()
        vm.now = LMStudioLogFixtures.date(2026, 9, 10, 12, 0, 0)
        vm.updateSnapshots([Fixtures.snapshots()[0], try runtime()])
        var ledger = LocalTokenLedger()
        ledger.record(LocalPrediction(instance: "qwen3.8-27b", at: vm.now.addingTimeInterval(-5), inputTokens: 20_000,
                                      outputTokens: 1_200, reasoningTokens: 600, tokensPerSecond: 24.1,
                                      draftTokens: 400, acceptedDraftTokens: 150), as: qwen)
        vm.updateLedger(ledger)
        vm.updatePerformances([qwen: LocalModelPerformance(outputTokens: 1200, tokensPerSecond: 24.1, measuredAt: vm.now.addingTimeInterval(-5))!],
                              source: "lmstudio")
        vm.localActivities = [qwen: LocalModelActivity(phase: .processingPrompt, queued: 1, since: vm.now.addingTimeInterval(-2))]
        vm.isExpanded = true
        vm.screenSize = CGSize(width: 1512, height: 982)
        let cell = try XCTUnwrap(vm.snapshots.first { $0.id == qwen })
        let plain = NotchLayout.cardHeight(windowCount: 0, localModelName: cell.localModel?.name, showsLocalPerformance: true)
        let withLedger = NotchLayout.cardHeight(windowCount: 0, localModelName: cell.localModel?.name,
                                                showsLocalPerformance: true, localLedgerRows: cell.localLedgerRowCount)
        XCTAssertEqual(withLedger - plain, 5 * (NotchLayout.cardBodyLineHeight + NotchLayout.sessionRowGap), accuracy: 0.001)
        for notchSize in NotchSize.allCases {
            vm.sizeScale = notchSize.scale
            for edge in NotchEdge.allCases {
                vm.edge = edge
                vm.hoveredIndex = 1
                let size = vm.panelSize
                XCTAssertLessThanOrEqual(size.height, vm.screenSize.height + 0.1, "\(edge) \(notchSize)")
                XCTAssertLessThanOrEqual(withLedger, vm.maxCardHeight(cellCount: vm.snapshots.count), "\(edge) \(notchSize)")
                let renderer = ImageRenderer(content: NotchRootView(model: vm).frame(width: size.width, height: size.height))
                renderer.scale = 2
                try save(XCTUnwrap(renderer.nsImage), name: "lmstudio-notch-\(edge.rawValue)-\(notchSize.rawValue).png")
                let card = ImageRenderer(content: TooltipCard(snapshot: cell, activity: vm.activity(for: cell),
                                                              now: vm.now, direction: edge.tooltipDirection))
                card.scale = 2
                let image = try XCTUnwrap(card.nsImage)
                XCTAssertGreaterThan(image.size.height, plain, "the ledger rows are drawn")
                try save(image, name: "lmstudio-card-\(edge.rawValue)-\(notchSize.rawValue).png")
            }
        }
    }

    func testTheFleetHandsANewDisplayEverythingItKnows() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires a display") }
        let fleet = NotchFleet(scope: .allDisplays, edge: .right)
        let speed = try XCTUnwrap(LocalModelPerformance(outputTokens: 100, tokensPerSecond: 50))
        let relayed = try XCTUnwrap(LocalModelPerformance(outputTokens: 30, durationNanoseconds: 1_000_000_000))
        var ledger = LocalTokenLedger()
        ledger.record(LocalPrediction(instance: "qwen3.8-27b", at: Date(), inputTokens: 100, outputTokens: 10), as: qwen)
        fleet.setLocalMetricsEnabled(true)
        fleet.setSnapshots([try runtime(), try ollama(["qwen3:latest"])])
        fleet.setPerformances([qwen: speed], source: "lmstudio")
        fleet.setPerformances(["qwen3:latest": relayed])
        fleet.setLocalActivities([qwen: LocalModelActivity(phase: .generating, queued: 0, since: Date())])
        fleet.setLedger(ledger)
        fleet.onRefreshProvider = { _ in }
        fleet.show()
        defer { fleet.stop() }
        for controller in fleet.controllersForTesting {
            let model = controller.model
            XCTAssertEqual(model.snapshots.first { $0.id == qwen }?.localPerformance, speed)
            XCTAssertEqual(model.snapshots.last?.localPerformance, relayed)
            XCTAssertEqual(model.activity(for: model.snapshots.first { $0.id == qwen }!)?.sessions.first?.name, "Generating")
            XCTAssertNotNil(model.snapshots.first { $0.id == qwen }?.localLedger)
        }
        fleet.setLocalMetricsEnabled(false)
        for controller in fleet.controllersForTesting {
            XCTAssertNil(controller.model.snapshots.last?.localPerformance, "the relay's reading goes with its switch")
            XCTAssertEqual(controller.model.snapshots.first { $0.id == qwen }?.localPerformance, speed, "LM Studio's stays")
        }
    }

    /// A second runtime (oMLX) reporting its own activities and ledger used
    /// to overwrite LM Studio's single slot; each source now keeps its own.
    private func secondRuntime() throws -> ProviderSnapshot {
        ProviderSnapshot(id: "omlx", displayName: "oMLX", glyph: .lmstudio, fidelity: .official, status: .ok,
                         windows: [], kind: .localRuntime,
                         localRuntime: try LMStudioUsage.parse(LMStudioFixtures.listing(instances: [
                             ("qwen3.8-27b-mlx", "qwen/qwen3.8-27b", 65_536)
                         ])))
    }

    func testASecondRuntimeNeverOverwritesLMStudiosLedger() throws {
        let vm = NotchViewModel()
        vm.now = LMStudioLogFixtures.date(2026, 9, 10, 12, 0, 0)
        vm.updateSnapshots([try runtime(), try secondRuntime()])
        let mlx = "omlx:model:qwen3.8-27b-mlx"
        var lmstudioLedger = LocalTokenLedger()
        lmstudioLedger.record(LocalPrediction(instance: "qwen3.8-27b", at: vm.now.addingTimeInterval(-60),
                                              inputTokens: 100, outputTokens: 10), as: qwen)
        var omlxLedger = LocalTokenLedger()
        omlxLedger.record(LocalPrediction(instance: "qwen3.8-27b-mlx", at: vm.now.addingTimeInterval(-30),
                                          inputTokens: 200, outputTokens: 20), as: mlx)

        vm.updateLedger(lmstudioLedger, source: "lmstudio")
        vm.updateLedger(omlxLedger, source: "omlx")
        XCTAssertEqual(vm.snapshots.first { $0.id == qwen }?.localLedger?.tokensTodayText, "100 in · 10 out")
        XCTAssertEqual(vm.snapshots.first { $0.id == mlx }?.localLedger?.tokensTodayText, "200 in · 20 out")

        // And the other way round: LM Studio reporting again leaves oMLX's alone.
        vm.updateLedger(LocalTokenLedger(), source: "lmstudio")
        XCTAssertNil(vm.snapshots.first { $0.id == qwen }?.localLedger)
        XCTAssertEqual(vm.snapshots.first { $0.id == mlx }?.localLedger?.tokensTodayText, "200 in · 20 out")
    }

    func testTheFleetKeepsEachRuntimesActivitiesAndLedgerApart() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires a display") }
        let fleet = NotchFleet(scope: .allDisplays, edge: .right)
        let mlx = "omlx:model:qwen3.8-27b-mlx"
        var lmstudioLedger = LocalTokenLedger()
        lmstudioLedger.record(LocalPrediction(instance: "qwen3.8-27b", at: Date(), inputTokens: 100, outputTokens: 10), as: qwen)
        var omlxLedger = LocalTokenLedger()
        omlxLedger.record(LocalPrediction(instance: "qwen3.8-27b-mlx", at: Date(), inputTokens: 200, outputTokens: 20), as: mlx)
        fleet.setSnapshots([try runtime(), try secondRuntime()])
        fleet.onRefreshProvider = { _ in }
        fleet.show()
        defer { fleet.stop() }

        fleet.setLocalActivities([qwen: LocalModelActivity(phase: .generating, queued: 0, since: Date())], source: "lmstudio")
        fleet.setLedger(lmstudioLedger, source: "lmstudio")
        fleet.setLocalActivities([mlx: LocalModelActivity(phase: .processingPrompt, queued: 1, since: Date())], source: "omlx")
        fleet.setLedger(omlxLedger, source: "omlx")
        for controller in fleet.controllersForTesting {
            let model = controller.model
            XCTAssertEqual(model.activity(for: model.snapshots.first { $0.id == qwen }!)?.sessions.first?.name, "Generating")
            XCTAssertEqual(model.activity(for: model.snapshots.first { $0.id == mlx }!)?.queued, 1)
            XCTAssertNotNil(model.snapshots.first { $0.id == qwen }?.localLedger, "oMLX reporting left LM Studio's ledger")
            XCTAssertNotNil(model.snapshots.first { $0.id == mlx }?.localLedger)
        }

        // LM Studio going idle clears only its own cell.
        fleet.setLocalActivities([:], source: "lmstudio")
        for controller in fleet.controllersForTesting {
            let model = controller.model
            XCTAssertNil(model.activity(for: model.snapshots.first { $0.id == qwen }!))
            XCTAssertNotNil(model.activity(for: model.snapshots.first { $0.id == mlx }!), "LM Studio idling left oMLX busy")
            XCTAssertNotNil(model.snapshots.first { $0.id == mlx }?.localLedger)
        }
    }

    func testTheSettingsRowRendersOnAndOff() async throws {
        let domain = "LMStudioSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        let store = UsageStore(providers: [LMStudioLocalProvider(endpoint: URL(string: LMStudioEndpoint.defaultAddress)!,
                                                                  session: URLSession(configuration: .ephemeral), token: { nil })],
                               archive: UsageArchive(defaults: defaults), disconnected: ["lmstudio"])
        let metrics = LMStudioMetrics(makeLink: { _ in LMStudioLinkStub() },
                                      logsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(domain))
        for enabled in [false, true] {
            preferences.setConnected(enabled, for: "lmstudio")
            store.disconnected = preferences.disconnectedIDs(among: store.knownIDs)
            let content = LMStudioSettingsRow(preferences: preferences, store: store, metrics: metrics)
                .padding(20).frame(width: 460).background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hosting.fittingSize.height, 100)
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let image = NSImage(size: hosting.bounds.size)
            image.addRepresentation(rep)
            try save(image, name: "lmstudio-settings-\(enabled ? "on" : "off").png")
        }
        metrics.stop()
    }

    private func save(_ image: NSImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["LMSTUDIO_RENDER_DIRECTORY"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
