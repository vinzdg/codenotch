import XCTest
@testable import Codenotch

@MainActor
final class AmpProviderTests: XCTestCase {
    private var directory: URL!
    private var secretsURL: URL!
    private var archive: UsageArchive!
    private var session: URLSession!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("amp-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        secretsURL = directory.appendingPathComponent("secrets.json")
        try #"{"apiKey@https://ampcode.com/":"sgamp_fixture"}"#.write(to: secretsURL, atomically: true, encoding: .utf8)
        let suite = "AmpProviderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        archive = UsageArchive(defaults: defaults)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AmpEndpoint.self]
        session = URLSession(configuration: config)
        AmpEndpoint.reset([])
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try FileManager.default.removeItem(at: directory)
        AmpEndpoint.reset([])
    }

    private func provider(at now: Date? = nil) -> AmpProvider {
        let value = now ?? date
        return AmpProvider(session: session, archive: archive, secretsURL: secretsURL, now: { value })
    }

    func testLiveAmpUsageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODENOTCH_TEST_AMP_LIVE"] == "1" else {
            throw XCTSkip("Opt-in live check requires a signed-in Amp CLI")
        }
        let liveSession = URLSession(configuration: .ephemeral)
        defer { liveSession.invalidateAndCancel() }
        let provider = AmpProvider(session: liveSession, archive: archive)
        let store = UsageStore(providers: [provider], archive: archive)
        await store.refresh()
        let snapshot = try XCTUnwrap(store.snapshots.first)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.id, "amp")
        XCTAssertNotNil(snapshot.usedFraction)
        XCTAssertNotNil(provider.account())
        print("Amp live headline: \(snapshot.headlineText), fidelity: \(snapshot.fidelity.rawValue)")
        for window in snapshot.windows {
            print("Amp live \(window.id): \(window.detail ?? window.summary)")
        }
    }

    func testRequestAndSnapshotUseTheAmpContract() async throws {
        AmpEndpoint.reset([.http(200, AmpFixture.subscription)])
        let snapshot = try await provider().fetchSnapshot()
        XCTAssertEqual(snapshot.id, "amp")
        XCTAssertEqual(snapshot.displayName, "Amp")
        XCTAssertEqual(snapshot.glyph, .amp)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.headlineID, "agent")
        XCTAssertEqual(snapshot.headlineText, "25%")
        XCTAssertNil(snapshot.weeklyID, "Orb usage is not a weekly allowance")
        XCTAssertEqual(snapshot.plan, "Megawatt")
        let request = try XCTUnwrap(AmpEndpoint.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://ampcode.com/api/internal")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sgamp_fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertFalse(request.httpShouldHandleCookies)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["method"] as? String, "userDisplayBalanceInfo")
        XCTAssertEqual(body["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(body["id"] as? Int, 1)
        XCTAssertEqual((body["params"] as? [String: String]), [:])
    }

    func testFreePlanDoesNotAcquireAnOrbOrWeeklyRing() async throws {
        AmpEndpoint.reset([.http(200, AmpFixture.free)])
        let snapshot = try await provider().fetchSnapshot()
        XCTAssertEqual(snapshot.fidelity, .derived)
        XCTAssertEqual(snapshot.headlineID, "free")
        XCTAssertEqual(snapshot.headlineText, "55%")
        XCTAssertNil(snapshot.weeklyWindow)
        XCTAssertFalse(snapshot.windows.contains { $0.id == "orb" })
    }

    func testMissingLoginDoesNotTouchTheNetworkAndExplainsWhereToSignIn() async throws {
        try FileManager.default.removeItem(at: secretsURL)
        let provider = provider()
        let store = UsageStore(providers: [provider], archive: archive)
        await store.refresh()
        let snapshot = try XCTUnwrap(store.snapshots.first)
        XCTAssertEqual(snapshot.status, .needsAuth)
        XCTAssertFalse(snapshot.hasReading)
        XCTAssertEqual(snapshot.statusMessage, "Run amp login in Terminal to read your usage")
        XCTAssertNil(provider.account())
        XCTAssertTrue(provider.signInRoute.explanation.contains("amp login"))
        XCTAssertTrue(AmpEndpoint.requests.isEmpty)
    }

    func testAuthenticationFailuresClearOldReadings() async throws {
        for status in [401, 403] {
            AmpEndpoint.reset([.http(200, AmpFixture.subscription), .http(status, Data())])
            let store = UsageStore(providers: [provider()], archive: archive)
            await store.refresh()
            XCTAssertEqual(store.snapshots.first?.headlineText, "25%")
            await store.refresh()
            XCTAssertEqual(store.snapshots.first?.status, .needsAuth)
            XCTAssertFalse(store.snapshots.first?.hasReading ?? true)
        }
    }

    func testServerNetworkAndParsingFailuresKeepAnHonestStaleReading() async throws {
        for failure in [AmpEndpoint.Reply.http(500, Data()), .failure(.notConnectedToInternet),
                        .failure(.timedOut), .http(200, Data("{}".utf8))] {
            AmpEndpoint.reset([.http(200, AmpFixture.subscription), failure])
            let store = UsageStore(providers: [provider()], staleAfter: -1, archive: archive)
            await store.refresh()
            await store.refresh()
            XCTAssertEqual(store.snapshots.first?.headlineText, "25%")
            XCTAssertTrue(store.snapshots.first?.status.isStale ?? false)
        }
    }

    func testAFailureBeforeAnyReadingShowsAnErrorWithoutANumber() async throws {
        AmpEndpoint.reset([.http(200, Data("{}".utf8))])
        let store = UsageStore(providers: [provider()], archive: archive)
        await store.refresh()
        let snapshot = try XCTUnwrap(store.snapshots.first)
        guard case .error = snapshot.status else { return XCTFail("expected a visible error") }
        XCTAssertEqual(snapshot.headlineText, "—")
        XCTAssertFalse(snapshot.hasReading)
    }

    func testRateLimitHonorsTheServerHintAcrossRelaunchAndClearsAfterSuccess() async throws {
        AmpEndpoint.reset([.http(429, Data(), ["Retry-After": "120"]), .http(200, AmpFixture.subscription)])
        let current = provider()
        for _ in 0..<2 {
            do {
                _ = try await current.fetchSnapshot()
                XCTFail("expected rateLimited")
            } catch UsageProviderError.rateLimited(let delay) {
                XCTAssertEqual(delay, 120)
            }
        }
        // Construct after the first response, like an actual relaunch.
        do {
            _ = try await provider().fetchSnapshot()
            XCTFail("expected persisted backoff")
        } catch UsageProviderError.rateLimited { }
        XCTAssertEqual(AmpEndpoint.requests.count, 1)
        XCTAssertEqual(archive.loadBackoffUntil(providerID: "amp"), date.addingTimeInterval(120))
        _ = try await provider(at: date.addingTimeInterval(121)).fetchSnapshot()
        XCTAssertEqual(AmpEndpoint.requests.count, 2)
        XCTAssertNil(archive.loadBackoffUntil(providerID: "amp"))
    }

    func testRateLimitHasAMinimumAndAcceptsHTTPDates() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        for (header, expected) in [("0", 60.0), ("invalid", 60.0), ("NaN", 60.0),
                                   (formatter.string(from: date.addingTimeInterval(300)), 300.0)] {
            archive.saveBackoffUntil(nil, providerID: "amp")
            AmpEndpoint.reset([.http(429, Data(), ["Retry-After": header])])
            do {
                _ = try await provider().fetchSnapshot()
                XCTFail("expected rateLimited")
            } catch UsageProviderError.rateLimited(let delay) {
                XCTAssertEqual(delay, expected, accuracy: 0.1)
            }
        }
    }

    func testRefreshFollowsRotatedCredentialsAndDisconnectLeavesThemAlone() async throws {
        AmpEndpoint.reset([.http(200, AmpFixture.subscription), .http(200, AmpFixture.free)])
        let provider = provider()
        _ = try await provider.fetchSnapshot()
        try #"{"apiKey@https://ampcode.com/":"sgamp_rotated"}"#.write(to: secretsURL, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: secretsURL)
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(AmpEndpoint.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer sgamp_rotated")
        XCTAssertEqual(provider.account()?.source, "Amp CLI")
        await provider.signOut()
        XCTAssertEqual(try Data(contentsOf: secretsURL), before)
        let store = UsageStore(providers: [provider], archive: archive, disconnected: ["amp"])
        await store.refresh()
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertEqual(AmpEndpoint.requests.count, 2)
    }
}

private final class AmpEndpoint: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(Int, Data, [String: String] = [:])
        case failure(URLError.Code)
    }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func reset(_ values: [Reply]) {
        lock.withLock { replies = values; recorded = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var copy = request
        if let stream = copy.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            copy.httpBody = data
        }
        let reply = Self.lock.withLock { () -> Reply? in
            Self.recorded.append(copy)
            return Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        }
        switch reply {
        case .http(let status, let data, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            XCTFail("unexpected Amp request")
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
    }
    override func stopLoading() {}
}
