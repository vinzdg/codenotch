import Foundation

/// Which language Codenotch's own copy uses.
///
/// Follow System is the default. A forced choice exists because the Mac's
/// language is not always the one the person wants this app in — bilingual
/// machines, or a Mac in a language we do not ship.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case french = "fr"
    case german = "de"
    case indonesian = "id"
    case japanese = "ja"
    case korean = "ko"
    case brazilianPortuguese = "pt-BR"
    case russian = "ru"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case ukrainian = "uk"
    case uzbek = "uz"
    case turkish = "tr"
    case spanish = "es"

    var id: String { rawValue }

    /// `nil` means follow the Mac.
    ///
    /// Plain `en`, not `en_US`: these identifiers are looked up against the
    /// string catalog, whose English is filed under `en`. A region-qualified
    /// identifier misses it and falls through to whatever localization the
    /// bundle offers next — which made choosing English serve Chinese.
    var locale: Locale? {
        switch self {
        case .system:              return nil
        case .english:             return Locale(identifier: "en")
        case .french:              return Locale(identifier: "fr")
        case .german:              return Locale(identifier: "de")
        case .indonesian:          return Locale(identifier: "id")
        case .japanese:            return Locale(identifier: "ja")
        case .korean:              return Locale(identifier: "ko")
        case .brazilianPortuguese: return Locale(identifier: "pt-BR")
        case .russian:             return Locale(identifier: "ru")
        case .simplifiedChinese:   return Locale(identifier: "zh-Hans")
        case .traditionalChinese:  return Locale(identifier: "zh-Hant")
        case .ukrainian:           return Locale(identifier: "uk")
        case .uzbek:               return Locale(identifier: "uz")
        case .turkish:             return Locale(identifier: "tr")
        case .spanish:             return Locale(identifier: "es")
        }
    }

    /// English, Français, Deutsch, Bahasa Indonesia, 日本語, 한국어,
    /// Português (Brasil), Русский, 简体中文, 繁體中文, Українська, Oʻzbekcha,
    /// Türkçe and Español stay in their own language so the row is
    /// recognizable when the rest of Settings is in another one.
    var title: String {
        switch self {
        case .system:              return L10n.t("Follow System")
        case .english:             return "English"
        case .french:              return "Français"
        case .german:              return "Deutsch"
        case .indonesian:          return "Bahasa Indonesia"
        case .japanese:            return "日本語"
        case .korean:              return "한국어"
        case .brazilianPortuguese: return "Português (Brasil)"
        case .russian:             return "Русский"
        case .simplifiedChinese:   return "简体中文"
        case .traditionalChinese:  return "繁體中文"
        case .ukrainian:           return "Українська"
        case .uzbek:               return "Oʻzbekcha"
        case .turkish:             return "Türkçe"
        case .spanish:             return "Español"
        }
    }

    var explanation: String {
        switch self {
        case .system:
            return L10n.t("Matches the Mac's preferred language.")
        case .english, .french, .german, .indonesian, .japanese, .korean,
             .brazilianPortuguese, .russian, .simplifiedChinese, .traditionalChinese,
             .ukrainian, .uzbek, .turkish, .spanish:
            return L10n.t("Codenotch uses this language even if the Mac does not.")
        }
    }
}
