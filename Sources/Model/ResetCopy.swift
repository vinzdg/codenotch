import Foundation

/// "Resets in 51 min" under an hour, "Resets Thu 12:00 AM" within the week,
/// "Resets Sep 28" beyond it.
enum ResetCopy {
    static func text(for resetsAt: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Resetting…" }

        // Rounding, not truncation, so 50m40s reads as 51 rather than 50. A
        // value that rounds up to 60 falls through to the absolute form, so
        // "Resets in 60 min" never appears.
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return "Resets in \(max(1, minutes)) min"
        }

        let formatter = formatter(for: calendar)

        // A weekday only identifies a day inside the coming week. Codex's
        // monthly window resets 26 days out, and "Resets Mon 3:55 PM" read as
        // *this* Monday — six days away rather than nearly four weeks, which is
        // what made the app disagree with Codex's own "Resets Sep 28".
        if daysApart(from: now, to: resetsAt, calendar: calendar) >= 7 {
            // Day and month only, matching how the vendors write it. A time
            // that far out is noise: nobody plans around 3:55 PM in four weeks.
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            return "Resets \(formatter.string(from: resetsAt))"
        }

        // A literal pattern rather than a localised template: the weekday and
        // AM/PM still come from the locale, but the separator stays a colon.
        // The template form yields "4.50 PM" in some regions, and both the
        // design frame and Claude's own usage panel write "4:50 PM".
        formatter.dateFormat = "E h:mm a"
        return "Resets \(formatter.string(from: resetsAt))"
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
        formatter.locale = calendar.locale ?? .current
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
