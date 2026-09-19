import Foundation

enum ResetTimeFormat: String, CaseIterable, Identifiable {
    case automatic
    case remaining

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L10n.t("Reset date")
        case .remaining: return L10n.t("Time remaining")
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            return L10n.t("Minutes under an hour; otherwise the reset date and time.")
        case .remaining:
            return L10n.t("Time until usage resets, such as 3 Days 3h or 3h 20m.")
        }
    }
}

/// "Resets in 51 min" under an hour, "Resets Thu 12:00 AM" within the week,
/// "Resets Sep 28" beyond it.
enum ResetCopy {
    static func text(for resetsAt: Date, now: Date = Date(), calendar: Calendar = .current,
                     format: ResetTimeFormat = .automatic, locale: Locale = L10n.locale) -> String {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return L10n.t("Resetting…", locale: locale) }

        if format == .remaining {
            let minutes = max(1, Int((seconds / 60).rounded()))
            let hours = minutes / 60
            let days = hours / 24
            if days > 0 {
                return days == 1
                    ? L10n.t("Resets in \(days) Day \(hours % 24)h", locale: locale)
                    : L10n.t("Resets in \(days) Days \(hours % 24)h", locale: locale)
            }
            if hours > 0 {
                return L10n.t("Resets in \(hours)h \(minutes % 60)m", locale: locale)
            }
            return L10n.t("Resets in \(minutes) min", locale: locale)
        }

        // Rounding, not truncation, so 50m40s reads as 51 rather than 50. A
        // value that rounds up to 60 falls through to the absolute form, so
        // "Resets in 60 min" never appears.
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return L10n.t("Resets in \(max(1, minutes)) min", locale: locale)
        }

        let formatter = formatter(for: calendar)
        formatter.locale = locale

        // A weekday only identifies a day inside the coming week. Codex's
        // monthly window resets 26 days out, and "Resets Mon 3:55 PM" read as
        // *this* Monday — six days away rather than nearly four weeks, which is
        // what made the app disagree with Codex's own "Resets Sep 28".
        if daysApart(from: now, to: resetsAt, calendar: calendar) >= 7 {
            // Day and month only, matching how the vendors write it. A time
            // that far out is noise: nobody plans around 3:55 PM in four weeks.
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            return L10n.t("Resets \(formatter.string(from: resetsAt))", locale: locale)
        }

        // `j`, not `h`: a literal hour symbol in a template pins the clock to
        // twelve hours whatever the region, so everywhere that writes 00:00
        // rather than 12:00 AM — most of Europe, Asia and Latin America — read
        // "Resets mer. 12:00 AM" here while every other clock on the Mac said
        // 00:00. `j` asks the locale, which also carries the "24-Hour Time"
        // switch in System Settings. Regions that write AM/PM keep it, so
        // English is still "Thu 12:00 AM".
        formatter.setLocalizedDateFormatFromTemplate("E j:mm")
        return L10n.t("Resets \(formatter.string(from: resetsAt))", locale: locale)
    }

    /// The time left before a reset, as short as the menu bar needs it: "2h 05m",
    /// "47m", "<1m". Nil once the reset has passed — a window that is over has
    /// no time left to show, and never a negative one.
    ///
    /// Truncated where `text` rounds. This one is read against a clock, so it
    /// may never claim more time than there is: "<1m" is always under a
    /// minute, and "1h 00m" is gone the moment the hour is.
    static func countdown(to resetsAt: Date, now: Date = Date(),
                          locale: Locale = L10n.locale) -> String? {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return L10n.t("<1m", locale: locale) }
        if minutes < 60 { return L10n.t("\(minutes)m", locale: locale) }
        // Two digits, so "2h 05m" is as wide as "2h 50m" and whatever sits
        // beside it in the menu bar does not shuffle as the minutes tick over.
        let padded = String(format: "%02d", minutes % 60)
        return L10n.t("\(minutes / 60)h \(padded)m", locale: locale)
    }

    /// When `countdown` next reads differently — the next whole minute of time
    /// left, or the reset itself in the last minute. Nil once it has passed.
    static func nextCountdownChange(to resetsAt: Date, now: Date = Date()) -> Date? {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        return resetsAt.addingTimeInterval(-(seconds / 60).rounded(.down) * 60)
    }

    /// A formatter that renders in the given calendar's own zone.
    ///
    /// Setting `calendar` does not carry its time zone across, and the formatter
    /// otherwise falls back to the device's — so a date rendered against an
    /// explicit calendar came out shifted by the difference. Shared because
    /// `UsageBlock.summary` formats the same kind of vendor reset time from the
    /// same kind of injected calendar, and had the same defect.
    static func formatter(for calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? L10n.locale
        return formatter
    }

    /// Whole days between two instants, counted by calendar day rather than by
    /// dividing seconds — so a clock change cannot shift the answer.
    static func daysApart(from: Date, to: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}
