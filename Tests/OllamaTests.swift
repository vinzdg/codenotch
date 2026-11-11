import XCTest
import SwiftUI
@testable import Codenotch

/// Memory sizes and token counts are printed through `Foundation`'s
/// locale-aware formatting, so a machine set to Indonesian prints "4,5 GB"
/// where a US one prints "4.5 GB". Building the expectation the same way is
/// the only version of these assertions that is true on both.
func expectedGigabytes(_ value: Double) -> String {
    "\(value.formatted(.number.precision(.fractionLength(0...1)))) GB"
}

func expectedTokens(_ value: Int) -> String {
    "\(value.formatted()) tokens"
}

final class OllamaLocalUsageTests: XCTestCase {
    func testEmptyListingIsAReadingWithoutAQuota() throws {
        let reading = try OllamaLocalUsage.parse(Data(#"{"models":[]}"#.utf8))
        let snapshot = ollamaSnapshot(reading)
        XCTAssertTrue(snapshot.hasReading)
        XCTAssertTrue(snapshot.notchSnapshots.isEmpty)
        XCTAssertNil(snapshot.ringFraction)
        XCTAssertTrue(snapshot.statusMessage?.contains("No models loaded") == true)
    }

    func testPreservesReportedUnitsAndMissingFields() throws {
        let data = Data(#"{"models":[{"name":"z-model","size":6442450944,"size_vram":4294967296,"context_length":32768,"details":{"quantization_level":"Q4_K_M"}},{"name":"a-model"}]}"#.utf8)
        let reading = try OllamaLocalUsage.parse(data)
        XCTAssertEqual(reading.models.map(\.name), ["a-model", "z-model"])
        XCTAssertEqual(ollamaSnapshot(reading).notchSnapshots.map(\.id),
                       ["ollama-local:model:a-model", "ollama-local:model:z-model"])
        XCTAssertNil(reading.models[0].memoryBytes)
        XCTAssertNil(reading.models[0].contextLength)
        XCTAssertNil(reading.models[0].quantizationLevel)
        XCTAssertEqual(reading.models[0].quantizationText, "Unavailable")
        XCTAssertEqual(reading.models[1].memoryBytes, 6_442_450_944)
        XCTAssertEqual(reading.models[1].contextLength, 32_768)
        XCTAssertEqual(reading.models[1].quantizationLevel, "Q4_K_M")
        XCTAssertNil(ollamaSnapshot(reading).usedFraction)
        XCTAssertTrue(ollamaSnapshot(reading).windows.isEmpty)
    }

    func testQuantizationUsesReportedMetadataInsteadOfTheModelTag() throws {
        for (details, expected) in [
            (#"{"quantization_level":"Q8_0"}"#, "Q8_0"),
            (#"{"quantization_level":" IQ4_XS "}"#, "IQ4_XS"),
            (#"{"quantization_level":"F16"}"#, "F16"),
            (#"{"quantization_level":"  "}"#, "Unavailable"),
            (#"{"quantization_level":null}"#, "Unavailable"),
            ("{}", "Unavailable"), ("null", "Unavailable")
        ] {
            let data = Data("{\"models\":[{\"name\":\"custom:Q4_K_M\",\"details\":\(details)}]}".utf8)
            let cell = try XCTUnwrap(ollamaSnapshot(OllamaLocalUsage.parse(data)).notchSnapshots.first)
            XCTAssertEqual(cell.localModel?.quantizationText, expected, details)
            XCTAssertTrue(cell.localModel?.detail.contains("Quantization \(expected)") == true)
        }
    }

    func testMalformedListingsAreNotEmptySuccesses() {
        for payload in ["{}", "{\"models\":null}", "not json",
                        #"{"models":[{"name":" "}]}"#,
                        #"{"models":[{"name":"a","size":-1}]}"#,
                        #"{"models":[{"name":"a","size_vram":-1}]}"#,
                        #"{"models":[{"name":"a","context_length":0}]}"#,
                        #"{"models":[{"name":"a"},{"name":"a"}]}"#] {
            XCTAssertThrowsError(try OllamaLocalUsage.parse(Data(payload.utf8)), payload)
        }
    }

    func testTheEnvironmentKeyWinsAndBlankIsAbsent() {
        XCTAssertEqual(OllamaCredentials.load(environment: ["OLLAMA_API_KEY": " k "], keychain: { "stored" }), "k")
        XCTAssertEqual(OllamaCredentials.load(environment: ["OLLAMA_API_KEY": "  "], keychain: { "stored" }), "stored",
                       "a blank export is no key")
        XCTAssertNil(OllamaCredentials.load(environment: [:], keychain: { nil }))
    }

    func testTheKeychainClosureIsNotCachedBetweenCalls() {
        var calls = 0
        _ = OllamaCredentials.load(environment: [:], keychain: { calls += 1; return "stored" })
        _ = OllamaCredentials.load(environment: [:], keychain: { calls += 1; return "stored" })
        XCTAssertEqual(calls, 2, "the injectable path must bypass the cache")
    }

    func testOnlyLocalHTTPOriginsAreAccepted() throws {
        XCTAssertEqual(try OllamaEndpoint.parse(" http://localhost:11434/ ").absoluteString,
                       "http://127.0.0.1:11434")
        XCTAssertEqual(try OllamaEndpoint.parse("http://[::1]:11434").port, 11434)
        for address in ["https://127.0.0.1:11434", "http://192.168.1.2:11434",
                        "http://127.0.0.1.example.com", "http://user:pass@localhost:11434",
                        "http://localhost:11434/api", "http://localhost:11434?x=y",
                        "http://localhost:11434#x", "http://localhost:0", "file:///tmp/a"] {
            XCTAssertThrowsError(try OllamaEndpoint.parse(address), address)
        }
    }
}

@MainActor
final class OllamaModelCellTests: XCTestCase {
    func testEachModelHasItsOwnMemoryReadingAndSharesTheRuntimeRefresh() throws {
        let reading = try OllamaLocalUsage.parse(Data(#"{"models":[{"name":"llama3.1:8b","size":4831838208,"context_length":2048},{"name":"qwen3:8b","size":6442450944}]}"#.utf8))
        let cloud = ProviderSnapshot(id: "cloud", displayName: "Cloud", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.4)])
        let model = NotchViewModel()
        model.updateSnapshots([cloud, ollamaSnapshot(reading)])
        XCTAssertEqual(model.snapshots.count, 3)
        XCTAssertEqual(model.snapshots[0], cloud)
        XCTAssertEqual(model.snapshots.dropFirst().map(\.providerID), ["ollama-local", "ollama-local"])
        XCTAssertEqual(model.snapshots.dropFirst().map(\.headlineText),
                       [expectedGigabytes(4.5), expectedGigabytes(6)])
        XCTAssertEqual(Set(model.snapshots.map(\.id)).count, 3)
        XCTAssertTrue(model.snapshots.dropFirst().allSatisfy { $0.ringFraction == nil })
        XCTAssertEqual(model.snapshots[1].localModel?.contextText, expectedTokens(2048))
        XCTAssertEqual(model.snapshots[2].localModel?.contextText, "Unavailable")
    }

    func testHoverKeepsTheSameModelWhenNeighborsChangeAndClearsOnUnload() throws {
        let model = NotchViewModel()
        func update(_ names: [String]) throws {
            let data = try JSONSerialization.data(withJSONObject: ["models": names.map { ["name": $0] }])
            model.updateSnapshots([ollamaSnapshot(try OllamaLocalUsage.parse(data))])
        }
        try update(["b-model", "a-model"])
        model.hoveredIndex = 1
        let selectedID = model.hoveredSnapshot?.id
        try update(["b-model"])
        XCTAssertEqual(model.hoveredIndex, 0)
        XCTAssertEqual(model.hoveredSnapshot?.id, selectedID)
        try update(["c-model"])
        XCTAssertNil(model.hoveredIndex)
        try update([])
        XCTAssertTrue(model.snapshots.isEmpty)
    }

    func testDiscoveryAppendsModelsWithoutReorderingExistingCellsOrTheirHover() throws {
        let model = NotchViewModel()
        let cloud = Fixtures.snapshots()[0]
        func update(_ names: [String], size: Int) throws {
            let data = try JSONSerialization.data(withJSONObject: ["models": names.map {
                ["name": $0, "size": size] as [String: Any]
            }])
            model.updateSnapshots([cloud, ollamaSnapshot(try OllamaLocalUsage.parse(data))])
        }
        try update(["qwen3:8b", "llama3.1:8b"], size: 100)
        model.hoveredIndex = 2
        let hoveredID = model.hoveredSnapshot?.id
        try update(["deepseek-r1:1.5b", "qwen3:8b", "llama3.1:8b"], size: 200)
        XCTAssertEqual(model.snapshots.dropFirst().compactMap { $0.localModel?.name },
                       ["llama3.1:8b", "qwen3:8b", "deepseek-r1:1.5b"])
        XCTAssertEqual(model.hoveredIndex, 2)
        XCTAssertEqual(model.hoveredSnapshot?.id, hoveredID)
        XCTAssertEqual(model.hoveredSnapshot?.localModel?.memoryBytes, 200)
        XCTAssertEqual(model.snapshots[0], cloud)
        try update(["deepseek-r1:1.5b", "qwen3:8b"], size: 300)
        XCTAssertEqual(model.snapshots.dropFirst().compactMap { $0.localModel?.name },
                       ["qwen3:8b", "deepseek-r1:1.5b"])
        XCTAssertEqual(model.hoveredSnapshot?.id, hoveredID)
        try update(["llama3.1:8b", "qwen3:8b", "deepseek-r1:1.5b"], size: 400)
        XCTAssertEqual(model.snapshots.dropFirst().compactMap { $0.localModel?.name },
                       ["qwen3:8b", "deepseek-r1:1.5b", "llama3.1:8b"])
    }

    func testLocalClickFeedbackIsIndependentFromPollingAndOtherModelClicks() async throws {
        let model = NotchViewModel()
        model.updateSnapshots([Fixtures.snapshots()[0], ollamaSnapshot(try OllamaLocalUsage.parse(
            Data(#"{"models":[{"name":"llama3.1:8b"},{"name":"qwen3:8b"}]}"#.utf8)))])
        let cloud = model.snapshots[0], first = model.snapshots[1], second = model.snapshots[2]
        model.refreshing = ["ollama-local", cloud.providerID]
        XCTAssertTrue(model.isRefreshing(cloud))
        XCTAssertFalse(model.isRefreshing(first), "Inventory polling must not press model icons")
        XCTAssertFalse(model.isRefreshing(second))
        var releases: [CheckedContinuation<Void, Never>] = []
        var requests: [String] = []
        let refresh: (String) async -> Void = { id in
            requests.append(id)
            await withCheckedContinuation { releases.append($0) }
        }
        let firstClick = Task { await model.refresh(first, using: refresh) }
        for _ in 0..<100 where releases.isEmpty { await Task.yield() }
        XCTAssertTrue(model.isRefreshing(first))
        XCTAssertFalse(model.isRefreshing(second))
        await model.refresh(first, using: refresh)
        XCTAssertEqual(requests, ["ollama-local"], "Repeated clicks must not start another refresh")
        let secondClick = Task { await model.refresh(second, using: refresh) }
        for _ in 0..<100 where releases.count < 2 { await Task.yield() }
        model.refreshing = []
        XCTAssertTrue(model.isRefreshing(first))
        XCTAssertTrue(model.isRefreshing(second))
        XCTAssertFalse(model.isRefreshing(cloud))
        guard releases.count == 2 else {
            releases.forEach { $0.resume() }
            firstClick.cancel(); secondClick.cancel()
            return XCTFail("Both model refreshes must start")
        }
        releases[0].resume()
        await firstClick.value
        XCTAssertFalse(model.isRefreshing(first))
        XCTAssertTrue(model.isRefreshing(second), "Finishing one model must not release the other")
        releases[1].resume()
        await secondClick.value
        XCTAssertTrue(model.refreshingCells.isEmpty)
    }

    func testPanelClickUsesTheEventLocationAndAnimatesOnlyThatModelOnEveryEdge() async throws {
        let runtime = ollamaSnapshot(try OllamaLocalUsage.parse(
            Data(#"{"models":[{"name":"llama3.1:8b"},{"name":"qwen3:8b"}]}"#.utf8)))
        for size in NotchSize.allCases {
            for edge in NotchEdge.allCases {
                let controller = NotchWindowController()
                controller.model.updateSnapshots([Fixtures.snapshots()[0], runtime])
                controller.model.edge = edge
                controller.model.sizeScale = size.scale
                controller.model.isExpanded = true
                controller.relocate()
                defer { controller.stop() }
                let panel = try XCTUnwrap(controller.panelContentViewForTesting?.window as? NotchPanel)
                panel.contentView?.layoutSubtreeIfNeeded()
                let model = controller.model
                let point = NotchPlacement(edge: edge, panelSize: panel.frame.size).point(
                    along: model.ringAlong(index: 1, in: model.cellWing),
                    across: model.ringAcross * model.sizeScale)
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                    location: CGPoint(x: point.x, y: panel.frame.height - point.y),
                    modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                var requestedIDs: [String] = []
                controller.onRefreshProvider = { requestedIDs.append($0) }
                panel.mouseDown(with: event)
                for _ in 0..<100 where requestedIDs.isEmpty { await Task.yield() }
                XCTAssertEqual(requestedIDs, ["ollama-local"], edge.rawValue)
                XCTAssertTrue(model.isRefreshing(model.snapshots[1]), edge.rawValue)
                XCTAssertFalse(model.isRefreshing(model.snapshots[2]), edge.rawValue)
                XCTAssertFalse(model.isRefreshing(model.snapshots[0]), edge.rawValue)
            }
        }
    }

    func testFleetProjectsLocalModelsAndSharesCachedActivityWithNewDisplays() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires a display") }
        let runtime = ollamaSnapshot(try OllamaLocalUsage.parse(
            Data(#"{"models":[{"name":"llama3.1:8b"},{"name":"qwen3:8b"}]}"#.utf8)))
        let cloud = Fixtures.snapshots()[0]
        let key = OllamaThinkingStream.modelKey("qwen3:8b")
        let measurement = try XCTUnwrap(LocalModelPerformance(
            outputTokens: 30, durationNanoseconds: 1_000_000_000))
        let fleet = NotchFleet(scope: .allDisplays, edge: .right)
        fleet.setLocalMetricsEnabled(true)
        fleet.setSnapshots([cloud, runtime])
        fleet.setThinkingModels([key: Date()])
        fleet.setPerformances([key: measurement])
        fleet.onRefreshProvider = { _ in }
        fleet.show()
        defer { fleet.stop() }

        XCTAssertEqual(fleet.controllersForTesting.count, NSScreen.screens.count)
        for controller in fleet.controllersForTesting {
            let model = controller.model
            XCTAssertEqual(model.snapshots.map(\.id),
                           [cloud.id, "ollama-local:model:llama3.1:8b", "ollama-local:model:qwen3:8b"])
            XCTAssertNil(model.snapshots[1].localPerformance)
            XCTAssertEqual(model.snapshots[2].localPerformance, measurement)
            XCTAssertNil(model.activity(for: model.snapshots[1]))
            XCTAssertEqual(model.activity(for: model.snapshots[2])?.state, .working)
            XCTAssertNotNil(controller.onRefreshProvider)
        }

        // Provider ordering still applies while one provider expands to many cells.
        fleet.setSnapshots([runtime, cloud])
        fleet.setThinkingModels([:])
        fleet.setPerformances([:])
        for controller in fleet.controllersForTesting {
            XCTAssertEqual(controller.model.snapshots.map(\.providerID), ["ollama-local", "ollama-local", cloud.id])
            XCTAssertTrue(controller.model.snapshots.allSatisfy { $0.localPerformance == nil })
            XCTAssertTrue(controller.model.thinkingModels.isEmpty)
        }
        fleet.setSnapshots([cloud])
        for controller in fleet.controllersForTesting {
            XCTAssertEqual(controller.model.snapshots, [cloud])
        }
    }

    func testUnavailableRuntimeDoesNotLeavePhantomModelCells() {
        let failure = ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal,
            fidelity: .official, status: .error("Unavailable"), windows: [], kind: .localRuntime)
        XCTAssertTrue(failure.notchSnapshots.isEmpty)
        XCTAssertNotNil(failure.statusMessage, "The connection problem must remain available in Settings")
    }

    func testUnknownAndSmallMemoryReadingsAreNotModelCountsOrZeroes() throws {
        let data = Data(#"{"models":[{"name":"a"},{"name":"b","size":536870912}]}"#.utf8)
        let cells = ollamaSnapshot(try OllamaLocalUsage.parse(data)).notchSnapshots
        XCTAssertEqual(cells.map(\.headlineText), ["—", "512 MB"])
        XCTAssertTrue(cells[0].hasReading)
        XCTAssertTrue(cells[0].localModel?.detail.contains("Memory unavailable") == true)
    }
}

@MainActor
final class LocalModelBrandTests: XCTestCase {
    func testDetectsBrandsAcrossVersionsTagsAndNamespaces() {
        let cases: [(String, LocalModelBrand)] = [
            ("qwen3:0.6b", .qwen), ("Qwen/Qwen2.5-Coder-7B-Instruct:Q4_K_M", .qwen),
            ("qwq:32b", .qwen), ("gemma3:270m", .gemma),
            ("google/gemma-3-1b-it-GGUF", .gemma), ("embeddinggemma:latest", .gemma),
            ("llama3.2:1b", .llama), ("meta-llama/Llama-3.1-8B-Instruct", .llama),
            ("hf.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF:Q4_K_M", .llama),
            ("deepseek-r1:1.5b", .deepseek),
            ("hf.co/unsloth/DeepSeek-R1-Distill-Qwen-1.5B-GGUF:Q4_K_M", .deepseek),
            ("DeepSeek-R1-Distill-Llama-8B", .deepseek),
            ("mistral:7b", .mistral), ("ministral-3:3b", .mistral),
            ("mistralai/Ministral-3-3B-Instruct-2512", .mistral),
            ("mixtral:8x7b", .mistral), ("devstral-small:24b", .mistral)
        ]
        for (name, expected) in cases {
            XCTAssertEqual(LocalModelBrand.detect(modelName: name), expected, name)
        }
    }

    func testUnknownNamesAndLookalikesKeepTheOllamaFallback() throws {
        for name in ["my-local-model:latest", "someone/my-qwen-helper:8b", "qwenish:latest",
                     "gemmaverse:latest", "llamafile:latest", "mistralicious:latest", "", "  "] {
            XCTAssertNil(LocalModelBrand.detect(modelName: name), name)
        }
        let data = Data(#"{"models":[{"name":"my-local-model","details":{"family":"llama"}}]}"#.utf8)
        let snapshot = ollamaSnapshot(try OllamaLocalUsage.parse(data))
        XCTAssertEqual(snapshot.notchSnapshots.first?.glyph, .ollamaLocal)
    }

    func testBrandIconsDoNotChangeTheRuntimeConnectionOrModelIdentity() throws {
        let data = Data(#"{"models":[{"name":"deepseek-r1:1.5b","details":{"family":"qwen2"}}]}"#.utf8)
        let runtime = ollamaSnapshot(try OllamaLocalUsage.parse(data))
        let cell = try XCTUnwrap(runtime.notchSnapshots.first)
        XCTAssertEqual(runtime.glyph, .ollamaLocal)
        XCTAssertEqual(cell.glyph, .deepseek)
        XCTAssertEqual(cell.localModel?.brand, .deepseek)
        XCTAssertEqual(cell.providerID, "ollama-local")
        XCTAssertEqual(cell.id, "ollama-local:model:deepseek-r1:1.5b")
        XCTAssertNil(cell.ringFraction)
    }

    func testEverySupportedBrandHasABundledVectorAsset() throws {
        for brand in LocalModelBrand.allCases {
            let asset = try XCTUnwrap(NSImage(named: brand.glyph.assetName), brand.rawValue)
            XCTAssertGreaterThan(asset.size.width, 0)
            XCTAssertGreaterThan(asset.size.height, 0)
            // Unsupported SVG root attributes can resolve an asset but render
            // a solid placeholder square. Check the native template's alpha.
            let renderer = ImageRenderer(content: ProviderGlyphView(glyph: brand.glyph, size: 32)
                .foregroundStyle(.white))
            let data = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            var inkPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { inkPixels += 1 }
                }
            }
            let coverage = Double(inkPixels) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
            XCTAssertGreaterThan(coverage, 0.05, brand.rawValue)
            XCTAssertLessThan(coverage, 0.85, brand.rawValue)
        }
        XCTAssertNotNil(Bundle.main.url(forResource: "LobeIcons-LICENSE", withExtension: "txt"))
    }
}

@MainActor
final class OllamaLocalProviderTests: XCTestCase {
    func testTransportUsesOnlyTheReadOnlyListing() async throws {
        let requested = expectation(description: "listing")
        let provider = makeProvider { request in
            XCTAssertEqual(request.url?.path, "/api/ps")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.timeoutInterval, 3)
            requested.fulfill()
            return (200, Data(#"{"models":[]}"#.utf8))
        }
        let snapshot = try await provider.fetchSnapshot()
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(snapshot.kind, .localRuntime)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertTrue(snapshot.hasReading)
        XCTAssertNil(provider.account())
    }

    func testTransportAndHTTPFailuresStayVisible() async {
        for status in [301, 401, 404, 500] {
            let provider = makeProvider { _ in (status, Data()) }
            do {
                _ = try await provider.fetchSnapshot()
                XCTFail("HTTP \(status) succeeded")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("HTTP \(status)"))
            }
        }
        let provider = makeProvider { _ in throw URLError(.timedOut) }
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("Timeout succeeded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unavailable"))
        }
    }

    func testCancelledRequestStaysCancellation() async {
        let provider = makeProvider { _ in throw URLError(.cancelled) }
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("Cancelled request succeeded")
        } catch is CancellationError {
        } catch {
            XCTFail("Cancellation became \(error)")
        }
    }

    func testSessionDoesNotStoreCredentialsOrFollowRedirects() {
        let session = OllamaLocalProvider.makeSession()
        defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        let url = URL(string: "http://127.0.0.1:11434/api/ps")!
        let task = session.dataTask(with: url)
        OllamaRedirectPolicy().urlSession(session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 302,
                httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: URL(string: "https://example.com")!)) { request in
                XCTAssertNil(request)
            }
    }

    private func makeProvider(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> OllamaLocalProvider {
        OllamaStubProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStubProtocol.self]
        return OllamaLocalProvider(endpoint: URL(string: OllamaEndpoint.defaultAddress)!,
                              session: URLSession(configuration: configuration))
    }
}

private final class OllamaStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!,
                statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class OllamaLifecycleTests: XCTestCase {
    func testDiscoveredModelsJoinSettingsAndShareTheNotchOrder() async throws {
        let local = RuntimeStub(), cloud = QuotaStub()
        let store = UsageStore(providers: [cloud, local], archive: UsageArchive(defaults: isolatedDefaults()))
        XCTAssertTrue(store.localModelSummaries.isEmpty)
        local.models = try OllamaLocalUsage.parse(Data(#"{"models":[{"name":"qwen3:8b"},{"name":"llama3.1:8b"}]}"#.utf8)).models
        await store.refresh()
        let llama = "ollama-local:model:llama3.1:8b", qwen = "ollama-local:model:qwen3:8b"
        XCTAssertEqual(store.notchSnapshots.map(\.id), [cloud.id, llama, qwen])
        XCTAssertEqual(store.providerSummaries.filter { $0.localModel != nil }.map(\.id), [llama, qwen])

        store.order = [qwen, cloud.id, llama]
        XCTAssertEqual(store.notchSnapshots.map(\.id), [qwen, cloud.id, llama])
        XCTAssertEqual(store.providerSummaries.filter { $0.kind == .usage || $0.localModel != nil }.map(\.id),
                       store.notchSnapshots.map(\.id))
        XCTAssertEqual(cloud.calls, 1)
        XCTAssertEqual(local.calls, 1, "Dragging changes display order without polling")

        let fleet = NotchFleet(scope: .allDisplays, edge: .right)
        fleet.setLocalMetricsEnabled(true)
        fleet.setSnapshots(store.notchSnapshots)
        fleet.show()
        defer { fleet.stop() }
        for controller in fleet.controllersForTesting {
            XCTAssertEqual(controller.model.snapshots.map(\.id), [qwen, cloud.id, llama])
        }

        local.models.removeAll { $0.name == "qwen3:8b" }
        await store.refresh(providerID: "ollama-local")?.value
        XCTAssertEqual(store.localModelSummaries.map(\.id), [llama])
        XCTAssertEqual(store.notchSnapshots.map(\.id), [cloud.id, llama])
        local.fails = true
        await store.refresh(providerID: "ollama-local")?.value
        XCTAssertTrue(store.localModelSummaries.isEmpty)
        XCTAssertEqual(store.notchSnapshots.map(\.id), [cloud.id])
    }

    func testModelVisibilityPersistsWithoutStoppingTheSharedRuntime() async throws {
        let defaults = isolatedDefaults(), local = RuntimeStub(), cloud = QuotaStub()
        let preferences = Preferences(defaults: defaults)
        preferences.setConnected(true, for: "ollama-local")
        preferences.setConnected(true, for: cloud.id)
        local.models = try OllamaLocalUsage.parse(Data(#"{"models":[{"name":"qwen3:8b"},{"name":"llama3.1:8b"}]}"#.utf8)).models
        let store = UsageStore(providers: [cloud, local], archive: UsageArchive(defaults: defaults))
        await store.refresh()
        let llama = "ollama-local:model:llama3.1:8b", qwen = "ollama-local:model:qwen3:8b"
        preferences.setConnected(true, for: llama)
        preferences.setConnected(true, for: qwen)
        preferences.setProviderOrder([qwen, cloud.id, llama])
        store.order = preferences.providerOrder
        preferences.setConnected(false, for: qwen)
        store.disconnected = preferences.disconnectedIDs(among: store.knownIDs)
        XCTAssertEqual(store.notchSnapshots.map(\.id), [cloud.id, llama])
        XCTAssertTrue(store.localModelSummaries.contains { $0.id == qwen }, "Hidden models remain available in Not connected")
        XCTAssertTrue(preferences.isConnected("ollama-local"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(local.calls, 1)
        XCTAssertEqual(cloud.calls, 1)

        let restored = Preferences(defaults: defaults)
        let relaunched = UsageStore(providers: [cloud, local], archive: UsageArchive(defaults: defaults),
                                    disconnected: restored.disconnectedIDs(among: [cloud.id, local.id, llama, qwen]), order: restored.providerOrder)
        await relaunched.refresh()
        XCTAssertEqual(relaunched.notchSnapshots.map(\.id), [cloud.id, llama])
        restored.setConnected(true, for: qwen)
        restored.setProviderOrder(ProviderOrder.joiningConnected(qwen, in: restored.providerOrder,
                                                                 isConnected: restored.isConnected))
        relaunched.disconnected = restored.disconnectedIDs(among: [cloud.id, local.id, llama, qwen])
        relaunched.order = restored.providerOrder
        XCTAssertEqual(relaunched.notchSnapshots.map(\.id), [cloud.id, llama, qwen])
        relaunched.disconnected.insert("ollama-local")
        XCTAssertTrue(relaunched.localModelSummaries.isEmpty)
        XCTAssertEqual(relaunched.notchSnapshots.map(\.id), [cloud.id])
    }

    func testNewlyLoadedModelsDoNotShuffleExistingRowsBeforeAnOrderIsChosen() async throws {
        let local = RuntimeStub(), cloud = QuotaStub()
        let store = UsageStore(providers: [local, cloud], archive: UsageArchive(defaults: isolatedDefaults()))
        for names in [["z-model"], ["a-model", "z-model"]] {
            let data = try JSONSerialization.data(withJSONObject: ["models": names.map { ["name": $0] }])
            local.models = try OllamaLocalUsage.parse(data).models
            await store.refresh()
        }
        XCTAssertEqual(store.notchSnapshots.map(\.id), ["ollama-local:model:z-model", "ollama-local:model:a-model", cloud.id])
        XCTAssertEqual(store.providerSummaries.filter { $0.kind == .usage || $0.localModel != nil }.map(\.id),
                       store.notchSnapshots.map(\.id))
    }

    func testInventoryDefaultsOnAndPreservesOtherChoices() {
        let defaults = isolatedDefaults()
        defaults.set(["cursor"], forKey: "hiddenProviders")
        let first = Preferences(defaults: defaults)
        XCTAssertTrue(first.isConnected("ollama-local"))
        XCTAssertFalse(first.isConnected("cursor"))
        XCTAssertTrue(first.isConnected("codex"))
        first.setConnected(false, for: "ollama-local")
        XCTAssertFalse(Preferences(defaults: defaults).isConnected("ollama-local"))
    }

    func testRuntimeNeverUsesTheQuotaArchiveAndFailureClearsItImmediately() async {
        let defaults = isolatedDefaults()
        let provider = RuntimeStub()
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: defaults))
        await store.refresh()
        XCTAssertTrue(store.snapshots[0].hasReading)
        XCTAssertTrue(UsageArchive(defaults: defaults).load().isEmpty)
        let relaunched = UsageStore(providers: [provider], archive: UsageArchive(defaults: defaults))
        XCTAssertFalse(relaunched.snapshots[0].hasReading)
        provider.fails = true
        await store.refresh()
        XCTAssertNil(store.snapshots[0].localRuntime)
        XCTAssertTrue(store.snapshots[0].statusMessage?.contains("unavailable") == true)
    }

    func testDisabledRuntimeMakesNoRequests() async {
        let provider = RuntimeStub()
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: isolatedDefaults()),
                               disconnected: ["ollama-local"])
        await store.refresh()
        store.refreshLocalRuntimes()
        store.refresh(providerID: "ollama-local")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(provider.calls, 0)
        XCTAssertTrue(store.snapshots.isEmpty)
    }

    func testLateResponseCannotRestoreDisabledRuntime() async {
        let provider = RuntimeStub()
        provider.suspended = true
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: isolatedDefaults()))
        let pass = Task { await store.refresh() }
        await started(provider)
        store.disconnected = ["ollama-local"]
        provider.finish()
        await pass.value
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.refreshing.isEmpty)
    }

    func testFullAndLocalRefreshCoalesce() async {
        let provider = RuntimeStub()
        provider.suspended = true
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: isolatedDefaults()))
        store.refreshLocalRuntimes()
        await started(provider)
        let pass = Task { await store.refresh() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(provider.calls, 1)
        provider.finish()
        await pass.value
        XCTAssertTrue(store.snapshots[0].hasReading)
    }

    func testClickedModelCanAwaitTheExistingInventoryPoll() async throws {
        let provider = RuntimeStub()
        provider.suspended = true
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: isolatedDefaults()))
        store.refreshLocalRuntimes()
        await started(provider)
        let pending = try XCTUnwrap(store.refresh(providerID: "ollama-local"))
        var completed = false
        let waiting = Task { await pending.value; completed = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(completed, "Joining a poll must await its actual completion")
        XCTAssertEqual(provider.calls, 1)
        provider.finish()
        await waiting.value
        XCTAssertTrue(completed)
        XCTAssertFalse(store.refreshing.contains("ollama-local"))
    }

    func testReconnectingIgnoresThePreviousConnectionResponse() async {
        let provider = RuntimeStub()
        provider.suspended = true
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: isolatedDefaults()))
        let first = Task { await store.refresh() }
        await started(provider)
        store.disconnected = ["ollama-local"]
        store.disconnected = []
        for _ in 0..<100 {
            if provider.calls == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(provider.calls, 2)
        provider.finish()
        await first.value
        XCTAssertFalse(store.snapshots[0].hasReading, "The cancelled request restored a reading")
        XCTAssertTrue(store.refreshing.contains("ollama-local"))
        provider.finish()
        await store.refresh()
        XCTAssertTrue(store.snapshots[0].hasReading)
    }

    func testLocalResultIsPublishedWhileACloudRequestIsStillPending() async {
        let cloud = RuntimeStub(id: "cloud", kind: .usage)
        cloud.suspended = true
        let local = RuntimeStub()
        let store = UsageStore(providers: [cloud, local], archive: UsageArchive(defaults: isolatedDefaults()))
        let pass = Task { await store.refresh() }
        await started(cloud)
        for _ in 0..<100 {
            if store.snapshots.last?.hasReading == true { break }
            await Task.yield()
        }
        XCTAssertTrue(store.snapshots.last?.hasReading == true)
        XCTAssertTrue(store.refreshing.contains("cloud"))
        cloud.finish()
        await pass.value
    }

    func testLocalTicksDoNotFetchOrStarveCloudProviders() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let local = RuntimeStub()
        let cloud = QuotaStub()
        let store = UsageStore(providers: [cloud, local], refreshInterval: 0.02,
                               idleRefreshInterval: 0.05, archive: UsageArchive(defaults: isolatedDefaults()),
                               pollingNow: { now })
        store.refreshLocalRuntimes()
        await started(local)
        XCTAssertEqual(cloud.calls, 0)
        store.start()
        defer { store.stop() }
        for _ in 0..<20 {
            now.addTimeInterval(0.01)
            store.refreshLocalRuntimes()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(cloud.calls, 2)
        XCTAssertEqual(store.snapshots.map(\.id), ["cloud", "ollama-local"])
    }

    func testLocalTimerDetectsAndRemovesModelsWithoutManualRefresh() async throws {
        let local = RuntimeStub(), cloud = QuotaStub()
        let store = UsageStore(providers: [cloud, local], archive: UsageArchive(defaults: isolatedDefaults()))
        store.start()
        defer { store.stop() }
        await started(local)
        let loaded = expectation(description: "Model discovered by the default local timer")
        let removed = expectation(description: "Unloaded model removed by the default local timer")
        let modelID = "ollama-local:model:qwen3:8b"
        var wasLoaded = false
        var wasRemoved = false
        let subscription = store.$notchSnapshots.sink { cells in
            if cells.contains(where: { $0.id == modelID }), !wasLoaded {
                wasLoaded = true
                loaded.fulfill()
            } else if wasLoaded && !wasRemoved && !cells.contains(where: { $0.id == modelID }) {
                wasRemoved = true
                removed.fulfill()
            }
        }
        defer { subscription.cancel() }
        local.models = try OllamaLocalUsage.parse(Data(#"{"models":[{"name":"qwen3:8b"}]}"#.utf8)).models
        await fulfillment(of: [loaded], timeout: 2.5)
        XCTAssertEqual(store.localModelSummaries.map(\.id), [modelID])
        local.models = []
        await fulfillment(of: [removed], timeout: 2.5)
        XCTAssertTrue(store.localModelSummaries.isEmpty)
        XCTAssertEqual(cloud.calls, 1, "Frequent local discovery must not refresh cloud usage")

        store.disconnected = ["ollama-local"]
        let calls = local.calls
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(local.calls, calls, "Disabled monitoring must stop local requests")
    }

    func testChangingEndpointClearsOldReadingAndDoesNotEnableMonitoring() async throws {
        let provider = OllamaLocalProvider(endpoint: try OllamaEndpoint.parse(OllamaEndpoint.defaultAddress))
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: isolatedDefaults()),
                               disconnected: ["ollama-local"])
        let updated = try OllamaEndpoint.parse("http://127.0.0.1:11435")
        store.updateOllamaEndpoint(updated)
        XCTAssertEqual(provider.endpoint, updated)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.refreshing.isEmpty)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "OllamaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func started(_ provider: RuntimeStub) async {
        for _ in 0..<100 {
            if provider.calls > 0 { return }
            await Task.yield()
        }
        XCTFail("Provider did not start")
    }
}

@MainActor
private final class RuntimeStub: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName = "Ollama"
    nonisolated let glyph = ProviderGlyph.ollamaLocal
    nonisolated let kind: ProviderKind
    var calls = 0
    var fails = false
    var suspended = false
    var models: [LocalRuntimeReading.Model] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    init(id: String = "ollama-local", kind: ProviderKind = .localRuntime) {
        self.id = id
        self.kind = kind
    }
    func fetchSnapshot() async throws -> ProviderSnapshot {
        calls += 1
        if suspended { await withCheckedContinuation { continuations.append($0) } }
        if fails { throw OllamaError.unavailable }
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok, windows: [],
                                kind: kind, localRuntime: LocalRuntimeReading(models: models))
    }
    func finish() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

@MainActor
private final class QuotaStub: UsageProvider {
    nonisolated let id = "cloud"
    nonisolated let displayName = "Cloud"
    nonisolated let glyph = ProviderGlyph.claude
    var calls = 0
    func fetchSnapshot() async throws -> ProviderSnapshot {
        calls += 1
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.4)])
    }
}

private func ollamaSnapshot(_ reading: LocalRuntimeReading) -> ProviderSnapshot {
    ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal,
                     fidelity: .official, status: .ok, windows: [],
                     kind: .localRuntime, localRuntime: reading)
}

@MainActor
final class OllamaRenderTests: XCTestCase {
    func testOpenSettingsUpdatesAsModelsAreDetectedReorderedAndHidden() async throws {
        let domain = "OllamaAccountRenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        let local = RuntimeStub(), cloud = QuotaStub()
        let store = UsageStore(providers: [cloud, local], archive: UsageArchive(defaults: defaults),
                               disconnected: preferences.disconnectedIDs(among: [cloud.id, local.id]))
        let content = SettingsView(preferences: preferences, providers: { store.providerSummaries },
            signOut: { store.signOut(providerID: $0) }, signIn: { store.signIn(providerID: $0) },
            switchAccount: { _ in false }, retry: { store.refresh(providerID: $0) },
            resetPosition: {}, quit: {}, updater: Updater(), usageStore: store)
            .frame(width: SettingsView.width, height: SettingsView.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000,
            width: SettingsView.width, height: SettingsView.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }

        func capture(_ state: String) async throws {
            try await Task.sleep(nanoseconds: 600_000_000)
            hosting.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let image = NSImage(size: hosting.bounds.size)
            image.addRepresentation(rep)
            try save(image, name: "ollama-accounts-\(state).png")
        }
        try await capture("off")
        preferences.setConnected(true, for: "ollama-local")
        store.disconnected = preferences.disconnectedIDs(among: store.knownIDs)
        await store.refresh()
        try await capture("empty")
        local.models = try OllamaLocalUsage.parse(Data(#"{"models":[{"name":"qwen3:8b","size":6442450944},{"name":"llama3.1:8b","size":4831838208}]}"#.utf8)).models
        await store.refresh(providerID: "ollama-local")?.value
        try await capture("detected")
        let qwen = "ollama-local:model:qwen3:8b", llama = "ollama-local:model:llama3.1:8b"
        preferences.setProviderOrder([qwen, cloud.id, llama])
        store.order = preferences.providerOrder
        try await capture("reordered")
        preferences.setConnected(false, for: qwen)
        store.disconnected = preferences.disconnectedIDs(among: store.knownIDs)
        try await capture("hidden")
        local.models = []
        await store.refresh(providerID: "ollama-local")?.value
        try await capture("unloaded")
        local.fails = true
        await store.refresh(providerID: "ollama-local")?.value
        try await capture("unavailable")
    }

    func testLocalCardsFitTheExistingPanelBudgetOnEveryEdge() throws {
        let models = (0..<8).map { index in
            LocalRuntimeReading.Model(name: "example/long-model-name-\(index):latest",
                memoryBytes: 6_442_450_944, contextLength: 32_768,
                quantizationLevel: index.isMultiple(of: 2) ? "Q4_K_M" : "Q8_0")
        }
        let snapshots = ollamaSnapshot(LocalRuntimeReading(models: models)).notchSnapshots
        XCTAssertEqual(snapshots.count, models.count)
        for (index, snapshot) in snapshots.enumerated() {
            let height = NotchLayout.cardHeight(windowCount: 0, localModelName: snapshot.localModel?.name)
            XCTAssertLessThanOrEqual(height, NotchLayout.maxCardHeight(sessionCap: 0))
            for edge in NotchEdge.allCases {
                let view = TooltipCard(snapshot: snapshot, now: Date(), direction: edge.tooltipDirection)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage)
                XCTAssertGreaterThan(image.size.height, 0)
                try save(image, name: "ollama-model-\(index)-\(edge.rawValue).png")
            }
        }
    }

    func testLiveLocalListingWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODENOTCH_OLLAMA_LIVE"] == "1" else {
            throw XCTSkip("Opt-in live Ollama check")
        }
        let provider = OllamaLocalProvider(endpoint: try OllamaEndpoint.parse(OllamaEndpoint.defaultAddress))
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertTrue(snapshot.hasReading)
        XCTAssertNil(snapshot.ringFraction)
        if let expectedName = ProcessInfo.processInfo.environment["CODENOTCH_OLLAMA_EXPECTED_MODEL"],
           let expectedBrand = ProcessInfo.processInfo.environment["CODENOTCH_OLLAMA_EXPECTED_BRAND"] {
            let cell = try XCTUnwrap(snapshot.notchSnapshots.first { $0.localModel?.name == expectedName })
            XCTAssertEqual(cell.localModel?.brand?.rawValue ?? "ollama", expectedBrand)
            XCTAssertEqual(cell.glyph, cell.localModel?.brand?.glyph ?? .ollamaLocal)
            XCTAssertEqual(cell.providerID, "ollama-local")
        }
        for (index, cell) in snapshot.notchSnapshots.enumerated() {
            XCTAssertNotNil(cell.localModel)
            let renderer = ImageRenderer(content: TooltipCard(snapshot: cell, now: Date()))
            renderer.scale = 2
            try save(XCTUnwrap(renderer.nsImage), name: "ollama-model-live-\(index).png")
        }
    }

    func testSettingsAndNotchRenderWithTheLocalStore() async throws {
        let domain = "OllamaSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        let store = UsageStore(providers: [RuntimeStub()], archive: UsageArchive(defaults: defaults),
                               disconnected: preferences.disconnectedIDs(among: ["ollama-local"]))
        for enabled in [false, true] {
            preferences.setConnected(enabled, for: "ollama-local")
            store.disconnected = preferences.disconnectedIDs(among: store.knownIDs)
            if enabled { await store.refresh() }
            let content = OllamaSettingsRow(preferences: preferences, store: store, relay: OllamaActivityRelay())
                .padding(20).frame(width: 460).background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let image = NSImage(size: hosting.bounds.size)
            image.addRepresentation(rep)
            try save(image, name: "ollama-settings-\(enabled ? "on" : "off").png")
        }
        let model = NotchViewModel()
        let models = [
            LocalRuntimeReading.Model(name: "llama3.1:8b",
                memoryBytes: 4_831_838_208, contextLength: 2_048, quantizationLevel: "Q4_K_M"),
            LocalRuntimeReading.Model(name: "qwen3:8b",
                memoryBytes: 6_442_450_944, contextLength: 8_192, quantizationLevel: nil)
        ]
        model.updateSnapshots([ollamaSnapshot(LocalRuntimeReading(models: models))])
        XCTAssertEqual(model.snapshots.count, 2)
        model.isExpanded = true
        model.hoveredIndex = 0
        for edge in NotchEdge.allCases {
            model.edge = edge
            let size = model.panelSize
            let renderer = ImageRenderer(content: NotchRootView(model: model)
                .frame(width: size.width, height: size.height))
            renderer.scale = 2
            try save(XCTUnwrap(renderer.nsImage), name: "ollama-notch-\(edge.rawValue).png")
        }
    }

    func testMixedCloudAndLocalCellsRenderOnEveryEdge() throws {
        let clouds = [ProviderGlyph.claude, .openai, .cursor].map { glyph in
            ProviderSnapshot(id: glyph.rawValue, displayName: glyph.rawValue,
                glyph: glyph, fidelity: .official, status: .ok,
                windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.4)])
        }
        let reading = try OllamaLocalUsage.parse(Data(#"{"models":[{"name":"a-long-model-name/with-a-long-variant:8b","size":4831838208,"context_length":2048},{"name":"b-model:8b","size":15569256448,"context_length":8192},{"name":"c-model:8b"}]}"#.utf8))
        let controller = NotchWindowController()
        let model = controller.model
        model.updateSnapshots(clouds + [ollamaSnapshot(reading)])
        model.isExpanded = true
        model.screenSize = CGSize(width: 1512, height: 982)
        XCTAssertEqual(model.snapshots.count, 6)
        for edge in NotchEdge.allCases {
            model.edge = edge
            XCTAssertGreaterThan(model.cellSpacing, 0)
            for index in model.snapshots.indices {
                let centre = model.slack + model.ringCenter(index: index)
                XCTAssertEqual(controller.cellIndex(along: centre), index)
                XCTAssertEqual(controller.cellIndex(along: centre + model.cellPitch / 2 - 0.01), index)
            }
            for index in [3, 5] {
                model.hoveredIndex = index
                let size = model.panelSize
                XCTAssertLessThanOrEqual(size.width, model.screenSize.width)
                XCTAssertLessThanOrEqual(size.height, model.screenSize.height + 0.001)
                let renderer = ImageRenderer(content: NotchRootView(model: model)
                    .frame(width: size.width, height: size.height))
                renderer.scale = 2
                try save(XCTUnwrap(renderer.nsImage), name: "ollama-mixed-\(edge.rawValue)-\(index).png")
            }
        }
        model.updateSnapshots([])
        model.isHoveringSettings = true
        let size = model.panelSize
        let renderer = ImageRenderer(content: NotchRootView(model: model)
            .frame(width: size.width, height: size.height))
        renderer.scale = 2
        try save(XCTUnwrap(renderer.nsImage), name: "ollama-empty-settings.png")
    }

    func testBrandIconsAndRuntimeLabelsRenderTogether() throws {
        let names = ["qwen3:0.6b", "gemma3:270m", "llama3.2:1b",
                     "deepseek-r1:1.5b", "ministral-3:3b", "my-custom-model:latest"]
        let models = names.sorted().map { LocalRuntimeReading.Model(name: $0,
            memoryBytes: 1_610_612_736, contextLength: 2_048, quantizationLevel: "Q4_K_M") }
        let runtime = ollamaSnapshot(LocalRuntimeReading(models: models))
        let model = NotchViewModel()
        model.updateSnapshots([runtime])
        model.isExpanded = true
        model.screenSize = CGSize(width: 1920, height: 1080)
        for edge in NotchEdge.allCases {
            model.edge = edge
            model.hoveredIndex = 0
            let size = model.panelSize
            let renderer = ImageRenderer(content: NotchRootView(model: model)
                .frame(width: size.width, height: size.height))
            renderer.scale = 2
            try save(XCTUnwrap(renderer.nsImage), name: "ollama-brands-\(edge.rawValue).png")
        }
        for cell in model.snapshots {
            let renderer = ImageRenderer(content: TooltipCard(snapshot: cell, now: Date()))
            renderer.scale = 2
            try save(XCTUnwrap(renderer.nsImage),
                     name: "ollama-brand-\(cell.localModel?.brand?.rawValue ?? "fallback")-tooltip.png")
        }
    }

    private func save(_ image: NSImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OLLAMA_RENDER_DIRECTORY"] else { return }
        let data = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
