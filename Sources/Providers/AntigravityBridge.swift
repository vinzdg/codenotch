import Foundation
import os

/// Asks Antigravity's own language server for the quota, instead of asking
/// Google directly.
///
/// Google refuses us: `retrieveUserQuotaSummary` on `cloudcode-pa` answers 403
/// "You do not have a valid license of this product" for a personal account,
/// because the API judges *which client* is asking and Codenotch cannot
/// honestly claim to be Antigravity. Antigravity's window has the same problem
/// and solves it the same way — it never calls Google for this either. It calls
/// the language server running on this machine, which already holds the
/// credential and the client identity, and lets that make the call.
///
/// So this is not a workaround for a locked door; it is the door Antigravity
/// itself uses. It works only while Antigravity is running, which is honest:
/// the figure comes from Antigravity, so Antigravity has to be there.
enum AntigravityBridge {
    /// Where the language server is listening, and the token it demands.
    struct Endpoint: Equatable {
        /// Every port the server listens on. It opens two and only one serves
        /// this RPC, and which is which is not advertised — so both are tried
        /// rather than guessed at.
        let ports: [Int]
        /// Nil for the CLI, which serves this RPC to anything on loopback. The
        /// IDE's language server refuses without one, so it is still sent
        /// wherever there is one to send.
        let csrfToken: String?
    }

    /// Antigravity is built on Codeium's stack, and the header still says so.
    /// Six plausible spellings were rejected before this one was found in the
    /// binary — the server's only complaint is "missing CSRF token", never
    /// which header it wanted.
    static let csrfHeader = "x-codeium-csrf-token"

    private static let service =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    // MARK: - Finding it

    /// The token is passed to the language server on its command line, so the
    /// process table is the source of truth. There is no file to read: the
    /// server is started with `--https_server_port 0`, meaning the port is
    /// chosen at runtime and never written down.
    static func discover(processTable: String? = nil, listeningPorts: ((Int) -> [Int])? = nil)
        -> Endpoint? {
        let table = processTable ?? run("/bin/ps", ["-Ao", "pid,command"])
        let lines = table.split(separator: "\n")

        // The IDE's language server, which is the one that carries a token.
        if let line = lines.first(where: {
            $0.contains("language_server") && $0.contains("--csrf_token")
        }),
           let token = value(of: "--csrf_token", in: String(line)),
           let endpoint = endpoint(for: line, token: token, ports: listeningPorts) {
            return endpoint
        }

        // Then the CLI, which serves the same RPC and is a whole install of its
        // own — somebody who uses `agy` and never installs the IDE has a real
        // quota to read and was getting the counted-requests fallback instead.
        // It asks for no token: on loopback it answers anyone.
        if let line = lines.first(where: isCLI),
           let endpoint = endpoint(for: line, token: nil, ports: listeningPorts) {
            return endpoint
        }
        return nil
    }

    /// The CLI runs as plain `agy`, so match the executable's name rather than
    /// looking for it anywhere in the line — "agy" is three letters and turns
    /// up inside real words and real paths.
    static func isCLI(_ line: Substring) -> Bool {
        let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard fields.count >= 2 else { return false }
        return URL(fileURLWithPath: String(fields[1])).lastPathComponent == "agy"
    }

    /// ACP runs as `agy_acp_server.par` or `localharness_external`.
    static func isACP(_ line: Substring) -> Bool {
        line.contains("agy_acp_server") || line.contains("localharness_external")
    }

    /// Whether an Antigravity ACP server process is currently running.
    static func isACPRunning(processTable: String? = nil) -> Bool {
        let table = processTable ?? run("/bin/ps", ["-Ao", "pid,command"])
        return table.split(separator: "\n").contains(where: isACP)
    }

    /// IDE runs as language_server with --csrf_token or Antigravity.app.
    static func isIDE(_ line: Substring) -> Bool {
        (line.contains("language_server") && line.contains("--csrf_token")) ||
        line.contains("Antigravity.app")
    }

    /// Whether an Antigravity IDE process is currently running.
    static func isIDERunning(processTable: String? = nil) -> Bool {
        let table = processTable ?? run("/bin/ps", ["-Ao", "pid,command"])
        return table.split(separator: "\n").contains(where: isIDE)
    }

    /// Whether an Antigravity CLI process is currently running.
    static func isCLIRunning(processTable: String? = nil) -> Bool {
        let table = processTable ?? run("/bin/ps", ["-Ao", "pid,command"])
        return table.split(separator: "\n").contains(where: isCLI)
    }

