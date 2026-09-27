import Foundation

/// The OAuth token of a Claude Code account on another machine, borrowed over SSH.
///
/// Tries `~/.claude/.credentials.json` first (Linux, and anywhere else Claude
/// Code files it), then the remote login keychain's bare service (a Mac
/// server reached the plain way). The JSON is the same document the local
/// keychain holds, so it decodes through the same reader and inherits its
/// guards — an emptied credential reads as signed-out-by-owner, not as
/// never-signed-in.
enum ClaudeRemoteCredentials {
    /// The remote command that prints the filed token, if there is one.
    static func fileCommand(path: String = "~/.claude/.credentials.json") -> String {
        "cat \(path)"
    }

    /// The remote command that prints a Mac server's token, if it signed in
    /// without `CLAUDE_CONFIG_DIR` set. A suffixed service — the variable set
    /// at sign-in — is not attempted: the suffix is a hash of the remote path,
    /// which cannot be known from here.
    static func keychainCommand(service: String = ClaudeProfile.defaultKeychainService) -> String {
        "security find-generic-password -s '\(service)' -w"
    }

    /// How long the renewal run gets: an SSH handshake plus Claude's own
    /// start-up, which the local renewal allows thirty seconds. Short of the
    /// store's sixty-second pass deadline, so a renewal usually still lands
    /// its reading in the same pass instead of the next one.
    static let renewalTimeout: TimeInterval = 45

    /// Printed by the renewal command when no `claude` was found to run. The
    /// only thing the caller reads out of that run's output — everything else
    /// is Claude refusing the empty prompt, which is the success shape.
    static let noCLISentinel = "CODENOTCH_NO_CLI"

    /// The remote command that renews a rotted token the way the local token
    /// renewal does: start the server's own Claude Code with no prompt, so it
    /// goes through its start-up — which is where it checks the token's age
    /// and renews it — and then exits for want of input, stdin already at
    /// end-of-input. Never judged by its exit code, which is non-zero on
    /// success too; the re-read afterwards is the whole verdict.
    ///
    /// The flags are the local renewal's (`ClaudeTokenRefresher.arguments`),
    /// repeated here rather than referenced: that type is MainActor-isolated
    /// and this command is assembled off it. `command -v` first, because a
    /// non-interactive shell's PATH need not include where an installer put
    /// the binary; the native install's directory as the fallback.
    static func renewalCommand() -> String {
        "cd \"${TMPDIR:-/tmp}\" 2>/dev/null; " +
        "for c in \"$(command -v claude)\" \"$HOME/.local/bin/claude\"; do " +
        "[ -x \"$c\" ] && exec \"$c\" -p --no-session-persistence --strict-mcp-config; " +
        "done; echo \(noCLISentinel)"
    }

    /// Reads the remote token, expired or not — judging expiry is the caller's
    /// job, exactly as with the keychain item.
    static func load(from host: RemoteHost, run: RemoteSSH.Runner = RemoteSSH.run) throws -> ClaudeCredentials {
        do {
            let file = try run(host, fileCommand())
            if file.exitCode == 0, !file.stdout.isEmpty {
                return try ClaudeCredentials.decode(file.stdout, services: ["ssh \(host.destination)"])
            }
            if RemoteSSH.isTransportFailure(file) {
                throw RemoteSSH.transportError(destination: host.destination, result: file)
            }
            let chain = try run(host, keychainCommand())
            if chain.exitCode == 0, !chain.stdout.isEmpty {
                return try ClaudeCredentials.decode(chain.stdout, services: ["ssh \(host.destination)"])
            }
            if RemoteSSH.isTransportFailure(chain) {
                throw RemoteSSH.transportError(destination: host.destination, result: chain)
            }
            Log.usage.error("ssh \(host.destination, privacy: .public): no claude credentials file and no keychain token")
            throw UsageProviderError.needsAuth
        } catch is RemoteSSH.TimeoutError {
            throw UsageProviderError.apiError(L10n.t("ssh to \(host.destination) timed out"))
        }
    }
}
