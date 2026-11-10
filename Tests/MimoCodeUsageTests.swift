import XCTest
@testable import Codenotch

final class MimoCodeUsageTests: XCTestCase {

    func testOfficialPlatformBalanceResponse() throws {
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

        let result = try MimoCodeUsage.parse(json)
        XCTAssertEqual(result.headlineID, "mimocode-balance")

        let window = try XCTUnwrap(result.windows.first { $0.id == "mimocode-balance" })
        XCTAssertEqual(window.label, "Balance")

        let money = try XCTUnwrap(window.money)
        XCTAssertEqual(money.currency, "CNY")
        XCTAssertEqual(money.remaining, 500.50, accuracy: 0.001)
        // credit_limit (500) - credit_available (380) = 120 spent
        XCTAssertEqual(money.spent, 120.0, accuracy: 0.001)
        // funded = 500.50 + 120 = 620.50. spentFraction = 120 / 620.50 ~= 0.19339
        XCTAssertEqual(money.spentFraction, 120.0 / 620.50, accuracy: 0.001)

        // Credit limit detail window
        let creditWindow = try XCTUnwrap(result.windows.first { $0.id == "mimocode-credit" })
        XCTAssertEqual(creditWindow.label, "Credit limit")
        XCTAssertEqual(creditWindow.detail, "¥380.00 / ¥500.00")

        // Bonus window
        let bonusWindow = try XCTUnwrap(result.windows.first { $0.id == "mimocode-bonus" })
        XCTAssertEqual(bonusWindow.label, "Bonus balance")
        XCTAssertEqual(bonusWindow.detail, "¥20.00")
    }

    func testNumericBalanceDictionary() throws {
        let json = """
        {
          "currency": "USD",
          "cash_balance": 250.75,
          "total_available": 250.75,
          "plan": "Pay-as-you-go",
          "user": "coder123"
        }
        """

        let result = try MimoCodeUsage.parse(json)
        XCTAssertEqual(result.headlineID, "mimocode-balance")
        XCTAssertEqual(result.planName, "Pay-as-you-go")
        XCTAssertEqual(result.accountName, "coder123")

        let window = try XCTUnwrap(result.windows.first { $0.id == "mimocode-balance" })
        let money = try XCTUnwrap(window.money)
        XCTAssertEqual(money.currency, "USD")
        XCTAssertEqual(money.remaining, 250.75, accuracy: 0.001)
        XCTAssertEqual(money.spent, 0, accuracy: 0.001)
    }

    func testTokenPlanCreditsSchema() throws {
        let json = """
        {
          "plan": "Token Plan Pro",
          "user": "team-lead",
          "total_credits": 1000000,
          "used_credits": 250000,
          "remaining_credits": 750000
        }
        """

        let result = try MimoCodeUsage.parse(json)
        XCTAssertEqual(result.headlineID, "mimocode-credits")
        XCTAssertEqual(result.planName, "Token Plan Pro")
        XCTAssertEqual(result.accountName, "team-lead")

        let window = try XCTUnwrap(result.windows.first { $0.id == "mimocode-credits" })
        XCTAssertEqual(window.label, "Credits")
        XCTAssertEqual(window.usedFraction ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(window.remaining, 750000)
        XCTAssertEqual(window.used, 250000)
        XCTAssertTrue(window.prefersUsedText)
    }

    func testNestedCreditsSchema() throws {
        let json = """
        {
          "plan_name": "Ultra",
          "token_plan": {
            "total": 500000,
            "remaining": 200000
          }
        }
        """

        let result = try MimoCodeUsage.parse(json)
        XCTAssertEqual(result.headlineID, "mimocode-credits")
        XCTAssertEqual(result.planName, "Ultra")

        let window = try XCTUnwrap(result.windows.first { $0.id == "mimocode-credits" })
        XCTAssertEqual(window.remaining, 200000)
        XCTAssertEqual(window.used, 300000)
        XCTAssertEqual(window.usedFraction ?? -1, 0.6, accuracy: 0.001)
    }

    func testMalformedJSONThrowsBadResponse() {
        XCTAssertThrowsError(try MimoCodeUsage.parse("not json")) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("Expected badResponse, got \(error)")
            }
        }

        XCTAssertThrowsError(try MimoCodeUsage.parse(#"{"unrelated": 123}"#)) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("Expected badResponse, got \(error)")
            }
        }
    }
}
