import XCTest
@testable import Codenotch

/// Pins what `kiro-cli chat --no-interactive "/usage"` prints. The CLI paints
/// a TUI card; these fixtures are that text, including the ANSI the parser
/// has to strip before it can read a plan or a bar.
final class KiroUsageTests: XCTestCase {
    /// Verbatim free-tier card, 25% of 50.
    private let free = """
    | KIRO FREE                                          |
    ████████████████████████████████████████████████████ 25%
    (12.50 of 50 covered in plan), resets on 01/15
    """

    /// Verbatim paid card with a bonus wallet.
    private let proBonus = """
    | KIRO PRO                                           |
    ████████████████████████████████████████████████████ 80%
    (40.00 of 50 covered in plan), resets on 02/01
    Bonus credits: 5.00/10 credits used, expires in 7 days
    """

    /// Verbatim kiro-cli 2.x `/usage` (ANSI left on).
    private let estimated = """
    \u{001B}[1mEstimated Usage\u{001B}[0m | resets on 2026-06-01 | \u{001B}[mKIRO FREE\u{001B}[0m

    🎁 Bonus credits: 45.53/2000 credits used, expires in 19 days

    \u{001B}[1mCredits\u{001B}[0m (0.17 of 50 covered in plan)
    ████████████████████████████████████████████████████████████████████████████████ 0%

    Overages: \u{001B}[1mDisabled\u{001B}[0m

    To manage your plan or configure overages navigate to https://app.kiro.dev/account/usage
    """

    /// Verbatim 2.20 summary — a plan with no meters.
    private let proMaxSummary = """
    \u{001B}[32mPlan: KIRO PRO MAX | 1 usage breakdowns\u{001B}[0m
    """

    /// Verbatim managed Q Developer card — a plan, no credits.
    private let qDeveloper = """
    Plan: Q Developer Pro
    Your plan is managed by admin

    Tip: to see context window usage, run /context
    """

    /// What the CLI actually prints when chat cannot start a session.
    private let notLoggedIn = """
    Failed to initialize auth portal.
    Please try again with: kiro-cli login --use-device-flow
    error: OAuth error: All callback ports are in use.
    """

