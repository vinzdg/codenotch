import XCTest
@testable import Codenotch

final class DeepSeekBalanceTests: XCTestCase {
    private func window(_ json: String) throws -> LimitWindow {
        try DeepSeekBalance.window(from: Data(json.utf8))
    }

    func testABalanceIsShownWithoutAPercentage() throws {
        let window = try window(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"8.75","granted_balance":"1.25","topped_up_balance":"7.50"}]}"#)
        XCTAssertEqual(window.usedText, "¥8.75")
        XCTAssertNil(window.usedFraction)
        XCTAssertTrue(window.prefersUsedText)
        XCTAssertEqual(window.detail?.contains("¥7.50"), true)
        XCTAssertEqual(window.detail?.contains("¥1.25"), true)
    }

    func testAnEmptyBalanceFillsTheRing() throws {
        let window = try window(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}"#)
        XCTAssertEqual(window.usedFraction, 1)
        XCTAssertEqual(window.usedText, "¥0.00")
    }

    func testAnUnavailableAccountFillsTheRingEvenWithABalance() throws {
        let window = try window(#"{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"3.00"}]}"#)
        XCTAssertEqual(window.usedFraction, 1)
        XCTAssertEqual(window.usedText, "$3.00")
    }

    func testTheLargestCurrencyIsShown() throws {
        let window = try window(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"0.00"},{"currency":"CNY","total_balance":"20.00"}]}"#)
        XCTAssertEqual(window.usedText, "¥20.00")
    }

    func testNoBalanceIsAnError() {
        XCTAssertThrowsError(try window(#"{"is_available":true,"balance_infos":[]}"#))
    }
}

final class DeepSeekCredentialsTests: XCTestCase {
    func testTheEnvironmentWinsOverTheKeychain() {
        let key = DeepSeekCredentials.loadAPIKey(environment: ["DEEPSEEK_API_KEY": " sk-env "],
                                                 keychain: { "sk-keychain" })
        XCTAssertEqual(key, "sk-env")
    }

    func testABlankEnvironmentFallsBackToTheKeychain() {
        let key = DeepSeekCredentials.loadAPIKey(environment: ["DEEPSEEK_API_KEY": "  "],
                                                 keychain: { "sk-keychain" })
        XCTAssertEqual(key, "sk-keychain")
    }

    func testNoKeyAnywhereIsNil() {
        XCTAssertNil(DeepSeekCredentials.loadAPIKey(environment: [:], keychain: { nil }))
    }
}

@MainActor
final class DeepSeekProviderTests: XCTestCase {
    private func provider(source: DeepSeekSource, key: String?) -> DeepSeekProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepSeekBalanceEndpoint.self]
        return DeepSeekProvider(web: WebSessionProvider(site: Sites.deepSeek),
                                session: URLSession(configuration: configuration),
                                source: { source },
                                loadAPIKey: { key })
    }

    func testAKeyReadsTheBalanceAsAnOfficialReading() async throws {
        DeepSeekBalanceEndpoint.reset(status: 200, body: #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"8.75"}]}"#)
        let snapshot = try await provider(source: .apiKey, key: "sk-test").fetchSnapshot()

        XCTAssertEqual(snapshot.id, "deepseek")
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.headline?.usedText, "¥8.75")
        XCTAssertNil(snapshot.usageDetail)
        let request = try XCTUnwrap(DeepSeekBalanceEndpoint.lastRequest)
        XCTAssertEqual(request.url, DeepSeekBalance.url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testARefusedKeyReadsAsSignedOut() async {
        DeepSeekBalanceEndpoint.reset(status: 401, body: #"{"error":{"message":"Authentication Fails"}}"#)
        await assertNeedsAuth(provider(source: .apiKey, key: "sk-revoked"))
    }

    func testNoKeyReadsAsSignedOutWithoutARequest() async {
        DeepSeekBalanceEndpoint.reset(status: 200, body: "{}")
        await assertNeedsAuth(provider(source: .apiKey, key: nil))
        XCTAssertNil(DeepSeekBalanceEndpoint.lastRequest)
    }

    func testTheSignInRouteFollowsTheSource() {
        guard case .modal = provider(source: .web, key: nil).signInRoute else {
            return XCTFail("the sign-in should open the Codenotch window")
        }
        guard case .guidance = provider(source: .apiKey, key: nil).signInRoute else {
            return XCTFail("a key has no window to open")
        }
    }

    private func assertNeedsAuth(_ provider: DeepSeekProvider,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth", file: file, line: line)
        } catch UsageProviderError.needsAuth {
        } catch {
            XCTFail("expected needsAuth, got \(error)", file: file, line: line)
        }
    }
}

private final class DeepSeekBalanceEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var reply = (status: 200, body: "{}")
    private static var recorded: URLRequest?
    static var lastRequest: URLRequest? { lock.withLock { recorded } }

    static func reset(status: Int, body: String) {
        lock.withLock { reply = (status, body); recorded = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { () -> (status: Int, body: String) in
            Self.recorded = request
            return Self.reply
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
