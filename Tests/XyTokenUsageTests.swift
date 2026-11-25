import JavaScriptCore
import XCTest
@testable import Codenotch

/// Guards the shape of `GET https://api.xytoken.xyb2b.com/api/subscription/self`
/// — the call the station's wallet page makes right after refreshing its
/// session. It is not a published API, so these are the tests that will fail
/// first if the station changes it. The fixture keeps the recorded structure
/// and the recorded `rule_key` values — the window ids are derived from them,
/// so a rewritten one would test a value the station never sends — while the
/// subscription ids and token counts are rewritten so no account data is
/// checked in.
final class XyTokenUsageTests: XCTestCase {
    /// Trimmed from a recorded response: the two active windows under
    /// `subscriptions`, the same subscription repeated under
    /// `all_subscriptions` (which the parser must not double-count), and the
    /// long tail of wallet detail the parser must not trip over.
    private let live = """
    {
        "code": true,
        "success": true,
        "message": "",
        "data": {
            "user_id": 99999,
            "quota": 12900000,
            "used_quota": 112000000,
            "request_count": 6400,
            "subscriptions": [
                {
                    "id": "99999",
                    "plan_name": "Pro",
                    "status": "active",
                    "quota_limits": [
                        {
                            "id": "13541",
                            "rule_key": "day:1|day:00:00",
                            "name": "每日",
                            "period_value": 1,
                            "period_unit": "day",
                            "reset_time": "00:00",
                            "amount": 60000000,
                            "amount_used": 3000000,
                            "remaining": 57000000,
                            "window_start": 1788940296,
                            "window_end": 1788969600
                        },
                        {
                            "id": "13542",
                            "rule_key": "week:1|week:MON 00:00",
                            "name": "每周",
                            "period_value": 1,
                            "period_unit": "week",
                            "reset_time": "00:00",
                            "amount": 240000000,
                            "amount_used": 12000000,
                            "remaining": 228000000,
                            "window_start": 1788940296,
                            "window_end": 1789315200
                        }
                    ]
                }
            ],
            "all_subscriptions": [
                {
                    "id": "99999",
                    "plan_name": "Pro",
                    "status": "active",
                    "quota_limits": [
                        {
                            "id": "13541",
                            "rule_key": "day:1|day:00:00",
                            "name": "每日",
                            "amount": 60000000,
                            "amount_used": 3000000,
                            "remaining": 57000000,
                            "window_start": 1788940296,
                            "window_end": 1788969600
                        }
                    ]
                },
                {
                    "id": "99998",
                    "plan_name": "Trial",
                    "status": "expired",
                    "quota_limits": []
                }
            ]
        }
    }
    """

