import XCTest
@testable import Codenotch

/// The token path of `GrokLocalProvider`: what it presents to the billing
/// endpoint once the session in `~/.grok/auth.json` has expired.
///
/// The one invariant every test here holds is that the file is never
/// written. A renewed token lives in the actor; the file stays the CLI's.
final class GrokLocalProviderTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokLocalProviderTests.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        GrokEndpoint.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        GrokEndpoint.reset()
        super.tearDown()
    }

    /// The token the CLI wrote is still good: no renewal, no other bearer.
    func testALiveSessionIsPresentedAsIs() async throws {
        let authURL = try authFile(token: "live-token", expiresIn: 3600)
        GrokEndpoint.billing = [.init(status: 200, body: Self.credits)]
        let provider = GrokLocalProvider(session: GrokEndpoint.session(), authURL: authURL)

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(GrokEndpoint.tokenRequests.count, 0)
        XCTAssertEqual(GrokEndpoint.bearers, ["live-token"])
    }

    /// An expired session is renewed with the file's own refresh token and
    /// client id, the way the CLI would — and the file is left exactly as
    /// the CLI wrote it.
    func testAnExpiredSessionIsRenewedInMemoryAndTheFileIsLeftAlone() async throws {
        let authURL = try authFile(token: "stale-token", expiresIn: -60)
        let before = try Data(contentsOf: authURL)
        GrokEndpoint.token = [.init(status: 200, body: Self.minted("fresh-token"))]
        GrokEndpoint.billing = [.init(status: 200, body: Self.credits)]
        let provider = GrokLocalProvider(session: GrokEndpoint.session(), authURL: authURL)

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.usedFraction ?? -1, 0.14, accuracy: 0.0001)
        XCTAssertEqual(GrokEndpoint.bearers, ["fresh-token"])
        XCTAssertEqual(GrokEndpoint.tokenRequests,
                       ["grant_type=refresh_token&refresh_token=refresh-abc&client_id=client-123"])
        XCTAssertEqual(try Data(contentsOf: authURL), before, "auth.json was written")
    }

    /// One renewal serves every tick until the minted token itself expires:
    /// the file stays expired between polls, and asking the issuer every
    /// five minutes would be the polling the CLI never does.
    func testARenewedTokenIsReusedAcrossTicks() async throws {
        let authURL = try authFile(token: "stale-token", expiresIn: -60)
        GrokEndpoint.token = [.init(status: 200, body: Self.minted("fresh-token"))]
        GrokEndpoint.billing = [.init(status: 200, body: Self.credits),
                                .init(status: 200, body: Self.credits)]
        let provider = GrokLocalProvider(session: GrokEndpoint.session(), authURL: authURL)

        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(GrokEndpoint.tokenRequests.count, 1)
        XCTAssertEqual(GrokEndpoint.bearers, ["fresh-token", "fresh-token"])
    }

    /// Once the CLI has renewed the file itself, its token wins — ours is
    /// stale by definition.
    func testTheFilesOwnTokenWinsOnceTheCLIRenewsIt() async throws {
        let authURL = try authFile(token: "stale-token", expiresIn: -60)
        GrokEndpoint.token = [.init(status: 200, body: Self.minted("fresh-token"))]
        GrokEndpoint.billing = [.init(status: 200, body: Self.credits),
                                .init(status: 200, body: Self.credits)]
        let provider = GrokLocalProvider(session: GrokEndpoint.session(), authURL: authURL)

        _ = try await provider.fetchSnapshot()
        _ = try authFile(token: "cli-renewed-token", expiresIn: 3600, at: authURL)
        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(GrokEndpoint.bearers, ["fresh-token", "cli-renewed-token"])
    }

    /// A refused renewal is the status the ring already knows how to show for
    /// an expired session, and the billing endpoint is not asked with a token
    /// known to be dead.
    func testARefusedRenewalIsCredentialExpired() async throws {
        let authURL = try authFile(token: "stale-token", expiresIn: -60)
        GrokEndpoint.token = [.init(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))]
        let provider = GrokLocalProvider(session: GrokEndpoint.session(), authURL: authURL)

        await assertCredentialExpired(from: provider)
        XCTAssertEqual(GrokEndpoint.bearers, [])
    }

    /// A file from before the CLI stored a refresh token can only be renewed
    /// by `grok login` — the answer it always gave.
    func testAFileWithoutARefreshTokenIsStillCredentialExpired() async throws {
        let authURL = try authFile(token: "stale-token", expiresIn: -60, refreshToken: nil)
        let provider = GrokLocalProvider(session: GrokEndpoint.session(), authURL: authURL)

        await assertCredentialExpired(from: provider)
        XCTAssertEqual(GrokEndpoint.tokenRequests.count, 0)
    }

    /// The billing endpoint refusing a token minted here must not pin that
    /// token: the next tick renews again.
    func testARefusedMintedTokenIsForgotten() async throws {
        let authURL = try authFile(token: "stale-token", expiresIn: -60)
        GrokEndpoint.token = [.init(status: 200, body: Self.minted("first")),
                              .init(status: 200, body: Self.minted("second"))]
        GrokEndpoint.billing = [.init(status: 401), .init(status: 200, body: Self.credits)]
        let provider = GrokLocalProvider(session: GrokEndpoint.session(), authURL: authURL)

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth")
        } catch UsageProviderError.needsAuth {}
        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(GrokEndpoint.bearers, ["first", "second"])
    }

    // MARK: - Helpers

    private func assertCredentialExpired(from provider: GrokLocalProvider,
                                         file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected credentialExpired", file: file, line: line)
        } catch UsageProviderError.credentialExpired {
        } catch {
            XCTFail("expected credentialExpired, got \(error)", file: file, line: line)
        }
    }

    /// The shape `grok login` writes: keyed by `issuer::client_id`, the
    /// refresh token and client id beside the access token.
    @discardableResult
    private func authFile(token: String, expiresIn: TimeInterval,
                          refreshToken: String? = "refresh-abc", at url: URL? = nil) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var entry: [String: Any] = [
            "key": token,
            "auth_mode": "oidc",
            "email": "someone@example.com",
            "expires_at": formatter.string(from: Date().addingTimeInterval(expiresIn)),
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client-123",
        ]
        if let refreshToken { entry["refresh_token"] = refreshToken }
        let root = ["https://auth.x.ai::client-123": entry]
        let url = url ?? directory.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }

    private static func minted(_ token: String) -> Data {
        Data(#"{"access_token":"\#(token)","refresh_token":"refresh-rotated","expires_in":21600,"token_type":"Bearer"}"#.utf8)
    }

    private static let credits = Data("""
    {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
    "start":"2026-09-28T00:27:25.092884+00:00",\
    "end":"2026-10-05T00:27:25.092884+00:00"},\
    "creditUsagePercent":14.0,\
    "productUsage":[{"product":"GrokBuild","usagePercent":14.0}],\
    "billingPeriodEnd":"2026-10-05T00:27:25.092884+00:00"}}
    """.utf8)
}

/// Answers `auth.x.ai` and `cli-chat-proxy.grok.com` from two queues and keeps
/// what each was asked: the bearer the billing endpoint saw, and the form the
/// token endpoint received.
private final class GrokEndpoint: URLProtocol {
    struct Answer {
        let status: Int
        var body: Data = Data()
    }

    private static let lock = NSLock()
    static var token: [Answer] = []
    static var billing: [Answer] = []
    private(set) static var tokenRequests: [String] = []
    private(set) static var bearers: [String] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        token = []; billing = []; tokenRequests = []; bearers = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokEndpoint.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let answer: Answer
        if request.url?.host == "auth.x.ai" {
            Self.tokenRequests.append(Self.formBody(of: request))
            answer = Self.token.isEmpty ? Answer(status: 500) : Self.token.removeFirst()
        } else {
            let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
            Self.bearers.append(header.replacingOccurrences(of: "Bearer ", with: ""))
            answer = Self.billing.isEmpty ? Answer(status: 500) : Self.billing.removeFirst()
        }
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, never as `httpBody`.
    private static func formBody(of request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
