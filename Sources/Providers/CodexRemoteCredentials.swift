import Foundation

/// The session of a Codex account on another machine, borrowed over SSH.
///
/// Codex files its token at `~/.codex/auth.json` on every platform, so there
/// is no keychain fallback to attempt — one read, judged by the same reader
/// as the local file.
enum CodexRemoteCredentials {
    /// Reads the remote session, expired or not — judging expiry is the
    /// caller's job, exactly as with the local file.
    static func load(from host: RemoteHost, run: RemoteSSH.Runner = RemoteSSH.run) throws -> CodexCredentials.Credential {
        do {
            let file = try run(host, "cat ~/.codex/auth.json")
            var hasAPIKey = false
            if file.exitCode == 0, !file.stdout.isEmpty {
                do {
                    return try CodexCredentials.load(from: file.stdout)
                } catch UsageProviderError.needsAuth {
                    // A file with no ChatGPT session in it — an API key, say —
                    // is the proxy setups' other shape. Fall through and look.
                    let fields = try? JSONSerialization.jsonObject(with: file.stdout) as? [String: Any]
                    let key = (fields?["OPENAI_API_KEY"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    hasAPIKey = key?.isEmpty == false
                }
            } else if RemoteSSH.isTransportFailure(file) {
                throw RemoteSSH.transportError(destination: host.destination, result: file)
            }
            // No login of its own can be deliberate: a Codex pointed at a proxy
            // (CLIProxyAPI and the like) signs in through that instead, and no
            // amount of `codex login` advice applies. Say so rather than ask.
            let config = try run(host, "cat ~/.codex/config.toml")
            if RemoteSSH.isTransportFailure(config) {
                throw RemoteSSH.transportError(destination: host.destination, result: config)
            }
            // A provider that takes the ChatGPT login counts only when an API
            // key is filed in its place — otherwise signing in is the fix.
            if config.exitCode == 0,
               let proxy = Proxy(configTOML: String(decoding: config.stdout, as: UTF8.self)),
               hasAPIKey || !proxy.requiresOpenAIAuth {
                Log.usage.notice("ssh \(host.destination, privacy: .public): codex goes through \(proxy.name, privacy: .public)")
                throw UsageProviderError.nothingMetered(
                    L10n.t("Codex on \(host.destination) signs in through \(proxy.name) at \(proxy.baseURL), not with a login of its own, so there is no account here to read limits from.")
                )
            }
            Log.usage.error("ssh \(host.destination, privacy: .public): no codex auth.json")
            throw UsageProviderError.needsAuth
        } catch is RemoteSSH.TimeoutError {
            throw UsageProviderError.apiError(L10n.t("ssh to \(host.destination) timed out"))
        }
    }

    /// The model provider a Codex config routes through, when it is not
    /// OpenAI's own login. Read from `config.toml` by line, not by a TOML
    /// parser: only `model_provider` and that provider's own table matter.
    /// Shapes it does not follow (inline or dotted-key tables, say) read as
    /// no proxy, which only leaves the old sign-in advice standing.
    struct Proxy: Equatable {
        let name: String
        let baseURL: String
        /// Whether the provider is handed the ChatGPT login (or the API key
        /// filed beside it) to pass on.
        let requiresOpenAIAuth: Bool

        init?(configTOML: String) {
            var top: [String: String] = [:]
            var section: String?
            var tables: [String: [String: String]] = [:]
            // Inside a multiline string, lines are text, not settings — an
            // instructions block may well quote a config example.
            var multiline: String?
            for raw in configTOML.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if let open = multiline {
                    if line.contains(open) { multiline = nil }
                    continue
                }
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.hasPrefix("[") {
                    // The name inside the brackets; a trailing comment is not part of it.
                    let name = line.prefix { $0 != "]" }
                    // `[model_providers."x"]` names the same table as `[model_providers.x]`.
                    section = name.trimmingCharacters(in: CharacterSet(charactersIn: "[ "))
                        .split(separator: ".", maxSplits: 1)
                        .map { Self.unquoted(String($0)) }
                        .joined(separator: ".")
                    continue
                }
                guard let equals = line.firstIndex(of: "=") else { continue }
                let key = Self.unquoted(String(line[..<equals]))  // `"requires_openai_auth" = true` is TOML too
                let rest = line[line.index(after: equals)...]
                for delimiter in ["\"\"\"", "'''"] where rest.components(separatedBy: delimiter).count == 2 {
                    multiline = delimiter
                }
                let value = Self.unquoted(String(rest))
                if let section {
                    tables[section, default: [:]][key] = value
                } else {
                    top[key] = value
                }
            }
            // A selected profile picks its own provider ahead of the top level.
            let profile = top["profile"].flatMap { tables["profiles." + $0] }
            let selected = profile?["model_provider"] ?? top["model_provider"]
            // `openai` is the login this ring reads. Any other provider with
            // an address is somewhere else answering.
            guard let selected, selected != "openai",
                  let table = tables["model_providers." + selected],
                  let baseURL = table["base_url"], !baseURL.isEmpty
            else { return nil }
            self.name = table["name"].flatMap { $0.isEmpty ? nil : $0 } ?? selected
            self.baseURL = Self.displayed(baseURL)
            self.requiresOpenAIAuth = table["requires_openai_auth"] == "true"
        }

        /// Scheme, host and port only. The message is logged and shown, and a
        /// `base_url` may carry a user, a password or a key in its query.
        private static func displayed(_ url: String) -> String {
            guard let parts = URLComponents(string: url), let host = parts.host else {
                return L10n.t("a proxy")
            }
            var shown = URLComponents()
            shown.scheme = parts.scheme
            shown.host = host
            shown.port = parts.port
            return shown.string ?? host
        }

        /// A value without its quotes or a trailing comment.
        private static func unquoted(_ value: String) -> String {
            var text = value.trimmingCharacters(in: .whitespaces)
            if let quote = text.first, quote == "\"" || quote == "'" {
                let body = text.dropFirst()
                if let end = body.firstIndex(of: quote) { return String(body[..<end]) }
                return String(body)
            }
            if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
            return text.trimmingCharacters(in: .whitespaces)
        }
    }
}
