import Foundation

/// A plugin exited non-zero without a protocol meaning. Carries the stderr
/// tail so the tooltip can say what actually happened.
enum PluginExecError: LocalizedError, Equatable {
    case failed(String)
    /// The plugin directory no longer matches the approved build. Not run.
    case changedSinceApproval

    var errorDescription: String? {
        switch self {
        case .failed(let why): return why
        case .changedSinceApproval: return L10n.t("Plugin changed since it was approved")
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
    /// The plugin's folder, the working directory of everything it spawns —
    /// the poll and the sign-in alike, so a relative script name means the
    /// same hashed file in both. Nil only for injected test runners.
    nonisolated let directory: URL?
    /// How the process is run. Injected for the same reason
    /// `ClaudeUsageCLI.output` is: a test that spawned real executables would
    /// be slow and machine-dependent, and the part worth testing — what the
    /// output means — is downstream of the spawn.
    let run: @Sendable (PluginManifest) async throws -> ExecResult
    /// Whether the plugin on disk is still the build the user approved.
    /// Asked before every run and every sign-in; a "no" refuses to spawn and
    /// reports through `onTamper`, so the registry can re-pend it.
    let verify: @Sendable () -> Bool
    let onTamper: @Sendable () -> Void

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
    nonisolated var isPlugin: Bool { true }

    /// The real thing: spawns the manifest's executable inside its plugin
    /// directory, after `verify` has vouched for the directory.
    init(plugin: PluginRegistry.RegisteredPlugin,
         verify: @escaping @Sendable () -> Bool,
         onTamper: @escaping @Sendable () -> Void) {
        self.manifest = plugin.manifest
        self.directory = plugin.directory
        self.run = { try await Self.spawn(manifest: $0, directory: plugin.directory) }
        self.verify = verify
        self.onTamper = onTamper
        self.id = plugin.manifest.id
        self.displayName = plugin.manifest.displayName
    }

    /// Tests: an injected runner, and no directory on disk to verify unless
    /// the test says otherwise.
    init(manifest: PluginManifest,
         verify: @escaping @Sendable () -> Bool = { true },
         onTamper: @escaping @Sendable () -> Void = {},
         run: @escaping @Sendable (PluginManifest) async throws -> ExecResult) {
        self.manifest = manifest
        self.directory = nil
        self.run = run
        self.verify = verify
        self.onTamper = onTamper
        self.id = manifest.id
        self.displayName = manifest.displayName
    }

    // MARK: - UsageProvider

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard verify() else {
            onTamper()
            throw PluginExecError.changedSinceApproval
        }
        let result = try await run(manifest)
        switch result.status {
        case Exit.ok:
            break
        case Exit.needsAuth:
            throw UsageProviderError.needsAuth
        case Exit.rateLimited:
            throw UsageProviderError.rateLimited(
                retryAfter: PluginSnapshotPayload.retryAfter(in: result.stdout) ?? 60)
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
        guard verify() else {
            onTamper()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = directory
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
    static func spawn(manifest: PluginManifest, directory: URL? = nil) async throws -> ExecResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try spawnSync(manifest: manifest, directory: directory) })
            }
        }
    }

    private static func spawnSync(manifest: PluginManifest, directory: URL?) throws -> ExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: manifest.exec.path)
        process.arguments = manifest.exec.args
        // The plugin directory, so a relative `script.sh` in the arguments
        // means the one the hash covers.
        process.currentDirectoryURL = directory
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
