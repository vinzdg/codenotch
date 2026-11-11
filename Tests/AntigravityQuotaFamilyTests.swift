import XCTest
@testable import Codenotch

/// The family a reader chose must never be answered with another family's
/// number, and a family that reported nothing must say so.
final class AntigravityQuotaFamilyTests: XCTestCase {

    private func window(_ id: String, _ group: String, _ label: String, used: Double?) -> LimitWindow {
        LimitWindow(id: id, group: group, label: label, usedFraction: used,
                    duration: id.hasSuffix("-weekly") ? 7 * 86400 : 5 * 3600)
    }

    private var geminiWindows: [LimitWindow] {
        [
            window("gemini-5h", "Gemini Models", "5-hour Limit", used: 0.15),
            window("gemini-weekly", "Gemini Models", "Weekly Limit", used: 0.04),
        ]
    }

    private var thirdPartyWindows: [LimitWindow] {
        [
            window("3p-5h", "Claude and GPT models", "5-hour Limit", used: 0.0),
            window("3p-weekly", "Claude and GPT models", "Weekly Limit", used: 0.0),
        ]
    }

    /// The family a reader chose, as the resolver reads it.
    ///
    /// The resolver reads the stored preference, so a case about the
    /// third-party family has to say so rather than rely on the default.
    private func withPreferredModel(_ model: AntigravityHeadlineModel,
                                    _ body: () -> Void) {
        let key = "antigravityHeadlineModel"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(model.rawValue, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    // MARK: - The chosen family is answered from itself

    func testTheChosenFamilyIsAnsweredFromItself() {
        withPreferredModel(.gemini) {
            let provider = AntigravityProvider(session: URLSession.shared)
            let windows = geminiWindows + thirdPartyWindows
            XCTAssertEqual(provider.resolveHeadlineID(for: windows), "gemini-5h")
            XCTAssertEqual(provider.resolveWeeklyID(for: windows), "gemini-weekly")
        }
    }

    // MARK: - A missing family is not answered with another one

    /// The reading before: a Gemini reader with no Gemini group was shown the
    /// third-party group's number, under the third-party group's name.
    func testAMissingFamilyIsNotAnsweredWithAnotherFamily() {
        withPreferredModel(.gemini) {
            let provider = AntigravityProvider(session: URLSession.shared)
            let windows = thirdPartyWindows

            XCTAssertEqual(
                provider.resolveHeadlineID(for: windows),
                AntigravityProvider.unavailableWindowID,
                "a family that reported nothing must not be answered with another family"
            )
            XCTAssertNil(
                provider.resolveWeeklyID(for: windows),
                "there is no weekly allowance to draw a second ring from"
            )
        }
    }

    /// The other direction: a third-party reader with no third-party group.
    func testAMissingThirdPartyFamilyIsNotAnsweredWithTheGeminiOne() {
        withPreferredModel(.thirdParty) {
            let provider = AntigravityProvider(session: URLSession.shared)
            XCTAssertEqual(
                provider.resolveHeadlineID(for: geminiWindows),
                AntigravityProvider.unavailableWindowID
            )
            XCTAssertNil(provider.resolveWeeklyID(for: geminiWindows))
        }
    }

    /// The unavailable reading names the family that reported nothing, so the
    /// cell says which one rather than going quiet.
    func testTheUnavailableReadingNamesTheFamily() {
        let unavailable = AntigravityProvider.unavailableWindow(for: .gemini)
        XCTAssertEqual(unavailable.id, AntigravityProvider.unavailableWindowID)
        XCTAssertEqual(unavailable.group, "Gemini Models")
        XCTAssertEqual(unavailable.label, "No reading")
        XCTAssertNil(unavailable.usedFraction, "an absent allowance is not a zero")
    }

    /// The id has to sit outside every family's namespace, or adding the
    /// unavailable reading would make that family look present again.
    func testTheUnavailableIdIsOutsideEveryFamily() {
        for model in AntigravityHeadlineModel.allCases {
            XCTAssertFalse(
                AntigravityProvider.unavailableWindowID.hasPrefix(model.rawValue),
                "\(model.rawValue) would match the unavailable reading"
            )
        }
    }

    /// A reading that is present is never displaced by the unavailable one.
    func testAPresentFamilyIsNotAffectedByTheUnavailableReading() {
        withPreferredModel(.gemini) {
            let provider = AntigravityProvider(session: URLSession.shared)
            let windows = geminiWindows + [AntigravityProvider.unavailableWindow(for: .gemini)]
            XCTAssertEqual(provider.resolveHeadlineID(for: windows), "gemini-5h")
            XCTAssertEqual(provider.resolveWeeklyID(for: windows), "gemini-weekly")
        }
    }
}
