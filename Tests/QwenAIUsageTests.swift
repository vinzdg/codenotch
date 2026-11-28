import XCTest
import SwiftUI
@testable import Codenotch

/// `QwenAIUsage` reads fields from the chat console's own frontend bundle —
/// there is no documented quota API and no live session this build can take —
/// so these tests are the contract the first signed-in probe has to confirm.
@MainActor
final class QwenAIUsageTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_764_000_000)
    private let reset = 1_764_086_400_000.0 // milliseconds, 24 h after `clock`

    private let usage = """
    {"success":true,"httpCode":200,"data":{
        "remainingPercent":62,"resetAt":1764086400000,"memberType":"pro",
        "lowCredits":{"agent":false,"warnCredits":true,"zeroCredits":false}}}
    """
    private let credits = """
    {"success":true,"httpCode":200,"data":{
        "totalCredits":1240,"subscriptionCredits":1100,"bonusCredits":140,
        "usageList":[],"total":0}}
    """

    private func envelope(usage: String? = nil, credits: String? = nil) throws -> String {
        let body: [String: Any] = [
            "usage": usage ?? self.usage,
            "credits": credits ?? self.credits,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    func testRemainingPercentBecomesTheWeeklyRing() throws {
        let windows = try QwenAIUsage.windows(fromJSON: envelope(), now: clock)
        XCTAssertEqual(windows.map(\.id), ["week"])
        let headline = try XCTUnwrap(windows.first)
        XCTAssertEqual(headline.label, "Pro plan")
        XCTAssertEqual(try XCTUnwrap(headline.usedFraction), 0.38, accuracy: 0.0001)
        // The console subtracts `Date.now()` from a millisecond reset.
        XCTAssertEqual(headline.resetsAt, Date(timeIntervalSince1970: reset / 1000))
        XCTAssertEqual(headline.remaining, 1100)
        XCTAssertEqual(headline.duration, 7 * 86_400)
    }

    func testTheCreditsTotalIsUsedWhenTheSubscriptionFigureIsGone() throws {
        let credits = """
        {"success":true,"httpCode":200,"data":{"totalCredits":900,"bonusCredits":0}}
        """
        let windows = try QwenAIUsage.windows(fromJSON: envelope(credits: credits), now: clock)
        XCTAssertEqual(windows[0].remaining, 900)
    }

    func testAnEnvelopeWithoutDataIsStillRead() throws {
        let usage = """
        {"remainingPercent":0,"resetAt":1764086400000,"memberType":"plus"}
        """
        let windows = try QwenAIUsage.windows(fromJSON: envelope(usage: usage), now: clock)
        XCTAssertEqual(windows[0].label, "Plus plan")
        XCTAssertEqual(try XCTUnwrap(windows[0].usedFraction), 1.0, accuracy: 0.0001)
    }

    func testASignedOutBodyIsNotAnUnreadableShape() throws {
        let signedOut = """
        {"errorCode":"NOT_LOGIN","errorMsg":"User not logged in","httpCode":401,
         "success":false,"traceId":"abc"}
        """
        XCTAssertThrowsError(try QwenAIUsage.windows(fromJSON: envelope(usage: signedOut), now: clock)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testAnotherNamedFailureIsReportedAsQwensOwn() throws {
        let failure = """
        {"errorCode":"INTERNAL_ERROR","httpCode":500,"success":false}
        """
        XCTAssertThrowsError(try QwenAIUsage.windows(fromJSON: envelope(usage: failure), now: clock)) { error in
            guard case UsageProviderError.apiError(let name) = error else {
                return XCTFail("expected apiError, got \(error)")
            }
            XCTAssertEqual(name, L10n.t("Qwen.ai refused the request."))
        }
    }

    func testAPercentThatIsNotAReadingReportsNothingMetered() throws {
        let usage = """
        {"success":true,"httpCode":200,"data":{"remainingPercent":"nan"}}
        """
        XCTAssertThrowsError(try QwenAIUsage.windows(fromJSON: envelope(usage: usage), now: clock)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testAStaleResetIsDroppedRatherThanDrawnAsAPastMoment() throws {
        let usage = """
        {"success":true,"httpCode":200,"data":{"remainingPercent":50,"resetAt":1}}
        """
        let windows = try QwenAIUsage.windows(fromJSON: envelope(usage: usage), now: clock)
        XCTAssertNil(windows[0].resetsAt)
    }

    func testABrokenCreditsBalanceDoesNotCostAnOtherwiseReadableRing() throws {
        let windows = try QwenAIUsage.windows(
            fromJSON: envelope(credits: "{\"errorCode\":\"NOT_LOGIN\",\"success\":false}"),
            now: clock
        )
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows[0].remaining)
        XCTAssertEqual(try XCTUnwrap(windows[0].usedFraction), 0.38, accuracy: 0.0001)
    }

    // MARK: - Site wiring

    func testTheSiteReadsTheWebConsoleNotTheCliToken() {
        let site = Sites.qwenAI
        XCTAssertEqual(site.id, "qwenai")
        XCTAssertEqual(site.displayName, "Qwen.ai")
        XCTAssertEqual(site.origin.host, "chat.qwen.ai")
        XCTAssertEqual(site.managePath, "settings/usage-billing")
        // The signed-out console redirects its protected settings routes to
        // the chat home, so sign-in opens its own `/auth` page instead.
        XCTAssertEqual(site.initialPath, "auth")
        XCTAssertEqual(site.headlineID, "week")
        XCTAssertEqual(site.weeklyID, "week")
        XCTAssertEqual(site.glyph, .qwenAI)
        XCTAssertFalse(site.logsResponseBody, "the envelope carries account details")
        XCTAssertTrue(site.associatedHosts.contains("sg-entitlement.qwen.com"))
        XCTAssertTrue(site.pollsDuringSignIn, "a finished login must commit without a second click")
        XCTAssertTrue(site.reloadsSessionOnAuthFailure)
        XCTAssertTrue(WebSessionProvider.matchesOrigin(
            URL(string: "https://chat.qwen.ai/settings/usage-billing"), expected: site.origin))
        XCTAssertFalse(WebSessionProvider.matchesOrigin(
            URL(string: "https://api.qwen.ai/"), expected: site.origin))
    }

    func testTheScriptUsesTheWebBearerAndTheEntitlementHost() {
        let site = Sites.qwenAI
        XCTAssertTrue(site.script.contains("qwen_access_token_state"))
        XCTAssertTrue(site.script.contains("https://auth.qwen.ai/api/v2/auths/refresh"),
                      "the console refreshes on its auth host, not on the chat page")
        XCTAssertTrue(site.script.contains("180000"), "renew three minutes before expiry")
        XCTAssertTrue(site.script.contains("'x-request-origin': location.origin"))
        XCTAssertTrue(site.script.contains("sg-entitlement.qwen.com"))
        XCTAssertTrue(site.script.contains("/api/entitlement/agent/usage"))
        XCTAssertTrue(site.script.contains("/api/entitlement/credits/credits/history"))
        XCTAssertTrue(site.script.contains("'Authorization': 'Bearer ' + bearer"))
        XCTAssertFalse(site.script.contains("subscription_credentials.json"))
        let probe = try? XCTUnwrap(site.authProbeScript)
        XCTAssertTrue(probe?.contains("qwen_access_token_state") == true)
        XCTAssertTrue(probe?.contains("expiresAt") == true)
        XCTAssertTrue(probe?.contains("https://auth.qwen.ai/api/v2/auths/refresh") == true)
        XCTAssertTrue(probe?.contains("180000") == true)
        XCTAssertTrue(probe?.contains("SHA-256") == true)
        XCTAssertFalse(probe?.contains("credits/query") == true,
                       "the probe must not depend on a feature-flagged endpoint")
    }

    func testTheSiteParserIsWiredToQwenAIUsage() throws {
        let windows = try Sites.qwenAI.parse(envelope())
        XCTAssertEqual(windows.map(\.id), ["week"])
    }

    func testTheRealQwenMarkIsUsedForTheProvider() throws {
        XCTAssertEqual(ProviderGlyph.qwenAI.rawValue, "qwenai")
        XCTAssertEqual(ProviderGlyph.qwenAI.assetName, "glyph-qwenai")
        XCTAssertEqual(ProviderGlyph.qwenAI.outline, [])
        XCTAssertEqual(ProviderGlyph.qwenAI.brandColor, Color(hex: 0x082DFF))
        let asset = try XCTUnwrap(NSImage(named: ProviderGlyph.qwenAI.assetName))
        XCTAssertGreaterThan(asset.size.width, 0)

        let renderer = ImageRenderer(
            content: ProviderGlyphView(glyph: .qwenAI, size: 32).foregroundStyle(.white)
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
        XCTAssertGreaterThan(coverage, 0.15, "an empty box, not the Qwen mark")
        XCTAssertLessThan(coverage, 0.60, "a plate, not the Qwen mark")
    }
}