    func testDecodesTheLiveShape() throws {
        let windows = try XyTokenUsage.windows(fromJSON: live)
        XCTAssertEqual(windows.map(\.id), ["day:1", "week:1"])
        XCTAssertEqual(windows.map(\.label), ["每日", "每周"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.05, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.05, accuracy: 0.0001)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1788969600))
        XCTAssertEqual(windows[1].resetsAt, Date(timeIntervalSince1970: 1789315200))
        XCTAssertEqual(windows[0].duration, 86_400)
        XCTAssertEqual(windows[1].duration, 7 * 86_400)
    }

    /// The window id is the stable half of `rule_key` — the rule's unit and
    /// count — never the reset schedule after the `|`, which moves with the
    /// reset day. The weekly ring goes missing when the id carries it: the
    /// first cut named the whole `rule_key`, and the live `week:MON 00:00`
    /// never matched what the fixture had.
    func testWindowIDIsTheStableHalfOfTheRuleKey() throws {
        let json = """
        { "data": { "subscriptions": [ { "quota_limits": [
            { "rule_key": "day:1|day:00:00", "name": "每日",
              "amount": 1000, "amount_used": 100, "window_end": 1788969600 },
            { "rule_key": "week:1|week:MON 00:00", "name": "每周",
              "amount": 1000, "amount_used": 100, "window_end": 1789315200 },
            { "rule_key": "week:1|week:SUN 12:30", "name": "每周（别的重置日）",
              "amount": 1000, "amount_used": 100, "window_end": 1789315200 } ] } ] } }
        """
        let windows = try XyTokenUsage.windows(fromJSON: json)
        // The third entry resets on a different day and still lands on the same
        // id as the second — the schedule is deliberately not part of it.
        XCTAssertEqual(windows.map(\.id), ["day:1", "week:1", "week:1"])
        XCTAssertEqual(windows.map(\.label), ["每日", "每周", "每周（别的重置日）"])
    }

    /// A limit that reports no `rule_key` still gets an id of its own, so two of
    /// them cannot collapse into one window.
    func testALimitWithoutARuleKeyFallsBackToItsPosition() throws {
        let json = """
        { "data": { "subscriptions": [ { "quota_limits": [
            { "name": "无规则", "amount": 1000, "amount_used": 100, "window_end": 1788969600 },
            { "name": "也无规则", "amount": 1000, "amount_used": 100, "window_end": 1788969600 } ] } ] } }
        """
        let windows = try XyTokenUsage.windows(fromJSON: json)
        XCTAssertEqual(windows.map(\.id), ["limit-0", "limit-1"])
    }

    /// The site declares which window is the headline and which is the weekly
    /// allowance, and consumers resolve those by id. This is the assertion that
    /// would have caught the first cut of those declarations: they named the
    /// whole `rule_key`, and the fixture — recorded with rewritten `rule_key`s —
    /// agreed with them, so the test passed while the live `week:1|week:MON
    /// 00:00` resolved to nothing and drew no weekly ring. The fixture now
    /// keeps the recorded `rule_key`s, so this asserts against what the station
    /// actually sends.
    func testSiteWindowRolesResolveToTheParsedWindows() throws {
        let headlineID = try XCTUnwrap(Sites.xytoken.headlineID)
        let weeklyID = try XCTUnwrap(Sites.xytoken.weeklyID)
        let ids = try XyTokenUsage.windows(fromJSON: live).map(\.id)
        XCTAssertTrue(ids.contains(headlineID),
                      "headlineID \(headlineID) resolves to no parsed window: \(ids)")
        XCTAssertTrue(ids.contains(weeklyID),
                      "weeklyID \(weeklyID) resolves to no parsed window: \(ids)")
        XCTAssertNotEqual(headlineID, weeklyID,
                          "one window cannot be both the headline and the weekly ring")
    }

    /// The sign-in must be able to *complete* on its own. Without a probe the
    /// sheet marked itself signed in the moment it opened — still on the login
    /// page — and the first fetch from there answered 401 and cleared the flag,
    /// which nothing set back after the login actually succeeded: the close
    /// path only confirms a site that has a probe. The probe is also what makes
    /// `X-Auth-Session`'s `session.sid` an identity the account switch can
    /// compare, so it has to report a fingerprint, not just a boolean.
    ///
    /// And it must not complete *too early*. On 2026-10-29 the station, waiting
    /// for a two-factor code it had not been given, still answered the refresh
    /// 200 with a session and a `sid` — a probe that stopped there committed a
    /// sign-in the site had not finished and closed the window on the code
    /// input, which is the one screen the app cannot get past for the user.
    func testSiteConfirmsSignInWithAPollingProbe() throws {
        let probe = try XCTUnwrap(Sites.xytoken.authProbeScript,
                                  "xytoken must confirm a sign-in, not assume it")
        XCTAssertTrue(Sites.xytoken.pollsDuringSignIn,
                      "a probe that is never polled still cannot commit a sign-in")
        XCTAssertTrue(probe.contains("session.sid"),
                      "the probe must report the session identity an account switch changes")
        XCTAssertTrue(probe.contains("access_token"),
                      "a session alone is not a sign-in: the station waits for a code behind one")
        XCTAssertTrue(probe.contains("authenticated"))
    }

    /// Runs a site script the way `callAsyncJavaScript` does — as an async
    /// function body — against a stubbed `fetch`, and returns what it answered.
    private func answer(
        from script: String,
        status: Int = 200,
        body: String
    ) throws -> [String: Any] {
        let context = try XCTUnwrap(JSContext(), "JavaScriptCore is how the sheet runs this")
        let literal = try XCTUnwrap(String(data: try JSONEncoder().encode(body), encoding: .utf8))
        // `window` is what the scripts treat as the page; in a bare context the
        // only page there is is the global object.
        let harness = """
        var window = globalThis;
        var __result = 'PENDING';
        var __reply = { ok: \(status >= 200 && status < 300), status: \(status), body: \(literal) };
        var fetch = function () {
            return Promise.resolve({
                ok: __reply.ok,
                status: __reply.status,
                headers: { get: function () { return ''; } },
                text: function () { return Promise.resolve(__reply.body); }
            });
        };
        (async function () {
            __result = await (async function () {
        \(script)
            })();
        })();
        """
        context.evaluateScript(harness)
        let raw = try XCTUnwrap(context.objectForKeyedSubscript("__result")?.toString(),
                                "the script answered nothing: \(String(describing: context.exception))")
        XCTAssertNotEqual(raw, "PENDING", "the script never settled")
        let data = try XCTUnwrap(raw.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "expected a JSON envelope, got \(raw)"
        )
    }

    /// The station's own definition of signed in, from its console's
    /// `isAuthBundle`: access token, user, session. All three, or the sheet
    /// stays open.
    func testProbeCommitsOnlyAWholeAuthBundle() throws {
        let probe = try XCTUnwrap(Sites.xytoken.authProbeScript)
        let bundle = """
        {"success":true,"data":{
            "access_token":"an-access-token","token_type":"Bearer",
            "access_expires_at":4102444800,
            "user":{"id":42,"username":"someone","role":1},
            "session":{"sid":"s-1","current":true,"login_method":"password"}}}
        """
        let answer = try answer(from: probe, body: bundle)
        XCTAssertEqual(answer["authenticated"] as? Bool, true)
        XCTAssertEqual(answer["fingerprint"] as? String, "s-1",
                       "the fingerprint is the identity an account switch has to change")
    }

    /// The refusal that started this: a pending second factor comes back as a
    /// session without the token the console would need.
    func testProbeRefusesASessionThatIsOnlyAPendingSignIn() throws {
        let probe = try XCTUnwrap(Sites.xytoken.authProbeScript)
        let pending = #"{"success":true,"data":{"session":{"sid":"s-1","current":true}}}"#
        XCTAssertEqual(try answer(from: probe, body: pending)["authenticated"] as? Bool, false,
                       "a session with no access token is the two-factor screen, not a sign-in")
        let noUser = #"{"success":true,"data":{"access_token":"t","session":{"sid":"s-1"}}}"#
        XCTAssertEqual(try answer(from: probe, body: noUser)["authenticated"] as? Bool, false)
        let refused = #"{"success":false,"code":"ADMIN_MFA_REQUIRED","data":{"methods":["2fa"],"need_setup":false,"require_admin_mfa":true}}"#
        XCTAssertEqual(try answer(from: probe, status: 403, body: refused)["authenticated"] as? Bool, false)
    }

    /// A `403` the station spends on a second factor is not a lost login, and
    /// the panel cannot say which it is — a refusal is a refusal, and Sign in
    /// opens the same sheet that answers both. The log can, and this is what it
    /// reads: the status it came with, and the station's own `code` field.
    func testASteppedUpRefusalIsNamedInTheLog() throws {
        let body = #"{"success":false,"message":"需要完成多因素认证","code":"ADMIN_MFA_REQUIRED","data":{"methods":["2fa"],"need_setup":false,"require_admin_mfa":true}}"#
        XCTAssertEqual(WebSessionProvider.stepUpCode(status: 403, body: body, site: Sites.xytoken),
                       "ADMIN_MFA_REQUIRED")
        XCTAssertNil(WebSessionProvider.stepUpCode(status: 401, body: body, site: Sites.xytoken),
                     "a `401` is a lost login whatever its body says about a second factor")
        XCTAssertNil(
            WebSessionProvider.stepUpCode(status: 403, body: #"{"code":"AUTH_SESSION_REVOKED"}"#,
                                          site: Sites.xytoken),
            "a revoked session is a lost login, not a step-up")
        XCTAssertNil(WebSessionProvider.stepUpCode(status: 403, body: body, site: Sites.deepSeek),
                     "only the site that declares the code reads it that way")
        let quoted = #"{"code":"AUTH_UNAUTHORIZED","message":"ADMIN_MFA_REQUIRED is not configured"}"#
        XCTAssertNil(WebSessionProvider.stepUpCode(status: 403, body: quoted, site: Sites.xytoken),
                     "the code named in a message is not the station's `code` field")
    }

    /// The fetch has to speak the station's rotation contract, not merely hit
    /// the endpoint. `X-Auth-Session` is what makes this client look like the
    /// page whose cookie it shares — a browser keeps it and holds a session for
    /// weeks, while this app refreshed without it and lost the session twice —
    /// and the two `409` codes are what the station answers instead of a token
    /// when two clients rotate the same cookie. Drop any of the three and the
    /// fetch quietly regresses to the shape that was being revoked.
    func testFetchFollowsTheStationsRotationContract() {
        let script = Sites.xytoken.script
        XCTAssertTrue(script.contains("X-Auth-Session"),
                      "a refresh without its session identity is the bootstrap path, not a steady state")
        XCTAssertTrue(script.contains("AUTH_REFRESH_RACE"))
        XCTAssertTrue(script.contains("AUTH_SESSION_MISMATCH"))
        XCTAssertTrue(script.contains("session.sid"),
                      "the identity has to be learned and replayed, not just handled")
        XCTAssertTrue(script.contains("X-Request-Id"),
                      "the response id is what makes a refusal traceable in the station's own log")
    }

    /// The cycle length comes from the limit's own period. `window_start` is
    /// unusable for this — in the recorded capture it is the instant of the
    /// call, which would make the day window 8.14 h long and leave the pace
    /// line reading as if no time had passed.
    func testDurationComesFromTheLimitsOwnPeriod() throws {
        let json = """
        { "data": { "subscriptions": [ { "quota_limits": [
            { "rule_key": "hour:3|hour:00", "name": "每三小时",
              "amount": 1000, "amount_used": 100,
              "period_value": 3, "period_unit": "hour",
              "window_end": 1788969600 },
            { "rule_key": "month:1|day:1,00:00", "name": "每月",
              "amount": 1000, "amount_used": 100,
              "period_value": 1, "period_unit": "month",
              "window_end": 1788969600 } ] } ] } }
        """
        let windows = try XyTokenUsage.windows(fromJSON: json)
        XCTAssertEqual(windows[0].duration, 3 * 3600)
        XCTAssertNil(windows[1].duration,
                     "an unreckoned unit leaves the pace line off rather than inventing a cycle")
    }

    /// A limit that states no period keeps its percentage and loses only the
    /// pace line — the reading is still worth drawing.
    func testALimitWithoutAPeriodStillReportsItsFraction() throws {
        let json = """
        { "data": { "subscriptions": [ { "quota_limits": [
            { "rule_key": "day:1|day:00:00", "name": "每日",
              "amount": 1000, "amount_used": 250,
              "window_end": 1788969600 } ] } ] } }
        """
        let windows = try XyTokenUsage.windows(fromJSON: json)
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertNil(windows[0].duration)
    }

    /// The reason `duration` is carried at all: the tooltip's pace line reads
    /// it. A tenth of the day's allowance spent with a third of the day gone
    /// is usage behind schedule, which is the state this makes visible.
    func testTheDayWindowGetsAPaceReading() throws {
        let json = """
        { "data": { "subscriptions": [ { "quota_limits": [
            { "rule_key": "day:1|day:00:00", "name": "每日",
              "amount": 1000, "amount_used": 100,
              "period_value": 1, "period_unit": "day",
              "window_end": 1788969600 } ] } ] } }
        """
        let window = try XCTUnwrap(XyTokenUsage.windows(fromJSON: json).first)
        let now = Date(timeIntervalSince1970: 1788969600 - 16 * 3600)
        let pace = try XCTUnwrap(window.usagePace(now: now))
        XCTAssertEqual(pace.percentagePoints, -23.33333, accuracy: 0.0001)
        XCTAssertFalse(pace.isDeficit)
        XCTAssertEqual(pace.summary, "23.3% reserved")
    }

    /// `all_subscriptions` repeats the active windows plus expired ones — only
    /// `subscriptions` may be read, or every window shows up twice.
    func testActiveSubscriptionsDoNotDuplicateWindows() throws {
        let windows = try XyTokenUsage.windows(fromJSON: live)
        XCTAssertEqual(windows.count, 2)
    }

    /// When nothing is active (e.g. the plan lapsed), fall back to
    /// `all_subscriptions` rather than reporting nothing at all.
    func testFallsBackToAllSubscriptions() throws {
        let json = """
        { "data": {
            "subscriptions": [],
            "all_subscriptions": [ { "quota_limits": [
                { "rule_key": "day:1|day:00:00", "name": "每日",
                  "amount": 60000000, "amount_used": 6000000,
                  "window_start": 1788940296, "window_end": 1788969600 } ] } ] } }
        """
        let windows = try XyTokenUsage.windows(fromJSON: json)
        XCTAssertEqual(windows.map(\.id), ["day:1"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.1, accuracy: 0.0001)
    }

    /// A limit with no quota is not drawn as a zero — that would read as a
    /// limit that has never been touched.
    func testUnusableLimitsAreDropped() throws {
        let json = """
        { "data": { "subscriptions": [ { "quota_limits": [
            { "rule_key": "day:1|day:00:00", "name": "每日",
              "amount": 0, "amount_used": 0, "window_end": 1788969600 } ] } ] } }
        """
        XCTAssertThrowsError(try XyTokenUsage.windows(fromJSON: json)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testMalformedBodyThrowsBadResponse() {
        XCTAssertThrowsError(try XyTokenUsage.windows(fromJSON: "sign in to continue")) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }
}
