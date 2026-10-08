import Foundation

/// The oMLX API key, borrowed from oMLX's own settings file.
///
/// Unlike LM Studio, oMLX keeps its key in plain JSON (`~/.omlx/settings.json`,
/// mode 0600, `auth.api_key`), so there is something on disk to borrow and
/// nothing for the user to paste. `OMLX_API_KEY` wins so a key exported for
/// scripts is honoured. The file is read on every call, with no cache and no
/// keychain copy: the key can be rotated in oMLX's dashboard at any moment, and
/// a stale copy would lock the admin session out until relaunch. When oMLX is
/// told to skip key verification no header is sent at all, so nothing is
/// returned. The value is never logged.
enum OMLXCredentials {
    static let environmentKey = "OMLX_API_KEY"

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String? {
        if let env = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        guard let auth = OMLXSettings.read(home: home)?["auth"] as? [String: Any] else { return nil }
        if auth["skip_api_key_verification"] as? Bool == true { return nil }
        guard let key = (auth["api_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }
}

/// Where the oMLX server is listening and where it writes its log.
enum OMLXEndpoint {
    static let defaultAddress = "http://127.0.0.1:8000"

    /// The same loopback-only rules as the Ollama address: plain HTTP to this
    /// Mac, no credentials in the URL, no path. The borrowed key must never be
    /// sent to another machine because of a typo.
    static func parse(_ address: String) throws -> URL {
        do {
            return try OllamaEndpoint.parse(address)
        } catch {
            throw OMLXError.invalidEndpoint
        }
    }

    /// The port oMLX itself is configured to serve on, so a server moved off
    /// 8000 is found without anyone retyping it here. Only a loopback or
    /// all-interfaces bind is reachable on 127.0.0.1; a server bound to one LAN
    /// address is not, and guessing it would mean sending the key off this Mac.
    static func configuredAddress(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String? {
        guard let server = OMLXSettings.read(home: home)?["server"] as? [String: Any],
              let host = server["host"] as? String, ["127.0.0.1", "localhost", "0.0.0.0"].contains(host),
              let port = server["port"] as? Int, (1...65535).contains(port)
        else { return nil }
        return "http://127.0.0.1:\(port)"
    }

    /// `~/.omlx/logs` unless `logging.log_dir` moves it, which oMLX allows.
    static func serverLogsDirectory(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        if let logging = OMLXSettings.read(home: home)?["logging"] as? [String: Any],
           let dir = (logging["log_dir"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".omlx/logs")
    }
}

/// oMLX's settings file, parsed loosely: every field this app reads is
/// optional, and a file from a newer oMLX with extra keys must still be read.
private enum OMLXSettings {
    static func read(home: URL) -> [String: Any]? {
        let file = home.appendingPathComponent(".omlx/settings.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum OMLXError: LocalizedError, Equatable {
    case invalidEndpoint
    case unavailable
    case invalidResponse
    /// oMLX refused the key, or there was none to send.
    case needsKey
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Use an HTTP address on this Mac, such as http://127.0.0.1:8000."
        case .unavailable:
            return "oMLX server unavailable. Start the server in oMLX and check the address."
        case .invalidResponse:
            return "This server did not return an oMLX model listing."
        case .needsKey:
            return "oMLX refused the request. The API key in ~/.omlx/settings.json could not be read or is not the main key."
        case .http(let code):
            return "oMLX returned HTTP \(code). Check the server address and configuration."
        }
    }
}
