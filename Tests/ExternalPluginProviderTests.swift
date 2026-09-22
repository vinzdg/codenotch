import Foundation
import Testing
@testable import Codenotch

struct ExternalPluginProviderTests {
    private func manifest(
        id: String = "plugin-codemie-budget",
        signIn: PluginManifest.SignIn? = nil
    ) -> PluginManifest {
        PluginManifest(
            schema: 1, id: id, displayName: "CodeMie Budget", version: "0.1.0",
            exec: PluginManifest.Exec(path: "/bin/sh", args: [], timeoutSeconds: nil),
            glyph: nil, signIn: signIn, activity: nil)
    }

    private func result(_ status: Int32, stdout: String = "", stderr: String = "") -> ExternalPluginProvider.ExecResult {
        ExternalPluginProvider.ExecResult(status: status,
                                          stdout: Data(stdout.utf8),
                                          stderr: Data(stderr.utf8))
    }

    private let payloadJSON = #"""
    {
        "fidelity": "official",
        "headlineID": "budget",
        "account": {"label": "dev@example.com", "source": "CodeMie CLI"},
        "windows": [{"id": "budget", "label": "CLI budget", "usedFraction": 0.42,
                     "money": {"currency": "USD", "spent": 21.0, "remaining": 29.0}}]
    }
    """#

    private func provider(
        manifest: PluginManifest? = nil,
        returning execResult: ExternalPluginProvider.ExecResult
    ) -> ExternalPluginProvider {
        ExternalPluginProvider(manifest: manifest ?? self.manifest()) { _ in execResult }
    }

    // MARK: - Happy path

    @Test func aZeroExitParsesThePayload() async throws {
        let provider = provider(returning: result(0, stdout: payloadJSON))

        let snapshot = try await provider.fetchSnapshot()

        #expect(snapshot.id == "plugin-codemie-budget")
        #expect(snapshot.displayName == "CodeMie Budget")
        #expect(snapshot.glyph == .external)
        #expect(snapshot.headlineID == "budget")
        #expect(snapshot.windows.first?.money?.spent == 21.0)
    }

    @Test func theReportedAccountSurvivesTheFetch() async throws {
        let provider = provider(returning: result(0, stdout: payloadJSON))
        #expect(provider.account() == nil, "no account before the first fetch")

        _ = try await provider.fetchSnapshot()

        #expect(provider.account()?.label == "dev@example.com")
        #expect(provider.account()?.source == "CodeMie CLI")
    }

    // MARK: - Exit codes

    @Test func exit3MeansNeedsAuth() async {
        let provider = provider(returning: result(3, stderr: "run codemie profile login"))
        await #expect(throws: UsageProviderError.needsAuth) {
            _ = try await provider.fetchSnapshot()
        }
    }

    @Test func exit4MeansRateLimitedWithTheHint() async {
        let provider = provider(returning: result(4, stdout: #"{"retryAfterSeconds": 45}"#))
        await #expect(throws: UsageProviderError.rateLimited(retryAfter: 45)) {
            _ = try await provider.fetchSnapshot()
        }
    }

    @Test func exit4WithoutAHintGetsTheDefault() async {
        let provider = provider(returning: result(4))
        await #expect(throws: UsageProviderError.rateLimited(retryAfter: 60)) {
            _ = try await provider.fetchSnapshot()
        }
    }

    @Test func exit5MeansNothingMeteredWithTheReason() async {
        let provider = provider(returning: result(5, stderr: "no CLI budget row for dev@example.com\n"))
        await #expect(throws: UsageProviderError.nothingMetered("no CLI budget row for dev@example.com")) {
            _ = try await provider.fetchSnapshot()
        }
    }

    @Test func anyOtherExitCarriesTheStderrTail() async {
        let provider = provider(returning: result(1, stderr: "some log line\nthe actual failure\n"))
        do {
            _ = try await provider.fetchSnapshot()
            Issue.record("expected a throw")
        } catch let error as PluginExecError {
            guard case .failed(let why) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(why == "the actual failure")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func unparseableStdoutIsABadResponse() async {
        let provider = provider(returning: result(0, stdout: "not json at all"))
        await #expect(throws: UsageProviderError.badResponse(status: 0)) {
            _ = try await provider.fetchSnapshot()
        }
    }

    // MARK: - Sign-in

    @Test func signInRouteComesFromTheManifest() {
        let withGuidance = manifest(signIn: PluginManifest.SignIn(guidance: "Run codemie profile login.", run: nil))
        let provider = ExternalPluginProvider(manifest: withGuidance) { _ in
            self.result(0, stdout: #"{"windows": []}"#)
        }
        #expect(provider.signInRoute == .guidance("Run codemie profile login."))
    }

    // MARK: - Verification before every run

    @Test func aPluginThatFailsVerificationIsNotRunAndIsReported() async {
        let tampered = Counter()
        let ran = Counter()
        let provider = ExternalPluginProvider(
            manifest: manifest(),
            verify: { false },
            onTamper: { tampered.bump() }
        ) { _ in
            ran.bump()
            return self.result(0, stdout: self.payloadJSON)
        }

        await #expect(throws: PluginExecError.changedSinceApproval) {
            _ = try await provider.fetchSnapshot()
        }
        #expect(ran.value == 0, "a changed plugin must not be spawned")
        #expect(tampered.value == 1, "the registry must hear about it")
    }

    @Test func aPluginThatPassesVerificationRuns() async throws {
        let tampered = Counter()
        let provider = ExternalPluginProvider(
            manifest: manifest(), verify: { true }, onTamper: { tampered.bump() }
        ) { _ in self.result(0, stdout: self.payloadJSON) }

        _ = try await provider.fetchSnapshot()
        #expect(tampered.value == 0)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func bump() { lock.withLock { count += 1 } }
    }

    @Test func theChildRunsInThePluginDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalPluginProviderTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = spawnManifest(args: ["-c", "pwd"])

        let result = try await ExternalPluginProvider.spawn(manifest: manifest, directory: directory)

        let printed = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(printed.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == directory.resolvingSymlinksInPath().path)
    }

    // MARK: - The real spawn

    @Test func spawnRunsTheExecutableAndCapturesBothPipes() async throws {
        let manifest = PluginManifest(
            schema: 1, id: "echo", displayName: "Echo", version: "1",
            exec: PluginManifest.Exec(
                path: "/bin/sh",
                args: ["-c", "printf '%s' '{\"windows\": []}'; echo a-warning >&2"],
                timeoutSeconds: 5),
            glyph: nil, signIn: nil, activity: nil)

        let result = try await ExternalPluginProvider.spawn(manifest: manifest)

        #expect(result.status == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == #"{"windows": []}"#)
        #expect(String(data: result.stderr, encoding: .utf8) == "a-warning\n")
    }

    @Test func spawnKillsAWedgedPlugin() async {
        let manifest = PluginManifest(
            schema: 1, id: "sleeper", displayName: "Sleeper", version: "1",
            exec: PluginManifest.Exec(path: "/bin/sleep", args: ["30"], timeoutSeconds: 0.2),
            glyph: nil, signIn: nil, activity: nil)

        do {
            _ = try await ExternalPluginProvider.spawn(manifest: manifest)
            Issue.record("expected a timeout")
        } catch let error as UsageProviderError {
            guard case .timedOut = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: - Spawning

    private func spawnManifest(
        args: [String],
        timeoutSeconds: TimeInterval? = nil
    ) -> PluginManifest {
        PluginManifest(
            schema: 1, id: "plugin-codemie-budget", displayName: "CodeMie Budget", version: "0.1.0",
            exec: PluginManifest.Exec(path: "/bin/sh", args: args, timeoutSeconds: timeoutSeconds),
            glyph: nil, signIn: nil, activity: nil)
    }

    @Test func theChildGetsTheAllowlistedEnvironment() async throws {
        // Deterministic: the allowlist's PATH is a constant, so echoing it proves
        // both that it was set and that the inherited one was not used.
        let manifest = spawnManifest(args: ["-c", "printf %s \"$PATH\""])
        let result = try await ExternalPluginProvider.spawn(manifest: manifest)
        #expect(String(data: result.stdout, encoding: .utf8)
                == "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin")
    }

    @Test func theTimeoutIsClampedToTheCeiling() {
        #expect(ExternalPluginProvider.effectiveTimeout(
            for: spawnManifest(args: [], timeoutSeconds: 9999)) == 30)
        #expect(ExternalPluginProvider.effectiveTimeout(
            for: spawnManifest(args: [], timeoutSeconds: 5)) == 5)
    }

    @Test func aPluginThatIgnoresSIGTERMIsKilled() async throws {
        // trap "" TERM swallows the watchdog's SIGTERM; only the SIGKILL
        // escalation ends this child.
        let manifest = spawnManifest(args: ["-c", "trap '' TERM; sleep 60"],
                                     timeoutSeconds: 1)
        let started = Date()
        await #expect(throws: UsageProviderError.timedOut) {
            _ = try await ExternalPluginProvider.spawn(manifest: manifest)
        }
        #expect(Date().timeIntervalSince(started) < 10,
                "SIGKILL escalation should end a SIGTERM-immune child within seconds")
    }

    @Test func stdoutBeyondTheCapIsABadResponse() async {
        let manifest = spawnManifest(
            args: ["-c", "head -c 2000000 /dev/zero | tr '\\0' 'a'"])
        await #expect(throws: UsageProviderError.badResponse(status: 0)) {
            _ = try await ExternalPluginProvider.spawn(manifest: manifest)
        }
    }

    @Test func stderrBeyondTheCapIsAnError() async {
        let manifest = spawnManifest(
            args: ["-c", "head -c 100000 /dev/zero | tr '\\0' 'a' 1>&2"])
        do {
            _ = try await ExternalPluginProvider.spawn(manifest: manifest)
            Issue.record("expected a throw")
        } catch let error as PluginExecError {
            guard case .failed(let why) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(why.contains("stderr"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func aGrandchildHoldingThePipeCannotHangTheFetch() async throws {
        // sh exits at once; the orphaned grandchild holds the pipe write end.
        // Only the bounded drain wait throws timedOut instead of hanging.
        let manifest = spawnManifest(args: ["-c", "sleep 30 &"])
        let started = Date()
        await #expect(throws: UsageProviderError.timedOut) {
            _ = try await ExternalPluginProvider.spawn(manifest: manifest)
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func presentSignInRunsInThePluginDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalPluginProviderTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("cwd.txt")
        let manifest = PluginManifest(
            schema: 1, id: "p", displayName: "P", version: "1",
            exec: PluginManifest.Exec(path: "/bin/sh", args: [], timeoutSeconds: nil),
            glyph: nil,
            signIn: PluginManifest.SignIn(guidance: "g", run: ["/bin/sh", "-c", "pwd > '\(marker.path)'"]),
            activity: nil)
        let plugin = PluginRegistry.RegisteredPlugin(manifest: manifest, directory: directory, contentHash: "x")
        let provider = ExternalPluginProvider(plugin: plugin, verify: { true }, onTamper: {})

        provider.presentSignIn()

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let printed = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: printed).resolvingSymlinksInPath().path
                == directory.resolvingSymlinksInPath().path)
    }
}
