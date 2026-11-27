import XCTest
@testable import Codenotch

final class AntigravityUsageCLITests: XCTestCase {
    func testParsesOfficialQuotaOutputInExpectedOrder() throws {
        let output = """
        Quota:
        Gemini Models Weekly Limit Remaining 94% 2026-09-12T01:47:23Z
        Gemini Models Five Hour Limit Remaining 78% 2026-09-10T06:12:31Z
        Claude and GPT models Weekly Limit Remaining 100% 2026-09-17T01:47:23Z
        Claude and GPT models Five Hour Limit Remaining 100% 2026-09-10T08:13:44Z
        """
        let windows = try AntigravityUsageCLI.parse(output)
        XCTAssertEqual(windows.map(\.id), ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])
        XCTAssertEqual(try XCTUnwrap(windows[0].usedFraction), 0.22, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(windows[1].usedFraction), 0.06, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(windows[2].usedFraction), 0.0, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(windows[3].usedFraction), 0.0, accuracy: 1e-5)
        XCTAssertEqual(windows[0].duration, 5 * 3600)
        XCTAssertEqual(windows[1].duration, 7 * 86_400)
        XCTAssertTrue(windows.allSatisfy { $0.resetsAt != nil })
    }

    func testParsesTSVOutputWithArgonAndANSIStripping() throws {
        let tsv = "\u{1B}[32mGemini Models\tWeekly Limit Remaining\t100%\t2026-10-31T21:02:20Z\u{1B}[0m\r\n"
            + "Gemini Models\tFive Hour Limit Remaining\t80%\t2026-10-25T02:02:20Z\r\n"
            + "Claude and GPT models\tWeekly Limit Remaining\t100%\t2026-10-31T22:31:55Z\r\n"
            + "Claude and GPT models\tFive Hour Limit Remaining\t100%\t2026-10-25T03:31:55Z\r\n"
            + "Gemini 4 Argon\tGemini 4 Argon Weekly Limit\t64%\t2026-10-31T20:59:36Z\r\n"

        let windows = try AntigravityUsageCLI.parse(tsv)
        XCTAssertEqual(windows.map(\.id), ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly", "3p-argon-weekly"])
        XCTAssertEqual(try XCTUnwrap(windows[0].usedFraction), 0.20, accuracy: 1e-5)
        XCTAssertEqual(windows[4].label, "Argon")
        XCTAssertEqual(try XCTUnwrap(windows[4].usedFraction), 0.36, accuracy: 1e-5)
    }

    func testParsesNumericOffsetAndUTCResetTimes() throws {
        let output = """
        Quota:
        Gemini Models          Weekly Limit Remaining     51%   2026-10-08 07:23 +07
        Gemini Models          Five Hour Limit Remaining  79%   2026-10-07 12:49 +0530
        Claude and GPT models  Weekly Limit Remaining     98%   2026-10-11 06:00 UTC
        """
        let windows = try AntigravityUsageCLI.parse(output)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0].resetsAt, AntigravityCredentials.parse("2026-10-07T07:19:00Z"))
        XCTAssertEqual(windows[1].resetsAt, AntigravityCredentials.parse("2026-10-08T00:23:00Z"))
        XCTAssertEqual(windows[2].resetsAt, AntigravityCredentials.parse("2026-10-11T06:00:00Z"))
    }

    func testRejectsMalformedAndOutOfRangeQuotaOutput() {
        let valid = "Quota:\nGemini Models Weekly Limit Remaining 94% 2026-09-12T01:47:23Z"
        for bad in [
            "",
            "authentication required",
            "Quota:\nunknown",
            valid.replacingOccurrences(of: "94%", with: "101%"),
            valid.replacingOccurrences(of: "94%", with: "-5%"),
            valid.replacingOccurrences(of: "94%", with: "NaN%"),
            valid.replacingOccurrences(of: "2026-09-12T01:47:23Z", with: "not-a-date"),
            valid.replacingOccurrences(of: "2026-09-12T01:47:23Z", with: "2026-10-10 22:31 +15"),
        ] {
            XCTAssertThrowsError(try AntigravityUsageCLI.parse(bad), "Should reject: \(bad)")
        }
    }

    func testLocatesAgyInHomeLocalBin() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityCLILocate-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let agy = bin.appendingPathComponent("agy")
        try Data("#!/bin/sh\n".utf8).write(to: agy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)

        let located = AntigravityUsageCLI.locate(home: home, root: home.appendingPathComponent("empty-root"), path: "")
        XCTAssertEqual(located?.binary.path, agy.path)
    }

    func testDecodesGoogleOAuthJSONWithRFC3339Expiry() throws {
        let json = Data("""
        {
          "access_token": "ya29.google-oauth",
          "refresh_token": "1//refresh",
          "client_id": "client.apps.googleusercontent.com",
          "client_secret": "secret",
          "expiry": "2126-08-31T21:53:49Z",
          "email": "dev@example.com"
        }
        """.utf8)
        let creds = try XCTUnwrap(AntigravityCredentials.decodeACP(json))
        XCTAssertEqual(creds.accessToken, "ya29.google-oauth")
        XCTAssertEqual(creds.refreshToken, "1//refresh")
        XCTAssertEqual(creds.email, "dev@example.com")
        XCTAssertFalse(creds.isExpired)
    }

    func testCLISourceReadsFromAgyWithoutTouchingIDEOrGoogle() async throws {
        let cli = AntigravityUsageCLI(binary: URL(fileURLWithPath: "/usr/local/bin/agy")) {
            """
            Quota:
            Gemini Models Five Hour Limit Remaining 75% 2026-10-10T12:00:00Z
            Gemini Models Weekly Limit Remaining 90% 2026-10-15T12:00:00Z
            """
        }
        let provider = AntigravityProvider(
            session: URLSession.shared,
            usageCLI: cli,
            source: { .cli }
        )

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.windows.map(\.id), ["gemini-5h", "gemini-weekly"])
        XCTAssertEqual(try XCTUnwrap(snapshot.windows.first?.usedFraction), 0.25, accuracy: 1e-5)
    }

    func testOAuthSourceRefreshesExpiredTokenAndCallsCloudCodeDirectly() async throws {
        final class OAuthStub: URLProtocol {
            nonisolated(unsafe) static var paths: [String] = []

            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                let url = request.url!
                Self.paths.append(url.path)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data: Data
                if url.host == "oauth2.googleapis.com" {
                    data = Data(#"{"access_token":"ya29.refreshed","expires_in":3600}"#.utf8)
                } else {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ya29.refreshed")
                    data = Data("""
                    {"groups":[{"displayName":"Gemini Models","buckets":[
                      {"bucketId":"gemini-5h","displayName":"5-hour Limit","remainingFraction":0.8,"resetTime":"2026-10-10T12:00:00Z"}
                    ]}]}
                    """.utf8)
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }

            override func stopLoading() {}
        }

        OAuthStub.paths = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthStub.self]
        let session = URLSession(configuration: config)

        let expired = AntigravityCredentials(
            accessToken: "",
            expiresAt: Date.distantPast,
            authMethod: "consumer",
            projectId: "proj-1",
            email: "dev@example.com",
            refreshToken: "1//refresh-token",
            clientID: "cid",
            clientSecret: "csec",
            tokenURI: "https://oauth2.googleapis.com/token",
            sourceName: "Google OAuth"
        )

        let provider = AntigravityProvider(
            session: session,
            usageCLI: nil,
            source: { .oauth },
            oauthCredentials: { expired }
        )

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.windows.map(\.id), ["gemini-5h"])
        XCTAssertEqual(try XCTUnwrap(snapshot.windows.first?.usedFraction), 0.2, accuracy: 1e-5)
        XCTAssertEqual(OAuthStub.paths.first, "/token")
        XCTAssertTrue(OAuthStub.paths.contains(where: { $0.contains("retrieveUserQuotaSummary") }))
    }

    func testDiscoverCLIIgnoresIDELanguageServer() {
        let table = """
        29283 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token abc
        """
        XCTAssertNil(AntigravityBridge.discoverCLI(processTable: table, listeningPorts: { _ in [63881] }))
    }

    func testSwitchingSourceInvalidatesCachedCLIReading() async throws {
        final class State: @unchecked Sendable {
            private let lock = NSLock()
            var source: AntigravitySource = .cli
            var cliCalls = 0
            func nextCLI() -> String {
                lock.lock(); defer { lock.unlock() }
                cliCalls += 1
                let remaining = cliCalls == 1 ? 80 : 60
                return "Quota:\nGemini Models Five Hour Limit Remaining \(remaining)% 2026-10-10T12:00:00Z"
            }
            func currentSource() -> AntigravitySource {
                lock.lock(); defer { lock.unlock() }
                return source
            }
            func setSource(_ value: AntigravitySource) {
                lock.lock(); source = value; lock.unlock()
            }
        }

        let state = State()
        let cli = AntigravityUsageCLI(binary: URL(fileURLWithPath: "/usr/local/bin/agy")) {
            state.nextCLI()
        }
        let provider = AntigravityProvider(
            session: URLSession.shared,
            usageCLI: cli,
            source: { state.currentSource() }
        )

        let first = try await provider.fetchSnapshot()
        XCTAssertEqual(try XCTUnwrap(first.windows.first?.usedFraction), 0.20, accuracy: 1e-5)

        // Switch away to .oauth (fails with needsAuth since no creds), then back to .cli:
        // cached CLI reading must be cleared so the next .cli read invokes the CLI fresh.
        state.setSource(.oauth)
        _ = try? await provider.fetchSnapshot()

        state.setSource(.cli)
        let second = try await provider.fetchSnapshot()
        XCTAssertEqual(try XCTUnwrap(second.windows.first?.usedFraction), 0.40, accuracy: 1e-5)
    }
}
