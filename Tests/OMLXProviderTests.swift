import XCTest
import SwiftUI
@testable import Codenotch

@MainActor
final class OMLXProviderTests: XCTestCase {
    func testTheListingIsReadWithoutAKeyWhenNoneExists() async throws {
        let requested = expectation(description: "listing")
        let provider = makeProvider(key: nil) { request in
            XCTAssertEqual(request.url?.path, "/v1/models/status")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                         "a server that skips key verification must not be sent one")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.timeoutInterval, 3)
            requested.fulfill()
            return (200, Data(OMLXFixtures.listing.utf8))
        }
        let snapshot = try await provider.fetchSnapshot()
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(snapshot.kind, .localRuntime)
        XCTAssertEqual(snapshot.id, "omlx")
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.notchSnapshots.map(\.id), ["omlx:model:Qwen3.8-27B-oQ8e-mtp"])
        XCTAssertNil(provider.account())
        XCTAssertFalse(provider.isVisibleWhenAbsent)
        XCTAssertEqual(provider.signInRoute, .openApp(bundleID: "app.omlx", name: "oMLX"))
    }

    func testTheListingIsAnsweredFromMemoryForAFewSeconds() async throws {
        var requests = 0
        var clock = Date(timeIntervalSince1970: 1_000)
        OMLXStubProtocol.handler = { _ in requests += 1; return (200, Data(OMLXFixtures.listing.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OMLXStubProtocol.self]
        let provider = OMLXLocalProvider(endpoint: URL(string: OMLXEndpoint.defaultAddress)!,
                                         session: URLSession(configuration: configuration), key: { nil },
                                         inventoryInterval: 5, now: { clock })
        _ = try await provider.fetchSnapshot()
        clock.addTimeInterval(1)
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(requests, 1, "a second-old listing is answered from memory")
        clock.addTimeInterval(5)
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(requests, 2)
        provider.endpoint = try OMLXEndpoint.parse("http://127.0.0.1:8123")
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(requests, 3, "a new address is never answered from the old one's memory")
    }

    func testAKeyIsSentAsABearer() async throws {
        let provider = makeProvider(key: "test-key") { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            return (200, Data(#"{"models":[]}"#.utf8))
        }
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertTrue(snapshot.hasReading)
    }

    func testARefusalSaysAKeyIsNeededRatherThanSignedOut() async {
        for status in [401, 403] {
            let provider = makeProvider(key: nil) { _ in
                (status, Data(#"{"detail":"API key required"}"#.utf8))
            }
            do {
                _ = try await provider.fetchSnapshot()
                XCTFail("HTTP \(status) succeeded")
            } catch {
                XCTAssertEqual(error as? OMLXError, .needsKey)
                XCTAssertTrue(error.localizedDescription.contains("settings.json"))
            }
        }
    }

    func testOtherFailuresStayVisible() async {
        for status in [301, 404, 500] {
            let provider = makeProvider(key: nil) { _ in (status, Data()) }
            do {
                _ = try await provider.fetchSnapshot()
                XCTFail("HTTP \(status) succeeded")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("HTTP \(status)"))
            }
        }
        let wrongService = makeProvider(key: nil) { _ in (200, Data(#"{"detail":"Not Found"}"#.utf8)) }
        do {
            _ = try await wrongService.fetchSnapshot()
            XCTFail("An error body succeeded")
        } catch {
            XCTAssertEqual(error as? OMLXError, .invalidResponse)
        }
        let down = makeProvider(key: nil) { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await down.fetchSnapshot()
            XCTFail("A refused connection succeeded")
        } catch {
            XCTAssertEqual(error as? OMLXError, .unavailable)
            XCTAssertTrue(error.localizedDescription.contains("unavailable"))
        }
        let cancelled = makeProvider(key: nil) { _ in throw URLError(.cancelled) }
        do {
            _ = try await cancelled.fetchSnapshot()
            XCTFail("Cancelled request succeeded")
        } catch is CancellationError {
        } catch {
            XCTFail("Cancellation became \(error)")
        }
    }

    func testTheStoreClearsTheReadingWhenTheAddressChangesAndDoesNotEnableMonitoring() throws {
        let provider = OMLXLocalProvider(endpoint: try OMLXEndpoint.parse(OMLXEndpoint.defaultAddress))
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: isolatedDefaults()),
                               disconnected: ["omlx"])
        let updated = try OMLXEndpoint.parse("http://127.0.0.1:8123")
        store.updateOMLXEndpoint(updated)
        XCTAssertEqual(provider.endpoint, updated)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.refreshing.isEmpty)
    }

    func testTheEndpointPreferenceIsLoopbackOnlyAndPersists() {
        let defaults = isolatedDefaults()
        let fresh = Preferences(defaults: defaults)
        XCTAssertFalse(fresh.isConnected("omlx"), "off until switched on; nothing shows until oMLX answers")
        XCTAssertNoThrow(try OMLXEndpoint.parse(fresh.omlxEndpoint))
        XCTAssertTrue(fresh.omlxEndpoint.hasPrefix("http://127.0.0.1:"))
        fresh.omlxEndpoint = "http://127.0.0.1:8123"
        XCTAssertEqual(Preferences(defaults: defaults).omlxEndpoint, "http://127.0.0.1:8123")
        defaults.set("http://10.0.0.1:8000", forKey: "omlxEndpoint")
        XCTAssertEqual(Preferences(defaults: defaults).omlxEndpoint, OMLXEndpoint.defaultAddress,
                       "a stored remote address is not honoured")
    }

    func testTheGlyphAssetRendersAsAMarkNotASquare() throws {
        let asset = try XCTUnwrap(NSImage(named: ProviderGlyph.omlx.assetName))
        XCTAssertGreaterThan(asset.size.width, 0)
        let renderer = ImageRenderer(content: ProviderGlyphView(glyph: .omlx, size: 32).foregroundStyle(.white))
        let data = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var ink = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { ink += 1 }
        }
        let coverage = Double(ink) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
        XCTAssertGreaterThan(coverage, 0.05)
        XCTAssertLessThan(coverage, 0.85)
    }

    private func makeProvider(key: String?, _ handler: @escaping (URLRequest) throws -> (Int, Data)) -> OMLXLocalProvider {
        OMLXStubProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OMLXStubProtocol.self]
        return OMLXLocalProvider(endpoint: URL(string: OMLXEndpoint.defaultAddress)!,
                                 session: URLSession(configuration: configuration), key: { key })
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "OMLXProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

private final class OMLXStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!,
                statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
