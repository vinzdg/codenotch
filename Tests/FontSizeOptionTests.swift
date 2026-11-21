import XCTest
@testable import Codenotch

@MainActor
final class FontSizeOptionTests: XCTestCase {
    func testAllCasesHaveValidScales() {
        XCTAssertEqual(FontSizeOption.standard.scale, 1.0)
        XCTAssertLessThan(FontSizeOption.small.scale, FontSizeOption.standard.scale)
        XCTAssertGreaterThan(FontSizeOption.medium.scale, FontSizeOption.standard.scale)
        XCTAssertGreaterThan(FontSizeOption.large.scale, FontSizeOption.medium.scale)
        XCTAssertGreaterThan(FontSizeOption.extraLarge.scale, FontSizeOption.large.scale)
    }

    func testAllCasesHaveExplanationsAndTitles() {
        for option in FontSizeOption.allCases {
            XCTAssertFalse(option.title.isEmpty, "Missing title for \(option)")
            XCTAssertFalse(option.explanation.isEmpty, "Missing explanation for \(option)")
            XCTAssertEqual(option.id, option.rawValue)
        }
    }

    func testPreferencesPersistence() {
        let defaults = UserDefaults(suiteName: "FontSizeOptionTests.\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)

        XCTAssertEqual(prefs.fontSizeOption, .standard)
        XCTAssertEqual(prefs.typographyScale, 1.0)

        prefs.fontSizeOption = .large
        XCTAssertEqual(prefs.fontSizeOption, .large)
        XCTAssertEqual(prefs.typographyScale, 1.30)
        XCTAssertEqual(defaults.string(forKey: "fontSizeOption"), "large")

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.fontSizeOption, .large)
        XCTAssertEqual(reloaded.typographyScale, 1.30)
    }
}
