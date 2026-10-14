import XCTest
@testable import Codenotch

final class LocalTokenLedgerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = LMStudioLogFixtures.zone
        return calendar
    }

    private func prediction(_ instance: String = "qwen", at: Date, input: Int? = 10, output: Int? = 100,
                            reasoning: Int? = nil, rate: Double? = nil, drafts: (Int, Int)? = nil) -> LocalPrediction {
        LocalPrediction(instance: instance, at: at, inputTokens: input, outputTokens: output,
                        reasoningTokens: reasoning, tokensPerSecond: rate,
                        draftTokens: drafts?.0, acceptedDraftTokens: drafts?.1)
    }

    /// A day is filed and looked up in the same calendar, because the ledger
    /// owns it.
    ///
    /// They used to be separate arguments: `record` took whatever calendar its
    /// caller passed and every query quietly defaulted to `.current`. The day
    /// key is `startOfDay` — an absolute instant — so "10 September" filed in
    /// one zone and asked for in another are different keys, and the ledger
    /// answered with an empty day. LM Studio's metrics filed in an injected
    /// calendar and were read back in the machine's own, which is how it
    /// passed in the fixtures' time zone and read zero everywhere else.
    func testTheLedgerAnswersInTheCalendarItFilesIn() throws {
        // A zone at least ten hours from the machine's own, so no local day
        // can coincide with it whatever time zone the suite runs in.
        var elsewhere = Calendar(identifier: .gregorian)
        elsewhere.timeZone = TimeZone(secondsFromGMT:
            TimeZone.current.secondsFromGMT() >= 0 ? -10 * 3600 : 12 * 3600)!
        let at = LMStudioLogFixtures.date(2026, 9, 10, 12, 0, 0)

        var ledger = LocalTokenLedger(calendar: elsewhere)
        ledger.record(prediction(at: at, input: 30, output: 40))

        let summary = try XCTUnwrap(ledger.summary(for: "qwen", now: at))
        XCTAssertEqual(summary.today.requests, 1, "filed and read in different calendars")
        XCTAssertEqual(ledger.totals(for: "qwen", on: at)?.outputTokens, 40)
        XCTAssertEqual(ledger.totalsToday(now: at).inputTokens, 30)
    }

    func testTotalsAreKeptPerInstanceAndPerLocalDay() throws {
        let morning = LMStudioLogFixtures.date(2026, 9, 10, 9, 0, 0)
        let night = LMStudioLogFixtures.date(2026, 9, 10, 23, 59, 59)
        let yesterday = LMStudioLogFixtures.date(2026, 9, 9, 23, 59, 59)
        var ledger = LocalTokenLedger(calendar: calendar)
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertNil(ledger.summary(for: "qwen", now: morning))
        ledger.record(prediction(at: yesterday, input: 1000, output: 50))
        ledger.record(prediction(at: morning, input: 100, output: 300, reasoning: 200, drafts: (492, 176)))
        ledger.record(prediction(at: night, input: 50, output: 100, reasoning: nil, drafts: (8, 8)))
        ledger.record(prediction("other", at: night, input: 7, output: 7))

        let summary = try XCTUnwrap(ledger.summary(for: "qwen", now: night))
        XCTAssertEqual(summary.today.requests, 2)
        XCTAssertEqual(summary.today.inputTokens, 150)
        XCTAssertEqual(summary.today.outputTokens, 400)
        XCTAssertEqual(summary.today.reasoningTokens, 200)
        XCTAssertEqual(try XCTUnwrap(summary.today.reasoningShare), 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.today.draftAcceptance), 184.0 / 500.0, accuracy: 0.0001)
        XCTAssertEqual(summary.tokensTodayText, "150 in · 400 out")
        XCTAssertEqual(summary.requestsTodayText, "2")
        XCTAssertEqual(summary.reasoningShareText, "50%")
        XCTAssertEqual(summary.reasoningShareText, "\(Percent.text(for: 0.5))%")
        XCTAssertEqual(summary.last?.inputTokens, 50)
        XCTAssertEqual(ledger.instances, ["other", "qwen"])

        let yesterdays = try XCTUnwrap(ledger.totals(for: "qwen", on: yesterday))
        XCTAssertEqual(yesterdays.requests, 1)
        XCTAssertEqual(yesterdays.inputTokens, 1000)
        let all = ledger.totalsToday(now: night)
        XCTAssertEqual(all.requests, 3)
        XCTAssertEqual(all.totalTokens, 150 + 400 + 14)
        // Tomorrow, nothing has happened yet, but the last response is still the last.
        let tomorrow = try XCTUnwrap(ledger.summary(for: "qwen", now: night.addingTimeInterval(60)))
        XCTAssertEqual(tomorrow.today.requests, 0)
        XCTAssertEqual(tomorrow.tokensTodayText, "0 in · 0 out")
        XCTAssertEqual(tomorrow.last?.inputTokens, 50)
    }

    func testSharesAreAbsentRatherThanZeroWhenNothingWasCounted() {
        var totals = LocalTokenLedger.Totals()
        XCTAssertNil(totals.reasoningShare)
        XCTAssertNil(totals.draftAcceptance)
        totals.add(prediction(at: Date(), output: 10, reasoning: 0))
        XCTAssertEqual(totals.reasoningShare, 0)
        XCTAssertNil(totals.draftAcceptance, "no drafts is not 0% accepted")
        let summary = LocalTokenLedger.Summary(today: LocalTokenLedger.Totals(), last: nil)
        XCTAssertEqual(summary.reasoningShareText, "—")
        XCTAssertEqual(summary.draftAcceptanceText, "—")
        XCTAssertEqual(summary.contextText(contextLength: 4096), "—")
        XCTAssertNil(summary.contextFraction(contextLength: 4096))
    }

    func testTheContextFractionIsTheLastPromptAgainstTheLoadedWindow() throws {
        let summary = LocalTokenLedger.Summary(today: LocalTokenLedger.Totals(),
                                               last: prediction(at: Date(), input: 1024, output: 1))
        XCTAssertEqual(try XCTUnwrap(summary.contextFraction(contextLength: 4096)), 0.25, accuracy: 0.0001)
        XCTAssertEqual(summary.contextText(contextLength: 4096), "25% · 1024")
        XCTAssertEqual(summary.contextFraction(contextLength: 512), 1, "a truncated prompt reads as a full window")
        XCTAssertNil(summary.contextFraction(contextLength: nil))
        XCTAssertNil(summary.contextFraction(contextLength: 0))
        XCTAssertEqual(summary.contextText(contextLength: nil), "1024 tokens")
        let large = LocalTokenLedger.Summary(today: LocalTokenLedger.Totals(),
                                             last: prediction(at: Date(), input: 131_072, output: 1))
        XCTAssertEqual(large.contextText(contextLength: 262_144), "50% · 131k")
    }

    func testTheNewestResponseKeepsTheCellWhateverOrderLinesArrive() {
        let earlier = LMStudioLogFixtures.date(2026, 9, 10, 9, 0, 0)
        let later = earlier.addingTimeInterval(60)
        var ledger = LocalTokenLedger(calendar: calendar)
        ledger.record(prediction(at: later, input: 2))
        ledger.record(prediction(at: earlier, input: 1))
        XCTAssertEqual(ledger.last["qwen"]?.inputTokens, 2)
        ledger.record(prediction(at: later, input: 3), as: "lmstudio:model:qwen")
        XCTAssertEqual(ledger.last["lmstudio:model:qwen"]?.inputTokens, 3, "a key names the entry")
        XCTAssertEqual(ledger.last["qwen"]?.inputTokens, 2)
    }

    func testOldDaysAgeOut() throws {
        let today = LMStudioLogFixtures.date(2026, 9, 10, 12, 0, 0)
        let ancient = calendar.date(byAdding: .day, value: -(LocalTokenLedger.retentionDays + 1), to: today)!
        let recent = calendar.date(byAdding: .day, value: -(LocalTokenLedger.retentionDays - 1), to: today)!
        var ledger = LocalTokenLedger(calendar: calendar)
        ledger.record(prediction(at: ancient))
        ledger.record(prediction(at: recent))
        ledger.record(prediction(at: today))
        XCTAssertNil(ledger.totals(for: "qwen", on: ancient))
        XCTAssertNotNil(ledger.totals(for: "qwen", on: recent))
        XCTAssertEqual(ledger.days["qwen"]?.count, 2)
    }
}

