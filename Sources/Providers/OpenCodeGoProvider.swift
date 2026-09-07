import Foundation

/// Reads OpenCode Go's limits from the quota endpoint OpenCode's own console
/// dashboard reads, with the key OpenCode itself stores once Go is connected.
///
/// Go is the $10/month subscription from the OpenCode team: one API key, a
/// curated set of open models, and limits expressed in *dollars* — $12 per
/// rolling 5 hours, $30 per week, $60 per month — rather than request counts.
/// The endpoint is not in the published docs; it is the one the dashboard's
/// percentages come from, and other quota tools read the same shape, so it is
/// pinned by tests here as the first place a change would show.
///
/// The numbers are OpenCode's own, so this is `.official`.
actor OpenCodeGoProvider: UsageProvider {
    nonisolated let id = "opencode-go"
    nonisolated let displayName = "OpenCode Go"
    nonisolated let glyph = ProviderGlyph.opencode

    private let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Usage rides on an OpenCode Go API key held by the OpenCode desktop app. "
                  + "Connect OpenCode Go there and the notch reads the key it stores.")
    }

    nonisolated func forgetCachedCredential() {
        // Nothing is cached: the key is re-read from an ordinary file on every
        // fetch, which never prompts.
    }

    nonisolated func account() -> ProviderAccount? {
        guard (try? OpenCodeGoCredentials.load()) != nil else { return nil }
        return ProviderAccount(
            label: nil,   // the stored key carries no address
            plan: "Go",
            source: "OpenCode",
            manageURL: URL(string: "https://opencode.ai/auth")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let credentials = try OpenCodeGoCredentials.load()
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(credentials.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codenotch", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 { throw UsageProviderError.needsAuth }
        if status == 403 {
            // A valid key that is refused with an entitlement error has no Go
            // subscription behind it — signed in, with nothing metered to read.
            // Saying "sign in" for that would send someone to fix something
            // that is not broken.
            let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if body.contains("entitlement") {
                throw UsageProviderError.nothingMetered("No OpenCode Go subscription on this key")
            }
            throw UsageProviderError.needsAuth
        }
        if status == 429 {
            let retry = http?
                .value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
            throw UsageProviderError.rateLimited(retryAfter: retry)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let windows = try OpenCodeGoUsage.windows(from: data)
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: "session"
        )
    }
}

/// The key behind an OpenCode Go subscription, borrowed from OpenCode itself.
///
/// Codenotch never signs in anywhere, so the key has to be one a tool already
/// holds. The OpenCode desktop app bundles the same server core as the CLI,
/// and both store credentials in `~/.local/share/opencode/auth.json` — the
/// desktop app writes its `opencode-go` entry there when Go is connected. The
/// file holds every provider's credentials, so only that entry is claimed —
/// the Anthropic, OpenAI and GitHub keys beside it belong to somebody else.
struct OpenCodeGoCredentials: Sendable {
    let key: String

    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    static func load() throws -> OpenCodeGoCredentials {
        guard let text = try? String(contentsOf: authURL, encoding: .utf8) else {
            throw UsageProviderError.needsAuth
        }
        return try load(authJSON: text)
    }

    /// The JSON is a parameter so a test can feed a fixture without touching a
    /// real auth file.
    static func load(authJSON: String?) throws -> OpenCodeGoCredentials {
        guard let text = authJSON,
              let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = root["opencode-go"]
        else { throw UsageProviderError.needsAuth }

        var key: String?
        if let object = entry as? [String: Any] {
            // The shape OpenCode writes: `{ "type": "api", "key": … }`. An
            // OAuth entry is somebody's browser session, not a key of ours to
            // send anywhere.
            if let type = object["type"] as? String, type != "api" {
                throw UsageProviderError.needsAuth
            }
            key = ["key", "apiKey", "api_key", "token"]
                .compactMap { nonEmpty(object[$0]) }.first
        } else {
            key = nonEmpty(entry)
        }
        guard let key else { throw UsageProviderError.needsAuth }
        return OpenCodeGoCredentials(key: key)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Parses the answer from `GET https://opencode.ai/zen/go/v1/usage`:
///
/// ```json
/// { "usage": {
///     "rolling": { "status": "ok", "percent": 4, "resetsAt": "2026-08-13T16:27:38.287Z" },
///     "weekly":  { "status": "ok", "percent": 3, "resetsAt": "2026-08-17T00:00:00.287Z" },
///     "monthly": { "status": "ok", "percent": 1, "resetsAt": "2026-09-13T06:06:01.287Z" } } }
/// ```
///
/// `percent` is how much has been *used* — the same figure OpenCode's dashboard
/// leads with, and the same convention Claude's endpoint speaks, so no flip to
/// remaining is needed. The limits behind it are dollar values, so the
/// percentage is the only honest reading there is: request counts would depend
/// on which model ran.
enum OpenCodeGoUsage {
    static func windows(from data: Data) throws -> [LimitWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        // Rolling first — the 5-hour window is the one the plan's own material
        // leads with, and the ring's headline.
        let windows = [("session", "5-hour session", usage["rolling"]),
                       ("weekly", "Weekly limit", usage["weekly"]),
                       ("monthly", "Monthly limit", usage["monthly"])]
            .compactMap { (id: String, label: String, value: Any?) -> LimitWindow? in
                guard let window = value as? [String: Any],
                      let percent = window["percent"] as? NSNumber,
                      percent.doubleValue.isFinite
                else { return nil }
                return LimitWindow(id: id, label: label,
                                   usedFraction: percent.doubleValue / 100,
                                   resetsAt: date(window["resetsAt"]))
            }
        guard !windows.isEmpty else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return windows
    }

    /// ISO 8601, fraction seconds or not.
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}
