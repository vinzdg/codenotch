import Foundation

/// Kiro's own `/usage`, asked of the binary rather than of any credential
/// this app could hold.
///
/// The CLI owns the login. This only asks `/usage` of it, off a session the
/// CLI already holds, and needs no keychain access from this app at all. A
/// grant, a keychain item, a session file — none of that is ours to open. If
/// the CLI has no login, it will say so in its own words, and the caller maps
/// that to `needsAuth`.
struct KiroCLI: Sendable {
    /// Where the binary was found.
    let binary: URL
    /// How its output is obtained. Injected so a test never has to spawn the
    /// real CLI: that would need a login and a network to be deterministic,
    /// and the part worth testing — what the text means — is downstream of this.
    let output: @Sendable () throws -> String

    init(binary: URL, output: @escaping @Sendable () throws -> String) {
        self.binary = binary
        self.output = output
    }

    /// Long enough for a cold start on a busy machine, short enough that a
    /// wedged process cannot hold a refresh open. A timeout kills the process
    /// group: kiro-cli starts children, and terminating only the parent leaves
    /// them behind.
    static let timeout: TimeInterval = 20

    /// Non-interactive chat, one `/usage` prompt. `--no-interactive` is what
    /// stops it waiting on a TTY this app does not have.
    ///
    /// The engine is named because the V3 engine does not run `/usage` itself
    /// in a headless chat: it hands it to the model as a prompt, and every poll
    /// then spends credits until the timeout kills it (#520). A saved
    /// `chat.agentEngine v3`, which kiro-cli's own upgrade prompt writes, is
    /// enough to get there. `--agent-engine` outranks that setting for this one
    /// call without changing it, and is accepted on `chat` only, not before it.
    static let arguments = ["chat", "--agent-engine", "v2", "--no-interactive", "/usage"]

    // MARK: - Finding the binary

    private static let systemPaths = [
        "/opt/homebrew/bin/kiro-cli",
        "/usr/local/bin/kiro-cli",
        "/usr/bin/kiro-cli"
    ]

