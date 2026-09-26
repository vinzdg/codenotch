import Foundation

/// The save-time check behind a remote host: is the server reachable, what is
/// it, and does this account's token live there.
///
/// One SSH call runs a small script that reports the OS and the first token
/// source found. The keychain check redirects the password away — existence
/// is all the probe may learn; the token itself only travels when a poll
/// reads it.
enum RemoteProbe {
    enum OS: String, Equatable, Sendable {
        case linux
        case mac
        case other

        var displayName: String {
            switch self {
            case .linux: return "Linux"
            case .mac: return "macOS"
            case .other: return "Unix"
            }
        }

        static func parse(_ uname: String) -> OS {
            switch uname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "linux": return .linux
            case "darwin": return .mac
            default: return .other
            }
        }
    }

    struct Report: Equatable, Sendable {
        /// How the probe names the token source back, e.g.
        /// `~/.claude/.credentials.json`.
        let found: String
        let os: OS
    }

    /// A failed probe, worded for the person saving the host: what was tried,
    /// what answered, and what to do about it.
    struct Failure: Error, Equatable {
        let message: String
    }

    /// The script, one SSH call. Markers rather than positions: a chatty
    /// `.bashrc` may print login noise above, and the parse must not care.
    /// Ends `true` so the remote side always exits 0 — anything else is the
    /// transport talking.
    static func script(for kind: RemoteHostKind) -> String {
        var lines = ["echo PROBE_OS=$(uname -s)"]
        for check in kind.credentialChecks {
            switch check {
            case .file(let path):
                lines.append("test -f \(path) && echo PROBE_FOUND=\(path)")
            case .macKeychain(let service):
                // The password is redirected away: existence is all the
                // probe may learn.
                lines.append("[ \"$(uname -s)\" = Darwin ] && security find-generic-password -s '\(service)' -w >/dev/null 2>&1 && echo PROBE_FOUND=keychain:\(service)")
            }
        }
        lines.append("true")
        return lines.joined(separator: "\n")
    }

    static func check(host: RemoteHost, run: RemoteSSH.Runner = RemoteSSH.run) throws -> Report {
        let result: RemoteSSH.CommandResult
        do {
            result = try run(host, script(for: host.kind))
        } catch is RemoteSSH.TimeoutError {
            throw Failure(message: L10n.t("SSH to \(host.destination) timed out after \(Int(RemoteSSH.timeout))s — the server may be down, the port wrong, or a firewall in the way."))
        }
        if RemoteSSH.isTransportFailure(result) {
            throw Failure(message: transportMessage(host: host, stderr: result.stderr))
        }
        guard result.exitCode == 0 else {
            let line = RemoteSSH.firstLine(of: result.stderr)
            throw Failure(message: L10n.t("The probe failed on the server: \(line)"))
        }
        let lines = String(data: result.stdout, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
        guard let osLine = lines.first(where: { $0.hasPrefix("PROBE_OS=") }) else {
            throw Failure(message: L10n.t("Connected, but the probe came back unreadable — the remote shell may print login noise that broke the parse. Run `ssh \(host.destination) true` in Terminal to see what it says."))
        }
        let os = OS.parse(String(osLine.dropFirst("PROBE_OS=".count)))
        if let found = lines.first(where: { $0.hasPrefix("PROBE_FOUND=") }) {
            return Report(found: String(found.dropFirst("PROBE_FOUND=".count)), os: os)
        }
        let checked = host.kind.credentialChecks.map(\.displayPath).joined(separator: ", ")
        throw Failure(message: L10n.t("Connected to \(host.destination) (\(os.displayName)) but found no \(host.kind.displayName) token. Looked in: \(checked). Sign in on the server first — `ssh \(host.destination)`, then run `\(host.kind.signInCommand)`."))
    }

    /// ssh's one line, translated into what to do. Each cause has exactly one
    /// first thing to try, and that is what the message names.
    private static func transportMessage(host: RemoteHost, stderr: String) -> String {
        let line = RemoteSSH.firstLine(of: stderr)
        if line.contains("Could not resolve hostname") {
            return L10n.t("Couldn't resolve '\(host.host)'. Check the hostname for typos.")
        }
        if line.contains("Permission denied") {
            return L10n.t("SSH rejected the login at \(host.destination). Key auth must work without a password: run `ssh \(host.destination) true` in Terminal — if it asks for a password, add your key with `ssh-copy-id \(host.destination)` or point Identity file at it.")
        }
        if line.contains("Connection timed out") || line.contains("Operation timed out") {
            return L10n.t("No answer from \(host.host):\(host.port). The server may be down, the port wrong, or a firewall in the way.")
        }
        if line.contains("Connection refused") {
            return L10n.t("Nothing is listening on \(host.host):\(host.port) — sshd may be down or the port wrong.")
        }
        if line.contains("Host key verification failed") {
            return L10n.t("SSH refused the host key for \(host.host). If the server was reinstalled, drop the stale key with `ssh-keygen -R \(host.host)` and retry.")
        }
        return L10n.t("SSH to \(host.destination) failed: \(line)")
    }
}
