import Foundation

/// "how long has it been like this" — the second half of answering "is Claude
/// still working".
enum ElapsedCopy {
    /// The same span, phrased as a point in the past.
    static func ago(since: Date, now: Date = Date(), locale: Locale = L10n.locale) -> String {
        let elapsed = text(since: since, now: now, locale: locale)
        return elapsed == L10n.t("just now", locale: locale)
            ? elapsed
            : L10n.t("\(elapsed) ago", locale: locale)
    }

    static func text(since: Date, now: Date = Date(), locale: Locale = L10n.locale) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 45 { return L10n.t("just now", locale: locale) }

        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return L10n.t("\(max(1, minutes)) min", locale: locale) }

        let hours = minutes / 60
        // Past a day the hours stop being useful, and "81 hr 9 min ago" no
        // longer fits a card header.
        if hours >= 24 {
            let days = hours / 24
            return days == 1 ? L10n.t("\(days) day", locale: locale) : L10n.t("\(days) days", locale: locale)
        }
        let rest = minutes % 60
        if rest == 0 { return L10n.t("\(hours) hr", locale: locale) }
        return L10n.t("\(hours) hr \(rest) min", locale: locale)
    }
}