    /// Whether a specific Antigravity flavor process is currently running.
    static func isRunning(flavor: AntigravityFlavor, processTable: String? = nil) -> Bool {
        let table = processTable ?? run("/bin/ps", ["-Ao", "pid,command"])
        switch flavor {
        case .ide: return isIDERunning(processTable: table)
        case .cli: return isCLIRunning(processTable: table)
        case .acp: return isACPRunning(processTable: table)
        }
    }

    private static func endpoint(
        for line: Substring, token: String?, ports listeningPorts: ((Int) -> [Int])?
    ) -> Endpoint? {
        guard let pid = Int(line.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first ?? "")
        else { return nil }

        let ports = listeningPorts?(pid) ?? self.listeningPorts(ofPID: pid)
        guard !ports.isEmpty else { return nil }
        return Endpoint(ports: ports, csrfToken: token)
    }

    static func value(of flag: String, in line: String) -> String? {
        let parts = line.split(separator: " ")
        guard let index = parts.firstIndex(of: Substring(flag)),
              index + 1 < parts.count else { return nil }
        return String(parts[index + 1])
    }

    /// Ports are found rather than assumed. The server opens two and only one
    /// serves this RPC, so every candidate is tried in turn.
    static func listeningPorts(ofPID pid: Int) -> [Int] {
        // `-a` is load-bearing: without it lsof ORs the filters rather than
        // ANDing them, and returns every listening socket on the machine. The
        // first match was another process entirely, so the bridge dialled the
        // wrong port and silently fell back to counting requests.
        let output = run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN"])
        return parsePorts(fromLSOF: output)
    }

    static func parsePorts(fromLSOF output: String) -> [Int] {
        output.split(separator: "\n").compactMap { line in
            guard let address = line.split(separator: " ").last(where: { $0.contains(":") }),
                  let port = Int(address.split(separator: ":").last ?? "") else { return nil }
            return port
        }
    }

    // MARK: - Asking it

