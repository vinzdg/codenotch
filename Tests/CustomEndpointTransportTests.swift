import XCTest
@testable import Codenotch

final class CustomEndpointTransportTests: XCTestCase {
    func testSharedAddressSpaceHTTPExceptionShipsInTheAppBundle() throws {
        let ats = try XCTUnwrap(Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertNotEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
        let domains = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: [String: Any]])
        XCTAssertEqual(Set(domains.keys), ["100.64.0.0/10"])
        let shared = try XCTUnwrap(domains["100.64.0.0/10"])
        XCTAssertEqual(shared["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true)
        XCTAssertNil(shared["NSExceptionMinimumTLSVersion"])
        XCTAssertNil(shared["NSExceptionRequiresForwardSecrecy"])
    }
}
