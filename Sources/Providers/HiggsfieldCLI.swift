import Foundation

/// Integrates with the official `@higgsfield/cli` (`hf` / `higgsfield`) binary.
struct HiggsfieldCLI: Sendable {
    static let timeout: TimeInterval = 10

    private static let systemPaths = [
        "/opt/homebrew/bin/hf",
        "/usr/local/bin/hf",
        "/opt/homebrew/bin/higgsfield",
        "/usr/local/bin/higgsfield"
    ]

    static func locateBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment["HIGGSFIELD_CLI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
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
            home.appendingPathComponent(".local/bin/hf"),
            home.appendingPathComponent(".local/bin/higgsfield"),
            home.appendingPathComponent(".nvm/current/bin/hf"),
            home.appendingPathComponent(".nvm/current/bin/higgsfield")
        ] + systemPaths.map { URL(fileURLWithPath: $0) }

        if let found = candidates.first(where: { isHiggsfield($0, fileManager: fileManager) }) {
            return found
        }

        return searchPATH(environment: environment, fileManager: fileManager)
    }

    /// `hf` is also the name of Hugging Face's CLI, so a binary by that name
    /// counts only when it resolves into Higgsfield's own package. A
    /// `higgsfield` binary is unambiguous.
    static func isHiggsfield(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard isRunnable(url.path, fileManager: fileManager) else { return false }
        if url.lastPathComponent == "higgsfield" { return true }
        return url.resolvingSymlinksInPath().path.lowercased().contains("higgsfield")
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
            for name in ["hf", "higgsfield"] {
                let candidate = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name))
                if isHiggsfield(candidate, fileManager: fileManager) {
                    return candidate
                }
            }
        }
        return nil
    }

    static func run(binary: URL, timeout: TimeInterval = timeout) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["workspace", "list", "--json"]
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
            if outString.localizedCaseInsensitiveContains("login") ||
               outString.localizedCaseInsensitiveContains("auth") ||
               outString.localizedCaseInsensitiveContains("unauthorized") {
                throw UsageProviderError.needsAuth
            }
            throw UsageProviderError.apiError(L10n.t("Higgsfield CLI exited with status \(status)"))
        }

        guard let text = String(data: collected.value, encoding: .utf8), !text.isEmpty else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return text
    }

    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data

        init(_ value: Data) { stored = value }

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
