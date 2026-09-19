import Foundation

/// A plugin exited non-zero without a protocol meaning. Carries the stderr
/// tail so the tooltip can say what actually happened.
enum PluginExecError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let why): return why
        }
    }
}

/// A `UsageProvider` backed by an external executable registered through a
/// `PluginManifest` (`docs/design/plugin-protocol.md`). Codenotch owns the
/// polling and the rendering; the plugin owns its credentials and its numbers,
/// and the only thing crossing the boundary is JSON on stdout.
///
/// An actor, like every cloud provider here: a wedged plugin must never stall
/// the UI, and the store's refresh deadline assumes fetches happen off the
/// main thread.
actor ExternalPluginProvider: UsageProvider {
    /// What one invocation of the plugin came back with.
    struct ExecResult: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    /// Protocol exit codes, per `docs/design/plugin-protocol.md`.
    enum Exit {
        static let ok: Int32 = 0
        static let needsAuth: Int32 = 3
        static let rateLimited: Int32 = 4
        static let nothingMetered: Int32 = 5
    }

    /// Nothing a plugin needs beyond basic identity and a system PATH — no
    /// tokens, no editor integration, nothing inherited from Codenotch.
    static var childEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
        ]
    }

    /// A manifest may ask for longer, but nothing a plugin does justifies more
    /// than half a minute of a refresh slot.
    static let timeoutCeiling: TimeInterval = 30
    /// How long SIGTERM gets to work before SIGKILL ends the child regardless.
    static let sigkillGrace: TimeInterval = 2
    /// A snapshot JSON is kilobytes; a plugin streaming forever must not grow
    /// memory without bound.
    static let stdoutCap = 1_048_576
    /// The tail is all the tooltip ever shows, so there is nothing to gain
    /// beyond this.
    static let stderrCap = 65_536

    static func effectiveTimeout(for manifest: PluginManifest) -> TimeInterval {
        min(manifest.exec.timeout, timeoutCeiling)
    }

    let manifest: PluginManifest
    /// How the process is run. Injected for the same reason
    /// `ClaudeUsageCLI.output` is: a test that spawned real executables would
    /// be slow and machine-dependent, and the part worth testing — what the
    /// output means — is downstream of the spawn.
    let run: @Sendable (PluginManifest) async throws -> ExecResult

    /// The last account the plugin reported, shared with `account()` below.
    /// `account()` is a synchronous, non-async protocol requirement called on
    /// the main actor, so it cannot hop into the actor — the box is the lock
    /// the keychain-backed providers get from `CredentialCache`.
    private final class AccountBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ProviderAccount?
        var value: ProviderAccount? { lock.withLock { stored } }
        func set(_ account: ProviderAccount?) { lock.withLock { stored = account } }
    }
    private let accountBox = AccountBox()

    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated var glyph: ProviderGlyph { .external }

    init(manifest: PluginManifest,
         run: (@Sendable (PluginManifest) async throws -> ExecResult)? = nil) {
        self.manifest = manifest
        self.run = run ?? { try await Self.spawn(manifest: $0) }
        self.id = manifest.id
        self.displayName = manifest.displayName
    }

    // MARK: - UsageProvider

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let result = try await run(manifest)
        switch result.status {
        case Exit.ok:
            break
        case Exit.needsAuth:
            throw UsageProviderError.needsAuth
        case Exit.rateLimited:
            throw UsageProviderError.rateLimited(retryAfter: Self.retryAfter(in: result.stdout) ?? 60)
        case Exit.nothingMetered:
            throw UsageProviderError.nothingMetered(Self.stderrTail(result.stderr) ?? "nothing metered")
        default:
            // Not `badResponse`: that renders as "HTTP <code>", and a process
            // exit code is not an HTTP status.
            throw PluginExecError.failed(
                Self.stderrTail(result.stderr) ?? "plugin exited \(result.status)")
        }
        guard let payload = try? PluginSnapshotPayload.decoder().decode(
            PluginSnapshotPayload.self, from: result.stdout
        ) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        accountBox.set(payload.providerAccount())
        return payload.snapshot(for: manifest)
    }

    nonisolated func account() -> ProviderAccount? {
        accountBox.value
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(manifest.signIn?.guidance
                  ?? L10n.t("Sign in with the tool that provides \(displayName)."))
    }

    /// Nothing of ours to discard: the session belongs to the plugin's vendor,
    /// exactly like a borrowed CLI credential.
    func signOut() async {}

    /// Kick off the plugin's own sign-in, if it declared one. Detached: the
    /// command may open a browser and outlive this call by minutes.
    nonisolated func presentSignIn() {
        guard let command = manifest.signIn?.run, let executable = command.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.environment = Self.childEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Codenotch holds no credential of the plugin's in memory, so there is
    /// nothing to drop; the next poll spawns a fresh process anyway.
    nonisolated func forgetCachedCredential() {}

    // MARK: - Running the plugin

    /// The default runner: spawn with an allowlisted environment, capture both
    /// pipes up to a cap, kill on timeout — SIGTERM first, SIGKILL if the
    /// child shrugs it off.
    ///
    /// stdin is `/dev/null` — a plugin must never block on interaction (see
    /// the protocol). stderr is captured, not discarded: exit-code mapping
    /// uses its tail as the error message. Both pipes are drained on their own
    /// threads because a pipe nobody reads fills at 64 KB and stalls the child.
    static func spawn(manifest: PluginManifest) async throws -> ExecResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try spawnSync(manifest: manifest) })
            }
        }
    }

    private static func spawnSync(manifest: PluginManifest) throws -> ExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: manifest.exec.path)
        process.arguments = manifest.exec.args
        process.environment = childEnvironment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let terminator = DispatchWorkItem { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let watchdog = DispatchWorkItem { [process, terminator] in
            if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + sigkillGrace, execute: terminator)
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + effectiveTimeout(for: manifest), execute: watchdog)
        defer { watchdog.cancel(); terminator.cancel() }

        // Both pipes are drained on their own threads because a pipe nobody reads
        // fills at 64 KB and stalls the child. The drain is capped: a plugin
        // streaming forever is killed rather than allowed to grow memory without
        // bound.
        var stdoutData = Data()
        var stderrData = Data()
        var stdoutOverflow = false
        var stderrOverflow = false
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            (stdoutData, stdoutOverflow) = drain(stdout.fileHandleForReading,
                                                 cap: stdoutCap, process: process)
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            (stderrData, stderrOverflow) = drain(stderr.fileHandleForReading,
                                                 cap: stderrCap, process: process)
            drained.leave()
        }

        process.waitUntilExit()

        // A killed plugin can leave children that inherited the pipes, and
        // their EOF would outlive the kill, so the drains get only the
        // SIGKILL grace to finish. Whatever a plugin like that managed to
        // say is unusable anyway.
        if drained.wait(timeout: .now() + sigkillGrace) != .success {
            throw UsageProviderError.timedOut
        }

        if stdoutOverflow {
            throw UsageProviderError.badResponse(status: 0)
        }
        if stderrOverflow {
            throw PluginExecError.failed("stderr exceeded \(stderrCap) bytes")
        }
        if process.terminationReason == .uncaughtSignal {
            throw UsageProviderError.timedOut
        }
        return ExecResult(status: process.terminationStatus, stdout: stdoutData, stderr: stderrData)
    }

    /// Read to EOF or to `cap`, whichever comes first. On overflow the child is
    /// SIGKILLed and the rest of its output discarded — the pipe still has to be
    /// drained to EOF so the dead child's file descriptors close cleanly.
    private static func drain(_ handle: FileHandle, cap: Int,
                              process: Process) -> (Data, Bool) {
        var data = Data()
        var overflow = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if overflow { continue }
            if data.count + chunk.count > cap {
                data.append(chunk.prefix(cap - data.count))
                overflow = true
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            } else {
                data.append(chunk)
            }
        }
        return (data, overflow)
    }

    /// A rate-limited plugin may say when to come back:
    /// `{"retryAfterSeconds": N}` on stdout.
    private static func retryAfter(in stdout: Data) -> TimeInterval? {
        struct Hint: Decodable { let retryAfterSeconds: TimeInterval }
        return try? JSONDecoder().decode(Hint.self, from: stdout).retryAfterSeconds
    }

    /// The last line of stderr, trimmed — enough to say *what* failed without
    /// pouring a stack trace into a tooltip.
    private static func stderrTail(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .last
            .map({ $0.trimmingCharacters(in: .whitespaces) }),
            !text.isEmpty else { return nil }
        return String(text.prefix(200))
    }
}
