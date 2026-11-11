import XCTest
@testable import Codenotch

/// Contract for `KiloProvider`'s injectable surface.
///
/// Tests always inject so they never read the real `~/.local/share/kilo`,
/// never hit api.kilo.ai, never write the archive's UserDefaults, and never
/// share `UserDefaults.standard` with the rest of the suite.
///
///     KiloProvider(session: URLSession, archive: UsageArchive,
///                  authURL: URL, baseURL: URL)
///
/// The stub URL protocol answers the queued bodies in order; running dry
/// answers 500, which the provider reports as a bad response rather than
/// retrying forever.
final class KiloProviderTests: XCTestCase {
    override func tearDown() {
        Stub.reset([])
        super.tearDown()
    }

    private static let subscriptionsJSON = """
    {"result":{"data":{"json":[\
    {"id":"sub-1","planId":"p1","planName":"Kilo Pro","providerName":"Anthropic","providerId":"anthropic",\
    "canQueryUsage":true,"hasInstalledByokKey":true,"status":"active","cancelAtPeriodEnd":false}]}}}
    """

    private static let usageJSON = """
    {"result":{"data":{"json":{\
    "schemaVersion":1,\
    "fetchedAt":"2026-09-22T08:00:00.000Z",\
    "subscription":{\
    "id":"sub-1","planName":"Kilo Pro","providerId":"anthropic","providerName":"Anthropic",\
    "windows":[\
    {"id":"five_hour","remainingPercent":75,"resetsAt":"2026-09-22T13:00:00.000Z",\
    "period":{"unit":"hour","value":5}},\
    {"id":"weekly","remainingPercent":40,"resetsAt":"2026-09-28T00:00:00.000Z",\
    "period":{"unit":"week","value":1}}]}}}}}
    """

    private static func authFile(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kilo-auth-\(UUID().uuidString).json")
        try text.data(using: .utf8)!.write(to: url)
        return url
    }

    private static func archive() -> UsageArchive {
        let d = UserDefaults(suiteName: "kilo-tests-\(UUID().uuidString)")!
        return UsageArchive(defaults: d)
    }

    private static func baseURL() -> URL {
        URL(string: "https://kilo.test")!
    }

    private func makeProvider(authJSON: String) throws -> KiloProvider {
        KiloProvider(
            session: Stub.session(),
            archive: Self.archive(),
            authURL: try Self.authFile(authJSON),
            baseURL: Self.baseURL()
        )
    }

