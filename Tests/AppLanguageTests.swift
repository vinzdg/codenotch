import XCTest
@testable import Codenotch

/// In-app language is a stored override, not the Mac's language. Follow
/// System still hits the XCTest English pin when nothing is stored.
final class AppLanguageTests: XCTestCase {
    private var suiteName = ""
    private var previousDefaults: UserDefaults?
    private var previousTestLocale: Locale?

    /// A scratch suite, not `.standard`. The test host *is* the app, so
    /// `.standard` is the preferences of the copy of Codenotch installed on
    /// this Mac: reading it would let a language chosen in Settings decide
    /// what these assert, and writing it would leave a language behind in the
    /// real app when a test failed before its restore.
    override func setUp() {
        super.setUp()
        suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: suiteName)!
        scratch.removePersistentDomain(forName: suiteName)
        previousDefaults = L10n.defaults
        previousTestLocale = L10n.testLocale
        L10n.defaults = scratch
        L10n.testLocale = nil
        L10n.apply(.system)
    }

    override func tearDown() {
        L10n.testLocale = previousTestLocale
        L10n.defaults.removePersistentDomain(forName: suiteName)
        if let previousDefaults { L10n.defaults = previousDefaults }
        super.tearDown()
    }

    func testFollowSystemUsesTheEnglishPinWhenNothingIsStored() {
        L10n.apply(.system)
        L10n.testLocale = nil
        XCTAssertTrue(
            L10n.locale.identifier.hasPrefix("en"),
            "XCTest pin should return English when appLanguage is unset, got \(L10n.locale.identifier)"
        )
    }

    /// A forced English must actually be English. The catalog files its
    /// source strings under `en`, so the region-qualified `en_US` this used
    /// to store matched nothing and fell through to the next localization the
    /// bundle offered — Chinese, on a build that ships one.
    func testApplyEnglishServesEnglishCopy() {
        L10n.apply(.english)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.t("Always show"), "Always show")
    }

    /// `apply(.simplifiedChinese)` stores `zh-Hans`, and `L10n.locale`
    /// honours that even under XCTest, so the default `t()` lookup is
    /// Chinese without setting `testLocale`.
    func testApplySimplifiedChineseServesChineseCopy() {
        L10n.apply(.simplifiedChinese)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.t("Always show"), "始终显示")
    }

    /// Japanese is offered in the picker under the identifier the catalog
    /// files its translations under. Deliberately no assertion on the copy
    /// `ja` serves: the catalog carries no Japanese yet, so today it falls
    /// back to English, and pinning that would turn into a failing test the
    /// moment a translation lands — which is the point of the branch.
    func testJapaneseIsOfferedAndMapsToJa() {
        XCTAssertTrue(AppLanguage.allCases.contains(.japanese))
        XCTAssertEqual(AppLanguage.japanese.title, "日本語")
    }

    /// The override round-trips through the store like any other language,
    /// even while the catalog has nothing to serve for it.
    func testApplyJapaneseStoresTheOverride() {
        L10n.apply(.japanese)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.locale.identifier, "ja")
    }

    func testGermanIsOfferedAndMapsToDe() {
        XCTAssertTrue(AppLanguage.allCases.contains(.german))
        XCTAssertEqual(AppLanguage.german.title, "Deutsch")
        XCTAssertEqual(AppLanguage.german.locale?.identifier, "de")
    }

    func testApplyGermanStoresTheOverride() {
        L10n.apply(.german)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.locale.identifier, "de")
    }

    func testRussianIsOfferedAndMapsToRu() {
        XCTAssertTrue(AppLanguage.allCases.contains(.russian))
        XCTAssertEqual(AppLanguage.russian.title, "Русский")
        XCTAssertEqual(AppLanguage.russian.locale?.identifier, "ru")
    }

    func testApplyRussianStoresTheOverride() {
        L10n.apply(.russian)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.locale.identifier, "ru")
    }

    func testUkrainianIsOfferedAndMapsToUk() {
        XCTAssertTrue(AppLanguage.allCases.contains(.ukrainian))
        XCTAssertEqual(AppLanguage.ukrainian.title, "Українська")
        XCTAssertEqual(AppLanguage.ukrainian.locale?.identifier, "uk")
    }

    func testApplyUkrainianStoresTheOverride() {
        L10n.apply(.ukrainian)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.locale.identifier, "uk")
    }

    func testTraditionalChineseIsOfferedAndMapsToZhHant() {
        XCTAssertTrue(AppLanguage.allCases.contains(.traditionalChinese))
        XCTAssertEqual(AppLanguage.traditionalChinese.title, "繁體中文")
        XCTAssertEqual(AppLanguage.traditionalChinese.locale?.identifier, "zh-Hant")
    }

    func testApplyTraditionalChineseStoresTheOverride() {
        L10n.apply(.traditionalChinese)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.locale.identifier, "zh-Hant")
    }

    func testApplyTraditionalChineseServesTraditionalCopy() {
        L10n.apply(.traditionalChinese)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.t("Always show"), "始終顯示")
        XCTAssertEqual(L10n.t("Settings…"), "設定…")
    }
    func testKoreanIsOfferedAndMapsToKo() {
        XCTAssertTrue(AppLanguage.allCases.contains(.korean))
        XCTAssertEqual(AppLanguage.korean.title, "한국어")
        XCTAssertEqual(AppLanguage.korean.locale?.identifier, "ko")
    }

    func testApplyKoreanStoresTheOverrideAndServesKoreanCopy() {
        L10n.apply(.korean)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.locale.identifier, "ko")
        XCTAssertEqual(L10n.t("Always show"), "항상 표시")
        XCTAssertEqual(L10n.t("Settings…"), "설정…")
    }


    func testUzbekIsOfferedAndMapsToUz() {
        XCTAssertTrue(AppLanguage.allCases.contains(.uzbek))
        XCTAssertEqual(AppLanguage.uzbek.title, "Oʻzbekcha")
        XCTAssertEqual(AppLanguage.uzbek.locale?.identifier, "uz")
    }

    func testApplyUzbekStoresTheOverride() {
        L10n.apply(.uzbek)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.locale.identifier, "uz")
    }

    func testApplyUzbekServesUzbekCopy() {
        L10n.apply(.uzbek)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.t("Always show"), "Doimo")
        XCTAssertEqual(L10n.t("Settings…"), "Sozlamalar…")

    func testIndonesianIsOfferedAndMapsToId() {
        XCTAssertTrue(AppLanguage.allCases.contains(.indonesian))
        XCTAssertEqual(AppLanguage.indonesian.title, "Bahasa Indonesia")
        XCTAssertEqual(AppLanguage.indonesian.locale?.identifier, "id")
    }

    func testApplyIndonesianStoresTheOverride() {
        L10n.apply(.indonesian)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.locale.identifier, "id")
    }
    }

    func testTurkishIsOfferedAndMapsToTr() {
        XCTAssertTrue(AppLanguage.allCases.contains(.turkish))
        XCTAssertEqual(AppLanguage.turkish.title, "Türkçe")
        XCTAssertEqual(AppLanguage.turkish.locale?.identifier, "tr")
    }

    func testApplyTurkishStoresTheOverride() {
        L10n.apply(.turkish)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.locale.identifier, "tr")
    }

    func testApplyTurkishServesTurkishCopy() {
        L10n.apply(.turkish)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.t("Always show"), "Her zaman")
        XCTAssertEqual(L10n.t("Settings…"), "Ayarlar…")
    }

    func testSpanishIsOfferedAndMapsToEs() {
        XCTAssertTrue(AppLanguage.allCases.contains(.spanish))
        XCTAssertEqual(AppLanguage.spanish.title, "Español")
        XCTAssertEqual(AppLanguage.spanish.locale?.identifier, "es")
    }

    func testApplySpanishStoresTheOverrideAndServesSpanishCopy() {
        L10n.apply(.spanish)
        L10n.testLocale = nil
        XCTAssertEqual(L10n.locale.identifier, "es")
        XCTAssertEqual(L10n.t("Always show"), "Mostrar siempre")
        XCTAssertEqual(L10n.t("Settings…"), "Ajustes…")
    }
}