    /// Isolated from the machine clock so `MM/DD` year wrapping is deterministic.
    private func noon(year: Int, month: Int, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func day(year: Int, month: Int, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func parse(_ text: String, now: Date? = nil) throws -> KiroUsage.Reading {
        try KiroUsage.parseCLIOutput(text, now: now ?? noon(year: 2026, month: 1, day: 10))
    }

    func testReadsTheFreeTierBar() throws {
        let reading = try parse(free)
        XCTAssertEqual(reading.plan, "Kiro Free")
        XCTAssertTrue(reading.hasUsageMetrics)
        XCTAssertEqual(reading.windows.map(\.id), ["credits"])
        let credits = try XCTUnwrap(reading.windows.first)
        XCTAssertEqual(credits.label, "Credits")
        XCTAssertEqual(credits.usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(credits.duration, 30 * 86400)
        XCTAssertEqual(credits.resetsAt, day(year: 2026, month: 1, day: 15))
        XCTAssertNil(reading.bonusUsed)
        XCTAssertNil(reading.overageEnabled)
    }

    func testReadsProCreditsAndTheBonusWallet() throws {
        let now = noon(year: 2026, month: 1, day: 10)
        let reading = try parse(proBonus, now: now)
        XCTAssertEqual(reading.plan, "Kiro Pro")
        XCTAssertEqual(reading.windows.map(\.id), ["credits", "bonus"])
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.80, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[0].resetsAt, day(year: 2026, month: 2, day: 1))

        let bonus = try XCTUnwrap(reading.windows.first { $0.id == "bonus" })
        XCTAssertEqual(bonus.group, "Bonus")
        XCTAssertEqual(bonus.label, "Credits")
        XCTAssertEqual(bonus.usedFraction ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(bonus.remaining, 5)
        XCTAssertEqual(bonus.resetsAt, Calendar.current.date(byAdding: .day, value: 7, to: now))
        XCTAssertEqual(reading.bonusUsed ?? -1, 5.00, accuracy: 0.0001)
        XCTAssertEqual(reading.bonusTotal ?? -1, 10, accuracy: 0.0001)
    }

    func testReadsTheTwoDotXEstimatedUsageCard() throws {
        let reading = try parse(estimated, now: noon(year: 2026, month: 5, day: 15))
        XCTAssertEqual(reading.plan, "Kiro Free")
        XCTAssertTrue(reading.hasUsageMetrics)
        XCTAssertEqual(reading.windows.map(\.id), ["credits", "bonus"])
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[0].resetsAt, day(year: 2026, month: 6, day: 1))
        XCTAssertEqual(reading.bonusUsed ?? -1, 45.53, accuracy: 0.0001)
        XCTAssertEqual(reading.bonusTotal ?? -1, 2000, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[1].usedFraction ?? -1, 45.53 / 2000, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[1].remaining, 1954)
        XCTAssertEqual(reading.overageEnabled, false)
        XCTAssertNil(reading.overageUsedCLI)
    }

    /// A breakdown count is not a meter. Drawing 0% here would report an
    /// allowance the CLI did not state.
    func testAPlanOnlyProMaxSummaryHasNoMeters() throws {
        let reading = try parse(proMaxSummary)
        XCTAssertEqual(reading.plan, "Kiro Pro Max")
        XCTAssertFalse(reading.hasUsageMetrics)
        XCTAssertTrue(reading.windows.isEmpty)
        XCTAssertNil(reading.bonusUsed)
        XCTAssertNil(reading.overageEnabled)
    }

    func testAManagedQDeveloperPlanHasNoMeters() throws {
        let reading = try parse(qDeveloper)
        XCTAssertEqual(reading.plan, "Q Developer Pro")
        XCTAssertFalse(reading.hasUsageMetrics)
        XCTAssertTrue(reading.windows.isEmpty)
    }

    func testLoginPhrasesNeedAuth() {
        func assertNeedsAuth(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try parse(text), file: file, line: line) { error in
                guard case UsageProviderError.needsAuth = error else {
                    return XCTFail("expected needsAuth, got \(error)", file: file, line: line)
                }
            }
        }
        assertNeedsAuth(notLoggedIn)
        assertNeedsAuth("\u{001B}[31mNot logged in.\u{001B}[0m")
        // Each of these is the whole message on some CLI builds; matching only
        // "not logged in" would miss them.
        assertNeedsAuth("Failed to initialize auth portal.")
        assertNeedsAuth("login required")
        assertNeedsAuth("NOT LOGGED IN")
    }

    func testGarbageIsNothingMetered() {
        for text in ["Usage: unknown format", "hello", ""] {
            XCTAssertThrowsError(try parse(text)) { error in
                guard case UsageProviderError.nothingMetered = error else {
                    return XCTFail("expected nothingMetered, got \(error)")
                }
            }
        }
    }

    func testDisplayPlanNameTitleCasesKiroAndLeavesOthers() {
        XCTAssertEqual(KiroUsage.displayPlanName("KIRO FREE"), "Kiro Free")
        XCTAssertEqual(KiroUsage.displayPlanName("KIRO PRO MAX"), "Kiro Pro Max")
        XCTAssertEqual(KiroUsage.displayPlanName("KIRO PRO+"), "Kiro Pro+")
        XCTAssertEqual(KiroUsage.displayPlanName("  KIRO   FREE  "), "Kiro Free")
        XCTAssertEqual(KiroUsage.displayPlanName("kiro free"), "Kiro Free")
        XCTAssertEqual(KiroUsage.displayPlanName("Q Developer Pro"), "Q Developer Pro")
        XCTAssertEqual(KiroUsage.displayPlanName("\u{001B}[1mKIRO FREE\u{001B}[0m"), "Kiro Free")
    }

    func testStripANSIRemovesCSIAndOSC() {
        XCTAssertEqual(KiroUsage.stripANSI("\u{001B}[32mKIRO\u{001B}[0m"), "KIRO")
        XCTAssertEqual(KiroUsage.stripANSI("\u{001B}[38;5;11m50%\u{001B}[m"), "50%")
        XCTAssertEqual(KiroUsage.stripANSI("\u{001B}[1;32mKIRO\u{001B}[0m"), "KIRO")
        XCTAssertEqual(KiroUsage.stripANSI("\u{001B}[?25lKIRO\u{001B}[?25h"), "KIRO")
        XCTAssertEqual(KiroUsage.stripANSI("\u{001B}[38:2:255:0:0m50%\u{001B}[m"), "50%")
        XCTAssertEqual(KiroUsage.stripANSI("\u{001B}(BKIRO"), "KIRO")
        XCTAssertEqual(KiroUsage.stripANSI("\u{001B}]0;title\u{0007}Plan"), "Plan")
        XCTAssertEqual(KiroUsage.stripANSI("\u{001B}]0;title\u{001B}\\Plan"), "Plan")
    }

    /// No year is printed. Read on the 20th, the 15th already passed and
    /// belongs to next year — picking this year puts the reset in the past.
    func testAJanuaryResetReadLaterInJanuaryBelongsToNextYear() throws {
        let reading = try parse(free, now: noon(year: 2026, month: 1, day: 20))
        XCTAssertEqual(reading.windows[0].resetsAt, day(year: 2027, month: 1, day: 15))
    }

    /// Midnight of the printed day is still "today". Comparing the stamp to
    /// noon of that day would wrap to next year.
    func testAResetReadOnThatDayStaysThisYear() throws {
        let reading = try parse(free, now: noon(year: 2026, month: 1, day: 15))
        XCTAssertEqual(reading.windows[0].resetsAt, day(year: 2026, month: 1, day: 15))
    }

    func testAJanuaryResetReadInDecemberBelongsToNextYear() throws {
        let reading = try parse(free, now: noon(year: 2026, month: 12, day: 20))
        XCTAssertEqual(reading.windows[0].resetsAt, day(year: 2027, month: 1, day: 15))
    }

    func testAnISOResetDateIsReadAsPrinted() throws {
        let reading = try parse(estimated, now: noon(year: 2026, month: 5, day: 15))
        XCTAssertEqual(reading.windows[0].resetsAt, day(year: 2026, month: 6, day: 1))
    }

    /// A bar with no credits line still has a fraction. The omitted
    /// free-tier total is 50, and is not needed to read the percent.
    func testPercentOnlyUsesTheBar() throws {
        let text = """
        | KIRO FREE |
        ████████████████████████████████████████████████████ 25%
        """
        let reading = try parse(text)
        XCTAssertEqual(reading.windows.map(\.id), ["credits"])
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertNil(reading.windows[0].duration)
        XCTAssertNil(reading.windows[0].resetsAt)
    }

    func testCreditsWithoutABarUseTheRatio() throws {
        let text = """
        | KIRO FREE |
        (12.50 of 50 covered in plan), resets on 01/15
        """
        let reading = try parse(text)
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.25, accuracy: 0.0001)
    }

