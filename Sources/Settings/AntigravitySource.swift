import Foundation

/// Where Antigravity reads its usage from on macOS.
enum AntigravitySource: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Prefers `agy` CLI and Google OAuth without launching Antigravity IDE.
    case automatic = "automatic"
    /// Reads exclusively from the `agy` CLI (`agy --print /usage`).
    case cli = "cli"
    /// Reads exclusively via Google OAuth tokens against Cloud Code PA.
    case oauth = "oauth"
    /// Uses Antigravity IDE's local language server bridge.
    case ide = "ide"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L10n.t("Automatic (CLI / OAuth)")
        case .cli: return L10n.t("agy CLI")
        case .oauth: return L10n.t("Google OAuth")
        case .ide: return L10n.t("Antigravity IDE")
        }
    }
}
