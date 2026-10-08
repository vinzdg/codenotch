import XCTest
@testable import Codenotch

private func remoteHost(id: String = "host-1", kind: RemoteHostKind = .claude,
                        name: String = "Work GPU",
                        host: String = "gpu.example.com", user: String = "armin",
                        port: Int = 22, identityFile: String? = nil,
                        isEnabled: Bool = true) -> RemoteHost {
    RemoteHost(id: id, kind: kind, name: name, host: host, user: user,
               port: port, identityFile: identityFile, isEnabled: isEnabled)
}

private func credentialsFile(expiresMs: Double = 1_900_000_000_000,
                             token: String = "remote-token") -> Data {
    Data("""
    {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"r",
     "expiresAt":\(expiresMs),"subscriptionType":"max"}}
    """.utf8)
}

/// `{"exp":1900000000}` payload, base64url — the loader judges this claim.
private let freshJWT = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjE5MDAwMDAwMDB9.c2ln"
/// `{"exp":1000}` — long spent.
private let staleJWT = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjEwMDB9.c2ln"

private func codexAuthFile(token: String = "") -> Data {
    let access = token.isEmpty ? freshJWT : token
    return Data("""
    {"tokens":{"access_token":"\(access)","account_id":"acct-1",
     "id_token":"\(freshJWT)"}}
    """.utf8)
}

final class RemoteHostTests: XCTestCase {
    func testProviderIDIsPrefixedPerKind() {
        XCTAssertEqual(remoteHost(id: "abc").providerID, "claude-remote-abc")
        XCTAssertEqual(remoteHost(id: "abc", kind: .codex).providerID, "codex-remote-abc")
        XCTAssertTrue(RemoteHost.isRemoteClaude(providerID: "claude-remote-abc"))
        XCTAssertTrue(RemoteHost.isRemoteCodex(providerID: "codex-remote-abc"))
        XCTAssertTrue(RemoteHost.isRemote(providerID: "codex-remote-abc"))
        XCTAssertFalse(RemoteHost.isRemote(providerID: "claude"))
        XCTAssertFalse(RemoteHost.isRemote(providerID: "claude-work"))
        XCTAssertFalse(RemoteHost.isRemote(providerID: "codex"))
    }

    func testFactoryBuildsPerKind() {
        XCTAssertTrue(remoteHost(kind: .claude).makeProvider() is ClaudeRemoteProvider)
        XCTAssertTrue(remoteHost(kind: .codex).makeProvider() is CodexRemoteProvider)
    }

    func testDestinationAndDisplayName() {
        XCTAssertEqual(remoteHost().destination, "armin@gpu.example.com")
        XCTAssertEqual(remoteHost().displayName, "Work GPU")
        // A blank name falls back to the destination rather than drawing empty.
        XCTAssertEqual(remoteHost(name: "  ").displayName, "armin@gpu.example.com")
    }

    func testIsConfiguredNeedsHostAndUser() {
        XCTAssertTrue(remoteHost().isConfigured)
        XCTAssertFalse(remoteHost(host: "  ").isConfigured)
        XCTAssertFalse(remoteHost(user: "").isConfigured)
        XCTAssertFalse(remoteHost(port: 0).isConfigured)
    }

    func testRoundTrips() throws {
        let host = remoteHost(kind: .codex, identityFile: "~/.ssh/gpu")
        let decoded = try JSONDecoder().decode(
            RemoteHost.self, from: JSONEncoder().encode(host))
        XCTAssertEqual(decoded, host)
    }

    func testEntriesWrittenBeforeKindsWereClaude() throws {
        let decoded = try JSONDecoder().decode(
            RemoteHost.self,
            from: Data("""
            {"id":"abc","name":"N","host":"h","user":"u","port":22,
             "identityFile":null,"isEnabled":true}
            """.utf8))
        XCTAssertEqual(decoded.kind, .claude)
        XCTAssertEqual(decoded.providerID, "claude-remote-abc")
    }

