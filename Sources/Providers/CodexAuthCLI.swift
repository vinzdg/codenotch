import Foundation

/// Integrates with the official `codex-auth` CLI binary (`@loongphy/codex-auth`).
struct CodexAuthCLI: Sendable {
    static let timeout: TimeInterval = 10

    private static let systemPaths = [
        "/opt/homebrew/bin/codex-auth",
        "/usr/local/bin/codex-auth"
    ]

    static func locateBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment["CODEX_AUTH_CLI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            if isRunnable(expanded, fileManager: fileManager) {
                return URL(fileURLWithPath: expanded)
            }
            return nil
        }

        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? fileManager.homeDirectoryForCurrentUser

        let candidates = [
            home.appendingPathComponent(".local/bin/codex-auth"),
            home.appendingPathComponent(".npm-global/bin/codex-auth"),
            home.appendingPathComponent(".bun/bin/codex-auth"),
            home.appendingPathComponent(".cargo/bin/codex-auth")
        ] + systemPaths.map { URL(fileURLWithPath: $0) }

        if let found = candidates.first(where: { isRunnable($0.path, fileManager: fileManager) }) {
            return found
        }

        return searchPATH(environment: environment, fileManager: fileManager)
    }

    static func isInstalled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        locateBinary(environment: environment, fileManager: fileManager) != nil
            || TerminalCommand.isInstalled(command: "codex-auth")
    }

    private static func isRunnable(_ path: String, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir)
            && !isDir.boolValue
            && fileManager.isExecutableFile(atPath: path)
    }

    private static func searchPATH(
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        guard let path = environment["PATH"] else { return nil }
        for dir in path.split(separator: ":").map(String.init) {
            guard dir.hasPrefix("/") else { continue }
            let candidate = (dir as NSString).appendingPathComponent("codex-auth")
            if isRunnable(candidate, fileManager: fileManager) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    static func run(
        binary: URL,
        arguments: [String],
        timeout: TimeInterval = timeout
    ) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        process.environment = env
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice

        let output = Pipe()
        process.standardOutput = output
        let errors = Pipe()
        process.standardError = errors

        let stdout = output.fileHandleForReading
        let stderr = errors.fileHandleForReading
        let collected = Slot(Data())

        stdout.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                stdout.readabilityHandler = nil
            } else {
                collected.append(chunk)
            }
        }
        stderr.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                stderr.readabilityHandler = nil
            }
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            stdout.readabilityHandler = nil
            stderr.readabilityHandler = nil
            exited.signal()
        }

        try process.run()
        let pid = process.processIdentifier
        let grouped = setpgid(pid, pid) == 0

        if exited.wait(timeout: .now() + timeout) != .success {
            if grouped { _ = killpg(pid, SIGKILL) }
            _ = kill(pid, SIGKILL)
            if process.isRunning { process.terminate() }
            stdout.readabilityHandler = nil
            stderr.readabilityHandler = nil
            try? stdout.close()
            throw UsageProviderError.timedOut
        }

        let status = process.terminationStatus
        guard status == 0 else {
            let outString = String(data: collected.value, encoding: .utf8) ?? ""
            if outString.localizedCaseInsensitiveContains("not_found") ||
               outString.localizedCaseInsensitiveContains("login") ||
               outString.localizedCaseInsensitiveContains("needsauth") {
                throw UsageProviderError.needsAuth
            }
            throw UsageProviderError.apiError(L10n.t("codex-auth exited with status \(status)"))
        }

        guard let text = String(data: collected.value, encoding: .utf8), !text.isEmpty else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return text
    }

    /// Queries the account list via `codex-auth list [--skip-api] --json`.
    static func listAccounts(
        binary: URL? = locateBinary(),
        skipAPI: Bool = true,
        timeout: TimeInterval = timeout
    ) throws -> [CodexAuthAccount] {
        guard let binary else { throw UsageProviderError.nothingMetered(L10n.t("codex-auth is not installed")) }
        var args = ["list", "--json"]
        if skipAPI {
            args.insert("--skip-api", at: 1)
        }
        let output = try run(binary: binary, arguments: args, timeout: timeout)
        guard let data = output.data(using: .utf8) else { throw UsageProviderError.badResponse(status: 0) }
        let registry = try JSONDecoder().decode(CodexAuthRegistry.self, from: data)
        return registry.accounts
    }

    /// Switches the active account via `codex-auth switch <query> --json`.
    @discardableResult
    static func switchAccount(
        query: String,
        binary: URL? = locateBinary(),
        timeout: TimeInterval = timeout
    ) throws -> CodexAuthAccount? {
        guard let binary else { throw UsageProviderError.nothingMetered(L10n.t("codex-auth is not installed")) }
        let output = try run(binary: binary, arguments: ["switch", query, "--json"], timeout: timeout)
        guard let data = output.data(using: .utf8) else { return nil }

        struct SwitchResponse: Decodable {
            let schemaVersion: Int?
            let command: String?
            let switchedTo: CodexAuthAccount?

            enum CodingKeys: String, CodingKey {
                case schemaVersion = "schema_version"
                case command
                case switchedTo = "switched_to"
            }
        }

        if let response = try? JSONDecoder().decode(SwitchResponse.self, from: data) {
            return response.switchedTo
        }
        return nil
    }

    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data

        init(_ initial: Data) { self.stored = initial }

        func append(_ chunk: Data) {
            lock.lock()
            stored.append(chunk)
            lock.unlock()
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
