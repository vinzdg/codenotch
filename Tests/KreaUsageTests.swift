import XCTest
@testable import Codenotch

final class KreaUsageTests: XCTestCase {

    func testProPlanParsesWithCalculatedUsedFraction() throws {
        let json = """
        [
          {
            "id": "ws_123",
            "name": "Creative Studio",
            "plan_type": "pro",
            "compute_units": 15400.0,
            "is_selected": true,
            "resets_at": "2026-11-01T00:00:00Z"
          }
        ]
        """

        let result = try KreaUsage.parse(json)
        XCTAssertEqual(result.headlineID, "credits")
        XCTAssertEqual(result.planName, "Pro")
        XCTAssertEqual(result.workspaceName, "Creative Studio")

        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(window.label, "Credits")
        XCTAssertEqual(window.remaining, 15400)
        XCTAssertEqual(window.used, 4600)

        // Pro allowance is 20,000. Used: 4,600 / 20,000 = 0.23
        let fraction = try XCTUnwrap(window.usedFraction)
        XCTAssertEqual(fraction, 4600.0 / 20000.0, accuracy: 0.001)
        XCTAssertEqual(window.detail, "15,400 of 20,000 left")
        XCTAssertNotNil(window.resetsAt)
    }

    func testMaxPlanHalfUsed() throws {
        let json = """
        {
          "workspaces": [
            {
              "id": "ws_max",
              "name": "Max Team",
              "plan_type": "max",
              "compute_units": 30000.0
            }
          ]
        }
        """

        let result = try KreaUsage.parse(json)
        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(window.usedFraction ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(window.remaining, 30000)
        XCTAssertEqual(window.used, 30000)
        XCTAssertEqual(window.detail, "30,000 of 60,000 left")
    }

    func testExtraCreditsWhenBalanceExceedsAllowance() throws {
        let json = """
        [
          {
            "id": "ws_extra",
            "name": "ComputePack",
            "plan_type": "basic",
            "compute_units": 6500.0
          }
        ]
        """

        let result = try KreaUsage.parse(json)
        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(window.usedFraction, 0.0)
        XCTAssertEqual(window.remaining, 6500)
        XCTAssertEqual(window.used, 0)
        XCTAssertEqual(window.detail, "6,500 of 5,000 · +1,500 extra")

        let extraWindow = try XCTUnwrap(result.windows.first { $0.id == "extra_credits" })
        XCTAssertEqual(extraWindow.label, "Extra credits")
        XCTAssertEqual(extraWindow.used, 1500)
        XCTAssertEqual(extraWindow.detail, "1500")
    }

    func testSelectedWorkspaceIsPreferredOverFirst() throws {
        let json = """
        [
          {
            "id": "ws_first",
            "name": "Personal",
            "plan_type": "free",
            "compute_units": 20.0,
            "is_selected": false
          },
          {
            "id": "ws_active",
            "name": "Production Studio",
            "plan_type": "pro",
            "compute_units": 18000.0,
            "is_selected": true
          }
        ]
        """

        let result = try KreaUsage.parse(json)
        XCTAssertEqual(result.workspaceName, "Production Studio")
        XCTAssertEqual(result.planName, "Pro")
        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(window.remaining, 18000)
    }

    func testDirectBalanceObjectParsing() throws {
        let json = """
        {
          "credits": 80.0,
          "subscription_plan_type": "free",
          "resets_at": "2026-10-31T23:59:59.999Z"
        }
        """

        let result = try KreaUsage.parse(json)
        XCTAssertEqual(result.planName, "Free")
        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        // Free allowance is 100. Remaining 80, used 20.
        XCTAssertEqual(window.remaining, 80)
        XCTAssertEqual(window.used, 20)
        XCTAssertEqual(window.usedFraction ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(window.detail, "80 of 100 left")
        XCTAssertNotNil(window.resetsAt)
    }

    func testExplicitAllowanceOverridesPlanTier() throws {
        let json = """
        {
          "compute_units": 4000.0,
          "compute_limit": 10000.0,
          "plan_type": "custom"
        }
        """

        let result = try KreaUsage.parse(json)
        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(window.remaining, 4000)
        XCTAssertEqual(window.used, 6000)
        XCTAssertEqual(window.usedFraction ?? -1, 0.6, accuracy: 0.001)
        XCTAssertEqual(window.detail, "4,000 of 10,000 left")
    }

    func testUnknownPlanWithoutAllowanceRendersCountOnly() throws {
        let json = """
        {
          "credits": 1250.0,
          "plan_type": "pay_as_you_go"
        }
        """

        let result = try KreaUsage.parse(json)
        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertNil(window.usedFraction)
        XCTAssertEqual(window.remaining, 1250)
        XCTAssertEqual(window.detail, "1,250 credits left")
    }

    func testEmptyWorkspacesThrowsNothingMetered() {
        let json = "[]"
        XCTAssertThrowsError(try KreaUsage.parse(json)) { error in
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
        XCTAssertThrowsError(try KreaUsage.parse(json)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("Expected nothingMetered, got \(error)")
            }
        }
    }

    func testOfficialKreaCLIBalanceOutput() throws {
        // Output from `krea balance --json`
        let json = """
        {
          "plan": {
            "id": "pro",
            "name": "Pro",
            "tier": "pro",
            "billing_period": "monthly",
            "is_paid": true,
            "monthly_compute_units": 20000
          },
          "compute_units": {
            "total": 15400,
            "plan": 15000,
            "purchased": 400,
            "free": 0
          }
        }
        """

        let result = try KreaUsage.parse(json)
        XCTAssertEqual(result.headlineID, "credits")
        XCTAssertEqual(result.planName, "Pro")

        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(window.remaining, 15400)
        XCTAssertEqual(window.used, 5000)
        let fraction = try XCTUnwrap(window.usedFraction)
        XCTAssertEqual(fraction, 5000.0 / 20000.0, accuracy: 0.001)
        XCTAssertEqual(window.detail, "15,400 of 20,000 · +400 extra")

        let extraWindow = try XCTUnwrap(result.windows.first { $0.id == "extra_credits" })
        XCTAssertEqual(extraWindow.used, 400)
        XCTAssertEqual(extraWindow.detail, "400")
    }

    func testMCPGetBalanceEnvelope() throws {
        let json = """
        {
          "jsonrpc": "2.0",
          "result": {
            "content": [
              {
                "type": "text",
                "text": "{\\"plan\\":{\\"id\\":\\"max\\",\\"name\\":\\"Max\\",\\"tier\\":\\"max\\",\\"billing_period\\":\\"monthly\\",\\"is_paid\\":true,\\"monthly_compute_units\\":60000},\\"compute_units\\":{\\"total\\":45000,\\"plan\\":45000,\\"purchased\\":0,\\"free\\":0}}"
              }
            ]
          },
          "id": 1
        }
        """

        let result = try KreaUsage.parse(json)
        XCTAssertEqual(result.headlineID, "credits")
        XCTAssertEqual(result.planName, "Max")

        let window = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(window.remaining, 45000)
        XCTAssertEqual(window.used, 15000)
        let fraction = try XCTUnwrap(window.usedFraction)
        XCTAssertEqual(fraction, 15000.0 / 60000.0, accuracy: 0.001)
        XCTAssertEqual(window.detail, "45,000 of 60,000 left")
    }

    func testInvalidJSONThrowsBadResponse() {
        let invalid = "not a json string"
        XCTAssertThrowsError(try KreaUsage.parse(invalid)) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("Expected badResponse, got \(error)")
            }
        }
    }
}