    func testDestinationLookupFindsTheHost() throws {
        let name = "RemoteHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(try JSONEncoder().encode([remoteHost()]), forKey: "remoteHosts")
        XCTAssertEqual(RemoteHost.destination(
            forProviderID: "claude-remote-host-1", defaults: defaults),
            "armin@gpu.example.com")
        XCTAssertNil(RemoteHost.destination(
            forProviderID: "claude-remote-gone", defaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }
}

final class RemoteSSHTests: XCTestCase {
    func testArgumentsBatchAndPin() {
        let args = RemoteSSH.arguments(for: remoteHost(), command: "cat x")
        XCTAssertEqual(args.first, "-o")
        XCTAssertTrue(args.contains("BatchMode=yes"), "a poll must fail, never prompt")
        XCTAssertTrue(args.contains("ConnectTimeout=10"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertEqual(args.suffix(3), ["--", "armin@gpu.example.com", "cat x"])
        // Every configured value travels as its own argument — no shell.
        XCTAssertTrue(args.contains("22"))
    }

    func testArgumentsCarryPortAndIdentity() {
        let args = RemoteSSH.arguments(
            for: remoteHost(port: 2222, identityFile: "~/.ssh/gpu"), command: "cat x")
        XCTAssertTrue(args.contains("2222"))
        XCTAssertTrue(args.contains("~/.ssh/gpu"))
    }
}

final class ClaudeRemoteCredentialsTests: XCTestCase {
    private typealias Result = RemoteSSH.CommandResult

    private func ok(_ data: Data) -> Result {
        Result(exitCode: 0, stdout: data, stderr: "")
    }

    func testFileCommandIsConstant() {
        XCTAssertEqual(ClaudeRemoteCredentials.fileCommand(), "cat ~/.claude/.credentials.json")
        XCTAssertTrue(ClaudeRemoteCredentials.keychainCommand().contains("Claude Code-credentials"))
    }

    func testRenewalCommandFindsClaudeAndReportsWhenMissing() {
        let command = ClaudeRemoteCredentials.renewalCommand()
        // The local renewal's flags, so the run stays contained and writes
        // no session.
        XCTAssertTrue(command.contains("-p --no-session-persistence --strict-mcp-config"), command)
        // PATH lookup first, the native install's directory as the fallback —
        // a non-interactive shell's PATH is minimal.
        XCTAssertTrue(command.contains("command -v claude"), command)
        XCTAssertTrue(command.contains("$HOME/.local/bin/claude"), command)
        // The only thing the caller reads out of the run.
        XCTAssertTrue(command.hasSuffix("echo \(ClaudeRemoteCredentials.noCLISentinel)"), command)
    }

    func testReadsTheFiledToken() throws {
        let credentials = try ClaudeRemoteCredentials.load(from: remoteHost()) { _, command in
            XCTAssertTrue(command.contains("credentials.json"))
            return self.ok(credentialsFile())
        }
        XCTAssertEqual(credentials.accessToken, "remote-token")
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertFalse(credentials.isExpired)
    }

    func testFallsBackToTheRemoteKeychain() throws {
        var commands: [String] = []
        let credentials = try ClaudeRemoteCredentials.load(from: remoteHost()) { _, command in
            commands.append(command)
            if command.contains("credentials.json") {
                return Result(exitCode: 1, stdout: Data(),
                              stderr: "cat: .claude/.credentials.json: No such file or directory\n")
            }
            return self.ok(credentialsFile())
        }
        XCTAssertEqual(credentials.accessToken, "remote-token")
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[1].contains("security find-generic-password"))
    }

    func testNoCredentialAnywhereNeedsAuth() {
        XCTAssertThrowsError(
            try ClaudeRemoteCredentials.load(from: remoteHost()) { _, _ in
                Result(exitCode: 1, stdout: Data(), stderr: "No such file\n")
            }
        ) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testTransportFailureKeepsTheReading() {
        // exit 255 is ssh's own failure — the road, not the account.
        XCTAssertThrowsError(
            try ClaudeRemoteCredentials.load(from: remoteHost()) { _, _ in
                Result(exitCode: 255, stdout: Data(),
                       stderr: "ssh: connect to host gpu.example.com port 22: Operation timed out\n")
            }
        ) { error in
            guard case UsageProviderError.apiError(let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(name.contains("Operation timed out"), name)
        }
    }

    func testPermissionDeniedIsATransportFailure() {
        // BatchMode turns a missing key into this instead of a prompt.
        XCTAssertThrowsError(
            try ClaudeRemoteCredentials.load(from: remoteHost()) { _, _ in
                Result(exitCode: 255, stdout: Data(),
                       stderr: "armin@gpu.example.com: Permission denied (publickey).\n")
            }
        ) { error in
            guard case UsageProviderError.apiError(let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(name.contains("Permission denied"), name)
        }
    }

    func testTimeoutIsATransportFailure() {
        XCTAssertThrowsError(
            try ClaudeRemoteCredentials.load(from: remoteHost()) { host, _ in
                throw RemoteSSH.TimeoutError(destination: host.destination)
            }
        ) { error in
            guard case UsageProviderError.apiError(let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(name.contains("timed out"), name)
        }
    }

    func testAnEmptiedCredentialIsSignedOutByOwner() {
        let emptied = Data("""
            {"claudeAiOauth":{"accessToken":"","expiresAt":0}}
            """.utf8)
        XCTAssertThrowsError(
            try ClaudeRemoteCredentials.load(from: remoteHost()) { _, _ in self.ok(emptied) }
        ) { error in
            guard case UsageProviderError.signedOutByOwner = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}

final class CodexRemoteCredentialsTests: XCTestCase {
    private typealias Result = RemoteSSH.CommandResult

    func testReadsTheFiledSession() throws {
        let credential = try CodexRemoteCredentials.load(from: remoteHost(kind: .codex)) { _, command in
            XCTAssertEqual(command, "cat ~/.codex/auth.json")
            return Result(exitCode: 0, stdout: codexAuthFile(), stderr: "")
        }
        XCTAssertEqual(credential.accessToken, freshJWT)
        XCTAssertEqual(credential.accountID, "acct-1")
    }

    func testExpiredSessionFailsWithoutFallback() {
        // One source, no second try: a spent token is spent.
        XCTAssertThrowsError(
            try CodexRemoteCredentials.load(from: remoteHost(kind: .codex)) { _, _ in
                Result(exitCode: 0, stdout: codexAuthFile(token: staleJWT), stderr: "")
            }
        ) { error in
            guard case UsageProviderError.credentialExpired = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testMissingFileNeedsAuth() {
        XCTAssertThrowsError(
            try CodexRemoteCredentials.load(from: remoteHost(kind: .codex)) { _, _ in
                Result(exitCode: 1, stdout: Data(), stderr: "No such file\n")
            }
        ) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testTransportFailureKeepsTheReading() {
        XCTAssertThrowsError(
            try CodexRemoteCredentials.load(from: remoteHost(kind: .codex)) { _, _ in
                Result(exitCode: 255, stdout: Data(), stderr: "Connection refused\n")
            }
        ) { error in
            guard case UsageProviderError.apiError(let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(name.contains("Connection refused"), name)
        }
    }

    func testTimeoutIsATransportFailure() {
        XCTAssertThrowsError(
            try CodexRemoteCredentials.load(from: remoteHost(kind: .codex)) { host, _ in
                throw RemoteSSH.TimeoutError(destination: host.destination)
            }
        ) { error in
            guard case UsageProviderError.apiError(let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(name.contains("timed out"), name)
        }
    }
}

final class RemoteProbeTests: XCTestCase {
    private typealias Result = RemoteSSH.CommandResult

    private func output(_ text: String) -> Result {
        Result(exitCode: 0, stdout: Data(text.utf8), stderr: "")
    }

    func testScriptReportsOSAndFindings() {
        let script = RemoteProbe.script(for: .claude)
        XCTAssertTrue(script.contains("echo PROBE_OS=$(uname -s)"))
        XCTAssertTrue(script.contains("test -f ~/.claude/.credentials.json"))
        XCTAssertTrue(script.contains("security find-generic-password"))
        // The password is redirected away: existence is all the probe learns.
        XCTAssertTrue(script.contains("-w >/dev/null 2>&1"))
        XCTAssertTrue(script.hasSuffix("true"))
    }

    func testScriptForCodexChecksAuthJSON() {
        let script = RemoteProbe.script(for: .codex)
        XCTAssertTrue(script.contains("test -f ~/.codex/auth.json"))
        XCTAssertFalse(script.contains("security"))
    }

    func testFoundTokenReportsOSAndPath() throws {
        let report = try RemoteProbe.check(host: remoteHost()) { _, _ in
            self.output("PROBE_OS=Linux\nPROBE_FOUND=~/.claude/.credentials.json\n")
        }
        XCTAssertEqual(report.os, .linux)
        XCTAssertEqual(report.found, "~/.claude/.credentials.json")
    }

    func testDarwinReadsAsMac() throws {
        let report = try RemoteProbe.check(host: remoteHost()) { _, _ in
            self.output("PROBE_OS=Darwin\nPROBE_FOUND=keychain:Claude Code-credentials\n")
        }
        XCTAssertEqual(report.os, .mac)
        XCTAssertTrue(report.found.contains("keychain"))
    }

    func testLoginNoiseAboveDoesNotMatter() throws {
        // Markers, not positions: a chatty `.bashrc` may print first.
        let report = try RemoteProbe.check(host: remoteHost()) { _, _ in
            self.output("Welcome to fish\nPROBE_OS=Linux\nPROBE_FOUND=~/.claude/.credentials.json\n")
        }
        XCTAssertEqual(report.os, .linux)
    }

    func testNoTokenNamesWhatWasChecked() {
        XCTAssertThrowsError(
            try RemoteProbe.check(host: remoteHost()) { _, _ in
                self.output("PROBE_OS=Linux\n")
            }
        ) { error in
            guard let failure = error as? RemoteProbe.Failure else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(failure.message.contains("armin@gpu.example.com"), failure.message)
            XCTAssertTrue(failure.message.contains("Linux"), failure.message)
            XCTAssertTrue(failure.message.contains("~/.claude/.credentials.json"), failure.message)
            XCTAssertTrue(failure.message.contains("claude"), failure.message)
        }
    }

    func testUnreadableOutputSaysSo() {
        XCTAssertThrowsError(
            try RemoteProbe.check(host: remoteHost()) { _, _ in self.output("hi\n") }
        ) { error in
            guard let failure = error as? RemoteProbe.Failure else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(failure.message.contains("unreadable"), failure.message)
        }
    }

    func testPermissionDeniedAdvisesTheKey() {
        XCTAssertThrowsError(
            try RemoteProbe.check(host: remoteHost()) { _, _ in
                Result(exitCode: 255, stdout: Data(),
                       stderr: "armin@gpu.example.com: Permission denied (publickey).\n")
            }
        ) { error in
            guard let failure = error as? RemoteProbe.Failure else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(failure.message.contains("Key auth must work"), failure.message)
            XCTAssertTrue(failure.message.contains("ssh-copy-id"), failure.message)
        }
    }

    func testUnresolvableHostBlamesTheName() {
        XCTAssertThrowsError(
            try RemoteProbe.check(host: remoteHost()) { _, _ in
                Result(exitCode: 255, stdout: Data(),
                       stderr: "ssh: Could not resolve hostname gpu.example.com: nodename nor servname provided\n")
            }
        ) { error in
            guard let failure = error as? RemoteProbe.Failure else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(failure.message.contains("Check the hostname"), failure.message)
        }
    }

    func testTimeoutBlamesTheRoad() {
        XCTAssertThrowsError(
            try RemoteProbe.check(host: remoteHost()) { host, _ in
                throw RemoteSSH.TimeoutError(destination: host.destination)
            }
        ) { error in
            guard let failure = error as? RemoteProbe.Failure else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(failure.message.contains("timed out"), failure.message)
        }
    }
}

final class ClaudeRemoteProviderTests: XCTestCase {
    private typealias Result = RemoteSSH.CommandResult

    private let usage = """
    { "limits": [
        { "kind": "session", "percent": 52, "resets_at": "2026-08-28T09:50:00.316290+00:00" },
        { "kind": "weekly_all", "percent": 17, "resets_at": "2026-09-02T17:00:00.316321+00:00" }
    ] }
    """

    private func makeProvider(answers: [(Int, String)],
                              runner: RemoteSSH.Runner? = nil,
                              runRenewal: (@Sendable () throws -> Result)? = nil)
        -> ClaudeRemoteProvider {
        RemoteClaudeEndpoint.reset(answers)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteClaudeEndpoint.self]
        let name = "ClaudeRemoteProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ClaudeRemoteProvider(
            host: remoteHost(),
            session: URLSession(configuration: configuration),
            archive: UsageArchive(defaults: defaults),
            loadCredentials: {
                try ClaudeRemoteCredentials.load(
                    from: remoteHost(),
                    run: runner ?? { _, _ in
                        Result(exitCode: 0, stdout: credentialsFile(), stderr: "")
                    })
            },
            runRenewal: runRenewal)
    }

    func testFetchesWindowsFromTheEndpoint() async throws {
        let snapshot = try await makeProvider(answers: [(200, usage)]).fetchSnapshot()
        XCTAssertEqual(snapshot.id, "claude-remote-host-1")
        XCTAssertEqual(snapshot.displayName, "Work GPU")
        XCTAssertEqual(snapshot.headlineText, "52%")
        XCTAssertEqual(snapshot.weeklyFraction ?? -1, 0.17, accuracy: 0.0001)
        XCTAssertEqual(snapshot.plan, "max")
        XCTAssertEqual(RemoteClaudeEndpoint.requestCount, 1)
        XCTAssertEqual(RemoteClaudeEndpoint.bearers, ["remote-token"])
    }

    func testUnauthorizedReReadsOnceThenNeedsAuth() async throws {
        var loads = 0
        let provider = makeProvider(answers: [(401, ""), (401, "")]) { _, _ in
            loads += 1
            return Result(exitCode: 0, stdout: credentialsFile(), stderr: "")
        }
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth")
        } catch UsageProviderError.needsAuth {
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(loads, 2, "the file is re-read once before giving up")
        XCTAssertEqual(RemoteClaudeEndpoint.requestCount, 2)
    }

    func testRateLimitedBacksOff() async throws {
        let provider = makeProvider(answers: [(429, "")])
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected rateLimited")
        } catch UsageProviderError.rateLimited {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testExpiredTokenRenewsThenFetches() async throws {
        var loads = 0
        var renewals = 0
        let provider = makeProvider(
            answers: [(200, usage), (200, usage)],
            runner: { _, _ in
                loads += 1
                // The first read finds the rotted token; the re-read after the
                // renewal finds what the server's own Claude Code filed.
                let file = loads == 1
                    ? credentialsFile(expiresMs: 1_000, token: "rotted-token")
                    : credentialsFile(token: "renewed-token")
                return Result(exitCode: 0, stdout: file, stderr: "")
            },
            runRenewal: {
                renewals += 1
                // Refusing the empty prompt is a non-zero exit and a
                // successful renewal at the same time — judged by the
                // re-read, never by this.
                return Result(exitCode: 1, stdout: Data("Input must be provided...".utf8),
                              stderr: "")
            })
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.headlineText, "52%")
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(RemoteClaudeEndpoint.requestCount, 1)
        XCTAssertEqual(RemoteClaudeEndpoint.bearers, ["renewed-token"],
                       "the renewed token is the one that travels")
        // The renewed token is held like any other.
        let again = try await provider.fetchSnapshot()
        XCTAssertEqual(again.headlineText, "52%")
        XCTAssertEqual(loads, 2, "no re-read while the held copy is fresh")
        XCTAssertEqual(renewals, 1, "no second renewal while the held copy is fresh")
    }

    func testRenewalThatChangesNothingStaysExpired() async throws {
        var loads = 0
        var renewals = 0
        let provider = makeProvider(
            answers: [(200, usage)],
            runner: { _, _ in
                loads += 1
                return Result(exitCode: 0, stdout: credentialsFile(expiresMs: 1_000),
                              stderr: "")
            },
            runRenewal: {
                renewals += 1
                return Result(exitCode: 1, stdout: Data(), stderr: "")
            })
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected credentialExpired")
        } catch UsageProviderError.credentialExpired {
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(loads, 2, "the initial read plus the re-read after the renewal")
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(RemoteClaudeEndpoint.requestCount, 0,
                       "an unrenewed token never reaches the endpoint")
        // One attempt per token: the same expiry next poll is refused without
        // respawning a remote process.
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected credentialExpired")
        } catch UsageProviderError.credentialExpired {
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(loads, 3)
        XCTAssertEqual(renewals, 1)
    }

    func testRenewalWithoutAClaudeBinaryStaysExpired() async throws {
        let provider = makeProvider(
            answers: [(200, usage)],
            runner: { _, _ in
                Result(exitCode: 0, stdout: credentialsFile(expiresMs: 1_000), stderr: "")
            },
            runRenewal: {
                Result(exitCode: 0,
                       stdout: Data("\(ClaudeRemoteCredentials.noCLISentinel)\n".utf8),
                       stderr: "")
            })
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected credentialExpired")
        } catch UsageProviderError.credentialExpired {
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(RemoteClaudeEndpoint.requestCount, 0)
    }

    func testRenewalTransportFailureKeepsTheReading() async throws {
        let provider = makeProvider(
            answers: [(200, usage)],
            runner: { _, _ in
                Result(exitCode: 0, stdout: credentialsFile(expiresMs: 1_000), stderr: "")
            },
            runRenewal: {
                Result(exitCode: 255, stdout: Data(),
                       stderr: "ssh: connect to host gpu.example.com port 22: Operation timed out\n")
            })
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected apiError")
        } catch UsageProviderError.apiError(let name) {
            XCTAssertTrue(name.contains("Operation timed out"), name)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSSHFailureSurfacesAsSSH() async throws {
        let provider = makeProvider(answers: [(200, usage)]) { _, _ in
            Result(exitCode: 255, stdout: Data(), stderr: "Connection refused\n")
        }
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected apiError")
        } catch UsageProviderError.apiError(let name) {
            XCTAssertTrue(name.contains("Connection refused"), name)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAccountNamesTheServer() {
        let account = makeProvider(answers: []).account()
        XCTAssertEqual(account?.source, "Claude Code on gpu.example.com")
        XCTAssertEqual(account?.manageURL?.absoluteString, "https://claude.ai/settings/usage")
    }
}

/// Canned answers for the usage endpoint, shared with the local provider's
/// tests in shape but not in instance — the two suites reset independently.
private final class RemoteClaudeEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var answers: [(Int, String)] = []
    private static var count = 0
    private static var seenBearers: [String] = []

    static var requestCount: Int { lock.withLock { count } }
    static var bearers: [String] { lock.withLock { seenBearers } }

    static func reset(_ values: [(Int, String)]) {
        lock.withLock { answers = values; count = 0; seenBearers = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString.hasPrefix("https://api.anthropic.com/api/oauth/usage") ?? false
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.hasPrefix("Bearer ") && auth.count > 7, "missing bearer: \(auth)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        let answer = Self.lock.withLock {
            Self.count += 1
            Self.seenBearers.append(String(auth.dropFirst("Bearer ".count)))
            return Self.answers.isEmpty ? (500, "") : Self.answers.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class CodexRemoteProviderTests: XCTestCase {
    private typealias Result = RemoteSSH.CommandResult

    private let usage = """
    {"rate_limit":{
      "primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":1800001000},
      "secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1800600000}}}
    """

    private func makeProvider(answers: [(Int, String)],
                              runner: RemoteSSH.Runner? = nil)
        -> CodexRemoteProvider {
        RemoteCodexEndpoint.reset(answers)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteCodexEndpoint.self]
        let name = "CodexRemoteProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return CodexRemoteProvider(
            host: remoteHost(kind: .codex, name: "Hetzner"),
            session: URLSession(configuration: configuration),
            archive: UsageArchive(defaults: defaults),
            loadCredential: {
                try CodexRemoteCredentials.load(
                    from: remoteHost(kind: .codex),
                    run: runner ?? { _, _ in
                        Result(exitCode: 0, stdout: codexAuthFile(), stderr: "")
                    })
            })
    }

    func testFetchesWindowsFromTheEndpoint() async throws {
        let snapshot = try await makeProvider(answers: [(200, usage)]).fetchSnapshot()
        XCTAssertEqual(snapshot.id, "codex-remote-host-1")
        XCTAssertEqual(snapshot.displayName, "Hetzner")
        XCTAssertEqual(snapshot.headlineText, "25%")
        XCTAssertEqual(snapshot.weeklyFraction ?? -1, 0.10, accuracy: 0.0001)
    }

    func testUnauthorizedReReadsOnceThenNeedsAuth() async throws {
        var loads = 0
        let provider = makeProvider(answers: [(401, ""), (401, "")]) { _, _ in
            loads += 1
            return Result(exitCode: 0, stdout: codexAuthFile(), stderr: "")
        }
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth")
        } catch UsageProviderError.needsAuth {
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(loads, 2, "the file is re-read once before giving up")
    }

    func testRateLimitedBacksOff() async throws {
        let provider = makeProvider(answers: [(429, "")])
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected rateLimited")
        } catch UsageProviderError.rateLimited {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testExpiredSessionDoesNotTouchTheNetwork() async throws {
        let provider = makeProvider(answers: [(200, usage)]) { _, _ in
            Result(exitCode: 0, stdout: codexAuthFile(token: staleJWT), stderr: "")
        }
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected credentialExpired")
        } catch UsageProviderError.credentialExpired {
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(RemoteCodexEndpoint.usageRequestCount, 0)
    }

    func testSSHFailureSurfacesAsSSH() async throws {
        let provider = makeProvider(answers: [(200, usage)]) { _, _ in
            Result(exitCode: 255, stdout: Data(), stderr: "Connection refused\n")
        }
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected apiError")
        } catch UsageProviderError.apiError(let name) {
            XCTAssertTrue(name.contains("Connection refused"), name)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAccountNamesTheServer() {
        let account = makeProvider(answers: []).account()
        XCTAssertEqual(account?.source, "Codex on gpu.example.com")
        XCTAssertEqual(account?.manageURL?.absoluteString, "https://chatgpt.com/#settings/Account")
    }
}

/// Canned usage answers; the profile and reset-credit side quests answer 500,
/// which the provider already treats as "no extras".
private final class RemoteCodexEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var answers: [(Int, String)] = []
    private static var usageCount = 0

    static var usageRequestCount: Int { lock.withLock { usageCount } }

    static func reset(_ values: [(Int, String)]) {
        lock.withLock { answers = values; usageCount = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString.hasPrefix("https://chatgpt.com/backend-api/wham/") ?? false
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-1")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") ?? false)
        let isUsage = request.url?.absoluteString.contains("/wham/usage") ?? false
        let answer = Self.lock.withLock {
            if isUsage {
                Self.usageCount += 1
                return Self.answers.isEmpty ? (500, "") : Self.answers.removeFirst()
            }
            return (500, "")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class RemoteWiringTests: XCTestCase {
    func testRemoteLoginUsesNoLocalKeychain() {
        let local = ProviderSummary(id: "claude-work", name: "Claude", glyph: .claude,
                                    account: nil, signIn: .guidance(""))
        XCTAssertTrue(local.usesKeychain)
        let remoteClaude = ProviderSummary(id: "claude-remote-abc", name: "GPU", glyph: .claude,
                                           account: nil, signIn: .guidance(""))
        XCTAssertFalse(remoteClaude.usesKeychain, "there is no local item to re-ask for")
        let remoteCodex = ProviderSummary(id: "codex-remote-abc", name: "GPU", glyph: .openai,
                                          account: nil, signIn: .guidance(""))
        XCTAssertFalse(remoteCodex.usesKeychain)
    }

    func testAuthPromptPointsAtTheServer() {
        // Provider ids no stored host answers, so the copy cannot depend on
        // whatever the developer has configured.
        let claude = ProviderSnapshot(id: "claude-remote-\(UUID().uuidString)",
                                      displayName: "GPU", glyph: .claude,
                                      fidelity: .official, status: .needsAuth, windows: [])
        XCTAssertEqual(claude.statusMessage,
                       "Sign in to Claude Code on that server to read this account's usage")
        let codex = ProviderSnapshot(id: "codex-remote-\(UUID().uuidString)",
                                     displayName: "GPU", glyph: .openai,
                                     fidelity: .official, status: .needsAuth, windows: [])
        XCTAssertEqual(codex.statusMessage,
                       "Sign in to Codex on that server to read this account's usage")
    }

    @MainActor
    func testMenuBarLabelIsTheHostName() {
        // The slug rule would print `<kind>-remote-<uuid>`; the user's own
        // short word is what tells two servers apart.
        let windows = [
            LimitWindow(id: "session", label: "Current session", usedFraction: 0.5,
                        resetsAt: Date().addingTimeInterval(3600), duration: 5 * 3600),
        ]
        func snapshot(id: String, name: String, glyph: ProviderGlyph) -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: name, glyph: glyph,
                             fidelity: .official, status: .ok, windows: windows,
                             headlineID: "session")
        }
        let summary = StatusItemSummary.make(
            from: [snapshot(id: "claude", name: "Claude", glyph: .claude),
                   snapshot(id: "claude-remote-abc", name: "Work GPU", glyph: .claude),
                   snapshot(id: "codex-remote-abc", name: "Hetzner", glyph: .openai)],
            showing: MenuBarLimits(isOn: true, chosen: ["claude", "claude-remote-abc", "codex-remote-abc"]),
            now: Date())
        let labels = Dictionary(uniqueKeysWithValues: summary.entries.map { ($0.id, $0.label) })
        XCTAssertEqual(labels["claude-remote-abc"], "Work GPU")
        // The codex ring shares no mark here, so it needs no label at all —
        // read off the entry, since a missing key and a nil label both
        // subscript to nil and only the entry tells them apart.
        let codexEntry = summary.entries.first { $0.id == "codex-remote-abc" }
        XCTAssertNotNil(codexEntry)
        XCTAssertNil(codexEntry?.label)
    }
}

@MainActor
final class RemoteHostsPreferencesTests: XCTestCase {
    private func makePreferences() -> (Preferences, String) {
        let name = "RemoteHostsPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (Preferences(defaults: defaults), name)
    }

    func testAddUpdateRemoveRoundTrip() throws {
        let (preferences, name) = makePreferences()
        defer { UserDefaults(suiteName: name)!.removePersistentDomain(forName: name) }
        XCTAssertTrue(preferences.remoteHosts.isEmpty)

        preferences.addRemoteHost(remoteHost())
        XCTAssertEqual(preferences.remoteHosts.count, 1)
        XCTAssertTrue(preferences.isConnected("claude-remote-host-1"))

        var edited = remoteHost()
        edited.port = 2222
        edited.isEnabled = false
        preferences.updateRemoteHost(edited)
        XCTAssertEqual(preferences.remoteHosts.first?.port, 2222)
        XCTAssertFalse(preferences.isConnected("claude-remote-host-1"))

        // Survives the encode back to disk.
        let reloaded = Preferences(defaults: UserDefaults(suiteName: name)!)
        XCTAssertEqual(reloaded.remoteHosts.first?.port, 2222)
        // And the off-actor reader the tooltip uses sees the same row.
        XCTAssertEqual(
            Preferences.storedRemoteHosts(defaults: UserDefaults(suiteName: name)!).first?.port,
            2222)

        preferences.removeRemoteHost(id: "host-1")
        XCTAssertTrue(preferences.remoteHosts.isEmpty)
    }

    func testLegacyClaudeOnlyEntriesMigrate() throws {
        let name = "RemoteHostsPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        // Written before kinds existed: no `kind`, old key.
        defaults.set(Data("""
            [{"id":"abc","name":"N","host":"h","user":"u","port":22,
              "identityFile":null,"isEnabled":true}]
            """.utf8), forKey: "remoteClaudeHosts")

        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.remoteHosts.map(\.providerID), ["claude-remote-abc"])

        // The next write moves house and drops the legacy key.
        preferences.addRemoteHost(remoteHost(id: "xyz", kind: .codex))
        XCTAssertNil(defaults.data(forKey: "remoteClaudeHosts"))
        XCTAssertEqual(preferences.remoteHosts.count, 2)
    }
}
