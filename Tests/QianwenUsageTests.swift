import XCTest
import SwiftUI
@testable import Codenotch

/// Guards the QianwenAI Token Plan answer and the site that fetches it.
///
/// **Recorded — with the account's own numbers taken out.** Every envelope here
/// is a recording from the platform: the failure bodies from running the shipped
/// script against the live gateway with only the `sec_token` call stubbed, and
/// the success shapes from live signed-in reads taken from the app's own log
/// (`Log.usage`, "usage -> …"). The weekly success shape is the first such read
/// (2026-09-18); the monthly one is a read of the same call once the account
/// moved to a monthly plan, captured 2026-09-23 against the console's own
/// 1.1.43 build. `per1WeekPercentage`, `per1WeekResetTime`,
/// `per1MonthPercentage`, `per1MonthResetTime` and the `requestId`s in those
/// success fixtures are synthetic — this repository is public, and the recorded
/// ones are the user's own usage and account traffic. Everything that is
/// protocol rather than personal is left as the platform sent it: the `ret`
/// message, `"Success."`, the `SUCCESS` code and the Api name.
///
/// The console publishes no usage API, no schema and no documentation, so these
/// recordings are the whole of the contract, and each fixture is pinned as far
/// as the read it came from can pin it.
@MainActor
final class QianwenUsageTests: XCTestCase {
    /// The tests run inside the app, so this is the installed app's own
    /// preference — saved and put back rather than left clobbered.
    private let signedInKey = "qianwenai.signedIn"
    private var savedSignedIn: Any?

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        savedSignedIn = UserDefaults.standard.object(forKey: signedInKey)
        UserDefaults.standard.removeObject(forKey: signedInKey)
    }

    override func tearDown() {
        if let savedSignedIn {
            UserDefaults.standard.set(savedSignedIn, forKey: signedInKey)
        } else {
            UserDefaults.standard.removeObject(forKey: signedInKey)
        }
        super.tearDown()
    }

    /// A success envelope in the shape both live signed-in reads answered with
    /// (2026-09-18 and 2026-09-23), with `payload` where the numbers sit:
    /// `data.DataV2.data.data`. The wrapper around them — `DataV2.ret`'s
    /// platform message, and `msg`/`code`/`requestId`/`success` of its own — is
    /// as recorded, and the console's own client reads straight through it. So
    /// every case below runs against the real nesting rather than a convenient
    /// one.
    private func envelope(payload: String) -> String {
        """
        { "code": "200", "successResponse": true, "httpStatusCode": "200",
          "requestId": "00000000-0000-4000-8000-000000000000",
          "data": { "success": true, "httpStatus": 200, "errorCode": "", "errorMsg": "",
                    "api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
                    "DataV2": { "ret": ["SUCCESS::接口调用成功"],
                                "data": { "msg": "Success.", "code": "SUCCESS",
                                          "success": true,
                                          "requestId": "00000000-0000-4000-8000-000000000000",
                                          "data": \(payload) } } } }
        """
    }

    /// The recorded nesting, read the way the console's own extractor reads it:
    /// through `DataV2.data` and then one level further into that, which is
    /// where the numbers are.
    func testEnvelopeUnwrapsTheRecordedDataV2Wrapper() throws {
        let flat = try QianwenUsage.payload(fromJSON: envelope(
            payload: #"{"per1WeekPercentage":0.25}"#
        ))
        XCTAssertEqual(flat["per1WeekPercentage"] as? Double, 0.25)

        // Stopping at the `DataV2.data` wrapper is precisely the failure the
        // extra unwrap avoids, and its own keys — `ret`'s message lives beside
        // them — are what tell the two levels apart here.
        XCTAssertNil(flat["msg"])
        XCTAssertNil(flat["requestId"])
        XCTAssertNil(flat["data"])

        // No read has answered with the numbers directly under `DataV2.data`,
        // so this is tolerance rather than a recording: the extractor asks for
        // one level further *when the object it reached carries a `data`*, and
        // a wrapper that did not would have to come through as it stands.
        let direct = try QianwenUsage.payload(fromJSON: """
        {"code":"200","successResponse":true,
         "data":{"success":true,"DataV2":{"data":{"per1WeekPercentage":0.25}}}}
        """)
        XCTAssertEqual(direct["per1WeekPercentage"] as? Double, 0.25)
    }

    /// The first live signed-in read, as the app logged it on 2026-09-18:
    /// `per1WeekPercentage`, `per1WeekResetTime` and both `requestId`s replaced
    /// with synthetic values, everything else as the platform sent it. This is
    /// the weekly plan's reading, and a weekly account still gets exactly it.
    func testTheRecordedSuccessReadsAsOneSevenDayWindow() throws {
        let recorded = """
        { "code": "200", "successResponse": true, "httpStatusCode": "200",
          "requestId": "00000000-0000-4000-8000-000000000000",
          "data": { "success": true, "httpStatus": 200, "errorCode": "", "errorMsg": "",
                    "api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
                    "DataV2": { "ret": ["SUCCESS::接口调用成功"],
                                "data": { "msg": "Success.", "code": "SUCCESS",
                                          "success": true,
                                          "requestId": "00000000-0000-4000-8000-000000000000",
                                          "data": { "per1WeekResetTime": 1700179200000,
                                                    "per1WeekPercentage": 0.42 } } } } }
        """
        let windows = try QianwenUsage.windows(fromJSON: recorded, now: now)

        // One window — not one per `ret` entry — and no error from `ret`'s
        // message, `msg`, or the `success`/`code` the wrapper carries of its
        // own. None of them is read as a reading.
        XCTAssertEqual(windows.count, 1)
        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.id, "week")
        XCTAssertEqual(window.label, "Weekly limit")
        XCTAssertEqual(window.duration, 7 * 86_400)
        XCTAssertEqual(window.usedFraction ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(window.resetsAt, Date(timeIntervalSince1970: 1_700_179_200))
    }

    /// The same call read on 2026-09-23, once the account's Token Plan was
    /// monthly: the payload's own pair carries `per1Month*` and there is no
    /// `per1Week*` field at all, which is exactly what the parser used to read
    /// as nothing metered — the ring reported no usage. Same envelope through
    /// `envelope(payload:)`, same synthetic percentage and reset time as the
    /// weekly fixture.
    func testTheMonthlyPlanReadsAsOneThirtyDayWindow() throws {
        let windows = try QianwenUsage.windows(
            fromJSON: envelope(
                payload: #"{"per1MonthPercentage":0.42,"per1MonthResetTime":1700179200000}"#
            ),
            now: now
        )

        XCTAssertEqual(windows.count, 1)
        let window = try XCTUnwrap(windows.first)
        // The id is the role, not the period: `Sites.qianwen` resolves its
        // headline and weekly rings by it, so "week" is what makes the ring
        // draw this monthly reading at all. The period is what the label says.
        XCTAssertEqual(window.id, "week")
        XCTAssertEqual(window.label, "Monthly limit")
        XCTAssertEqual(window.duration, 30 * 86_400)
        XCTAssertEqual(window.usedFraction ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(window.resetsAt, Date(timeIntervalSince1970: 1_700_179_200))
    }

    /// Both pairs present is not a tie to break by preference: the console's
    /// own card takes the weekly branch whenever `per1WeekPercentage` is there
    /// (`t = e.per1WeekPercentage != null`), so the percentage and the reset
    /// time have to be read from that same branch rather than per field.
    func testWeeklyWinsWhenBothPairsArePresent() throws {
        let window = try XCTUnwrap(try QianwenUsage.windows(
            fromJSON: envelope(payload: """
                {"per1WeekPercentage":0.42,"per1WeekResetTime":1700179200000,
                 "per1MonthPercentage":0.9,"per1MonthResetTime":1704067200000}
                """),
            now: now
        ).first)

        XCTAssertEqual(window.label, "Weekly limit")
        XCTAssertEqual(window.duration, 7 * 86_400)
        XCTAssertEqual(window.usedFraction ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(window.resetsAt, Date(timeIntervalSince1970: 1_700_179_200),
                       "the weekly branch's own reset time, not the monthly one")
    }

    /// An explicit JSON `null` is the *absence* of the weekly pair, not a
    /// present-but-unreadable one. The console says the same thing —
    /// `e.per1WeekPercentage != null` is false for `null` — so a monthly plan
    /// that also answers a nulled weekly field still reads as monthly. Pinned
    /// separately from the missing-key case because the two are only the same
    /// answer if the `NSNull` check is actually there.
    func testANulledWeeklyFieldStillReadsAsMonthly() throws {
        let window = try XCTUnwrap(try QianwenUsage.windows(
            fromJSON: envelope(payload: """
                {"per1WeekPercentage":null,"per1MonthPercentage":0.42,
                 "per1MonthResetTime":1700179200000}
                """),
            now: now
        ).first)

        XCTAssertEqual(window.label, "Monthly limit")
        XCTAssertEqual(window.duration, 30 * 86_400)
        XCTAssertEqual(window.usedFraction ?? -1, 0.42, accuracy: 0.0001)
    }

    /// The branch is chosen by the field's *presence*, not by whether its value
    /// can be read — the one rule that separates this from a plausible
    /// alternative (`number(weeklyValue) != nil`), which no other test here can
    /// tell apart, since a readable weekly field makes both rules agree.
    ///
    /// An unreadable weekly field is a failed read of a weekly plan: falling
    /// through to the monthly number would report a *different period's* usage
    /// as this one's, which is worse than reporting nothing. So this is
    /// `nothingMetered`, and specifically not a monthly reading of 0.42.
    func testAnUnreadableWeeklyFieldDoesNotFallThroughToTheMonthlyOne() {
        XCTAssertThrowsError(try QianwenUsage.windows(
            fromJSON: envelope(payload: """
                {"per1WeekPercentage":"abc","per1MonthPercentage":0.42,
                 "per1MonthResetTime":1700179200000}
                """)
        )) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    /// The whole path the ring takes, for the monthly payload: parsed windows
    /// plus the roles `Sites.qianwen` declares for them. A read that labelled
    /// the period correctly but reported it under an id of its own would pass
    /// every assertion above and still draw an empty ring — `headline` returns
    /// nil when no window matches `headlineID`. This is the assertion that
    /// catches that class of bug rather than the parser's shape.
    func testTheMonthlyPayloadStillResolvesTheSitesDeclaredRings() throws {
        let windows = try QianwenUsage.windows(
            fromJSON: envelope(
                payload: #"{"per1MonthPercentage":0.42,"per1MonthResetTime":1700179200000}"#
            ),
            now: now
        )
        let site = Sites.qianwen
        let snapshot = ProviderSnapshot(
            id: site.id, displayName: site.displayName, glyph: site.glyph,
            fidelity: site.fidelity, status: .ok,
            windows: windows, headlineID: site.headlineID, weeklyID: site.weeklyID
        )

        let headline = try XCTUnwrap(snapshot.headline, "the main ring resolves no window")
        XCTAssertEqual(headline.usedFraction ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(snapshot.weeklyLimitWindow?.usedFraction ?? -1, 0.42, accuracy: 0.0001)
        // Same id in both roles, so the second ring is suppressed rather than
        // drawing the one allowance twice.
        XCTAssertNil(snapshot.weeklyWindow)
    }

    /// `per1WeekPercentage` is the fraction of the 7-day allowance already
    /// spent — the console draws remaining as `1 - it` — and both ends are
    /// clamped, because the platform stops the work at the limit instead of
    /// reporting past it. The monthly field is the same kind of number and gets
    /// the same clamp.
    func testPercentageIsTheSpentFractionAndIsClamped() throws {
        let window = try XCTUnwrap(try QianwenUsage.windows(
            fromJSON: envelope(payload: #"{"per1WeekPercentage":0.42}"#), now: now
        ).first)

        XCTAssertEqual(window.id, "week")
        XCTAssertEqual(window.label, "Weekly limit")
        XCTAssertEqual(window.duration, 7 * 86_400)
        XCTAssertEqual(window.usedFraction ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertNil(window.resetsAt, "this payload names no reset")
        XCTAssertNil(window.remaining, "no credits in the payload, so no count to invent")
        XCTAssertNil(window.used)

        for (field, duration) in [("per1WeekPercentage", 7 * 86_400 as TimeInterval),
                                  ("per1MonthPercentage", 30 * 86_400 as TimeInterval)] {
            for (percentage, expected) in [(1.4, 1.0), (-0.3, 0.0)] {
                let clamped = try QianwenUsage.windows(
                    fromJSON: envelope(payload: #"{"\#(field)":\#(percentage)}"#), now: now
                )
                XCTAssertEqual(clamped.first?.usedFraction ?? -1, expected,
                               accuracy: 0.0001, field)
                XCTAssertEqual(clamped.first?.duration, duration, field)
            }
        }
    }

    func testResetTimeReadsEpochMillisecondsAndSeconds() throws {
        let expected = Date(timeIntervalSince1970: 1_700_179_200)
        for value in ["1700179200000", "1700179200"] {
            let windows = try QianwenUsage.windows(
                fromJSON: envelope(
                    payload: #"{"per1WeekPercentage":0.5,"per1WeekResetTime":\#(value)}"#
                ),
                now: now
            )
            XCTAssertEqual(try XCTUnwrap(windows.first).resetsAt, expected, value)
        }
    }

    func testResetTimeReadsISO8601WithAndWithoutFractionalSeconds() throws {
        let formatter = ISO8601DateFormatter()
        let expected = try XCTUnwrap(formatter.date(from: "2023-11-17T00:00:00Z"))
        for value in ["2023-11-17T00:00:00Z", "2023-11-17T00:00:00.000Z"] {
            let windows = try QianwenUsage.windows(
                fromJSON: envelope(
                    payload: #"{"per1WeekPercentage":0.5,"per1WeekResetTime":"\#(value)"}"#
                ),
                now: now
            )
            XCTAssertEqual(try XCTUnwrap(windows.first).resetsAt, expected, value)
        }
    }

    /// A reset behind `now` is stale data, not a countdown, and a countdown to
    /// a moment that has passed is worse than no countdown at all.
    func testAPastResetIsLeftAsNoCountdown() throws {
        for payload in [
            #"{"per1WeekPercentage":0.5,"per1WeekResetTime":"2023-11-01T00:00:00Z"}"#,
            #"{"per1WeekPercentage":0.5,"per1WeekResetTime":1698796800000}"#,
            #"{"per1WeekPercentage":0.5,"per1WeekResetTime":1698796800}"#
        ] {
            let windows = try QianwenUsage.windows(fromJSON: envelope(payload: payload), now: now)
            XCTAssertNil(try XCTUnwrap(windows.first).resetsAt, payload)
        }
    }

    /// Credits are the fallback: they reach the console's model as decimal
    /// strings, and a payload that carries them without a fraction still states
    /// the allowance.
    func testCreditsFallBackToCountArithmetic() throws {
        let window = try XCTUnwrap(try QianwenUsage.windows(
            fromJSON: envelope(
                payload: #"{"totalCredits":"10000.00","remainingCredits":"4000.00"}"#
            ),
            now: now
        ).first)

        XCTAssertEqual(window.usedFraction ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(window.used, 6_000)
        XCTAssertEqual(window.remaining, 4_000)

        // The quota spelling, and a plan that has spent nothing yet.
        let quota = try XCTUnwrap(try QianwenUsage.windows(
            fromJSON: envelope(payload: #"{"totalQuota":2500,"availableQuota":2500}"#),
            now: now
        ).first)
        XCTAssertEqual(quota.usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(quota.remaining, 2_500)
        XCTAssertEqual(quota.used, 0)

        // Both present: the console's own fraction wins, the counts still show.
        let both = try XCTUnwrap(try QianwenUsage.windows(
            fromJSON: envelope(
                payload: #"{"per1WeekPercentage":0.75,"totalCredits":2500,"remainingCredits":625}"#
            ),
            now: now
        ).first)
        XCTAssertEqual(both.usedFraction ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(both.remaining, 625)
        XCTAssertEqual(both.used, 1_875)
    }

    func testAPayloadWithoutAnAllowanceIsNothingMetered() {
        for payload in [
            "{}",
            #"{"plan":"lite"}"#,
            #"{"totalCredits":0,"remainingCredits":0}"#,
            #"{"totalCredits":"0.00","remainingCredits":"0.00"}"#
        ] {
            XCTAssertThrowsError(try QianwenUsage.windows(fromJSON: envelope(payload: payload))) { error in
                guard case UsageProviderError.nothingMetered = error else {
                    return XCTFail("expected nothingMetered for \(payload), got \(error)")
                }
            }
        }
    }

    /// A number nobody can read is not a reading, and the console's own client
    /// says so first: it refuses this very field unless
    /// `typeof n == 'number' && Number.isFinite(n)` — so `"nan"`, which
    /// `Double(_:)` happily parses, is refused there too.
    ///
    /// Without the same refusal here the fraction is not merely wrong, it is
    /// fatal: `min(max(.nan, 0), 1)` is `NaN`, not a clamp, so the value passes
    /// the parser's `guard` and reaches `Percent.text(for:)` /
    /// `Percent.halves(for:)`, whose `Int(_: Double)` conversion aborts the
    /// process — "Fatal error: Double value cannot be converted to Int because
    /// it is either infinite or NaN". The same applies to a JSON number the
    /// platform's own serialization cannot represent, which arrives as
    /// `-infinity` rather than as a failure to parse.
    func testNonFiniteNumbersAreNotReadings() {
        for payload in [
            // The string spellings `Double(_:)` accepts and JSON does not send.
            #"{"per1WeekPercentage":"nan"}"#,
            #"{"per1WeekPercentage":"inf"}"#,
            #"{"per1MonthPercentage":"nan"}"#,
            #"{"per1MonthPercentage":"-inf"}"#,
            // Parsed as a number by `JSONSerialization`, and not a finite one:
            // -1e400 saturates to -infinity rather than throwing.
            #"{"per1WeekPercentage":-1e400}"#,
            // The credit counts, where the string path reaches the same trap
            // through `Int(_: Double)` instead: "1e30" parses as a double and
            // aborts on the conversion.
            #"{"totalCredits":"1e30","remainingCredits":"0"}"#
        ] {
            XCTAssertThrowsError(try QianwenUsage.windows(fromJSON: envelope(payload: payload))) { error in
                guard case UsageProviderError.nothingMetered = error else {
                    return XCTFail("expected nothingMetered for \(payload), got \(error)")
                }
            }
        }
    }

    /// Recorded from the live gateway on 2026-09-18 (`requestId` elided — it
    /// changes per request): the answer to a call whose `params.Data` carried no
    /// `cornerstoneParam`. HTTP 200, the wrapper's `code` "200" straight through
    /// it, and the whole of the failure in `data.errorCode` — which the old
    /// parser never read, so this came out as `badResponse(0)`, the "HTTP 0"
    /// that was reported.
    func testTheRecordedRefusalNamesItsFailure() {
        let body = """
        {"code":"200","successResponse":true,"httpStatusCode":"200",
         "data":{"success":false,"httpStatus":200,"errorCode":"Bad Request",
                 "api":"zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
                 "errorMsg":"Bad Request"}}
        """
        XCTAssertThrowsError(try QianwenUsage.windows(fromJSON: body)) { error in
            guard case UsageProviderError.apiError(let name) = error else {
                return XCTFail("expected apiError, got \(error)")
            }
            // As recorded, not normalized: the console's own bundle spells this
            // one both ways, and the name is the server's to choose.
            XCTAssertEqual(name, "Bad Request")
        }
    }

    /// The other recorded answer, from the same harness with a dummy token: the
    /// shape is accepted and the *session* is what is missing. HTTP 200 with the
    /// wrapper's `code` still "200", so this is the case the old envelope check
    /// could never turn into `needsAuth` — a signed-out user was told "HTTP 0"
    /// and never told to sign in.
    func testTheRecordedSessionFailureIsNeedsAuth() {
        let body = """
        {"code":"200","successResponse":true,"httpStatusCode":"200",
         "data":{"success":false,"httpStatus":200,
                 "errorCode":"BailianGateway.Login.NotLogined",
                 "api":"zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
                 "errorMsg":"BailianGateway.Login.NotLogined"}}
        """
        XCTAssertThrowsError(try QianwenUsage.windows(fromJSON: body)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    /// The platform's own signed-out codes, which the console's bundle keys its
    /// "session expired" dialogue off — and the only names allowed to become
    /// `needsAuth`, because that is the one status that discards the remembered
    /// reading. Matched the way the page script matches them, case-insensitively,
    /// and read from whichever field carries them.
    func testTheSessionCodesAreNeedsAuth() {
        for body in [
            #"{"code":"ConsoleNeedLogin","message":"请登录","successResponse":false}"#,
            #"{"code":"no_login","successResponse":false}"#,
            #"{"code":"200","successResponse":true,"data":{"success":false,"code":"ConsoleNeedLogin"}}"#
        ] {
            XCTAssertThrowsError(try QianwenUsage.windows(fromJSON: body)) { error in
                guard case UsageProviderError.needsAuth = error else {
                    return XCTFail("expected needsAuth for \(body), got \(error)")
                }
            }
        }
    }

    /// Everything else that names itself keeps its name: that name is the whole
    /// of what such an answer says, and it is what the ring shows. The order is
    /// the dialect's — `errorCode`, then the data's `code`, then a wrapper `code`
    /// that is not a success, then the human-readable `errorMsg`.
    func testANamedBusinessFailureKeepsItsName() {
        for (body, name) in [
            (#"{"code":"200","successResponse":true,"data":{"success":false,"errorCode":"SOME_FAILURE"}}"#,
             "SOME_FAILURE"),
            (#"{"code":"200","successResponse":true,"data":{"success":false,"errorCode":"BadRequest","errorMsg":"ignored"}}"#,
             "BadRequest"),
            // Free text from the server is never passed through, only our own line.
            (#"{"code":"200","successResponse":true,"data":{"success":false,"errorMsg":"plan not subscribed"}}"#,
             "QianwenAI refused the request."),
            (#"{"code":"503","successResponse":false,"data":{}}"#, "503")
        ] {
            XCTAssertThrowsError(try QianwenUsage.windows(fromJSON: body)) { error in
                guard case UsageProviderError.apiError(let got) = error else {
                    return XCTFail("expected apiError for \(body), got \(error)")
                }
                XCTAssertEqual(got, name, body)
            }
        }
    }

    /// Shape-broken bodies, and business failures with no name to show, stay
    /// `badResponse` as they were: the parser says what it can support and no
    /// more. A good `DataV2` behind a failure flag is still a failure — the flag
    /// is what the console's own client reads first.
    func testNamelessFailuresAndGarbageAreBadResponses() {
        for json in [
            #"{"code":"200","successResponse":false,"data":{"success":true,"DataV2":{"data":{"per1WeekPercentage":0.5}}}}"#,
            #"{"code":"200","successResponse":true,"data":{"success":false,"DataV2":{"data":{"per1WeekPercentage":0.5}}}}"#,
            #"{"code":"500","successResponse":true,"data":{"success":true,"DataV2":{"data":{"per1WeekPercentage":0.5}}}}"#,
            #"{"code":"200","successResponse":true,"data":{"success":true}}"#,
            #"{"code":"200","successResponse":true}"#,
            "not json",
            "[]"
        ] {
            XCTAssertThrowsError(try QianwenUsage.windows(fromJSON: json)) { error in
                guard case UsageProviderError.badResponse(let status) = error, status == 0 else {
                    return XCTFail("expected badResponse(0), got \(error)")
                }
            }
        }
    }

    func testTheSiteIsTheConsoleTheUserSignsInto() throws {
        let site = Sites.qianwen
        XCTAssertEqual(site.id, "qianwenai")
        XCTAssertEqual(site.displayName, "QianwenAI")
        // The platform's own mark, not the Lobe Icons model brand: a local
        // Qwen model cell and this ring have to be tellable apart.
        XCTAssertEqual(site.glyph, .qianwenAI)
        XCTAssertNotEqual(site.glyph, .qwen)
        XCTAssertEqual(site.origin, try XCTUnwrap(URL(string: "https://platform.qianwenai.com/")))
        // A console session we hold, not a published API — the same reading
        // MiniMax's cookie path gets.
        XCTAssertEqual(site.fidelity, .derived)
        XCTAssertEqual(site.headlineID, "week")
        XCTAssertEqual(site.weeklyID, "week")
        XCTAssertEqual(site.associatedHosts,
                       ["platform-home.qianwenai.com", "cs-data.qianwenai.com",
                        "account.qianwenai.com", "account.aliyun.com"])
        XCTAssertEqual(WebSessionProvider.websiteDataHosts(for: site),
                       ["platform.qianwenai.com", "platform-home.qianwenai.com",
                        "cs-data.qianwenai.com", "account.qianwenai.com", "account.aliyun.com"])
    }

    /// The settings row's manage link. The console serves its SPA only under
    /// `/home`, so the default page name — `origin/usage` — is a 404 on this
    /// site, and this is the page the console's own route table maps the
    /// individual Token Plan to.
    func testTheManageLinkOpensAPageTheConsoleServes() throws {
        UserDefaults.standard.set(true, forKey: signedInKey)
        let account = try XCTUnwrap(WebSessionProvider(site: Sites.qianwen).account())
        XCTAssertEqual(account.manageURL?.absoluteString,
                       "https://platform.qianwenai.com/home/analytics/token-plan/individual")
    }

    func testTheScriptPostsTheTokenPlanCallToTheGateway() {
        let script = Sites.qianwen.script
        XCTAssertTrue(script.contains("https://cs-data.qianwenai.com/data/api.json"))
        XCTAssertTrue(script.contains("zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"),
                      "the Api inside params is what routes the call")
        XCTAssertTrue(script.contains("credentials: 'include'"))
        XCTAssertTrue(script.contains("'sfm_bailian'"))
        XCTAssertTrue(script.contains("'BroadScopeAspnGateway'"))
        XCTAssertTrue(script.contains("'cn-beijing'"))
        // The gateway validates `params.Data.cornerstoneParam` before it looks
        // at the Api at all: without it the platform answers 200 with
        // `errorCode: "Bad Request"` under `data.success: false` and never
        // reaches the business layer — measured on the live gateway.
        XCTAssertTrue(script.contains("Data: { cornerstoneParam: cornerstoneParam }"),
                      "the call is rejected before the business layer without it")
        XCTAssertTrue(script.contains("const cornerstoneParam = {")
                      && script.contains("consoleSite: 'QIANWENAI'"),
                      "the fields are the console's own, not an invented set")
        // The console also puts `product`/`action`/`api` in the query string,
        // but the gateway echoes the Api it read out of `params.Api` without it
        // — measured, so this call does not build one.
        XCTAssertFalse(script.contains("?product=") || script.contains("&api="),
                       "the query string the console sends is not what routes the call")
        // Only the console's own session-failure codes may become 401. 401 turns
        // into `needsAuth`, which discards the remembered reading, so mapping a
        // server fault to it would blank the ring and tell a signed-in user to
        // sign in. Everything else has to reach the parser, which renders an
        // error the store keeps the last reading through.
        //
        // And the marker has to be looked for where the platform puts it: a
        // dead session is named in `data.errorCode` while the wrapper's `code`
        // stays "200" — measured — so the old check of `envelope.code` alone
        // could never fire.
        XCTAssertTrue(script.contains("[envelope.code, data.errorCode, data.code]"),
                      "the failure is named in `data.errorCode`, not only in `code`")
        XCTAssertTrue(script.contains("['ConsoleNeedLogin', 'BailianGateway.Login.NotLogined', "
                                      + "'NO_LOGIN']"),
                      "the session codes are the set the console's own bundle keys its dialogue off")
        XCTAssertTrue(script.contains("status = 401"))
        XCTAssertFalse(script.contains("successResponse === false ||"),
                       "a plain business failure must keep its status, not become 401")
        XCTAssertFalse(script.contains("String(envelope.code) !== '200'"),
                       "a non-200 code is not the same thing as a dead session")
        // The console caches its own token on `window`; a stale one would look
        // like an expired session on every call.
        XCTAssertFalse(script.contains("__QWEN_CONSOLE_SHARED_SEC_TOKEN__"))
    }

    func testTheProbeReadsTheSessionHostAndFingerprintsTheToken() throws {
        let probe = try XCTUnwrap(Sites.qianwen.authProbeScript)
        XCTAssertTrue(probe.contains("https://platform-home.qianwenai.com/tool/user/info.json"))
        XCTAssertTrue(probe.contains("credentials: 'include'"))
        XCTAssertTrue(probe.contains("crypto.subtle.digest('SHA-256'"))
        XCTAssertTrue(probe.contains("fingerprint"),
                      "a switch needs a session identity, not just a boolean")
        XCTAssertTrue(probe.contains("authenticated: false"))
    }

    func testASiteWithAProbeWaitsForItToConfirm() {
        WebSessionProvider(site: Sites.qianwen).signInSheetDidOpen()
        XCTAssertFalse(UserDefaults.standard.bool(forKey: signedInKey),
                       "opening the sheet is not a sign-in for a site that can confirm one")
    }

    func testTheSiteParseIsWiredToTheTokenPlanParser() throws {
        let json = envelope(payload: #"{"per1WeekPercentage":0.3}"#)
        XCTAssertEqual(try Sites.qianwen.parse(json).map(\.id), ["week"])
    }

    /// The asset draws the mark, not the plate it came on.
    ///
    /// This mark's ink covers about 0.40 of the box; the plate version — the
    /// blue rounded square the favicon puts behind it — covers about 0.70. Both
    /// are under the 0.85 ceiling the older glyph tests use, so that ceiling
    /// would not have caught the plate coming back; these bounds are what
    /// separate the two.
    func testTheGlyphAssetRendersAsAMarkNotASquare() throws {
        XCTAssertEqual(ProviderGlyph.qianwenAI.assetName, "glyph-qianwenai")
        let asset = try XCTUnwrap(NSImage(named: ProviderGlyph.qianwenAI.assetName))
        XCTAssertGreaterThan(asset.size.width, 0)
        XCTAssertGreaterThan(asset.size.height, 0)

        let renderer = ImageRenderer(
            content: ProviderGlyphView(glyph: .qianwenAI, size: 32).foregroundStyle(.white)
        )
        let data = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var ink = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                ink += 1
            }
        }
        let coverage = Double(ink) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
        XCTAssertGreaterThan(coverage, 0.15, "a plate or an empty box, not a mark")
        XCTAssertLessThan(coverage, 0.60, "the favicon's plate is back — the mark cannot show through it")
    }
}