final class LocalModelPerformanceSourcesTests: XCTestCase {
    func testSecondsAndRatesAgreeWithTheNanosecondReading() throws {
        let nanoseconds = try XCTUnwrap(LocalModelPerformance(outputTokens: 300, durationNanoseconds: 17_839_055_000))
        let seconds = try XCTUnwrap(LocalModelPerformance(outputTokens: 300, seconds: 17.839055))
        let rate = try XCTUnwrap(LocalModelPerformance(outputTokens: 300, tokensPerSecond: 17.92897117267284))
        XCTAssertEqual(seconds.tokensPerSecond, nanoseconds.tokensPerSecond, accuracy: 0.0001)
        XCTAssertEqual(rate.tokensPerSecond, 17.929, accuracy: 0.001)
        XCTAssertEqual(rate.band, .slow)
        XCTAssertFalse(rate.isApproximate)
        XCTAssertEqual(rate.speedText, "\(17.9.formatted(.number.precision(.fractionLength(0...1)))) tok/s")
        XCTAssertEqual(rate.headlineText, "18 tok/s")
        for seconds in [0, -1, Double.nan, Double.infinity, 2e9] {
            XCTAssertNil(LocalModelPerformance(outputTokens: 10, seconds: seconds), "\(seconds)")
        }
        XCTAssertNil(LocalModelPerformance(outputTokens: 10, tokensPerSecond: 0))
        XCTAssertNil(LocalModelPerformance(outputTokens: 0, tokensPerSecond: 5))
    }

