import XCTest
@testable import Codenotch

final class AmpUsageTests: XCTestCase {
    func testCurrentTierResponseUsesThePercentagesReportedByAmp() throws {
        let reading = try AmpUsage.parse(AmpFixture.tier)
        XCTAssertEqual(reading.plan, "Gigawatt")
        XCTAssertEqual(reading.fidelity, .official)
        XCTAssertEqual(reading.headlineID, "agent")
        XCTAssertEqual(reading.windows.map(\.id), ["agent", "orb", "renewal"])
        XCTAssertEqual(try XCTUnwrap(reading.windows[0].usedFraction), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(reading.windows[1].usedFraction), 0.10, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[2].detail, "About 25 days")
        XCTAssertTrue(reading.windows.allSatisfy { $0.resetsAt == nil && $0.duration == nil })
    }

    func testTierWithoutAnOrbSizeAndWithGroupedDollarAmounts() throws {
        let data = try AmpFixture.response("Amp Team Tier: agent usage $1,500.25 of $2,000 remaining (75%), orb usage 0h of 1,000h orb hours remaining (0%)")
        let reading = try AmpUsage.parse(data)
        XCTAssertEqual(reading.plan, "Team")
        XCTAssertEqual(reading.windows.map(\.usedFraction), [0.25, 1])
    }

    func testSubscriptionUsesAgentAsHeadlineAndKeepsOrbSeparate() throws {
        let reading = try AmpUsage.parse(AmpFixture.subscription)
        XCTAssertEqual(reading.plan, "Megawatt")
        XCTAssertEqual(reading.headlineID, "agent")
        XCTAssertEqual(reading.fidelity, .official)
        XCTAssertEqual(reading.windows.map(\.id), ["agent", "orb", "renewal"])
        XCTAssertEqual(try XCTUnwrap(reading.windows[0].usedFraction), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(reading.windows[1].usedFraction), 0.05, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[2].detail, "About 20 days")
        XCTAssertTrue(reading.windows.allSatisfy { $0.resetsAt == nil && $0.duration == nil },
                      "whole days must not become an exact reset or an invented monthly duration")
    }

    func testFlatPlainTextResponseSupportsDecimalsAndMultiwordPlans() throws {
        let data = try AmpFixture.response(
            "Amp Team Plan Subscription: 99.5% agent usage and 0% orb usage remaining - resets upon renewal in 1 day",
            wrapped: false
        )
        let reading = try AmpUsage.parse(data)
        XCTAssertEqual(reading.plan, "Team Plan")
        XCTAssertEqual(try XCTUnwrap(reading.windows[0].usedFraction), 0.005, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[1].usedFraction, 1)
        XCTAssertEqual(reading.windows[2].detail, "About 1 day")
    }

    func testAnExplicitUnusedAllowanceIsZeroWithoutInventingARenewal() throws {
        let data = try AmpFixture.response("Amp Kilowatt Subscription: 100% other usage and 100% orb usage remaining")
        let reading = try AmpUsage.parse(data)
        XCTAssertEqual(reading.windows.count, 2)
        XCTAssertEqual(reading.windows.map(\.usedFraction), [0, 0])
    }

    func testFreeAllowanceDerivesAFractionAndRetainsTheDollarAmounts() throws {
        let reading = try AmpUsage.parse(AmpFixture.free)
        XCTAssertEqual(reading.plan, "Free")
        XCTAssertEqual(reading.headlineID, "free")
        XCTAssertEqual(reading.fidelity, .derived)
        XCTAssertEqual(reading.windows.map(\.id), ["free", "freeBalance", "replenishment"])
        XCTAssertEqual(try XCTUnwrap(reading.windows[0].usedFraction), 0.55, accuracy: 0.0001)
        XCTAssertNil(reading.windows[0].detail, "only the computed percentage gets the derived qualifier")
        XCTAssertEqual(reading.windows[1].detail, "$4.50 of $10.00 left")
        XCTAssertEqual(reading.windows[2].detail, "$0.50/hour")
        XCTAssertTrue(reading.windows.allSatisfy { $0.resetsAt == nil && $0.duration == nil },
                      "continuous replenishment is not a scheduled quota reset")
    }

    func testFreeAllowanceCanBeFullOrExhausted() throws {
        for (remaining, fraction) in [("10.00", 0.0), ("0.00", 1.0)] {
            let data = try AmpFixture.response("Amp Free: $\(remaining)/$10.00 remaining (replenishes +$0.50/hour)")
            XCTAssertEqual(try AmpUsage.parse(data).windows[0].usedFraction, fraction)
        }
    }

    func testMissingUnknownAndErrorResponsesNeverBecomeAZeroReading() throws {
        let invalid = [
            "not json", "[]", "{}", #"{"result":{}}"#,
            #"{"displayText":"Signed in as fixture@example.invalid"}"#,
            #"{"result":{"displayText":"Credits: $42.00"}}"#,
            #"{"result":null,"displayText":"Amp Free: $4.50/$10.00 remaining (replenishes +$0.50/hour)"}"#,
            #"{"ok":false,"result":{"displayText":"Amp Free: $4.50/$10.00 remaining (replenishes +$0.50/hour)"}}"#,
            #"{"error":{"code":-32000,"message":"private server detail"},"result":{"displayText":"Amp Free: $4.50/$10.00 remaining (replenishes +$0.50/hour)"}}"#
        ]
        for json in invalid {
            XCTAssertThrowsError(try AmpUsage.parse(Data(json.utf8))) { error in
                guard case UsageProviderError.apiError(let message) = error else {
                    return XCTFail("expected a visible parse error, got \(error)")
                }
                XCTAssertFalse(message.contains("private server detail"))
            }
        }
    }

