import XCTest
@testable import Codenotch

final class OMLXCredentialsTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("OMLXCredentialsTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".omlx"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeSettings(_ json: String) throws {
        try Data(json.utf8).write(to: home.appendingPathComponent(".omlx/settings.json"))
    }

    func testTheEnvironmentKeyWinsAndBlankIsAbsent() throws {
        try writeSettings(#"{"auth":{"api_key":"stored-key","skip_api_key_verification":false}}"#)
        XCTAssertEqual(OMLXCredentials.load(environment: ["OMLX_API_KEY": " test-key\n"], home: home), "test-key")
        XCTAssertEqual(OMLXCredentials.load(environment: ["OMLX_API_KEY": "  "], home: home), "stored-key",
                       "a blank export is no key")
    }

    func testTheKeyIsBorrowedFromOMLXsSettings() throws {
        try writeSettings(#"{"server":{"host":"127.0.0.1","port":8000},"auth":{"api_key":"test-key","skip_api_key_verification":false,"sub_keys":[]}}"#)
        XCTAssertEqual(OMLXCredentials.load(environment: [:], home: home), "test-key")
    }

    func testTheFileIsReadAgainSoARotatedKeyIsSeen() throws {
        try writeSettings(#"{"auth":{"api_key":"test-key"}}"#)
        XCTAssertEqual(OMLXCredentials.load(environment: [:], home: home), "test-key")
        try writeSettings(#"{"auth":{"api_key":"test-key-2"}}"#)
        XCTAssertEqual(OMLXCredentials.load(environment: [:], home: home), "test-key-2")
    }

    func testSkippedVerificationOrNoUsableKeyMeansNoKey() throws {
        try writeSettings(#"{"auth":{"api_key":"test-key","skip_api_key_verification":true}}"#)
        XCTAssertNil(OMLXCredentials.load(environment: [:], home: home), "oMLX ignores keys, so none is sent")
        for settings in [#"{"auth":{"api_key":"  "}}"#, #"{"auth":{"api_key":null}}"#, #"{"auth":{}}"#, "{}", "not json"] {
            try writeSettings(settings)
            XCTAssertNil(OMLXCredentials.load(environment: [:], home: home), settings)
        }
    }

    func testAMissingSettingsFileMeansNoKey() {
        let empty = home.appendingPathComponent("nowhere")
        XCTAssertNil(OMLXCredentials.load(environment: [:], home: empty))
    }

    func testTheConfiguredPortIsReadOnlyForALoopbackReachableBind() throws {
        XCTAssertNil(OMLXEndpoint.configuredAddress(home: home), "no settings, no address")
        for host in ["127.0.0.1", "localhost", "0.0.0.0"] {
            try writeSettings(#"{"server":{"host":"\#(host)","port":8123}}"#)
            XCTAssertEqual(OMLXEndpoint.configuredAddress(home: home), "http://127.0.0.1:8123", host)
        }
        try writeSettings(#"{"server":{"host":"192.168.1.20","port":8123}}"#)
        XCTAssertNil(OMLXEndpoint.configuredAddress(home: home), "a LAN-only bind is not reachable on loopback")
        try writeSettings(#"{"server":{"host":"127.0.0.1","port":0}}"#)
        XCTAssertNil(OMLXEndpoint.configuredAddress(home: home))
        try writeSettings(#"{"server":{"host":"127.0.0.1","port":70000}}"#)
        XCTAssertNil(OMLXEndpoint.configuredAddress(home: home))
        try writeSettings("not json")
        XCTAssertNil(OMLXEndpoint.configuredAddress(home: home))
    }

    func testTheLogDirectoryDefaultsToOMLXsOwnAndFollowsTheSetting() throws {
        XCTAssertEqual(OMLXEndpoint.serverLogsDirectory(home: home).path,
                       home.appendingPathComponent(".omlx/logs").path, "no settings file")
        try writeSettings(#"{"logging":{"log_dir":null,"retention_days":7}}"#)
        XCTAssertEqual(OMLXEndpoint.serverLogsDirectory(home: home).path, home.appendingPathComponent(".omlx/logs").path)
        try writeSettings(#"{"logging":{"log_dir":""}}"#)
        XCTAssertEqual(OMLXEndpoint.serverLogsDirectory(home: home).path, home.appendingPathComponent(".omlx/logs").path)
        try writeSettings(#"{"logging":{"log_dir":"/var/tmp/omlx-logs"}}"#)
        XCTAssertEqual(OMLXEndpoint.serverLogsDirectory(home: home).path, "/var/tmp/omlx-logs")
    }

    func testOnlyLocalHTTPOriginsAreAcceptedAndNormalised() throws {
        XCTAssertEqual(try OMLXEndpoint.parse(" http://localhost:8000/ ").absoluteString, "http://127.0.0.1:8000")
        XCTAssertEqual(try OMLXEndpoint.parse(OMLXEndpoint.defaultAddress).port, 8000)
        XCTAssertEqual(try OMLXEndpoint.parse("http://[::1]:8123").port, 8123)
        for address in ["https://127.0.0.1:8000", "http://10.238.1.89:8000", "http://user:pass@localhost:8000",
                        "http://localhost:8000/v1", "ws://127.0.0.1:8000", "http://localhost:0", ""] {
            XCTAssertThrowsError(try OMLXEndpoint.parse(address), address) { error in
                XCTAssertEqual(error as? OMLXError, .invalidEndpoint)
            }
        }
    }

    func testEveryErrorExplainsItself() {
        XCTAssertTrue(OMLXError.needsKey.errorDescription?.contains("~/.omlx/settings.json") == true)
        XCTAssertTrue(OMLXError.http(500).errorDescription?.contains("500") == true)
        for error in [OMLXError.invalidEndpoint, .unavailable, .invalidResponse] {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
    }
}
