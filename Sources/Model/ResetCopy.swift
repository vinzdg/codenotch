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

/// "Resets in 42 sec" inside the last minute, "Resets in 51 min" under an hour,
/// "Resets Thu 12:00 AM" within the week, "Resets Sep 28" beyond it.
enum ResetCopy {
    static func text(for resetsAt: Date, now: Date = Date(), calendar: Calendar = .current,
                     format: ResetTimeFormat = .automatic, locale: Locale = L10n.locale) -> String {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return L10n.t("Resetting…", locale: locale) }

        // Under a minute the sentence counted in minutes, so it read "Resets in
        // 1 min" for anything from one second to fifty-nine of them — the one
        // stretch where the exact figure is the whole point, and the only one
        // where "1 min" could mean four seconds. Both formats get the seconds;
        // the card is redrawn every second while it is open.
        //
        // Rounded like the minutes below, and for the same reason a value that
        // rounds to sixty falls through rather than being clamped: "Resets in
        // 60 sec" never appears, "Resets in 1 min" does.
        let wholeSeconds = Int(seconds.rounded())
        if wholeSeconds < 60 {
            return L10n.t("Resets in \(max(1, wholeSeconds)) sec", locale: locale)
        }

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

        // A weekday only identifies a day inside the coming week. Codex's
        // monthly window resets 26 days out, and "Resets Mon 3:55 PM" read as
        // *this* Monday — six days away rather than nearly four weeks, which is
        // what made the app disagree with Codex's own "Resets Sep 28".
        if daysApart(from: now, to: resetsAt, calendar: calendar) >= 7 {
            // Day and month only, matching how the vendors write it. A time
            // that far out is noise: nobody plans around 3:55 PM in four weeks.
            let stamp = formatter(template: "MMM d", calendar: calendar,
                                  locale: locale).string(from: resetsAt)
            return L10n.t("Resets \(stamp)", locale: locale)
        }

        // `j`, not `h`: a literal hour symbol in a template pins the clock to
        // twelve hours whatever the region, so everywhere that writes 00:00
        // rather than 12:00 AM — most of Europe, Asia and Latin America — read
        // "Resets mer. 12:00 AM" here while every other clock on the Mac said
        // 00:00. `j` asks the locale, which also carries the "24-Hour Time"
        // switch in System Settings. Regions that write AM/PM keep it, so
        // English is still "Thu 12:00 AM".
        let stamp = formatter(template: "E j:mm", calendar: calendar,
                              locale: locale).string(from: resetsAt)
        return L10n.t("Resets \(stamp)", locale: locale)
    }

    /// The time left before a reset, as short as the menu bar needs it: "2h 05m",
    /// "47m", "09s". Nil once the reset has passed — a window that is over has
    /// no time left to show, and never a negative one.
    ///
    /// Truncated where `text` rounds. This one is read against a clock, so it
    /// may never claim more time than there is: "09s" is always at least nine
    /// seconds, and "1h 00m" is gone the moment the hour is.
    static func countdown(to resetsAt: Date, now: Date = Date(),
                          locale: Locale = L10n.locale) -> String? {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        // The last minute counts in seconds. "<1m" was true for fifty-nine of
        // them and said nothing about which — and it is the minute somebody is
        // actually watching the bar for. Truncated, like the minutes below and
        // for the reason in the doc comment: "09s" is always at least nine
        // seconds, never ten. Two digits, so the figure does not change width
        // as it falls.
        if minutes < 1 {
            let padded = String(format: "%02d", Int(seconds))
            return L10n.t("\(padded)s", locale: locale)
        }
        if minutes < 60 { return L10n.t("\(minutes)m", locale: locale) }
        // Two digits, so "2h 05m" is as wide as "2h 50m" and whatever sits
        // beside it in the menu bar does not shuffle as the minutes tick over.
        let padded = String(format: "%02d", minutes % 60)
        return L10n.t("\(minutes / 60)h \(padded)m", locale: locale)
    }

    /// When `countdown` next reads differently — the next whole second of time
    /// left inside the last minute, the next whole minute above it, or the reset
    /// itself. Nil once it has passed.
    ///
    /// The menu bar wakes itself on this and nothing else, so it is the only
    /// thing deciding how often the item is redrawn: once a minute for four
    /// hours and fifty-nine minutes of a five-hour window, then once a second
    /// for the last sixty.
    static func nextCountdownChange(to resetsAt: Date, now: Date = Date()) -> Date? {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let step: TimeInterval = seconds <= 60 ? 1 : 60
        return resetsAt.addingTimeInterval(-(seconds / step).rounded(.down) * step)
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

    /// A formatter for `template`, kept across calls.
    ///
    /// `setLocalizedDateFormatFromTemplate` rebuilds the formatter's ICU state
    /// on every call — milliseconds a throw — and the notch's hover path asks
    /// for the same handful of templates on every mouse event (see
    /// `NotchWindowController.cursorMoved`), so building a fresh formatter
    /// there cost real CPU even at idle. The key carries everything a caller
    /// could otherwise set after the fact, so a cached formatter is never
    /// mutated again. Per-thread because `DateFormatter` is not thread-safe.
    static func formatter(template: String, calendar: Calendar,
                          locale: Locale, timeZone: TimeZone? = nil) -> DateFormatter {
        let zone = timeZone ?? calendar.timeZone
        let key = [template, "\(calendar.identifier)", zone.identifier,
                   locale.identifier].joined(separator: "\n")
        let caches = Thread.current.threadDictionary
        if let hit = caches[key] as? DateFormatter { return hit }
        let formatter = formatter(for: calendar)
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(template)
        caches[key] = formatter
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
