import XCTest

/// The catalog's source language is English. A missing translation in any
/// other language must fall back to that English, not fail the suite — the
/// app's language is English, and a half-finished locale must not block CI.
final class CatalogCoverageTests: XCTestCase {
    func testSourceLanguageIsEnglish() throws {
        XCTAssertEqual(try loadCatalog().json.sourceLanguage, "en")
    }

    func testTheCatalogHasKeys() throws {
        XCTAssertFalse(try loadCatalog().json.strings.isEmpty, "catalog has no strings")
    }

    func testCatalogHasNoMergeConflictMarkers() throws {
        XCTAssertFalse(
            try loadCatalog().raw.contains("<<<<<<"),
            "Localizable.xcstrings still has a leftover conflict marker"
        )
    }

    func testRussianCoreCopyIsTranslated() throws {
        let catalog = try loadCatalog().json
        let expected = [
            "just now": "только что",
            "Resets in %lld min": "Сброс через %lld мин",
            "%lld%% Used · %lld%% left": "Использовано %lld%% · осталось %lld%%",
            "Always show": "Всегда показывать",
            "Settings…": "Настройки…",
            "Sign in to %@": "Войти в %@",
            "%lld%% of its %@ limit used.": "Использовано %lld%% от лимита «%@»."
        ]

        for (key, value) in expected {
            XCTAssertEqual(
                catalog.strings[key]?.localizations?["ru"]?.stringUnit?.value,
                value,
                "missing Russian translation for \(key)"
            )
        }
    }

    func testUkrainianCoreCopyIsTranslated() throws {
        let catalog = try loadCatalog().json
        let expected = [
            "just now": "щойно",
            "Resets in %lld min": "Скидання через %lld хв",
            "%lld%% Used · %lld%% left": "Використано %lld%% · лишилось %lld%%",
            "Always show": "Показувати завжди",
            "Settings…": "Налаштування…",
            "Sign in to %@": "Увійти в %@",
            "%lld%% of its %@ limit used.": "Використано %lld%% ліміту «%@»."
        ]

        for (key, value) in expected {
            XCTAssertEqual(
                catalog.strings[key]?.localizations?["uk"]?.stringUnit?.value,
                value,
                "missing Ukrainian translation for \(key)"
            )
        }
    }

    func testSimplifiedChineseCoreCopyIsTranslated() throws {
        let catalog = try loadCatalog().json
        let expected = [
            "just now": "刚刚",
            "Resets in %lld min": "%lld 分钟后重置",
            "%lld%% Used · %lld%% left": "%lld%% 已用 · %lld%% 剩余",
            "Always show": "始终显示",
            "Settings…": "设置…",
            "Sign in to %@": "登录 %@",
            "%lld%% of its %@ limit used.": "已用其 %2$@ 额度的 %1$lld%%。",
            "Ready on %@:%d": "已在 %@:%d 就绪",
            "Expires in %@": "%@ 后过期"
        ]

        for (key, value) in expected {
            XCTAssertEqual(
                catalog.strings[key]?.localizations?["zh-Hans"]?.stringUnit?.value,
                value,
                "missing Simplified Chinese translation for \(key)"
            )
        }
    }

    func testTraditionalChineseCoreCopyIsTranslated() throws {
        let catalog = try loadCatalog().json
        let expected = [
            "just now": "剛剛",
            "Resets in %lld min": "%lld 分鐘後重置",
            "%lld%% Used · %lld%% left": "%lld%% 已用 · %lld%% 剩餘",
            "Always show": "始終顯示",
            "Settings…": "設定…",
            "Sign in to %@": "登入 %@",
            "%lld%% of its %@ limit used.": "已用其 %2$@ 額度的 %1$lld%%。"
        ]

        for (key, value) in expected {
            XCTAssertEqual(
                catalog.strings[key]?.localizations?["zh-Hant"]?.stringUnit?.value,
                value,
                "missing Traditional Chinese translation for \(key)"
            )
        }
    }

