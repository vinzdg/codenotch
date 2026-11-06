import Combine
import Foundation

@MainActor
final class OllamaActivityRelay: ObservableObject {
    static let address = "http://127.0.0.1:11435"
    @Published private(set) var status = L10n.t("Off")
    @Published private(set) var ready = false
    @Published private(set) var thinkingModels: [String: Date] = [:]
    @Published private(set) var performances: [String: LocalModelPerformance] = [:]
    private var requests: [UUID: (model: String, since: Date)] = [:]
    private var server: OllamaRelayServer?
    private var revision = UUID()
    private var configuration: Task<Void, Never>?

    func configure(enabled: Bool, endpoint: String) {
        let revision = UUID()
        self.revision = revision
        requests.removeAll()
        thinkingModels = [:]
        performances = [:]
        ready = false
        status = enabled ? L10n.t("Starting…") : L10n.t("Off")
        let previous = configuration
        configuration = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if let server = self.server { await server.stop(); self.server = nil }
            guard self.revision == revision, enabled else { return }
            do {
                let endpoint = try OllamaEndpoint.parse(endpoint)
                let server = OllamaRelayServer(upstream: endpoint, onPerformance: { [weak self] model, measurement in
                    DispatchQueue.main.async {
                        guard let self, self.revision == revision else { return }
                        self.recordPerformance(measurement, model: model)
                    }
                }) { [weak self] id, model, active in
                    // Preserve the single NIO event loop's order so a thinking
                    // stop cannot reach the UI before its start.
                    DispatchQueue.main.async {
                        guard let self, self.revision == revision else { return }
                        self.observe(id: id, model: model, thinking: active)
                    }
                }
                self.server = server
                _ = try await server.start()
                guard self.revision == revision else { return }
                self.ready = true
                self.status = L10n.t("Ready · \(Self.address)")
            } catch {
                if let server = self.server { await server.stop(); self.server = nil }
                guard self.revision == revision else { return }
                self.status = L10n.t("Cannot start relay. Check that port 11435 is free and the server uses a different port.")
            }
        }
    }

    func recordPerformance(_ measurement: LocalModelPerformance, model: String) {
        guard !model.isEmpty else { return }
        let key = OllamaThinkingStream.modelKey(model)
        if let previous = performances[key], previous.measuredAt > measurement.measuredAt { return }
        performances[key] = measurement
        // Model names can accumulate for the app's lifetime, so cap this cache.
        if performances.count > 128,
           let oldest = performances.min(by: { $0.value.measuredAt < $1.value.measuredAt })?.key {
            performances.removeValue(forKey: oldest)
        }
    }

    func observe(id: UUID, model: String, thinking: Bool, now: Date = Date()) {
        if thinking, !model.isEmpty {
            let key = OllamaThinkingStream.modelKey(model)
            let since = requests[id]?.model == key ? requests[id]!.since : now
            requests[id] = (key, since)
        } else {
            requests.removeValue(forKey: id)
        }
        var models: [String: Date] = [:]
        for request in requests.values {
            models[request.model] = min(models[request.model] ?? request.since, request.since)
        }
        if thinkingModels != models { thinkingModels = models }
    }
}
