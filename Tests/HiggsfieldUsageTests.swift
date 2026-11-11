import XCTest
@testable import Codenotch

final class HiggsfieldUsageTests: XCTestCase {

    func testUltraPlanParsesWithCalculatedUsedFraction() throws {
        let json = """
        [
          {
            "id": "ws_123",
            "name": "Personal Workspace",
            "plan_type": "ultra",
            "credits": 2777.1,
            "is_selected": true,
            "resets_at": "2026-11-01T00:00:00Z"
          }
        ]
        """

        let result = try HiggsfieldUsage.parse(json)
        XCTAssertEqual(result.headlineID, "credits")
        XCTAssertEqual(result.planName, "Ultra")
        XCTAssertEqual(result.workspaceName, "Personal Workspace")

        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(window.label, "Credits")
        XCTAssertEqual(window.remaining, 2777)
        XCTAssertEqual(window.used, 223)

        // Used: (3000 - 2777.1) / 3000 = 222.9 / 3000 = 0.0743
        let fraction = try XCTUnwrap(window.usedFraction)
        XCTAssertEqual(fraction, (3000.0 - 2777.1) / 3000.0, accuracy: 0.001)
        XCTAssertEqual(window.detail, "2,777 of 3,000 left")
        XCTAssertNotNil(window.resetsAt)
    }

    func testPlusPlanHalfUsed() throws {
        let json = """
        {
          "workspaces": [
            {
              "id": "ws_plus",
              "name": "Team",
              "plan_type": "plus",
              "credits": 600.0
            }
          ]
        }
        """

        let result = try HiggsfieldUsage.parse(json)
        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(window.usedFraction ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(window.remaining, 600)
        XCTAssertEqual(window.used, 600)
        XCTAssertEqual(window.detail, "600 of 1,200 left")
    }

    func testExtraCreditsWhenBalanceExceedsMonthlyAllowance() throws {
        let json = """
        [
          {
            "id": "ws_extra",
            "name": "TopUp",
            "plan_type": "pro",
            "credits": 1500.0
          }
        ]
        """

        let result = try HiggsfieldUsage.parse(json)
        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(window.usedFraction, 0.0)
        XCTAssertEqual(window.remaining, 1500)
        XCTAssertEqual(window.used, 0)
        XCTAssertEqual(window.detail, "1,500 of 1,200 · +300 extra")

        let extraWindow = try XCTUnwrap(result.windows.first { $0.id == "extra_credits" })
        XCTAssertEqual(extraWindow.label, "Extra credits")
        XCTAssertEqual(extraWindow.used, 300)
        XCTAssertEqual(extraWindow.detail, "300")
    }

    func testSelectedWorkspaceIsPreferredOverFirst() throws {
        let json = """
        [
          {
            "id": "ws_first",
            "name": "Old Workspace",
            "plan_type": "starter",
            "credits": 10.0,
            "is_selected": false
          },
          {
            "id": "ws_active",
            "name": "Active Studio",
            "plan_type": "plus",
            "credits": 1100.0,
            "is_selected": true
          }
        ]
        """

        let result = try HiggsfieldUsage.parse(json)
        XCTAssertEqual(result.workspaceName, "Active Studio")
        XCTAssertEqual(result.planName, "Plus")
        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(window.remaining, 1100)
    }

    func testDirectBalanceObjectParsing() throws {
        let json = """
        {
          "credits": 125.0,
          "subscription_plan_type": "basic",
          "resets_at": "2026-10-31T23:59:59.999Z"
        }
        """

        let result = try HiggsfieldUsage.parse(json)
        XCTAssertEqual(result.planName, "Basic")
        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        // Basic allowance is 150. Remaining 125, used 25.
        XCTAssertEqual(window.remaining, 125)
        XCTAssertEqual(window.used, 25)
        XCTAssertEqual(window.usedFraction ?? -1, 25.0 / 150.0, accuracy: 0.001)
        XCTAssertEqual(window.detail, "125 of 150 left")
        XCTAssertNotNil(window.resetsAt)
    }

    func testExplicitAllowanceOverridesPlanTier() throws {
        let json = """
        {
          "credits": 400.0,
          "allowance": 500.0,
          "plan_type": "custom"
        }
        """

        let result = try HiggsfieldUsage.parse(json)
        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(window.remaining, 400)
        XCTAssertEqual(window.used, 100)
        XCTAssertEqual(window.usedFraction ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(window.detail, "400 of 500 left")
    }

    func testUnknownPlanWithoutAllowanceRendersCountOnly() throws {
        let json = """
        {
          "credits": 42.0,
          "plan_type": "pay_as_you_go"
        }
        """

        let result = try HiggsfieldUsage.parse(json)
        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertNil(window.usedFraction)
        XCTAssertEqual(window.remaining, 42)
        XCTAssertEqual(window.detail, "42 credits left")
    }

    func testEmptyWorkspacesThrowsNothingMetered() {
        let json = "[]"
        XCTAssertThrowsError(try HiggsfieldUsage.parse(json)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("Expected nothingMetered, got \(error)")
            }
        }
    }

    func testMissingCreditsThrowsNothingMetered() {
        let json = """
        [
          {
            "id": "ws_123",
            "name": "Workspace Without Credits"
          }
        ]
        """
        XCTAssertThrowsError(try HiggsfieldUsage.parse(json)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("Expected nothingMetered, got \(error)")
            }
        }
    }

    func testInvalidJSONThrowsBadResponse() {
        let invalid = "not a json string"
        XCTAssertThrowsError(try HiggsfieldUsage.parse(invalid)) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("Expected badResponse, got \(error)")
            }
        }
    }
}