    func testATimedReadingSaysSo() throws {
        let timed = try XCTUnwrap(LocalModelPerformance(outputTokens: 60, seconds: 2, isApproximate: true))
        XCTAssertEqual(timed.speedText, "~\(30.0.formatted(.number.precision(.fractionLength(0...1)))) tok/s")
        XCTAssertEqual(timed.headlineText, "30 tok/s")
        XCTAssertEqual(timed.band, .smooth)
        let exact = try XCTUnwrap(LocalModelPerformance(outputTokens: 60, seconds: 2))
        XCTAssertNotEqual(timed, exact, "the qualifier is part of the reading")
        let fast = try XCTUnwrap(LocalModelPerformance(outputTokens: 2400, seconds: 1, isApproximate: true))
        // Built the way the label is, so a comma-decimal Mac agrees with a point-decimal one.
        XCTAssertEqual(fast.headlineText, "\(2400.0.formatted(.number.notation(.compactName).precision(.significantDigits(1...2)))) t/s")
    }

    func testTheHeadlineDropsTheTenthAndTheTooltipKeepsIt() throws {
        let tenth = try XCTUnwrap(LocalModelPerformance(outputTokens: 300, tokensPerSecond: 42.8))
        XCTAssertEqual(tenth.headlineText, "43 tok/s")
        XCTAssertEqual(tenth.speedText, "\(42.8.formatted(.number.precision(.fractionLength(0...1)))) tok/s")
        let hundreds = try XCTUnwrap(LocalModelPerformance(outputTokens: 300, tokensPerSecond: 123.4))
        XCTAssertEqual(hundreds.headlineText, "123 tok/s")
        let slow = try XCTUnwrap(LocalModelPerformance(outputTokens: 300, tokensPerSecond: 0.5))
        XCTAssertEqual(slow.headlineText, "<1 tok/s")
        let edge = try XCTUnwrap(LocalModelPerformance(outputTokens: 300, tokensPerSecond: 999.6))
        XCTAssertEqual(edge.headlineText, "\(1000.0.formatted(.number.notation(.compactName).precision(.significantDigits(1...2)))) t/s")
        let approximate = try XCTUnwrap(LocalModelPerformance(outputTokens: 5, seconds: 2, isApproximate: true))
        XCTAssertEqual(approximate.headlineText, "3 tok/s")
    }
}