    func testKoreanCoreCopyIsTranslated() throws {
        let catalog = try loadCatalog().json
        let expected = [
            "just now": "방금",
            "Resets in %lld min": "%lld분 후 재설정",
            "%lld%% Used · %lld%% left": "%lld%% 사용 · %lld%% 남음",
            "Always show": "항상 표시",
            "Settings…": "설정…",
            "Watch limit": "주의 표시 기준",
            "Critical limit": "위험 표시 기준"
        ]
        for (key, value) in expected {
            XCTAssertEqual(
                catalog.strings[key]?.localizations?["ko"]?.stringUnit?.value,
                value,
                "missing Korean translation for \(key)"
            )
        }
    }

    func testUzbekCoreCopyIsTranslated() throws {
        let catalog = try loadCatalog().json
        let expected = [
            "just now": "hozirgina",
            "Resets in %lld min": "%lld daqiqadan soʻng yangilanadi",
            "%lld%% Used · %lld%% left": "%lld%% ishlatilgan · %lld%% qoldi",
            "Always show": "Doimo",
            "Settings…": "Sozlamalar…",
            "Sign in to %@": "%@ ga kirish",
            "%lld%% of its %@ limit used.": "%2$@ limitining %1$lld%% ishlatilgan."
        ]

        for (key, value) in expected {
            XCTAssertEqual(
                catalog.strings[key]?.localizations?["uz"]?.stringUnit?.value,
                value,
                "missing Uzbek translation for \(key)"
            )
        }
    }

    func testTurkishCoreCopyIsTranslated() throws {
        let catalog = try loadCatalog().json
        let expected = [
            "just now": "az önce",
            "Resets in %lld min": "%lld dk içinde sıfırlanır",
            "%lld%% Used · %lld%% left": "%%%lld kullanıldı · %%%lld kaldı",
            "Always show": "Her zaman",
            "Settings…": "Ayarlar…",
            "Sign in to %@": "Giriş yap: %@",
            "%lld%% of its %@ limit used.": "%2$@ limitinin %%%1$lld kadarı kullanıldı."
        ]

        for (key, value) in expected {
            XCTAssertEqual(
                catalog.strings[key]?.localizations?["tr"]?.stringUnit?.value,
                value,
                "missing Turkish translation for \(key)"
            )
        }
    }

    func testSpanishCoreCopyIsTranslated() throws {
        let catalog = try loadCatalog().json
        let expected = [
            "just now": "ahora mismo",
            "Resets in %lld min": "Se renueva en %lld min",
            "%lld%% Used · %lld%% left": "%lld%% usado · %lld%% restante",
            "Always show": "Mostrar siempre",
            "Settings…": "Ajustes…",
            "Sign in to %@": "Iniciar sesión en %@",
            "%lld%% of its %@ limit used.": "Se usó el %lld%% de su límite (%@)."
        ]

        for (key, value) in expected {
            XCTAssertEqual(
                catalog.strings[key]?.localizations?["es"]?.stringUnit?.value,
                value,
                "missing Spanish translation for \(key)"
            )
        }
    }

    /// There is deliberately no "language X covers every key" test.
    ///
    /// The rule at the top of this file is that a missing translation falls
    /// back to English rather than failing the suite, and no locale here is
    /// complete: French and Portuguese cover 350 of 470 keys, Japanese 428.
    /// #141 added one for Russian, which passed only while Russian happened to
    /// be complete — the next pull request to add a string broke it, and that
    /// is exactly the CI block the rule exists to prevent.

    // MARK: - Loading

    /// Repo `Tests/`, so the catalog is `../Sources/Localizable.xcstrings`.
    private func catalogURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Localizable.xcstrings")
            .standardizedFileURL
    }

    private func loadCatalog() throws -> (raw: String, json: CatalogFile) {
        let url = catalogURL()
        do {
            let data = try Data(contentsOf: url)
            return (String(decoding: data, as: UTF8.self), try JSONDecoder().decode(CatalogFile.self, from: data))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            throw XCTSkip("macOS privacy restricts reading the source catalog at \(url.path)")
        }
    }
}

private struct CatalogFile: Decodable {
    var sourceLanguage: String
    var strings: [String: CatalogEntry]
}

private struct CatalogEntry: Decodable {
    var localizations: [String: CatalogLocalization]?
}

private struct CatalogLocalization: Decodable {
    var stringUnit: CatalogStringUnit?
}

private struct CatalogStringUnit: Decodable {
    var state: String?
    var value: String?
}