    /// The happy path: subscriptions, then usage per plan, then the balance.
    func testAPlanAccountReadsWindowsAndBalance() async throws {
        let provider = try makeProvider(
            authJSON: #"{"kilo":{"type":"oauth","access":"acc","refresh":"r","expires":1}}"#
        )
        Stub.reset([
            (200, Self.subscriptionsJSON),
            (200, Self.usageJSON),
            (200, #"{"balance":14.28}"#),
        ])

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.id, "kilo")
        XCTAssertEqual(snapshot.glyph, .kilo)
        XCTAssertEqual(snapshot.displayName, "Kilo")
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.plan, "Kilo Pro")
        XCTAssertEqual(snapshot.status, .ok)
        // The balance row trails the plan windows; the ring is the shortest
        // quota window, the same subject Claude's session is.
        XCTAssertEqual(snapshot.windows.last?.id, "balance")
        XCTAssertEqual(snapshot.headlineID, "five_hour")
        XCTAssertEqual(snapshot.usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.windows.first?.usedText, nil)
        XCTAssertEqual(snapshot.windows.count, 3)
        // The weekly ring never repeats the headline.
        XCTAssertEqual(snapshot.weeklyID, "weekly")
        XCTAssertEqual(snapshot.weeklyFraction ?? -1, 0.60, accuracy: 0.0001)
    }

    /// An API key reads the balance only: the coding-plan procedures refuse
    /// it, and that is not a sign-out.
    func testAnAPIKeyAccountReadsBalanceOnly() async throws {
        let provider = try makeProvider(
            authJSON: #"{"kilo":{"type":"api","key":"sk-kilo-1"}}"#
        )
        Stub.reset([
            (401, #"{"error":{"message":"unauthorized"}}"#),
            (200, #"{"balance":42.5}"#),
        ])

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.windows.map(\.id), ["balance"])
        XCTAssertEqual(snapshot.headlineID, "balance")
        XCTAssertEqual(snapshot.plan, nil)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.windows[0].usedText, "$42.50")
    }

    /// A measured zero is still a real balance and must remain visible.
    func testZeroBalanceIsShown() async throws {
        let provider = try makeProvider(
            authJSON: #"{"kilo":{"type":"oauth","access":"acc","refresh":"r","expires":1}}"#
        )
        Stub.reset([
            (200, #"{"result":{"data":{"json":[]}}}"#),
            (200, #"{"balance":0}"#),
        ])

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.windows.map(\.id), ["balance"])
        XCTAssertEqual(snapshot.windows[0].usedText, "$0.00")
    }

    func testNoCredentialFileMeansNeedsAuth() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kilo-absent-\(UUID().uuidString).json")
        let provider = KiloProvider(
            session: Stub.session(),
            archive: Self.archive(),
            authURL: missing,
            baseURL: Self.baseURL()
        )

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth")
        } catch let error as UsageProviderError {
            guard case .needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testAccountRequiresTheSameFile() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kilo-absent-\(UUID().uuidString).json")
        let provider = KiloProvider(
            session: Stub.session(),
            archive: Self.archive(),
            authURL: missing,
            baseURL: Self.baseURL()
        )
        XCTAssertNil(provider.account())
    }

    /// A 401 from the balance endpoint is signed out — the last reading is
    /// gone, and the tooltip must ask for a sign-in, not shrug.
    func testUnauthorizedOnTheBalanceIsNeedsAuth() async throws {
        let provider = try makeProvider(
            authJSON: #"{"kilo":{"type":"oauth","access":"acc","refresh":"r","expires":1}}"#
        )
        Stub.reset([
            (200, Self.subscriptionsJSON),
            (200, Self.usageJSON),
            (401, #"{"error":{"message":"expired"}}"#),
        ])

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth")
        } catch let error as UsageProviderError {
            guard case .needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    /// The tRPC error envelope arrives under HTTP 200 — a business failure,
    /// not a reading.
    func testAnErrorEnvelopeIsNotAReading() async throws {
        let provider = try makeProvider(
            authJSON: #"{"kilo":{"type":"oauth","access":"acc","refresh":"r","expires":1}}"#
        )
        Stub.reset([
            (200, #"{"error":{"message":"procedure not found"}}"#),
            (200, #"{"balance":9}"#),
        ])

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected apiError")
        } catch let error as UsageProviderError {
            guard case .apiError = error else {
                return XCTFail("expected apiError, got \(error)")
            }
        }
    }

    func testARateLimitBooksBackoffThatOutlivesTheFetch() async throws {
        let provider = try makeProvider(
            authJSON: #"{"kilo":{"type":"oauth","access":"acc","refresh":"r","expires":1}}"#
        )
        Stub.reset([(429, "no")])

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected rateLimited")
        } catch let error as UsageProviderError {
            guard case .rateLimited(let after) = error else {
                return XCTFail("expected rateLimited, got \(error)")
            }
            XCTAssertGreaterThanOrEqual(after, 60, "the first limit waits at least a minute")
        }
    }

    func testTheBackoffScheduleDoublesAndCaps() {
        XCTAssertEqual(KiloProvider.backoff(forAttempt: 0, retryAfter: nil), 60)
        XCTAssertEqual(KiloProvider.backoff(forAttempt: 2, retryAfter: nil), 240)
        XCTAssertEqual(KiloProvider.backoff(forAttempt: 9, retryAfter: nil), 15 * 60, "capped so it always recovers")
        XCTAssertEqual(KiloProvider.backoff(forAttempt: 0, retryAfter: 300), 300, "the server's hint raises the floor")
        XCTAssertEqual(KiloProvider.backoff(forAttempt: 0, retryAfter: 5), 60, "and never lowers it")
    }

    func testGlyphBasics() {
        XCTAssertEqual(ProviderGlyph.kilo.rawValue, "kilo")
        XCTAssertEqual(ProviderGlyph.kilo.assetName, "glyph-kilo")
        XCTAssertEqual(ProviderGlyph.kilo.outline, GlyphOutline.kilo)
    }
}

private final class Stub: URLProtocol {
    struct Answer {
        let status: Int
        var body: String
    }

    private static let lock = NSLock()
    private static var queued: [Answer] = []
    private static var served = 0

    static func reset(_ answers: [(Int, String)]) {
        lock.lock(); queued = answers.map { Answer(status: $0.0, body: $0.1) }; served = 0; lock.unlock()
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return served
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return URLSession(configuration: configuration)
    }

    private static func next() -> Answer {
        lock.lock(); defer { lock.unlock() }
        served += 1
        // Running dry is a test bug, and a 500 says so more clearly than a
        // crash — the provider under test reports a bad response either way.
        return queued.count > 0 ? queued.removeFirst() : Answer(status: 500, body: "stub exhausted")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override func startLoading() {
        let answer = Self.next()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: answer.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
