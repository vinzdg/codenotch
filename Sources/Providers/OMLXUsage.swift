import Foundation

/// `GET /v1/models/status`, oMLX's own listing, recorded from 0.7.0 on
/// 2026-10-08 and trimmed to the fields read here:
///
///     {"final_ceiling":87827013104,"current_model_memory":31501724030,"model_count":2,"loaded_count":2,
///      "models":[
///       {"id":"Qwen3.8-27B-oQ8e-mtp","model_path":"/Users/istar/Models/Jundot/Qwen3.8-27B-oQ8e-mtp",
///        "loaded":true,"is_loading":false,"estimated_size":31501724030,"resident_estimated_size":31501724030,
///        "actual_size":30203498392,"pinned":false,"engine_type":"vlm","model_type":"vlm",
///        "model_context_length":262144,"is_helper":false,"source_type":"local","source_repo_id":null,
///        "max_context_window":262144,"model_alias":"qwen3.8-27b-oq8e","is_hidden":false,"max_tokens":32768},
///       {"id":"qwen3.8-27b-oq8e:nomtp","loaded":true,"is_loading":false,"estimated_size":31501724030,
///        "actual_size":30203498392,"engine_type":"vlm","model_context_length":262144,"is_helper":false,
///        "source_model_id":"Qwen3.8-27B-oQ8e-mtp","profile_name":"nomtp","profile_api_name":"nomtp",
///        "max_context_window":262144,"model_alias":"qwen3.8-27b-oq8e","is_hidden":false,"max_tokens":32768}]}
///
/// One cell per loaded model, named by its canonical `id`. That is the name
/// oMLX's server log writes on every response and the one its activity endpoint
/// reports on, whereas `/v1/models` lists aliases that match neither. An entry
/// with `source_model_id` is a profile of a model that is already listed: it
/// shares that model's engine and memory, so a second cell would count the same
/// weights twice. Embedding, reranker and audio engines never generate, so
/// there is no speed, context or queue to show for them.
///
/// `actual_size` is what the engine measured after loading; `estimated_size`
/// is the pre-load guess and only stands in while the first is absent.
enum OMLXUsage {
    private struct Response: Decodable {
        let models: [Model]
    }

    private struct Model: Decodable {
        let id: String
        let loaded: Bool?
        let is_helper: Bool?
        let is_hidden: Bool?
        let source_model_id: String?
        let source_repo_id: String?
        let engine_type: String?
        let actual_size: Int64?
        let estimated_size: Int64?
        let max_context_window: Int?
        let model_context_length: Int?

        var generates: Bool {
            let engine = engine_type?.lowercased() ?? ""
            return !(engine == "embeddings" || engine == "embedding" || engine == "reranker"
                     || engine.hasPrefix("audio_"))
        }
    }

    static func parse(_ data: Data) throws -> LocalRuntimeReading {
        // A wrong service or a refused key answers with its own envelope
        // (`{"detail": …}`), so the listing has to be recognised by `models`.
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OMLXError.invalidResponse
        }
        var seen = Set<String>()
        let models = try response.models
            .filter { $0.loaded == true && $0.is_helper != true && $0.is_hidden != true
                && $0.source_model_id == nil && $0.generates }
            .map { model in
                let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let context = model.max_context_window ?? model.model_context_length
                guard !id.isEmpty, seen.insert(id).inserted,
                      context.map({ $0 > 0 }) ?? true else {
                    throw OMLXError.invalidResponse
                }
                let memory = model.actual_size.flatMap { $0 > 0 ? $0 : nil } ?? model.estimated_size
                return LocalRuntimeReading.Model(
                    name: id, memoryBytes: memory, contextLength: context,
                    quantizationLevel: nil, memoryKind: .allocation,
                    modelKey: model.source_repo_id ?? id
                )
            }.sorted { $0.id < $1.id }
        return LocalRuntimeReading(models: models, measuresSpeed: true)
    }
}
