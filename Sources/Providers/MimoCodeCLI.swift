import Foundation

/// Integrates with the official MiMo Code (`@mimo-ai/cli` / `mimo` / `mimo-code`) binary.
struct MimoCodeCLI: Sendable {
    static let timeout: TimeInterval = 10

    private static let systemPaths = [
        "/opt/homebrew/bin/mimo",
        "/opt/homebrew/bin/mimo-code",
        "/usr/local/bin/mimo",
        "/usr/local/bin/mimo-code"
    ]

    static func locateBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        for envKey in ["MIMO_CLI_PATH", "MIMOCODE_CLI_PATH"] {
            if let override = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                let expanded = (override as NSString).expandingTildeInPath
                if isRunnable(expanded, fileManager: fileManager) {
                    return URL(fileURLWithPath: expanded)
                }
            }
        }

        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? fileManager.homeDirectoryForCurrentUser

        let candidates = [
            home.appendingPathComponent(".local/bin/mimo"),
            home.appendingPathComponent(".local/bin/mimo-code"),
            home.appendingPathComponent(".nvm/current/bin/mimo"),
            home.appendingPathComponent(".nvm/current/bin/mimo-code")
        ] + systemPaths.map { URL(fileURLWithPath: $0) }

        if let found = candidates.first(where: { isRunnable($0.path, fileManager: fileManager) }) {
            return found
        }

        return searchPATH(environment: environment, fileManager: fileManager)
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
        let binaryNames = ["mimo", "mimo-code"]
        for dir in path.split(separator: ":").map(String.init) {
            guard dir.hasPrefix("/") else { continue }
            for name in binaryNames {
                let candidate = (dir as NSString).appendingPathComponent(name)
                if isRunnable(candidate, fileManager: fileManager) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }

    static func run(
        binary: URL,
        arguments: [String] = ["balance", "--json"],
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
            exited.signal()
        }

        do {
            try process.run()
        } catch {
            throw UsageProviderError.apiError(L10n.t("Failed to run MimoCode CLI: \(error.localizedDescription)"))
        }

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil

        if timedOut {
            process.terminate()
            throw UsageProviderError.timedOut
        }

        let status = process.terminationStatus
        guard status == 0 else {
            throw UsageProviderError.apiError(L10n.t("MimoCode CLI exited with status \(status)"))
        }

        let data = collected.read()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw UsageProviderError.badResponse(status: Int(status))
        }

        return text
    }

    private final class Slot: @unchecked Sendable {
        private var data: Data
        private let lock = NSLock()

        init(_ data: Data) { self.data = data }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
        }

        func read() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
}
