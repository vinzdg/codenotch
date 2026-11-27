import XCTest
import SwiftUI
@testable import Codenotch

@MainActor
final class DeepSeekUsageTests: XCTestCase {
    func testPricingUsesDeepSeekUTCWeekdayAndWindows() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        XCTAssertEqual(DeepSeekPricing.phase(at: try XCTUnwrap(formatter.date(from: "2026-09-14T02:00:00Z"))), .peak)
        XCTAssertEqual(DeepSeekPricing.phase(at: try XCTUnwrap(formatter.date(from: "2026-09-14T04:00:00Z"))), .offPeak)
        XCTAssertEqual(DeepSeekPricing.phase(at: try XCTUnwrap(formatter.date(from: "2026-09-14T07:00:00Z"))), .peak)
        XCTAssertEqual(DeepSeekPricing.phase(at: try XCTUnwrap(formatter.date(from: "2026-09-14T10:00:00Z"))), .offPeak)
        XCTAssertEqual(DeepSeekPricing.phase(at: try XCTUnwrap(formatter.date(from: "2026-09-13T02:00:00Z"))), .offPeak)
    }

    func testPricingFindsTheNextLocalBillingPhaseBoundaryInUTC() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let now = try XCTUnwrap(formatter.date(from: "2026-09-14T02:30:00Z"))
        let transition = DeepSeekPricing.nextTransition(after: now)

        XCTAssertEqual(transition.phase, .offPeak)
        XCTAssertEqual(transition.date,
                       try XCTUnwrap(formatter.date(from: "2026-09-14T04:00:00Z")))

        let friday = try XCTUnwrap(formatter.date(from: "2026-09-18T10:30:00Z"))
        let monday = DeepSeekPricing.nextTransition(after: friday)
        XCTAssertEqual(monday.phase, .peak)
        XCTAssertEqual(monday.date,
                       try XCTUnwrap(formatter.date(from: "2026-09-21T01:00:00Z")))
    }

    func testPricingUsesTheMaintainedSchedule() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let schedule = DeepSeekPricing.Schedule(
            peakWeekdays: [2],
            windows: [.init(startMinute: 120, endMinute: 180)]
        )

        XCTAssertEqual(DeepSeekPricing.phase(
            at: try XCTUnwrap(formatter.date(from: "2026-09-14T02:30:00Z")),
            schedule: schedule
        ), .peak)
        XCTAssertEqual(DeepSeekPricing.phase(
            at: try XCTUnwrap(formatter.date(from: "2026-09-14T03:00:00Z")),
            schedule: schedule
        ), .offPeak)
        XCTAssertEqual(DeepSeekPricing.phase(
            at: try XCTUnwrap(formatter.date(from: "2026-09-15T02:30:00Z")),
            schedule: schedule
        ), .offPeak)
    }

    func testPricingSupportsMoreThanTwoPeakWindows() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let schedule = DeepSeekPricing.Schedule(
            peakWeekdays: [2],
            windows: [
                .init(startMinute: 60, endMinute: 120),
                .init(startMinute: 360, endMinute: 420),
                .init(startMinute: 1_080, endMinute: 1_140)
            ]
        )

        XCTAssertEqual(DeepSeekPricing.phase(
            at: try XCTUnwrap(formatter.date(from: "2026-09-14T18:30:00Z")),
            schedule: schedule
        ), .peak)
        XCTAssertEqual(DeepSeekPricing.phase(
            at: try XCTUnwrap(formatter.date(from: "2026-09-14T19:00:00Z")),
            schedule: schedule
        ), .offPeak)
    }

    /// Trimmed from holiday-cn's 2026.json: National Day, the Spring Festival,
    /// and a make-up working day, which must not count as a day off.
    private static let holidays2026 = #"""
    {"year": 2026, "papers": [], "days": [
      {"name": "春节", "date": "2026-02-15", "isOffDay": true},
      {"name": "春节", "date": "2026-02-16", "isOffDay": true},
      {"name": "春节", "date": "2026-02-17", "isOffDay": true},
      {"name": "春节", "date": "2026-02-18", "isOffDay": true},
      {"name": "春节", "date": "2026-02-19", "isOffDay": true},
      {"name": "春节", "date": "2026-02-20", "isOffDay": true},
      {"name": "春节", "date": "2026-02-21", "isOffDay": true},
      {"name": "春节", "date": "2026-02-22", "isOffDay": true},
      {"name": "春节", "date": "2026-02-23", "isOffDay": true},
      {"name": "国庆节", "date": "2026-10-01", "isOffDay": true},
      {"name": "国庆节", "date": "2026-10-02", "isOffDay": true},
      {"name": "国庆节", "date": "2026-10-05", "isOffDay": true},
      {"name": "国庆节", "date": "2026-10-06", "isOffDay": true},
      {"name": "国庆节", "date": "2026-10-07", "isOffDay": true},
      {"name": "国庆节", "date": "2026-10-10", "isOffDay": false}
    ]}
    """#

    private func holidayCalendar() throws -> ChineseHolidayCalendar {
        try XCTUnwrap(ChineseHolidayCalendar.empty.merging(holidayCNJSON: Data(Self.holidays2026.utf8)))
    }

    func testChineseHolidaysAreOffPeakOnAWeekday() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let holidays = try holidayCalendar()
        // Friday 2 October 2026, 10:00 in Beijing.
        let nationalDay = try XCTUnwrap(formatter.date(from: "2026-10-02T02:00:00Z"))

        XCTAssertEqual(DeepSeekPricing.phase(at: nationalDay, schedule: .current, holidays: holidays), .offPeak)
        XCTAssertEqual(DeepSeekPricing.phase(at: nationalDay, schedule: .current), .peak)

        var weekdaysOnly = DeepSeekPricing.Schedule.current
        weekdaysOnly.offPeakOnChineseHolidays = false
        XCTAssertEqual(DeepSeekPricing.phase(at: nationalDay, schedule: weekdaysOnly, holidays: holidays), .peak)

        // Thursday 8 October is a working day again.
        XCTAssertEqual(DeepSeekPricing.phase(
            at: try XCTUnwrap(formatter.date(from: "2026-10-08T02:00:00Z")),
            schedule: .current, holidays: holidays
        ), .peak)
    }

    func testHolidayCalendarIgnoresMakeUpDaysAndUnpublishedYears() throws {
        let holidays = try holidayCalendar()

        XCTAssertEqual(holidays.years, [2026])
        XCTAssertTrue(holidays.offDays.contains("2026-10-01"))
        XCTAssertFalse(holidays.offDays.contains("2026-10-10"))
        XCTAssertNil(holidays.merging(holidayCNJSON: Data(#"{"year": 2027, "papers": [], "days": []}"#.utf8)))
        XCTAssertNil(holidays.merging(holidayCNJSON: Data("not json".utf8)))
    }

    func testNextPeakSkipsTheWholeHoliday() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let holidays = try holidayCalendar()

        let nationalDay = DeepSeekPricing.nextTransition(
            after: try XCTUnwrap(formatter.date(from: "2026-10-02T02:00:00Z")),
            schedule: .current, holidays: holidays
        )
        XCTAssertEqual(nationalDay.phase, .peak)
        XCTAssertEqual(nationalDay.date, try XCTUnwrap(formatter.date(from: "2026-10-08T01:00:00Z")))

        // Friday evening before the Spring Festival: eleven days to the next peak.
        let springFestival = DeepSeekPricing.nextTransition(
            after: try XCTUnwrap(formatter.date(from: "2026-02-13T10:30:00Z")),
            schedule: .current, holidays: holidays
        )
        XCTAssertEqual(springFestival.phase, .peak)
        XCTAssertEqual(springFestival.date, try XCTUnwrap(formatter.date(from: "2026-02-24T01:00:00Z")))
    }

    func testAHolidayEndsAWindowThatRunsAcrossBeijingMidnight() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let schedule = DeepSeekPricing.Schedule(
            peakWeekdays: [1, 2, 3, 4, 5, 6, 7],
            windows: [.init(startMinute: 900, endMinute: 1_020)]
        )

        let transition = DeepSeekPricing.nextTransition(
            after: try XCTUnwrap(formatter.date(from: "2026-09-30T15:30:00Z")),
            schedule: schedule, holidays: try holidayCalendar()
        )
        XCTAssertEqual(transition.phase, .offPeak)
        XCTAssertEqual(transition.date, try XCTUnwrap(formatter.date(from: "2026-09-30T16:00:00Z")))
    }

    func testAScheduleSavedBeforeTheHolidayRuleStillDecodes() throws {
        let saved = #"{"peakWeekdays": [2, 3], "windows": [{"startMinute": 60, "endMinute": 240}]}"#
        let schedule = try JSONDecoder().decode(DeepSeekPricing.Schedule.self, from: Data(saved.utf8))

        XCTAssertEqual(schedule.peakWeekdays, [2, 3])
        XCTAssertTrue(schedule.offPeakOnChineseHolidays)
    }

    func testTheBundledHolidayCalendarCoversTheYearItShipsWith() {
        XCTAssertTrue(ChineseHolidays.bundled.years.contains(2026))
        XCTAssertNotNil(Bundle.main.url(forResource: "holiday-cn-LICENSE", withExtension: "txt"))
    }

    func testDisablingPricingOnlyRemovesPricingRowsFromTheCardHeight() {
        XCTAssertGreaterThan(
            NotchLayout.usageDetailHeight(1, showsPricing: true),
            NotchLayout.usageDetailHeight(1, showsPricing: false)
        )
    }

    func testSwitchGateIgnoresTheExistingSession() {
        var gate = WebSessionAuthenticationGate(baselineFingerprint: "old")

        XCTAssertFalse(gate.observe(authenticated: true, fingerprint: "old"))
        XCTAssertFalse(gate.observe(authenticated: false, fingerprint: nil))
        XCTAssertFalse(gate.observe(authenticated: true, fingerprint: "old"))
        XCTAssertFalse(gate.observe(authenticated: true, fingerprint: "old"))
    }

    func testNormalSignInDoesNotCommitAnExistingSessionBeforeLogout() {
        var gate = WebSessionAuthenticationGate(
            baselineFingerprint: "old",
            requiresNewFingerprint: false
        )

        XCTAssertFalse(gate.observe(authenticated: true, fingerprint: "old"))
        XCTAssertFalse(gate.observe(authenticated: false, fingerprint: nil))
        XCTAssertTrue(gate.observe(authenticated: true, fingerprint: "old"))
    }

    func testManualCloseCanCommitACompletedNormalSignIn() {
        let gate = WebSessionAuthenticationGate(
            baselineFingerprint: "old",
            requiresNewFingerprint: false
        )

        XCTAssertTrue(gate.acceptsAuthenticatedStateOnManualClose(
            authenticated: true,
            fingerprint: "old"
        ))
        XCTAssertFalse(gate.acceptsAuthenticatedStateOnManualClose(
            authenticated: false,
            fingerprint: nil
        ))
    }

    func testManualCloseCannotCommitTheExistingAccountDuringASwitch() {
        let gate = WebSessionAuthenticationGate(baselineFingerprint: "old")

        XCTAssertFalse(gate.acceptsAuthenticatedStateOnManualClose(
            authenticated: true,
            fingerprint: "old"
        ))
        XCTAssertTrue(gate.acceptsAuthenticatedStateOnManualClose(
            authenticated: true,
            fingerprint: "new"
        ))
    }

    func testDeepSeekAuthenticationProbeUsesThePlatformHeader() {
        let probe = try! XCTUnwrap(Sites.deepSeek.authProbeScript)

        XCTAssertTrue(probe.contains("'x-client-platform': 'web'"))
    }

    func testSwitchGateCommitsOnlyAfterLogoutAndANewSession() {
        var gate = WebSessionAuthenticationGate(baselineFingerprint: "old")

        XCTAssertFalse(gate.observe(authenticated: false, fingerprint: nil))
        XCTAssertFalse(gate.observe(authenticated: false, fingerprint: nil))
        XCTAssertTrue(gate.observe(authenticated: true, fingerprint: "new"))
    }

    func testSignedInSessionAppearsAsAnAccountInSettings() {
        let key = "deepseek.signedIn"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set(true, forKey: key)
        let provider = WebSessionProvider(site: Sites.deepSeek)
        let account = provider.account()

        XCTAssertNotNil(account)
        XCTAssertEqual(account?.source, "DeepSeek")
        XCTAssertEqual(account?.manageURL?.absoluteString, "https://platform.deepseek.com/usage")
    }

    func testPlatformSummaryBuildsMoneyWindow() throws {
        let json = #"{"data":{"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"10.87"}],"total_costs":[{"currency":"CNY","amount":"9.20"}],"total_available_token_estimation":"3300000"}}}"#
        let reading = try DeepSeekUsage.reading(fromJSON: json)
        XCTAssertEqual(reading.currency, "CNY")
        XCTAssertEqual(reading.spent, 9.20, accuracy: 0.001)
        XCTAssertEqual(reading.balance, 10.87, accuracy: 0.001)
        XCTAssertEqual(reading.usedFraction, 9.20 / 20.07, accuracy: 0.001)
        XCTAssertEqual(reading.availableTokens, 3_300_000)
    }

    func testAmountAndCostSeriesMergeByAPIKeyAndModel() throws {
        let summary = #"{"data":{"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"1"}],"total_costs":[]}}}"#
        let amountObject: [String: Any] = ["data": ["biz_data": ["series": [[
            "api_key": ["name": "main", "tracking_id": "key-1"],
            "model": "deepseek-chat", "buckets": [[
                "time": 1800000000,
                "usage": ["PROMPT_CACHE_HIT_TOKEN": "100", "PROMPT_CACHE_MISS_TOKEN": 50,
                           "RESPONSE_TOKEN": 25, "REQUEST": 2]
            ]]
        ]]]]]
        let amount = String(data: try JSONSerialization.data(withJSONObject: amountObject), encoding: .utf8)!
        let costObject: [String: Any] = ["data": ["biz_data": ["data": [[
            "currency": "CNY", "series": [[
                "api_key": ["name": "main", "tracking_id": "key-1"],
                "model": "deepseek-chat", "buckets": [["time": 1800000000, "cost": "0.12"]]
            ]]
        ]]]]]
        let cost = String(data: try JSONSerialization.data(withJSONObject: costObject), encoding: .utf8)!
        let object: [String: Any] = ["summary": summary, "amount": amount, "cost": cost,
                                      "start": 1800000000, "end": 1800086400,
                                      "time_zone_seconds": 28800]
        let payload = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        let detail = try XCTUnwrap(DeepSeekUsage.detail(fromJSON: payload))
        let group = try XCTUnwrap(detail.groups.first)
        XCTAssertEqual(group.apiKeyLabel, "main")
        XCTAssertEqual(group.model, "deepseek-chat")
        XCTAssertEqual(group.totalTokens, 175)
        XCTAssertEqual(group.requests, 2)
        XCTAssertEqual(group.totalCost, 0.12, accuracy: 0.001)
        XCTAssertEqual(detail.visibleAPIKeyCount, 1)
        XCTAssertEqual(detail.totalTokens, 175)
        XCTAssertEqual(detail.totalRequests, 2)
    }

    func testDeepSeekCardRendersMoneySummaryAndCharts() throws {
        let detail = ProviderUsageDetail(
            start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_086_400),
            timeZoneSeconds: 28_800,
            currency: "CNY",
            groups: [UsageDetailGroup(apiKeyID: "key-1", apiKeyLabel: "main",
                                      model: "deepseek-chat",
                                      days: [UsageDetailDay(date: Date(timeIntervalSince1970: 1_800_000_000),
                                                            cacheHitTokens: 100,
                                                            cacheMissTokens: 50,
                                                            outputTokens: 25,
                                                            requests: 2,
                                                            cost: 0.12)])]
        )
        let snapshot = ProviderSnapshot(
            id: "deepseek", displayName: "DeepSeek", glyph: .deepseek,
            fidelity: .derived, status: .ok,
            windows: [LimitWindow(id: "spend", label: "Account usage (CNY)",
                                  usedFraction: 9.20 / 20.07,
                                  money: UsageMoneyBreakdown(currency: "CNY", spent: 9.20, remaining: 10.87))],
            usageDetail: detail
        )
        let image = try XCTUnwrap(ImageRenderer(content: TooltipCard(snapshot: snapshot, now: Date())).nsImage)
        XCTAssertGreaterThan(image.size.height, NotchLayout.cardHeight(windowCount: 1) + NotchLayout.usageDetailChartHeight)
        if let path = ProcessInfo.processInfo.environment["DEEPSEEK_TOOLTIP_RENDER_PATH"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// The money bar's headline reads spent by default, what is left when the
/// notch is set that way — the same rounded-used derivation as the window
/// rows, so the two never disagree by a point.
final class MoneyHeadlineTests: XCTestCase {
    private let balance = UsageMoneyBreakdown(currency: "CNY", spent: 9.20, remaining: 10.87)

    func testSpentLeadsByDefault() {
        XCTAssertEqual(balance.headlineText(showingRemaining: false), "46% used")
    }

    func testRemainingLeadsWhenSet() {
        XCTAssertEqual(balance.headlineText(showingRemaining: true), "54% left")
    }

    func testTheEndsAgreeAtTheBoundaries() {
        let empty = UsageMoneyBreakdown(currency: "USD", spent: 0, remaining: 0)
        XCTAssertEqual(empty.headlineText(showingRemaining: false), "0% used")
        XCTAssertEqual(empty.headlineText(showingRemaining: true), "100% left")
        let drained = UsageMoneyBreakdown(currency: "USD", spent: 20, remaining: 0)
        XCTAssertEqual(drained.headlineText(showingRemaining: false), "100% used")
        XCTAssertEqual(drained.headlineText(showingRemaining: true), "0% left")
    }
}

/// One wallet per currency, and the order the server lists them in says nothing
/// about which holds the money. Reading the first is what made a funded CNY
/// wallet sitting behind an empty USD one read as 0%.
final class DeepSeekMultiWalletTests: XCTestCase {
    private func summary(wallets: [(String, String)], costs: [(String, String)]) -> String {
        let walletJSON = wallets
            .map { #"{"currency":"\#($0.0)","balance":"\#($0.1)"}"# }
            .joined(separator: ",")
        let costJSON = costs
            .map { #"{"currency":"\#($0.0)","amount":"\#($0.1)"}"# }
            .joined(separator: ",")
        return #"{"data":{"biz_data":{"normal_wallets":[\#(walletJSON)],"total_costs":[\#(costJSON)]}}}"#
    }

    /// The reported case: USD listed first and empty, CNY funded and used. It
    /// read 0% because the empty wallet was chosen, and its currency is the one
    /// `total_costs` is looked up in, so a real balance and a real cost were both
    /// read as zero.
    func testAFundedWalletIsReadEvenWhenAnEmptyOneIsListedFirst() throws {
        let json = summary(wallets: [("USD", "0"), ("CNY", "10.87")],
                           costs: [("CNY", "9.20")])
        let reading = try DeepSeekUsage.reading(fromJSON: json)
        XCTAssertEqual(reading.currency, "CNY")
        XCTAssertEqual(reading.spent, 9.20, accuracy: 0.001)
        XCTAssertEqual(reading.balance, 10.87, accuracy: 0.001)
        XCTAssertEqual(reading.usedFraction, 9.20 / 20.07, accuracy: 0.001)
    }

    /// The reverse order, so the fix is not a CNY special case.
    func testTheOrderTheWalletsArriveInDoesNotDecideIt() throws {
        let json = summary(wallets: [("CNY", "10.87"), ("USD", "0")],
                           costs: [("CNY", "9.20")])
        XCTAssertEqual(try DeepSeekUsage.reading(fromJSON: json).currency, "CNY")
    }

    /// A wallet with a balance but no recorded cost is still funded, and must
    /// not be passed over for one that merely has a cost line.
    func testABalanceAloneMakesAWalletTheFundedOne() throws {
        let json = summary(wallets: [("USD", "0"), ("EUR", "5")], costs: [])
        let reading = try DeepSeekUsage.reading(fromJSON: json)
        XCTAssertEqual(reading.currency, "EUR")
        XCTAssertEqual(reading.spent, 0, accuracy: 0.001)
        XCTAssertEqual(reading.usedFraction, 0, accuracy: 0.001)
    }

    /// Where two currencies are both real, the card carries one figure, so the
    /// largest is the one that means something — and the choice is not
    /// positional, which is the whole bug.
    func testTheLargestFundedWalletWinsWhenBothAreReal() throws {
        let json = summary(wallets: [("USD", "100"), ("CNY", "20")],
                           costs: [("USD", "10"), ("CNY", "5")])
        XCTAssertEqual(try DeepSeekUsage.reading(fromJSON: json).currency, "USD")

        let reversed = summary(wallets: [("CNY", "20"), ("USD", "100")],
                               costs: [("USD", "10"), ("CNY", "5")])
        XCTAssertEqual(try DeepSeekUsage.reading(fromJSON: reversed).currency, "USD")
    }

    /// Nothing funded anywhere is zero, which is what an empty account has always
    /// read as — not an error.
    func testAnAccountWithNothingInAnyWalletStillReadsAsZero() throws {
        let json = summary(wallets: [("USD", "0"), ("CNY", "0")], costs: [])
        let reading = try DeepSeekUsage.reading(fromJSON: json)
        XCTAssertEqual(reading.currency, "USD")
        XCTAssertEqual(reading.usedFraction, 0, accuracy: 0.001)
    }

    /// No wallets at all is still "no wallet", as before.
    func testNoWalletsIsStillAnError() {
        XCTAssertThrowsError(try DeepSeekUsage.reading(
            fromJSON: #"{"data":{"biz_data":{"normal_wallets":[],"total_costs":[]}}}"#))
    }

    /// A balance that will not parse must not become a reading that looks spent.
    func testAnUnparseableBalanceIsSkippedRatherThanZeroed() throws {
        let json = summary(wallets: [("USD", "not-a-number"), ("CNY", "3")], costs: [])
        XCTAssertEqual(try DeepSeekUsage.reading(fromJSON: json).currency, "CNY")
    }

    /// A single funded wallet is unchanged — the common case must not move.
    func testASingleFundedWalletIsUnchanged() throws {
        let json = summary(wallets: [("CNY", "10.87")], costs: [("CNY", "9.20")])
        let reading = try DeepSeekUsage.reading(fromJSON: json)
        XCTAssertEqual(reading.currency, "CNY")
        XCTAssertEqual(reading.usedFraction, 9.20 / 20.07, accuracy: 0.001)
    }

    /// Granted credit is spendable too, so it counts toward what is left.
    func testGrantedBalanceCountsAsRemaining() throws {
        let json = #"{"data":{"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"8.75"}],"bonus_wallets":[{"currency":"CNY","balance":"2.25"}],"total_costs":[{"currency":"CNY","amount":"9"}]}}}"#
        let reading = try DeepSeekUsage.reading(fromJSON: json)
        XCTAssertEqual(reading.balance, 11, accuracy: 0.001)
        XCTAssertEqual(reading.usedFraction, 9.0 / 20.0, accuracy: 0.001)
    }
}

/// DeepSeek answers an expired or missing token with HTTP 200 and an error code
/// in the body. That has to read as signed out, or the card keeps showing the
/// last reading with no hint that a sign-in would fix it.
@MainActor
final class DeepSeekExpiredSessionTests: XCTestCase {
    private func payload(summary: String) throws -> String {
        let object: [String: Any] = ["summary": summary, "amount": "{}", "cost": "{}",
                                     "start": 0, "end": 1, "time_zone_seconds": 28_800]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testAnInvalidTokenReadsAsSignedOut() throws {
        let json = try payload(summary: #"{"code":40003,"msg":"Authorization Failed (invalid token)","data":null}"#)
        XCTAssertThrowsError(try Sites.deepSeek.parse(json)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testAMissingTokenReadsAsSignedOut() throws {
        let json = try payload(summary: #"{"code":40002,"msg":"Missing Token","data":null}"#)
        XCTAssertThrowsError(try Sites.deepSeek.parse(json)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testTheSignInProbeRejectsAnExpiredToken() throws {
        let probe = try XCTUnwrap(Sites.deepSeek.authProbeScript)
        XCTAssertTrue(probe.contains("40002") && probe.contains("40003"))
    }
}

@MainActor
final class DeepSeekDisplayModeTests: XCTestCase {
    func testReadingFormattedBalanceAndLeftText() {
        let cnyReading = DeepSeekUsage.Reading(currency: "CNY", spent: 900, balance: 100, availableTokens: nil)
        XCTAssertEqual(cnyReading.formattedBalance, "¥100.00")
        XCTAssertEqual(cnyReading.balanceLeftText, "¥100.00 left")

        let usdReading = DeepSeekUsage.Reading(currency: "USD", spent: 50, balance: 14.28, availableTokens: 100_000)
        XCTAssertEqual(usdReading.formattedBalance, "$14.28")
        XCTAssertEqual(usdReading.balanceLeftText, "$14.28 left")

        let eurReading = DeepSeekUsage.Reading(currency: "EUR", spent: 0, balance: 5, availableTokens: nil)
        XCTAssertEqual(eurReading.formattedBalance, "€5.00")
        XCTAssertEqual(eurReading.balanceLeftText, "€5.00 left")

        let otherReading = DeepSeekUsage.Reading(currency: "GBP", spent: 10, balance: 25.50, availableTokens: nil)
        XCTAssertEqual(otherReading.formattedBalance, "GBP 25.50")
        XCTAssertEqual(otherReading.balanceLeftText, "GBP 25.50 left")
    }

    /// The ring prints the symbol and the whole units; the card keeps the exact
    /// figure. "¥51.83 left" under a ring was cut off at both ends of the notch.
    func testTheRingPrintsTheWholeBalanceAndTheCardTheExactOne() {
        let reading = DeepSeekUsage.Reading(currency: "CNY", spent: 0, balance: 51.83, availableTokens: nil)
        XCTAssertEqual(reading.wholeBalanceText, "¥51")
        XCTAssertEqual(reading.balanceLeftText, "¥51.83 left")

        let balanceWindow = DeepSeekUsage.windows(from: reading, displayMode: .balance)[0]
        XCTAssertEqual(balanceWindow.usedText, "¥51")
        XCTAssertEqual(balanceWindow.detail, "¥51.83 left")
    }

    func testWholeMoneyTruncatesRatherThanPromisingWhatTheWalletLacks() {
        XCTAssertEqual(DeepSeekUsage.wholeMoney(51.99, currency: "CNY"), "¥51")
        XCTAssertEqual(DeepSeekUsage.wholeMoney(52, currency: "CNY"), "¥52")
        XCTAssertEqual(DeepSeekUsage.wholeMoney(100, currency: "CNY"), "¥100")
        XCTAssertEqual(DeepSeekUsage.wholeMoney(9_999.99, currency: "CNY"), "¥9999")
        XCTAssertEqual(DeepSeekUsage.wholeMoney(12_345.67, currency: "CNY"), "¥12k")
        XCTAssertEqual(DeepSeekUsage.wholeMoney(14.28, currency: "USD"), "$14")
        XCTAssertEqual(DeepSeekUsage.wholeMoney(5, currency: "EUR"), "€5")
        XCTAssertEqual(DeepSeekUsage.wholeMoney(25.5, currency: "GBP"), "GBP 25")
    }

    /// Under one unit the ring is still green, so the figure must not say "¥0".
    func testWholeMoneySaysLessThanOneRatherThanZeroWhileAnythingIsLeft() {
        XCTAssertEqual(DeepSeekUsage.wholeMoney(0.83, currency: "CNY"), "<¥1")
        XCTAssertEqual(DeepSeekUsage.wholeMoney(0.004, currency: "CNY"), "<¥1")
        XCTAssertEqual(DeepSeekUsage.wholeMoney(0, currency: "CNY"), "¥0")
    }

    /// The balance is parsed out of the site's own text, so it can be any value
    /// `Double` reads. The exact formatting of nonsense is `formatMoney`'s; what
    /// matters is that none of it traps.
    func testWholeMoneySurvivesABalanceThatIsNotAnAmount() {
        XCTAssertEqual(DeepSeekUsage.wholeMoney(.infinity, currency: "CNY"),
                       DeepSeekUsage.formatMoney(.infinity, currency: "CNY"))
        XCTAssertEqual(DeepSeekUsage.wholeMoney(.nan, currency: "CNY"),
                       DeepSeekUsage.formatMoney(.nan, currency: "CNY"))
        XCTAssertEqual(DeepSeekUsage.wholeMoney(1e300, currency: "CNY"),
                       DeepSeekUsage.formatMoney(1e300, currency: "CNY"))
        XCTAssertEqual(DeepSeekUsage.wholeMoney(-0.5, currency: "CNY"), "¥0")
        XCTAssertEqual(DeepSeekUsage.wholeMoney(-1e300, currency: "CNY"), "¥0")
        // Past `Int.max` the exact formatting is `formatMoney`'s, but the
        // answer is still an amount rather than a trap.
        XCTAssertEqual(DeepSeekUsage.wholeMoney(-Double(Int.max), currency: "CNY"), "¥0")
    }

    /// The label that was cut off, and the compact one beside it, measured at
    /// the ring's own size: the balance has to sit inside the widest percentage
    /// the notch already draws.
    func testTheBalanceUnderTheRingIsNoWiderThanAPercentage() {
        let font = NSFont.systemFont(ofSize: Typography.fontSize(capPixels: 27), weight: .semibold)
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        let widestPercentage = width(">99.9%")

        for text in ["¥0", "<¥1", "¥51", "¥100", "¥9999", "¥12k", "GBP 25"] {
            XCTAssertLessThanOrEqual(width(text), widestPercentage, text)
        }
        XCTAssertGreaterThan(width("¥51.83 left"), width("100%"), "the label that was cut off")
    }

    func testBalanceDisplayModeBuildsBalanceAndHistoricalSpendWindows() {
        let reading = DeepSeekUsage.Reading(currency: "CNY", spent: 900, balance: 100, availableTokens: 3_300_000)
        let windows = DeepSeekUsage.windows(from: reading, displayMode: .balance)

        XCTAssertEqual(windows.count, 3)

        // Headline balance window
        let balanceWindow = windows[0]
        XCTAssertEqual(balanceWindow.id, "balance")
        XCTAssertEqual(balanceWindow.label, "Credit balance")
        XCTAssertNil(balanceWindow.usedFraction)
        XCTAssertEqual(balanceWindow.usedText, "¥100")
        XCTAssertEqual(balanceWindow.detail, "¥100.00 left")
        XCTAssertEqual(balanceWindow.bandOverride, .ample)
        XCTAssertTrue(balanceWindow.prefersUsedText)
        XCTAssertNil(balanceWindow.money)

        // Historical spend window (available in detailed card)
        let spendWindow = windows[1]
        XCTAssertEqual(spendWindow.id, "spend")
        XCTAssertEqual(spendWindow.label, "Account usage (CNY)")
        XCTAssertEqual(spendWindow.usedFraction, 900.0 / 1000.0)
        XCTAssertEqual(spendWindow.money?.spent, 900)
        XCTAssertEqual(spendWindow.money?.remaining, 100)
        XCTAssertFalse(spendWindow.prefersUsedText)

        // Available tokens window
        let tokenWindow = windows[2]
        XCTAssertEqual(tokenWindow.id, "available-tokens")
        XCTAssertEqual(tokenWindow.detail, "3.3M available")
    }

    func testZeroBalanceInBalanceModeIsExhausted() {
        let reading = DeepSeekUsage.Reading(currency: "CNY", spent: 100, balance: 0, availableTokens: nil)
        let windows = DeepSeekUsage.windows(from: reading, displayMode: .balance)

        XCTAssertEqual(windows[0].bandOverride, .exhausted)
        XCTAssertEqual(windows[0].usedText, "¥0")
        XCTAssertEqual(windows[0].detail, "¥0.00 left")
    }

    func testLifetimeSpendDisplayModeBuildsOnlySpendWindow() {
        let reading = DeepSeekUsage.Reading(currency: "CNY", spent: 900, balance: 100, availableTokens: 3_300_000)
        let windows = DeepSeekUsage.windows(from: reading, displayMode: .lifetimeSpend)

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].id, "spend")
        XCTAssertEqual(windows[0].label, "Account usage (CNY)")
        XCTAssertEqual(windows[0].usedFraction, 0.9)
        XCTAssertEqual(windows[0].money?.spent, 900)
        XCTAssertEqual(windows[0].money?.remaining, 100)
        XCTAssertFalse(windows[0].prefersUsedText)

        XCTAssertEqual(windows[1].id, "available-tokens")
    }

    func testSnapshotHeadlineTextInBalanceModeIsTheWholeBalance() {
        let reading = DeepSeekUsage.Reading(currency: "CNY", spent: 900, balance: 100, availableTokens: nil)
        let windows = DeepSeekUsage.windows(from: reading, displayMode: .balance)
        let snapshot = ProviderSnapshot(
            id: "deepseek",
            displayName: "DeepSeek",
            glyph: .deepseek,
            fidelity: .derived,
            status: .ok,
            windows: windows
        )

        XCTAssertEqual(snapshot.headlineText, "¥100")
        XCTAssertEqual(snapshot.headlineText(showingRemaining: true), "¥100")
        XCTAssertNil(snapshot.usedFraction)
        XCTAssertNil(snapshot.ringFraction)
        XCTAssertFalse(snapshot.isDepleted)
        XCTAssertEqual(snapshot.bandOverride, .ample)

        let title = StatusItemController.headerTitle(for: snapshot, now: Date())
        XCTAssertEqual(title, "DeepSeek — ¥100")
    }

    func testCardRendersWithBalanceDisplayMode() throws {
        let reading = DeepSeekUsage.Reading(currency: "CNY", spent: 900, balance: 100, availableTokens: 3_300_000)
        let windows = DeepSeekUsage.windows(from: reading, displayMode: .balance)
        let snapshot = ProviderSnapshot(
            id: "deepseek",
            displayName: "DeepSeek",
            glyph: .deepseek,
            fidelity: .derived,
            status: .ok,
            windows: windows
        )

        let image = try XCTUnwrap(ImageRenderer(content: TooltipCard(snapshot: snapshot, now: Date())).nsImage)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testPreferencesPersistDeepSeekDisplayMode() {
        let defaults = UserDefaults(suiteName: "DeepSeekDisplayModeTests")!
        defaults.removePersistentDomain(forName: "DeepSeekDisplayModeTests")

        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.deepSeekDisplayMode, .balance)

        prefs.deepSeekDisplayMode = .lifetimeSpend
        XCTAssertEqual(prefs.deepSeekDisplayMode, .lifetimeSpend)
        XCTAssertEqual(Preferences.storedDeepSeekDisplayMode(defaults: defaults), .lifetimeSpend)

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.deepSeekDisplayMode, .lifetimeSpend)

        defaults.removePersistentDomain(forName: "DeepSeekDisplayModeTests")
    }
}
