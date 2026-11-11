import XCTest
@testable import Codenotch

/// The language server's quota summary covers the groups it serves, which is
/// not the whole account. These are the two shapes, reduced to what matters.
final class AntigravityQuotaCompletionTests: XCTestCase {
    private var savedFamily: String?

    /// The headline follows the stored family, so these cases pin the one
    /// they are about rather than read whatever this Mac has chosen.
    override func setUp() {
        super.setUp()
        savedFamily = UserDefaults.standard.string(forKey: "antigravityHeadlineModel")
        UserDefaults.standard.set(AntigravityHeadlineModel.gemini.rawValue, forKey: "antigravityHeadlineModel")
    }

    override func tearDown() {
        if let savedFamily { UserDefaults.standard.set(savedFamily, forKey: "antigravityHeadlineModel") }
        else { UserDefaults.standard.removeObject(forKey: "antigravityHeadlineModel") }
        super.tearDown()
    }

    /// The language server answers with the third-party group only.
    private let bridgePayload = Data("""
    {
      "response": {
        "groups": [
          {
            "displayName": "Claude and GPT models",
            "buckets": [
              { "bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly", "remainingFraction": 1, "resetTime": "2026-10-26T22:00:17Z" },
              { "bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining", "window": "5h", "remainingFraction": 1, "resetTime": "2026-10-20T03:00:17Z" }
            ]
          }
        ]
      }
    }
    """.utf8)

    /// Cloud Code PA answers with both groups.
    private let directPayload = Data("""
    {
      "groups": [
        {
          "displayName": "Gemini Models",
          "buckets": [
            { "bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly", "remainingFraction": 0.9677128, "resetTime": "2026-10-26T20:29:07Z" },
            { "bucketId": "gemini-5h", "displayName": "Five Hour Limit Remaining", "window": "5h", "remainingFraction": 0.88699496, "resetTime": "2026-10-20T01:29:07Z" }
          ]
        },
        {
          "displayName": "Claude and GPT models",
          "buckets": [
            { "bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly", "remainingFraction": 1, "resetTime": "2026-10-26T22:04:57Z" },
            { "bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining", "window": "5h", "remainingFraction": 1, "resetTime": "2026-10-20T03:04:57Z" }
          ]
        }
      ]
    }
    """.utf8)

    private func windows(_ payload: Data) -> [LimitWindow] {
        AntigravityProvider.windows(in: payload, now: Date(timeIntervalSince1970: 1788900000))
    }

    /// The server's answer on its own names one group, so a reader who chose
    /// the Gemini family would be shown the other allowance instead.
    func testTheBridgeAnswerOnItsOwnCoversOnlyOneFamily() {
        let bridged = windows(bridgePayload)
        XCTAssertEqual(bridged.map(\.id).sorted(), ["3p-5h", "3p-weekly"])
        XCTAssertEqual(bridged.first?.group, "Claude and GPT models")
    }

    /// The whole account names both.
    func testTheDirectAnswerCoversBothFamilies() {
        let direct = windows(directPayload)
        XCTAssertEqual(direct.map(\.id).sorted(), ["3p-5h", "3p-weekly", "gemini-5h", "gemini-weekly"])
        XCTAssertEqual(direct.first { $0.id == "gemini-5h" }?.group, "Gemini Models")
    }

    /// Union by id, the direct answer winning, so nothing is lost either way.
    func testTheUnionKeepsEveryWindowAndPrefersTheDirectAnswer() {
        let bridged = windows(bridgePayload)
        let direct = windows(directPayload)

        let merged = AntigravityProvider.union(bridged, direct)

        XCTAssertEqual(merged.map(\.id).sorted(), ["3p-5h", "3p-weekly", "gemini-5h", "gemini-weekly"])
        XCTAssertEqual(merged.first { $0.id == "gemini-5h" }?.group, "Gemini Models")
        // The third-party windows survive the union.
        XCTAssertNotNil(merged.first { $0.id == "3p-5h" })
        XCTAssertNotNil(merged.first { $0.id == "3p-weekly" })
    }

    /// The reading a reader of the Gemini family gets once the account is
    /// complete: Google's group, not the third-party one.
    func testAGeminiReaderGetsTheGeminiGroup() {
        let provider = AntigravityProvider(session: URLSession.shared)
        let bridged = windows(bridgePayload)
        let direct = windows(directPayload)

        // The whole account answers the reader of the Gemini family.
        let merged = direct
        let headlineAfter = provider.resolveHeadlineID(for: merged)
        XCTAssertEqual(headlineAfter, "gemini-5h")
        XCTAssertEqual(merged.first { $0.id == headlineAfter }?.group, "Gemini Models")
        XCTAssertEqual(provider.resolveWeeklyID(for: merged), "gemini-weekly")
    }
}