    func testInvalidNumbersAndPartialSubscriptionsAreRejected() throws {
        let invalid = [
            "Amp Megawatt Subscription: 101% other usage and 50% orb usage remaining",
            "Amp Megawatt Subscription: -1% other usage and 50% orb usage remaining",
            "Amp Megawatt Subscription: 50% other usage remaining\nAmp Free: $4.50/$10.00 remaining (replenishes +$0.50/hour)",
            "Amp Gigawatt Tier: agent usage $50 of $200 remaining (101%), orb usage 900h of 1,000h a1.xxlarge orb hours remaining (90%)",
            "Amp Gigawatt Tier: agent usage $201 of $200 remaining (100%), orb usage 900h of 1,000h a1.xxlarge orb hours remaining (90%)",
            "Amp Gigawatt Tier: agent usage $50 of $200 remaining (25%), orb usage 1,001h of 1,000h a1.xxlarge orb hours remaining (100%)",
            "Amp Gigawatt Tier: agent usage $50 of $200 remaining (25%)\nAmp Free: $4.50/$10.00 remaining (replenishes +$0.50/hour)",
            "Amp Free: $0/$0 remaining (replenishes +$0.50/hour)",
            "Amp Free: $11/$10 remaining (replenishes +$0.50/hour)",
            "Amp Free: $-1/$10 remaining (replenishes +$0.50/hour)",
            "Amp Free: $1.2.3/$10 remaining (replenishes +$0.50/hour)"
        ]
        for text in invalid {
            XCTAssertThrowsError(try AmpUsage.parse(AmpFixture.response(text)), text)
        }
    }
}

final class AmpCredentialsTests: XCTestCase {
    private func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("amp-\(UUID()).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testOnlyTheOfficialServersKeyIsReadAndTheFileIsUnchanged() throws {
        let url = try file(#"{"apiKey@https://proxy.example/":"sgamp_proxy","apiKey@https://ampcode.com/":" sgamp_fixture "}"#)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(try AmpCredentials.load(from: url), "sgamp_fixture")
        XCTAssertEqual(try Data(contentsOf: url), before)
        try #"{"apiKey@https://ampcode.com":"sgamp_rotated"}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try AmpCredentials.load(from: url), "sgamp_rotated")
    }

    func testMissingEmptyForeignAndLookalikeKeysNeedLogin() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var urls = [missing]
        for text in ["{}", #"{"apiKey@https://ampcode.com/":" "}"#,
                     #"{"apiKey@https://ampcode.com.evil/":"sgamp_other"}"#,
                     #"{"apiKey@http://ampcode.com/":"sgamp_other"}"#,
                     #"{"apiKey@https://proxy.example/":"sgamp_other"}"#,
                     #"{"apiKey@https://ampcode.com/":"sgamp_bad\r\nHeader: value"}"#] {
            urls.append(try file(text))
        }
        for url in urls {
            XCTAssertThrowsError(try AmpCredentials.load(from: url)) { error in
                guard case UsageProviderError.needsAuth = error else {
                    return XCTFail("expected needsAuth, got \(error)")
                }
            }
        }
    }

    func testBrokenStorageIsAnErrorRatherThanALogout() throws {
        for url in [try file("not json"), try file("[]"), FileManager.default.temporaryDirectory] {
            XCTAssertThrowsError(try AmpCredentials.load(from: url)) { error in
                guard case UsageProviderError.apiError = error else {
                    return XCTFail("expected a credential-read error, got \(error)")
                }
            }
        }
    }
}

enum AmpFixture {
    // The current Tier shape was verified against Amp CLI and the live API.
    // Amounts, dates and percentages here are synthetic, not the live account.
    static let tier = Data(#"{"ok":true,"result":{"displayText":"**Amp Gigawatt Tier:** agent usage $150.25 of $200 remaining (75%), orb usage 900.5h of 1,000h a1.xxlarge orb hours remaining (90%) - period 2026-09-01 to 2026-10-01, resets upon renewal in 25 days\nIndividual credits: $0 remaining - https://ampcode.com/settings"}}"#.utf8)
    // Synthetic account and round numbers, based on the shapes documented by
    // iamgp/openusage's Amp adapter linked from robinebers/openusage#1188.
    static let subscription = Data(#"{"jsonrpc":"2.0","id":1,"result":{"displayText":"Signed in as fixture@example.invalid\n**Amp Megawatt Subscription:** 75% other usage and 95% orb usage remaining - resets upon renewal in 20 days"}}"#.utf8)
    static let free = Data(#"{"result":{"displayText":"Amp Free: $4.50/$10.00 remaining (replenishes +$0.50/hour)"}}"#.utf8)

    static func response(_ text: String, wrapped: Bool = true) throws -> Data {
        let payload = ["displayText": text]
        let object: [String: Any] = wrapped ? ["result": payload] : payload
        return try JSONSerialization.data(withJSONObject: object)
    }
}
