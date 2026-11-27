import XCTest
@testable import Codenotch

@MainActor
final class MiMoProviderTests: XCTestCase {
    private func provider(key: String?, web: WebSessionProvider? = nil) -> MiMoProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MiMoBalanceEndpointMock.self]
        return MiMoProvider(
            web: web,
            session: URLSession(configuration: configuration),
            loadAPIKey: { key }
        )
    }

    func testMetadata() {
        let p = provider(key: nil)
        XCTAssertEqual(p.id, "mimo")
        XCTAssertEqual(p.displayName, "MiMo")
        XCTAssertEqual(p.glyph, ProviderGlyph.mimo)
    }

    func testFetchesBalanceWithAPIKey() async throws {
        let json = """
        {
          "object": "balance",
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "cash_balance": "100.50",
              "gift_balance": "20.00",
              "frozen_balance": "0.00",
              "credit_limit": "500.00",
              "credit_available": "380.00",
              "total_available": "500.50"
            }
          ]
        }
        """
        MiMoBalanceEndpointMock.reset(status: 200, body: json)
        let snapshot = try await provider(key: "sk-test-key").fetchSnapshot()

        XCTAssertEqual(snapshot.id, "mimo")
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.headlineID, "balance")

        let balanceWindow = try XCTUnwrap(snapshot.windows.first { $0.id == "balance" })
        XCTAssertEqual(balanceWindow.label, "Balance")
        let money = try XCTUnwrap(balanceWindow.money)
        XCTAssertEqual(money.currency, "CNY")
        XCTAssertEqual(money.remaining, 500.50, accuracy: 0.001)
        XCTAssertEqual(money.spent, 120.0, accuracy: 0.001)

        let request = try XCTUnwrap(MiMoBalanceEndpointMock.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.xiaomimimo.com/v1/platform/balance")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-key")
    }

    func testThrowsNeedsAuthOn401() async {
        MiMoBalanceEndpointMock.reset(status: 401, body: #"{"error":"Unauthorized"}"#)
        do {
            _ = try await provider(key: "sk-invalid").fetchSnapshot()
            XCTFail("Expected needsAuth error")
        } catch UsageProviderError.needsAuth {
            // Success
        } catch {
            XCTFail("Expected needsAuth, got \(error)")
        }
    }

    func testThrowsNeedsAuthWhenNoCredentialsAndNoWeb() async {
        do {
            _ = try await provider(key: nil, web: nil).fetchSnapshot()
            XCTFail("Expected needsAuth error")
        } catch UsageProviderError.needsAuth {
            // Success
        } catch {
            XCTFail("Expected needsAuth, got \(error)")
        }
    }

    func testAccountSourceWhenCLICredentialPresent() throws {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimo-auth-\(UUID().uuidString).json")
        try #"{"apiKey":"cli-key"}"#.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Test with CLI credential path
        XCTAssertTrue(MiMoCredentials.isCLICredentialPresent(authURL: tempFile))
    }
}

private final class MiMoBalanceEndpointMock: URLProtocol {
    private static let lock = NSLock()
    private static var reply = (status: 200, body: "{}")
    private static var recorded: URLRequest?
    static var lastRequest: URLRequest? { lock.withLock { recorded } }

    static func reset(status: Int, body: String) {
        lock.withLock {
            reply = (status, body)
            recorded = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.lock.withLock {
            Self.recorded = request
            return Self.reply
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.xiaomimimo.com/v1/platform/balance")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
