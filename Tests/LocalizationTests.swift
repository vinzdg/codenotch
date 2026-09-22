import XCTest
@testable import Codenotch

/// Catalog lookups with an explicit locale. English is the source; Chinese,
/// French and Brazilian Portuguese assertions here only prove a translation
/// that exists is served, not that every key has one.
final class LocalizationTests: XCTestCase {
    private let zhHans = Locale(identifier: "zh-Hans")
    private let zhHant = Locale(identifier: "zh-Hant")
    private let french = Locale(identifier: "fr")
    private let german = Locale(identifier: "de")
    private let japanese = Locale(identifier: "ja")
    private let russian = Locale(identifier: "ru")
    private let ukrainian = Locale(identifier: "uk")
    private let brazilianPortuguese = Locale(identifier: "pt-BR")
    private let english = Locale(identifier: "en")
    private let now = Date(timeIntervalSince1970: 1_787_900_000)
    private let resetNow = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - ElapsedCopy

    func testElapsedCopyInSimplifiedChinese() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: zhHans),
            "刚刚"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-6 * 60), now: now, locale: zhHans),
            "6 分钟"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-60 * 60), now: now, locale: zhHans),
            "1 小时"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-65 * 60), now: now, locale: zhHans),
            "1 小时 5 分钟"
        )
        XCTAssertEqual(
            ElapsedCopy.ago(since: now.addingTimeInterval(-6 * 60), now: now, locale: zhHans),
            "6 分钟前"
        )
    }

    func testElapsedCopyInEnglishWhenAsked() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: english),
            "just now"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-6 * 60), now: now, locale: english),
            "6 min"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-60 * 60), now: now, locale: english),
            "1 hr"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-65 * 60), now: now, locale: english),
            "1 hr 5 min"
        )
        XCTAssertEqual(
            ElapsedCopy.ago(since: now.addingTimeInterval(-6 * 60), now: now, locale: english),
            "6 min ago"
        )
    }

    // MARK: - ResetCopy

    func testResetCopyUnderAnHourInSimplifiedChinese() {
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: zhHans),
            "51 分钟后重置"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(-5), now: resetNow, locale: zhHans),
            "正在重置…"
        )
    }

    func testResetCopyUnderAnHourInEnglishWhenAsked() {
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: english),
            "Resets in 51 min"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(-5), now: resetNow, locale: english),
            "Resetting…"
        )
    }

    // MARK: - LimitWindow.summary

    func testWindowSummaryInSimplifiedChinese() {
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: zhHans),
            "12% 已用 · 88% 剩余"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", used: 8).summary(locale: zhHans),
            "已用 8"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", remaining: 3).summary(locale: zhHans),
            "剩余 3"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests").summary(locale: zhHans),
            "暂无读数"
        )
    }

    func testWindowSummaryInEnglishWhenAsked() {
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: english),
            "12% Used · 88% left"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", used: 8).summary(locale: english),
            "8 used"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", remaining: 3).summary(locale: english),
            "3 left"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests").summary(locale: english),
            "No reading"
        )
    }

    // MARK: - Menu and settings keys

    func testMenuCopyInSimplifiedChinese() {
        XCTAssertEqual(L10n.t("Always show", locale: zhHans), "始终显示")
        XCTAssertEqual(L10n.t("Settings…", locale: zhHans), "设置…")
    }

    func testMenuCopyInEnglishWhenAsked() {
        XCTAssertEqual(L10n.t("Always show", locale: english), "Always show")
        XCTAssertEqual(L10n.t("Settings…", locale: english), "Settings…")
    }

    // MARK: - Sign-in

    func testSignInActionTitleStaysEnglishUnderTheTestPin() {
        XCTAssertEqual(
            SignInRoute.modal(name: "Perplexity").actionTitle,
            "Sign in to Perplexity"
        )
    }

    func testSignInCopyInSimplifiedChinese() {
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: zhHans),
            "登录 Perplexity"
        )
    }

    func testLimitNotificationCopyInSimplifiedChinese() {
        XCTAssertEqual(L10n.t("When a limit is reached", locale: zhHans), "额度用尽时")
        XCTAssertEqual(L10n.t("Show notification for session limit", locale: zhHans), "会话额度用尽时显示通知")
        XCTAssertEqual(L10n.t("Show notification for weekly limit", locale: zhHans), "周额度用尽时显示通知")
        XCTAssertEqual(L10n.t("Alert sound", locale: zhHans), "提示音")
        XCTAssertEqual(L10n.t("Preview session limit alert", locale: zhHans), "预览会话额度提醒")
        XCTAssertEqual(L10n.t("Preview weekly limit alert", locale: zhHans), "预览周额度提醒")
        XCTAssertEqual(
            L10n.t("Displays a notification card from the side of the notch when a provider's session or weekly usage limit is reached.", locale: zhHans),
            "当某家服务的会话或周额度用尽时，刘海侧面滑出一张通知卡片。"
        )
        XCTAssertEqual(L10n.t("When a limit resets", locale: zhHans), "额度重置时")
        XCTAssertEqual(L10n.t("Show notification from notch", locale: zhHans), "从刘海显示通知")
        XCTAssertEqual(L10n.t("Reset sound", locale: zhHans), "重置提示音")
        XCTAssertEqual(L10n.t("Preview notification", locale: zhHans), "预览通知")
        XCTAssertEqual(
            L10n.t("Displays a notification card from the side of the notch when a provider's usage limit resets.", locale: zhHans),
            "当某家服务的额度窗口滚动过后，刘海侧面滑出一张通知卡片。"
        )
    }

    func testSignInCopyInEnglishWhenAsked() {
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: english),
            "Sign in to Perplexity"
        )
    }

    // MARK: - French

    func testElapsedCopyInFrench() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: french),
            "à l'instant"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-6 * 60), now: now, locale: french),
            "6 min"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-60 * 60), now: now, locale: french),
            "1 h"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-65 * 60), now: now, locale: french),
            "1 h 5 min"
        )
        XCTAssertEqual(
            ElapsedCopy.ago(since: now.addingTimeInterval(-6 * 60), now: now, locale: french),
            "il y a 6 min"
        )
    }

    func testResetCopyUnderAnHourInFrench() {
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: french),
            "Réinit. dans 51 min"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(-5), now: resetNow, locale: french),
            "Réinitialisation…"
        )
    }

    func testWindowSummaryInFrench() {
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: french),
            "12% utilisés · 88% restants"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", used: 8).summary(locale: french),
            "8 utilisés"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", remaining: 3).summary(locale: french),
            "3 restants"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests").summary(locale: french),
            "Aucun relevé"
        )
    }

    func testMenuCopyInFrench() {
        XCTAssertEqual(L10n.t("Always show", locale: french), "Toujours afficher")
        XCTAssertEqual(L10n.t("Settings…", locale: french), "Réglages…")
    }

    func testSignInCopyInFrench() {
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: french),
            "Se connecter à Perplexity"
        )
    }

    // MARK: - German

    func testElapsedCopyInGerman() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: german),
            "gerade eben"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-6 * 60), now: now, locale: german),
            "6 Min"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-60 * 60), now: now, locale: german),
            "1 Std"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-65 * 60), now: now, locale: german),
            "1 Std 5 Min"
        )
        XCTAssertEqual(
            ElapsedCopy.ago(since: now.addingTimeInterval(-6 * 60), now: now, locale: german),
            "vor 6 Min"
        )
    }

    func testResetCopyUnderAnHourInGerman() {
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: german),
            "Zurücksetzung in 51 Min."
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(-5), now: resetNow, locale: german),
            "Wird zurückgesetzt…"
        )
    }

    func testWindowSummaryInGerman() {
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: german),
            "12% verwendet · 88% übrig"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", used: 8).summary(locale: german),
            "8 verwendet"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", remaining: 3).summary(locale: german),
            "3 übrig"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests").summary(locale: german),
            "Kein Messwert"
        )
    }

    func testMenuCopyInGerman() {
        XCTAssertEqual(L10n.t("Always show", locale: german), "Immer anzeigen")
        XCTAssertEqual(L10n.t("Settings…", locale: german), "Einstellungen…")
    }

    func testSignInCopyInGerman() {
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: german),
            "Bei Perplexity anmelden"
        )
    }

    /// The German keeps every format specifier in the order the English put
    /// them, so an `Int` still lands on `%lld` and a `String` on `%@` — the
    /// same trap the Simplified Chinese threshold alert fell into by
    /// reordering without positional specifiers.
    func testThresholdAlertKeepsArgumentOrderInGerman() {
        XCTAssertEqual(
            L10n.t("\(80)% of its \("weekly") limit used.", locale: german),
            "80% des weekly-Limits verwendet."
        )
    }

    // MARK: - Brazilian Portuguese

    func testElapsedCopyInBrazilianPortuguese() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: brazilianPortuguese),
            "agora mesmo"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-6 * 60), now: now, locale: brazilianPortuguese),
            "6 min"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-60 * 60), now: now, locale: brazilianPortuguese),
            "1 h"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-65 * 60), now: now, locale: brazilianPortuguese),
            "1 h 5 min"
        )
        XCTAssertEqual(
            ElapsedCopy.ago(since: now.addingTimeInterval(-6 * 60), now: now, locale: brazilianPortuguese),
            "há 6 min"
        )
    }

    func testResetCopyUnderAnHourInBrazilianPortuguese() {
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: brazilianPortuguese),
            "Renova em 51 min"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(-5), now: resetNow, locale: brazilianPortuguese),
            "Renovando…"
        )
    }

    func testWindowSummaryInBrazilianPortuguese() {
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: brazilianPortuguese),
            "12% usado · 88% restante"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", used: 8).summary(locale: brazilianPortuguese),
            "8 usados"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", remaining: 3).summary(locale: brazilianPortuguese),
            "3 restantes"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests").summary(locale: brazilianPortuguese),
            "Sem leitura"
        )
    }

    func testMenuCopyInBrazilianPortuguese() {
        XCTAssertEqual(L10n.t("Always show", locale: brazilianPortuguese), "Sempre exibir")
        XCTAssertEqual(L10n.t("Settings…", locale: brazilianPortuguese), "Ajustes…")
    }

    func testSignInCopyInBrazilianPortuguese() {
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: brazilianPortuguese),
            "Entrar no Perplexity"
        )
    }

    /// `pt-BR` is the only offered identifier that carries a region, so it
    /// is the one that could hit the trap `AppLanguage.locale` documents for
    /// `en_US`: an identifier the catalog is not filed under falls through to
    /// another localization. The catalog is filed under `pt-BR`, so the
    /// picker's identifier has to stay region-qualified to match it.
    func testPortugueseIsServedUnderTheRegionQualifiedIdentifier() {
        XCTAssertEqual(L10n.t("Usage", locale: brazilianPortuguese), "Uso")
        XCTAssertEqual(AppLanguage.brazilianPortuguese.locale?.identifier, "pt-BR")
    }

    // MARK: - Japanese

    func testElapsedCopyInJapanese() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: japanese),
            "たった今"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-6 * 60), now: now, locale: japanese),
            "6 分"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-60 * 60), now: now, locale: japanese),
            "1 時間"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-65 * 60), now: now, locale: japanese),
            "1 時間 5 分"
        )
        XCTAssertEqual(
            ElapsedCopy.ago(since: now.addingTimeInterval(-6 * 60), now: now, locale: japanese),
            "6 分前"
        )
    }

    func testResetCopyUnderAnHourInJapanese() {
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: japanese),
            "51 分後にリセット"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(-5), now: resetNow, locale: japanese),
            "リセット中…"
        )
    }

    func testWindowSummaryInJapanese() {
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: japanese),
            "12% 使用 · 残り 88%"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", used: 8).summary(locale: japanese),
            "8 使用"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", remaining: 3).summary(locale: japanese),
            "残り 3"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests").summary(locale: japanese),
            "読み取りなし"
        )
    }

    func testMenuCopyInJapanese() {
        XCTAssertEqual(L10n.t("Always show", locale: japanese), "常に表示")
        XCTAssertEqual(L10n.t("Settings…", locale: japanese), "設定…")
    }

    func testSignInCopyInJapanese() {
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: japanese),
            "Perplexity にサインイン"
        )
    }

    /// The Japanese keeps every format specifier in the order the English put
    /// them, so an `Int` still lands on `%lld` and a `String` on `%@`. This is
    /// the threshold alert, whose two arguments are of different types and
    /// would be read through the wrong conversion if a translation swapped
    /// them without positional specifiers.
    func testThresholdAlertKeepsArgumentOrderInJapanese() {
        XCTAssertEqual(
            L10n.t("\(80)% of its \("weekly") limit used.", locale: japanese),
            "80% を使用（weekly の上限）。"
        )
    }

    // MARK: - Russian

    func testCoreCopyInRussian() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: russian),
            "только что"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: russian),
            "Сброс через 51 мин"
        )
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: russian),
            // The catalog's own wording. The expectation was written against
            // an earlier draft of the translation and never matched what
            // shipped, so this failed on its own branch.
            "Использовано 12% · осталось 88%"
        )
        XCTAssertEqual(L10n.t("Always show", locale: russian), "Всегда показывать")
        XCTAssertEqual(L10n.t("Settings…", locale: russian), "Настройки…")
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: russian),
            "Войти в Perplexity"
        )
    }

    func testRussianThresholdAlertKeepsArgumentOrder() {
        XCTAssertEqual(
            L10n.t("\(80)% of its \("weekly") limit used.", locale: russian),
            "Использовано 80% от лимита «weekly»."
        )
    }

    // MARK: - Ukrainian

    func testCoreCopyInUkrainian() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: ukrainian),
            "щойно"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: ukrainian),
            "Скидання через 51 хв"
        )
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: ukrainian),
            "Використано 12% · лишилось 88%"
        )
        XCTAssertEqual(L10n.t("Always show", locale: ukrainian), "Показувати завжди")
        XCTAssertEqual(L10n.t("Settings…", locale: ukrainian), "Налаштування…")
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: ukrainian),
            "Увійти в Perplexity"
        )
    }

    func testUkrainianThresholdAlertKeepsArgumentOrder() {
        XCTAssertEqual(
            L10n.t("\(80)% of its \("weekly") limit used.", locale: ukrainian),
            "Використано 80% ліміту «weekly»."
        )
    }

    // MARK: - Traditional Chinese

    func testCoreCopyInTraditionalChinese() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: zhHant),
            "剛剛"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-6 * 60), now: now, locale: zhHant),
            "6 分鐘"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: zhHant),
            "51 分鐘後重置"
        )
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: zhHant),
            "12% 已用 · 88% 剩餘"
        )
        XCTAssertEqual(L10n.t("Always show", locale: zhHant), "始終顯示")
        XCTAssertEqual(L10n.t("Settings…", locale: zhHant), "設定…")
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: zhHant),
            "登入 Perplexity"
        )
    }

    func testTraditionalChineseThresholdAlertKeepsArgumentOrder() {
        XCTAssertEqual(
            L10n.t("\(80)% of its \("weekly") limit used.", locale: zhHant),
            "已用其 weekly 額度的 80%。"
        )
    }

    /// Every language the picker offers must resolve to a locale the catalog
    /// is filed under — a region-qualified or unshipped identifier silently
    /// serves another language instead.
    func testEveryOfferedLanguageResolves() {
        XCTAssertEqual(
            AppLanguage.allCases.map(\.rawValue),
            ["system", "en", "fr", "de", "ja", "ko", "pt-BR", "ru", "zh-Hans", "zh-Hant", "uk"]
        )
        XCTAssertNil(AppLanguage.system.locale)
        for language in AppLanguage.allCases where language != .system {
            XCTAssertEqual(language.locale?.identifier, language.rawValue)
        }
    }

    private func percentWindow(_ fraction: Double) -> LimitWindow {
        LimitWindow(id: "w", label: "Monthly limit", usedFraction: fraction)
    }
}
