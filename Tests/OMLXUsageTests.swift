import XCTest
@testable import Codenotch

/// `GET /v1/models/status` as oMLX 0.7.0 answered it on 2026-10-08, cut down
/// to the fields the parser reads plus the entries it must leave out.
enum OMLXFixtures {
    static let listing = #"""
    {"final_ceiling":87827013104,"current_model_memory":31501724030,"model_count":6,"loaded_count":5,
     "load_seconds_per_gb_estimate":0.304,"load_time_observations":16,
     "models":[
      {"id":"Qwen3.8-27B-oQ8e-mtp","model_path":"/Users/istar/Models/Jundot/Qwen3.8-27B-oQ8e-mtp","loaded":true,"is_loading":false,
       "loading_started_at":null,"estimated_size":31501724030,"resident_estimated_size":31501724030,"distributed":false,"cluster":null,
       "actual_size":30203498392,"pinned":false,"engine_type":"vlm","model_type":"vlm","config_model_type":"qwen3_5","realtime_stt":false,
       "model_context_length":262144,"is_helper":false,"thinking_default":true,"preserve_thinking_default":true,"source_type":"local",
       "source_repo_id":null,"last_access":1791407364.46658,"max_context_window":262144,"model_alias":"qwen3.8-27b-oq8e","is_favorite":true,"is_hidden":false,"max_tokens":32768},
      {"id":"qwen3.8-27b-oq8e:nomtp","model_path":"/Users/istar/Models/Jundot/Qwen3.8-27B-oQ8e-mtp","loaded":true,"is_loading":false,
       "estimated_size":31501724030,"actual_size":30203498392,"engine_type":"vlm","model_type":"vlm","config_model_type":"qwen3_5",
       "model_context_length":262144,"is_helper":false,"source_type":"local","source_repo_id":null,"last_access":1791407364.46658,
       "source_model_id":"Qwen3.8-27B-oQ8e-mtp","profile_name":"nomtp","profile_api_name":"nomtp","profile_display_name":"oQ8e bez spekulacji (kontrola)",
       "max_context_window":262144,"model_alias":"qwen3.8-27b-oq8e","is_favorite":true,"is_hidden":false,"max_tokens":32768},
      {"id":"Qwen3.8-27B-oQ4e-mtp","loaded":false,"is_loading":false,"estimated_size":17000000000,"actual_size":0,
       "engine_type":"vlm","model_context_length":262144,"is_helper":false,"max_context_window":262144,"is_hidden":false},
      {"id":"qwen3-draft-helper","loaded":true,"is_loading":false,"estimated_size":500000000,"actual_size":480000000,
       "engine_type":"batched","model_context_length":8192,"is_helper":true,"max_context_window":8192,"is_hidden":false},
      {"id":"nomic-embed-text-v1.5","loaded":true,"is_loading":false,"estimated_size":300000000,"actual_size":280000000,
       "engine_type":"embeddings","model_context_length":2048,"is_helper":false,"max_context_window":2048,"is_hidden":false},
      {"id":"whisper-large-v3","loaded":true,"is_loading":false,"estimated_size":3000000000,"actual_size":2900000000,
       "engine_type":"audio_stt","model_context_length":448,"is_helper":false,"max_context_window":448,"is_hidden":false}
     ]}
    """#

    static func snapshot(_ reading: LocalRuntimeReading) -> ProviderSnapshot {
        ProviderSnapshot(id: "omlx", displayName: "oMLX", glyph: .omlx,
                         fidelity: .official, status: .ok, windows: [],
                         kind: .localRuntime, localRuntime: reading)
    }

    static func listing(_ models: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["models": models])
    }
}

final class OMLXUsageTests: XCTestCase {
    func testALoadedGeneratingModelBecomesACellAndProfilesHelpersAndNonGeneratorsAreLeftOut() throws {
        let reading = try OMLXUsage.parse(Data(OMLXFixtures.listing.utf8))
        XCTAssertTrue(reading.measuresSpeed, "oMLX logs its own responses; no relay is needed for speed")
        XCTAssertEqual(reading.models.map(\.name), ["Qwen3.8-27B-oQ8e-mtp"],
                       "the :nomtp profile shares the engine, and an unloaded model, a helper, an embedding and an audio model never get a cell")
        let model = try XCTUnwrap(reading.models.first)
        XCTAssertEqual(model.memoryBytes, 30_203_498_392)
        XCTAssertEqual(model.memoryKind, .allocation)
        XCTAssertEqual(model.memoryLabel, "Memory")
        XCTAssertEqual(model.contextLength, 262_144)
        XCTAssertNil(model.quantizationLevel)
        XCTAssertNil(model.gpuMemoryBytes)
        XCTAssertNil(model.expiresAt)
        XCTAssertEqual(model.modelKey, "Qwen3.8-27B-oQ8e-mtp")
        XCTAssertEqual(model.brand, .qwen)

        let snapshot = OMLXFixtures.snapshot(reading)
        XCTAssertTrue(snapshot.hasReading)
        XCTAssertEqual(snapshot.notchSnapshots.map(\.id), ["omlx:model:Qwen3.8-27B-oQ8e-mtp"])
        let cell = try XCTUnwrap(snapshot.notchSnapshots.first)
        XCTAssertEqual(cell.glyph, .qwen)
        XCTAssertEqual(cell.providerID, "omlx")
        XCTAssertTrue(cell.localRuntimeMeasuresSpeed)
    }

    func testTheMeasuredSizeIsPreferredAndTheEstimateStandsInWhenItIsMissing() throws {
        let reading = try OMLXUsage.parse(OMLXFixtures.listing([
            ["id": "measured", "loaded": true, "engine_type": "batched", "actual_size": 100, "estimated_size": 200],
            ["id": "estimated", "loaded": true, "engine_type": "batched", "estimated_size": 200],
            ["id": "zero-actual", "loaded": true, "engine_type": "batched", "actual_size": 0, "estimated_size": 300]
        ]))
        XCTAssertEqual(reading.models.map(\.name), ["estimated", "measured", "zero-actual"])
        XCTAssertEqual(reading.models.map(\.memoryBytes), [200, 100, 300])
    }

    func testTheContextFallsBackToTheModelsOwnAndTheRepoKeepsTheBrand() throws {
        let reading = try OMLXUsage.parse(OMLXFixtures.listing([
            ["id": "my-assistant", "loaded": true, "engine_type": "batched",
             "model_context_length": 8192, "source_repo_id": "qwen/qwen3.8-flash-next"],
            ["id": "plain", "loaded": true, "model_context_length": 4096, "max_context_window": 2048]
        ]))
        XCTAssertEqual(reading.models.map(\.name), ["my-assistant", "plain"])
        XCTAssertEqual(reading.models[0].contextLength, 8192)
        XCTAssertEqual(reading.models[0].brand, .qwen, "the id says nothing; the source repo does")
        XCTAssertEqual(reading.models[1].contextLength, 2048, "the window the server enforces, not the model's maximum")
        XCTAssertNil(reading.models[1].brand)
    }

    func testHiddenModelsAndRerankersAreLeftOut() throws {
        let reading = try OMLXUsage.parse(OMLXFixtures.listing([
            ["id": "hidden", "loaded": true, "engine_type": "batched", "is_hidden": true],
            ["id": "ranker", "loaded": true, "engine_type": "reranker"],
            ["id": "tts", "loaded": true, "engine_type": "audio_tts"],
            ["id": "shown", "loaded": true, "engine_type": "batched"]
        ]))
        XCTAssertEqual(reading.models.map(\.name), ["shown"])
    }

    func testAnEmptyListingIsAReadingWithoutModels() throws {
        let reading = try OMLXUsage.parse(Data(#"{"models":[]}"#.utf8))
        let snapshot = OMLXFixtures.snapshot(reading)
        XCTAssertTrue(snapshot.hasReading)
        XCTAssertTrue(snapshot.notchSnapshots.isEmpty)
        XCTAssertTrue(snapshot.statusMessage?.contains("No models loaded") == true)
    }

    func testTheWrongServiceAndMalformedListingsAreNotEmptySuccesses() {
        for payload in [#"{"detail":"API key required"}"#,
                        "{}", #"{"models":null}"#, "not json",
                        #"{"models":[{"id":" ","loaded":true,"engine_type":"batched"}]}"#,
                        #"{"models":[{"id":"a","loaded":true,"max_context_window":0}]}"#,
                        #"{"models":[{"id":"a","loaded":true,"model_context_length":-1}]}"#,
                        #"{"models":[{"id":"a","loaded":true},{"id":"a","loaded":true}]}"#] {
            XCTAssertThrowsError(try OMLXUsage.parse(Data(payload.utf8)), payload) { error in
                XCTAssertEqual(error as? OMLXError, .invalidResponse, payload)
            }
        }
    }
}