    /// Nil means kiro-cli is not installed in any of the places it installs
    /// itself, and the caller should treat Kiro as absent.
    ///
    /// Finder launches this app with a `PATH` of `/usr/bin:/bin:/usr/sbin:/sbin`,
    /// so the places kiro-cli actually lands are not on it. An explicit
    /// `KIRO_CLI_PATH` wins; then the well-known install locations; absolute
    /// `PATH` entries last, for a copy somewhere the installers do not use.
    /// `HOME` is read from `environment` so a test can point `~/.local/bin`
    /// at a temporary directory without this finding the machine's own copy.
    static func locateBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment["KIRO_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            if isRunnable(expanded, fileManager: fileManager) {
                return URL(fileURLWithPath: expanded)
            }
            // Set, but not a runnable file: the user named a path, and it is
            // not there. Falling through would silently pick a different
            // binary than the one they pointed at.
            return nil
        }

        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? fileManager.homeDirectoryForCurrentUser

        let candidates = [
            home.appendingPathComponent(".local/bin/kiro-cli"),
            home.appendingPathComponent(".cargo/bin/kiro-cli")
        ] + systemPaths.map { URL(fileURLWithPath: $0) }
        if let found = candidates.first(where: { isRunnable($0.path, fileManager: fileManager) }) {
            return found
        }

        return searchPATH(environment: environment, fileManager: fileManager)
    }

    /// Absolute directories only. Relative `PATH` entries (`.` , `bin`)
    /// would run whatever `kiro-cli` happens to sit in the app's cwd, and
    /// `/usr/bin/which` is a csh script that would inherit that `PATH`.
    private static func searchPATH(
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        guard let pathVar = environment["PATH"], !pathVar.isEmpty else { return nil }
        for raw in pathVar.split(separator: ":", omittingEmptySubsequences: true) {
            let directory = (String(raw) as NSString).expandingTildeInPath
            guard directory.hasPrefix("/") else { continue }
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("kiro-cli")
            if isRunnable(candidate.path, fileManager: fileManager) {
                return candidate
            }
        }
        return nil
    }

    /// `isExecutableFile` is true for directories. A relative path is
    /// resolved against cwd, which is how `PATH` injection lands.
    private static func isRunnable(_ path: String, fileManager: FileManager) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: path)
        else { return false }
        return true
    }

    // MARK: - Asking it

    /// Runs `/usage` and returns what it reported.
    static func run(binary: URL, timeout: TimeInterval = timeout) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        // 2.x defaults to a TUI. xterm-256color makes that TUI think it has
        // a capable terminal; launched from Terminal it then drives the
        // inherited /dev/tty and never returns. dumb plus redirected stdin
        // is what `--no-interactive` is for.
        environment["TERM"] = "dumb"
        environment["KIRO_CHAT_UI"] = "classic"

        let process = Process()
        process.executableURL = binary
        process.arguments = Self.arguments
        process.environment = environment
        // Not the project the app was launched from — chat keys MCP and
        // session files on cwd, and a huge tree is how this poll hangs.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        // Never a terminal. Left inheriting the app's stdin, the CLI waits
        // for input that will never come and the timeout is the only thing
        // that ends it.
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        // Kept, not discarded: kiro-cli 2.21 prints the whole /usage card to
        // stderr and leaves stdout empty (#220).
        let errors = Pipe()
        process.standardError = errors

        let stdout = output.fileHandleForReading
        let stderr = errors.fileHandleForReading
        let collected = Slot(Data())
        let collectedErrors = Slot(Data())
        // Both drained as they fill: a pipe left unread blocks the CLI once
        // its buffer is full, and the timeout would be the only way out.
        for (handle, slot) in [(stdout, collected), (stderr, collectedErrors)] {
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    slot.append(chunk)
                }
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
        // Own group so a timeout can take the children with the parent.
        // After exec this can lose the race; the pid is still killed below.
        let grouped = setpgid(pid, pid) == 0

        if exited.wait(timeout: .now() + timeout) != .success {
            if grouped { _ = killpg(pid, SIGKILL) }
            _ = kill(pid, SIGKILL)
            if process.isRunning { process.terminate() }
            stdout.readabilityHandler = nil
            stderr.readabilityHandler = nil
            // Children that inherited stdout keep the parent reaper blocked
            // after a lone kill. Closing the read end is what makes the
            // timeout actually return.
            try? stdout.close()
            try? stderr.close()
            _ = exited.wait(timeout: .now() + 1)
            Log.usage.debug("kiro-cli /usage timed out")
            throw UsageProviderError.timedOut
        }
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
        collected.append(drainNonBlocking(stdout))
        collectedErrors.append(drainNonBlocking(stderr))

        guard process.terminationStatus == 0 else {
            Log.usage.debug("kiro-cli /usage exited \(process.terminationStatus)")
            let said = (String(data: collected.value, encoding: .utf8) ?? "")
                + (String(data: collectedErrors.value, encoding: .utf8) ?? "")
            // A CLI that does not take the engine pin says so by name before
            // it runs anything. That is not a missing login, and asking again
            // without the pin is not safe: that is the call a V3 engine sends
            // to the model.
            if said.contains("--agent-engine") {
                throw UsageProviderError.apiError(
                    L10n.t("Kiro CLI rejected --agent-engine v2. Update kiro-cli to read usage.")
                )
            }
            // Otherwise a non-zero exit is the CLI declining to answer, which
            // in practice means it has no login of its own.
            throw UsageProviderError.needsAuth
        }
        guard let text = usageText(
            stdout: String(data: collected.value, encoding: .utf8) ?? "",
            stderr: String(data: collectedErrors.value, encoding: .utf8) ?? ""
        ) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return text
    }

    private static let cardMarkers = [
        "Estimated Usage",
        "covered in plan",
        "usage breakdown",
        "Bonus credits",
        "Overages:",
        "KIRO",
        "Kiro",
        "Plan:"
    ]

    private static func hasCardMarkers(in text: String) -> Bool {
        cardMarkers.contains { text.contains($0) }
    }

    /// Whichever stream carries the card. Older CLIs print it to stdout and
    /// newer ones to stderr; either may also hold stray warnings, so the one
    /// with the card's heading wins, and otherwise whatever was said at all.
    static func usageText(stdout: String, stderr: String) -> String? {
        let marker = "Estimated Usage"
        if stdout.contains(marker) && !stderr.contains(marker) { return stdout }
        if stderr.contains(marker) && !stdout.contains(marker) { return stderr }

        let stdoutCard = hasCardMarkers(in: stdout)
        let stderrCard = hasCardMarkers(in: stderr)
        if stdoutCard && !stderrCard { return stdout }
        if stderrCard && !stdoutCard { return stderr }

        let said = stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stderr : stdout
        return said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : said
    }

    /// Leftover bytes after the process has exited. `availableData` blocks
    /// when a child still holds the write end; a non-blocking read cannot.
    private static func drainNonBlocking(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return Data() }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            collected.append(contentsOf: buffer[0..<n])
        }
        return collected
    }

    /// Bytes from the readability handler, read after the process exits.
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
