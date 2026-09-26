import Foundation

/// One SSH command to another machine, for the remote providers and the
/// save-time probe. No shell anywhere on this side: every user-configured
/// value travels as its own argument, and the remote command is an assembled
/// constant, never interpolated input.
enum RemoteSSH {
    /// Long enough for an SSH handshake plus a file read on a slow link, short
    /// enough that a hung connection cannot hold a refresh open. A timeout
    /// kills the process.
    static let timeout: TimeInterval = 20

    struct CommandResult: Equatable, Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: String
    }

    /// Thrown when the connection outlives `timeout`. Carries the destination
    /// so each caller can word it its own way — a poll error, a probe report.
    struct TimeoutError: Error {
        let destination: String
    }

    /// Runs one remote command. Injected so tests never spawn ssh: the part
    /// worth testing — what the bytes mean — is downstream of this.
    typealias Runner = @Sendable (RemoteHost, String) throws -> CommandResult

    /// The argv for one poll.
    ///
    /// `BatchMode` is what makes a timer-driven poll safe to run at all: with
    /// it a password or passphrase prompt fails instead of hanging, so key
    /// auth that is not set up reads as unreachable rather than wedging the
    /// refresh until the watchdog. `accept-new` pins an unknown host key on
    /// first sight rather than asking — there is nobody to ask.
    static func arguments(for host: RemoteHost, command: String) -> [String] {
        var args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", "\(host.port)",
        ]
        let identity = (host.identityFile ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !identity.isEmpty {
            args += ["-i", identity]
        }
        return args + ["--", host.destination, command]
    }

    static func run(host: RemoteHost, command: String) throws -> CommandResult {
        try run(host: host, command: command, timeout: timeout)
    }

    /// The same run with its own watchdog. The renewal command needs longer
    /// than a file read: an SSH handshake plus Claude's own start-up.
    static func run(host: RemoteHost, command: String, timeout: TimeInterval) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments(for: host, command: command)
        // Never a terminal: with BatchMode nothing prompts, and whatever the
        // far side does with stdin is its own business.
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        // Set inside the watchdog, read after the process is gone. Locked:
        // the only writer runs on another queue.
        let timedOut = LockedFlag()
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        // Both pipes are small — a token file and ssh diagnostics — so
        // sequential reads cannot stall the way a chatty CLI's could.
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if timedOut.value {
            throw TimeoutError(destination: host.destination)
        }
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Whether the command never reached the far side. ssh exits 255 on its
    /// own failures; anything else with stderr is the remote shell reporting
    /// back, which means the transport worked.
    static func isTransportFailure(_ result: CommandResult) -> Bool {
        result.exitCode == 255
            || result.stderr.contains("Connection timed out")
            || result.stderr.contains("Could not resolve hostname")
            || result.stderr.contains("Permission denied")
            || result.stderr.contains("Connection refused")
            || result.stderr.contains("Host key verification failed")
            || result.stderr.contains("Operation timed out")
    }

    /// The first stderr line — the whole diagnosis ssh gives. Truncated, and
    /// never the token, which only ever leaves stdout.
    static func firstLine(of stderr: String) -> String {
        stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            ?? "ssh failed"
    }

    /// A transport failure for a poll keeps the last reading: it says nothing
    /// about the account, only about the road to it.
    static func transportError(destination: String, result: CommandResult) -> Error {
        let line = firstLine(of: result.stderr)
        Log.usage.error("ssh \(destination, privacy: .public) failed: \(line.prefix(160), privacy: .public)")
        return UsageProviderError.apiError("ssh: \(line.prefix(160))")
    }
}

/// One bit across two queues, for the watchdog above.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
