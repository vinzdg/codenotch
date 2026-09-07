import XCTest
@testable import Codenotch

final class GitHubCopilotUsageTests: XCTestCase {
    func testReadsCopilotQuotas() throws {
        let json = """
        {"copilot_plan":"individual","quota_snapshots":{
          "chat":{"entitlement":50,"remaining":48,"used":2,"unlimited":false},
          "completions":{"entitlement":2000,"remaining":1990,"used":10,"unlimited":false},
          "premium_interactions":{"entitlement":300,"remaining":294,"used":6,"unlimited":false}}}
        """

        let windows = try GitHubCopilotUsage.windows(from: Data(json.utf8))
        XCTAssertEqual(windows.map(\.id), ["premium_interactions", "chat", "completions"])
        XCTAssertEqual(windows[0].label, "Premium requests")
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.02, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.04, accuracy: 0.0001)
    }

    func testSkipsUnlimitedAndZeroEntitlement() throws {
        let json = """
        {"quota_snapshots":{
          "chat":{"entitlement":0,"remaining":0,"used":0,"unlimited":false},
          "completions":{"entitlement":0,"remaining":0,"used":0,"unlimited":true}}}
        """

        XCTAssertThrowsError(try GitHubCopilotUsage.windows(from: Data(json.utf8))) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testLoadsEnvironmentTokenBeforeHosts() throws {
        let credentials = try GitHubCopilotCredentials.load(
            environment: ["GH_TOKEN": "env-token"],
            hosts: "github.com:\n    user: octocat\n    oauth_token: old-token\n",
            command: { XCTFail("should not invoke gh"); return nil }
        )
        XCTAssertEqual(credentials.token, "env-token")
        XCTAssertEqual(credentials.username, "octocat")
    }

    func testParsesGitHubCLIHosts() throws {
        let credentials = try GitHubCopilotCredentials.load(
            environment: [:],
            hosts: "github.com:\n    user: octocat\n    oauth_token: cli-token\n",
            command: { XCTFail("should not invoke gh"); return nil }
        )
        XCTAssertEqual(credentials.token, "cli-token")
        XCTAssertEqual(credentials.source, "GitHub CLI")
    }
}
