import Foundation
import Testing
@testable import Codenotch

struct ExternalPluginProviderTests {
    private func manifest(
        id: String = "codemie-budget",
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

        #expect(snapshot.id == "codemie-budget")
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
            schema: 1, id: "codemie-budget", displayName: "CodeMie Budget", version: "0.1.0",
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
}