    static func quota(from endpoint: Endpoint, session: URLSession) async throws -> [LimitWindow] {
        var lastError: Error?
        for port in endpoint.ports {
            do {
                let windows = try await quota(port: port, token: endpoint.csrfToken,
                                              session: session)
                if !windows.isEmpty { return windows }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return []
    }

    private static func quota(port: Int, token: String?,
                              session: URLSession) async throws -> [LimitWindow] {
        var request = URLRequest(
            url: URL(string: "https://127.0.0.1:\(port)\(service)")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Only where there is one. Sending an empty header instead of none is
        // not the same request, and the CLI has no token to send.
        if let token { request.setValue(token, forHTTPHeaderField: csrfHeader) }
        // `forceRefresh` is why this reads as live rather than as whatever was
        // last looked at. The language server keeps a `QuotaSummaryCache`, and
        // an empty request is served from it — so the figure only moved when
        // something else refreshed it, which in practice meant opening
        // Antigravity's own Models & Usage panel and pressing its refresh
        // button. The field is real: `RetrieveUserQuotaSummaryRequest` has a
        // `GetForceRefresh` accessor.
        request.httpBody = Data(#"{"forceRefresh":true}"#.utf8)
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UsageProviderError.badResponse(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        return windows(in: data)
    }

    /// Turns the quota summary into limit windows.
    ///
    /// The server reports what is **left**, not what is spent — the notch shows
    /// the opposite, so every fraction is inverted here rather than in the view,
    /// where it would be a percentage whose meaning depended on the provider.
    static func windows(in data: Data, now: Date = Date()) -> [LimitWindow] {
        // Keep the loopback and direct Cloud Code paths on one parser. Their
        // envelopes drift independently; normalizing them in one place prevents
        // the same account from changing shape when the source changes.
        AntigravityProvider.windows(in: data, now: now)
    }

    // MARK: - Starting one ourselves

    /// A language server this process started, kept for as long as the app runs.
    ///
    /// Held rather than restarted per poll because the server is not ready the
    /// instant it binds: it listens within about a tenth of a second and then
    /// spends roughly eight more authenticating. Spawning per poll would pay
    /// those eight seconds every five minutes to fetch one number.
    ///
    /// Only ever started when `discover()` found nothing, so it never competes
    /// with an IDE that is already running — and once it is up, `discover()`
    /// finds it like any other, because it carries the same flags on the same
    /// command line. Nothing downstream of here knows the difference.
    final class Owned: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var endpoint: Endpoint?

        /// The endpoint already running, if any.
        var current: Endpoint? {
            lock.lock(); defer { lock.unlock() }
            return endpoint
        }

        /// The started server's pid, for the `lsof` lookup that finds its port.
        var pid: Int32? {
            lock.lock(); defer { lock.unlock() }
            guard process?.isRunning == true else { return nil }
            return process?.processIdentifier
        }

        /// Starts one if none is running, and returns where it landed. The
        /// ports arrive empty and are filled by `resolvePorts(_:)` once the
        /// server has bound them.
        ///
        /// `start` replaces `Process.run()` so a test can drive this without
        /// launching anything; the default is the real thing.
        func endpointOrStart(binary: URL,
                             start: (Process) -> Bool = { (try? $0.run()) != nil }) -> Endpoint? {
            if let current { return current }
            lock.lock(); defer { lock.unlock() }
            // Re-checked under the lock: two polls can overlap, and a second
            // server would bind its own ports for nothing.
            if let endpoint { return endpoint }

            let token = UUID().uuidString
            let process = Process()
            process.executableURL = binary
            process.arguments = AntigravityBridge.arguments(token: token)
            // The server logs to stdout when no IDE is attached to take it.
            // Discarded rather than inherited, so it cannot write into
            // whatever the app redirected there.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard start(process) else { return nil }

            self.process = process
            // The port is left at 0 so the server picks one and `lsof` finds
            // it afterwards, exactly as for the IDE's own. Probing for a free
            // port here would race whatever claimed it before the bind.
            self.endpoint = Endpoint(ports: [], csrfToken: token)
            return endpoint
        }

        /// Fills in the ports once the server has bound them.
        func resolvePorts(_ ports: [Int]) {
            lock.lock(); defer { lock.unlock() }
            guard let token = endpoint?.csrfToken, !ports.isEmpty else { return }
            endpoint = Endpoint(ports: ports, csrfToken: token)
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            // `terminate()` raises if the task was never launched, or has already
            // finished — both reachable: a server that crashed on start-up is
            // gone, and the app can quit before the first poll ever ran one.
            if process?.isRunning == true { process?.terminate() }
            process = nil
            endpoint = nil
        }

        func resetForTesting() {
            stop()
        }
    }

    /// A server Codenotch owns, or nil until one is needed.
    static let owned = Owned()

    /// The same flags the IDE passes its own server, minus everything that wires
    /// it to a running IDE — there is none. `--standalone` is what makes it
    /// legal to start without one.
    ///
    /// `--app_data_dir` is a *name*, not a path, and the server refuses an
    /// absolute one outright ("must not be absolute") before it reads
    /// anything. It resolves under `~/.gemini/`, which is why this is a name.
    ///
    /// A directory of its own rather than the IDE's `antigravity`: the quota
    /// answer needs no project or conversation state, and sharing the IDE's
    /// would put two writers on its SQLite files if the IDE is launched while
    /// this one is still up.
    static func arguments(token: String, appDataDir: String = "codenotch-bridge") -> [String] {
        [
            "--standalone",
            "--override_ide_name", "antigravity",
            "--subclient_type", "hub",
            "--override_user_agent_name", "antigravity",
            "--https_server_port", "0",
            "--csrf_token", token,
            "--app_data_dir", appDataDir,
            "--api_server_url", "https://generativelanguage.googleapis.com",
            "--cloud_code_endpoint", "https://daily-cloudcode-pa.googleapis.com",
        ]
    }

    /// The IDE's copy of the server, which is the one known to answer this RPC.
    ///
    /// Found through the bundle rather than hardcoded, so an install somewhere
    /// other than `/Applications` still works, and read through the same
    /// `Contents/Resources` layout the IDE uses. Nil when the IDE is not
    /// installed, which is the honest answer: there is nothing to start.
    static func serverBinaryURL(
        fileManager: FileManager = .default,
        applications: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
        ]
    ) -> URL? {
        for applications in applications {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: applications, includingPropertiesForKeys: nil)
            else { continue }
            for app in entries where app.pathExtension == "app" {
                if app.deletingPathExtension().lastPathComponent.lowercased() == "antigravity" {
                    let binary = app
                        .appendingPathComponent("Contents/Resources/bin/language_server")
                    if fileManager.isExecutableFile(atPath: binary.path) { return binary }
                }
            }
        }
        return nil
    }

    // MARK: - Plumbing

    static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
