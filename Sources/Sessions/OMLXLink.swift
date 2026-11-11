import Foundation

/// What each loaded oMLX model is doing this instant, as its admin dashboard
/// reads it. Only what the metrics fold into a cell is kept.
///
/// `GET /admin/api/activity`, recorded idle from oMLX 0.7.0 on 2026-10-08
/// (trimmed):
///
///     {"active_models":{"models":[{"id":"Qwen3.8-27B-oQ8e-mtp","is_loading":false,
///       "active_requests":0,"waiting_requests":0,"waiting":[],"activities":[],
///       "prefilling":[],"generating":[],"idle_seconds":44455.94, …}],
///      "total_active_requests":0,"total_waiting_requests":0}}
///
/// The busy shapes are source-derived from `admin/routes.py`
/// (`_build_active_models_data`), not recorded: `waiting` items carry
/// `queue_position`, `prefilling` items `processed` / `total`, `generating`
/// items `generated_tokens`, `elapsed_seconds`, `tokens_per_second` and
/// `prompt_tokens`. `activities` is what non-streaming engines report instead;
/// its items have no fixed shape, so only their count is read.
struct OMLXActivity: Equatable {
    struct Model: Equatable {
        let id: String
        let isLoading: Bool
        /// Requests queued behind the one in progress.
        let waiting: Int
        /// Requests still reading their prompt.
        let prefilling: Int
        let generating: [Generating]
        /// Work reported by an engine that does not stream.
        let activities: Int

        init(id: String, isLoading: Bool = false, waiting: Int = 0, prefilling: Int = 0,
             generating: [Generating] = [], activities: Int = 0) {
            self.id = id
            self.isLoading = isLoading
            self.waiting = waiting
            self.prefilling = prefilling
            self.generating = generating
            self.activities = activities
        }
    }

    struct Generating: Equatable {
        let generatedTokens: Int
        let elapsedSeconds: Double?
        let tokensPerSecond: Double?
        let promptTokens: Int
    }

    let models: [Model]

    /// Loose on purpose, like the settings file: a newer oMLX adding fields
    /// must still be read, and a missing count is zero rather than a failure.
    /// Only a body without the model list is the wrong service.
    static func parse(_ data: Data) throws -> OMLXActivity {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let active = root["active_models"] as? [String: Any],
              let models = active["models"] as? [[String: Any]]
        else { throw OMLXError.invalidResponse }
        return OMLXActivity(models: try models.map { model in
            guard let id = model["id"] as? String, !id.isEmpty else { throw OMLXError.invalidResponse }
            let waiting = (model["waiting"] as? [Any])?.count
            let generating = (model["generating"] as? [[String: Any]] ?? []).map { item in
                Generating(generatedTokens: integer(item["generated_tokens"]) ?? 0,
                           elapsedSeconds: number(item["elapsed_seconds"]),
                           tokensPerSecond: number(item["tokens_per_second"]),
                           promptTokens: integer(item["prompt_tokens"]) ?? 0)
            }
            return Model(id: id,
                         isLoading: model["is_loading"] as? Bool ?? false,
                         // The count oMLX keeps, else the list it shows.
                         waiting: integer(model["waiting_requests"]) ?? waiting ?? 0,
                         prefilling: (model["prefilling"] as? [Any])?.count ?? 0,
                         generating: generating,
                         activities: (model["activities"] as? [Any])?.count ?? 0)
        })
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber).map { $0.intValue }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = (value as? NSNumber)?.doubleValue, value.isFinite else { return nil }
        return value
    }
}

/// What the metrics need of the server, so a test can stand one in.
protocol OMLXCalling: AnyObject {
    func activity() async throws -> OMLXActivity
    func close() async
}

/// The admin activity endpoint, behind oMLX's own dashboard session.
///
/// The per-model phase and queue exist only on `/admin/api/activity`, and the
/// admin routes accept a session cookie, not the Bearer key the listing takes.
/// So the borrowed main key logs in (`POST /admin/api/login`) the first time a
/// read is refused, the cookie is kept in this link's own session, and every
/// later read rides on it until oMLX expires it (a day) and the next refusal
/// logs in again. Sub keys cannot log in; that refusal is `needsKey`.
///
/// A session of its own rather than `OllamaLocalProvider.makeSession()`, which
/// disables cookies; the same refusal of redirects and proxies, so the key is
/// never sent anywhere but the configured loopback address. The key and the
/// login body are never logged.
final class OMLXLink: OMLXCalling {
    private let endpoint: URL
    private let key: () -> String?
    private let session: URLSession
    private let timeout: TimeInterval

    init(endpoint: URL, key: @escaping () -> String? = { OMLXCredentials.load() },
         timeout: TimeInterval = 3, configuration: URLSessionConfiguration? = nil) {
        self.endpoint = endpoint
        self.key = key
        self.timeout = timeout
        let configuration = configuration ?? .ephemeral
        configuration.httpCookieStorage = configuration.httpCookieStorage ?? HTTPCookieStorage()
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration, delegate: OllamaRedirectPolicy(), delegateQueue: nil)
    }

    func activity() async throws -> OMLXActivity {
        var (status, data) = try await send(read())
        if status == 401 {
            try await login()
            (status, data) = try await send(read())
        }
        if status == 401 || status == 403 { throw OMLXError.needsKey }
        guard status == 200 else { throw OMLXError.http(status) }
        return try OMLXActivity.parse(data)
    }

    /// The session cookie dies with the link; a new one logs in afresh.
    func close() async {
        session.invalidateAndCancel()
    }

    private func login() async throws {
        guard let key = key() else { throw OMLXError.needsKey }
        var request = URLRequest(url: endpoint.appendingPathComponent("admin/api/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // `remember: false`: a session cookie, not a thirty-day one, since this
        // link logs in again whenever it is refused anyway.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["api_key": key, "remember": false])
        let (status, _) = try await send(request)
        if status == 401 || status == 403 { throw OMLXError.needsKey }
        guard status == 200 else { throw OMLXError.http(status) }
    }

    private func read() -> URLRequest {
        var request = URLRequest(url: endpoint.appendingPathComponent("admin/api/activity"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Int, Data) {
        var request = request
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch where error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OMLXError.unavailable
        }
    }
}