    /// First number is used, not remaining. Remaining-of-total would be 100%.
    func testZeroCoveredIsZeroUsedNotAFullRing() throws {
        let text = """
        Plan: KIRO PRO MAX | 1 usage breakdowns
        Credits (0 of 5000 covered in plan)
        """
        let reading = try parse(text)
        XCTAssertTrue(reading.hasUsageMetrics)
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0, accuracy: 0.0001)
    }

    func testEnabledOveragesAndCreditsUsedAreRead() throws {
        let text = """
        Estimated Usage | resets on 2026-06-01 | KIRO PRO
        Credits (1000.00 of 1000 covered in plan)
        ████████████████████████████████████████████████████████████████████████████████ 100%

        Overages: Enabled  billed at $0.04 per request
        Credits used: 40.29
        Est. cost: $1.61 USD
        """
        let reading = try parse(text, now: noon(year: 2026, month: 5, day: 15))
        XCTAssertEqual(reading.plan, "Kiro Pro")
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(reading.overageEnabled, true)
        XCTAssertEqual(reading.overageUsedCLI ?? -1, 40.29, accuracy: 0.0001)
    }

    func testAPipeHeaderAloneIsAPlanNotAZeroRing() throws {
        let reading = try parse("| KIRO FREE                                          |")
        XCTAssertEqual(reading.plan, "Kiro Free")
        XCTAssertFalse(reading.hasUsageMetrics)
        XCTAssertTrue(reading.windows.isEmpty)
    }

    /// A plan line with no meters is not an error and not a 0% ring — even
    /// without "managed by admin" or the breakdowns suffix.
    func testABarePlanLineHasNoMeters() throws {
        let reading = try parse("Plan: KIRO PRO MAX")
        XCTAssertEqual(reading.plan, "Kiro Pro Max")
        XCTAssertFalse(reading.hasUsageMetrics)
        XCTAssertTrue(reading.windows.isEmpty)
    }

    func testABoxedPlanSummaryHasNoMeters() throws {
        let reading = try parse("┃ Plan: KIRO PRO MAX | 1 usage breakdowns ┃")
        XCTAssertEqual(reading.plan, "Kiro Pro Max")
        XCTAssertFalse(reading.hasUsageMetrics)
        XCTAssertTrue(reading.windows.isEmpty)
    }

    func testTitleCaseKiroPlanWithEstimatedUsage() throws {
        let text = """
        Estimated Usage | resets on 2026-06-01 | Kiro Pro
        Credits (100.00 of 1,000 covered in plan)
        ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ 10%
        """
        let reading = try parse(text, now: noon(year: 2026, month: 5, day: 15))
        XCTAssertEqual(reading.plan, "Kiro Pro")
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.10, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[0].resetsAt, day(year: 2026, month: 6, day: 1))
    }

    func testUnicodeBoxDrawingsAndDecimalPercent() throws {
        let text = """
        │ Kiro Free │
        [████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░] 12.5%
        (6.25 of 50.0 covered in plan), Resets on: 2026-07-01
        """
        let reading = try parse(text, now: noon(year: 2026, month: 5, day: 15))
        XCTAssertEqual(reading.plan, "Kiro Free")
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.125, accuracy: 0.0001)
        XCTAssertEqual(reading.windows[0].resetsAt, day(year: 2026, month: 7, day: 1))
    }

    func testOutputWithLoginHintDoesNotFalselyNeedAuth() throws {
        let text = """
        Estimated Usage | resets on 2026-06-01 | KIRO PRO
        Credits (500 of 1,000 covered in plan)
        ████████████████████████████████████████ 50%
        Tip: To change accounts use kiro-cli login
        """
        let reading = try parse(text, now: noon(year: 2026, month: 5, day: 15))
        XCTAssertEqual(reading.plan, "Kiro Pro")
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.50, accuracy: 0.0001)
    }

    func testThousandsCommasAndBonusCreditsFormatting() throws {
        let text = """
        Estimated Usage | KIRO PRO+
        Credits (1,250 of 5,000 covered in plan)
        ████████████ 25%
        Bonus credits: 1,000 / 2,000 credits used, expires in 10 days
        """
        let reading = try parse(text, now: noon(year: 2026, month: 5, day: 15))
        XCTAssertEqual(reading.plan, "Kiro Pro+")
        XCTAssertEqual(reading.windows[0].usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(reading.bonusUsed ?? -1, 1000, accuracy: 0.0001)
        XCTAssertEqual(reading.bonusTotal ?? -1, 2000, accuracy: 0.0001)
    }
}
