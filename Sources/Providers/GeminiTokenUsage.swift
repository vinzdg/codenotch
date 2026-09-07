import Foundation

/// Tokens billed against a bare `GEMINI_API_KEY`, counted from the logs the
/// tools keep for themselves.
///
/// Google publishes no usage endpoint for an API key, so the only number that
/// exists is the one each tool wrote down after its own call. Three tools keep
/// such a log — Gemini CLI, OpenCode and Hermes — and each of them stamps its
/// records in UTC. The bill and the user's day are local, though, so every
/// reader hands its entries to `bucket` rather than doing the arithmetic
/// itself: one routine is the only way the three rows in the tooltip can agree
/// on where "today" and "this month" start.
struct GeminiTokenUsage: Equatable {
    var tokensThisMonth = 0
    var tokensToday = 0
    var callsThisMonth = 0

    static let zero = GeminiTokenUsage()

    func adding(_ other: GeminiTokenUsage) -> GeminiTokenUsage {
        GeminiTokenUsage(
            tokensThisMonth: tokensThisMonth + other.tokensThisMonth,
            tokensToday: tokensToday + other.tokensToday,
            callsThisMonth: callsThisMonth + other.callsThisMonth
        )
    }

    /// Local, deliberately. `Calendar.current` would follow the user's chosen
    /// calendar identifier as well as their zone, and a non-Gregorian month is
    /// not the month Google bills.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// Local midnight on the first of `now`'s month. Readers use it to throw
    /// away files and rows that cannot contribute before parsing them.
    static func startOfMonth(now: Date, calendar: Calendar = GeminiTokenUsage.calendar) -> Date {
        calendar.dateInterval(of: .month, for: now)!.start
    }

    /// The one place a timestamp turns into a window.
    ///
    /// A call with no tokens is a call that was aborted before the model
    /// answered — OpenCode writes those rows with every counter at zero. It
    /// costs nothing, so it is not a call either.
    static func bucket(
        _ entries: [(at: Date, tokens: Int, calls: Int)],
        now: Date,
        calendar: Calendar = GeminiTokenUsage.calendar
    ) -> GeminiTokenUsage {
        var usage = GeminiTokenUsage.zero
        for entry in entries where entry.tokens > 0 {
            guard calendar.isDate(entry.at, equalTo: now, toGranularity: .month) else { continue }
            usage.tokensThisMonth += entry.tokens
            usage.callsThisMonth += entry.calls
            if calendar.isDate(entry.at, inSameDayAs: now) { usage.tokensToday += entry.tokens }
        }
        return usage
    }
}

/// One tool's contribution, kept separate so the tooltip can say which log a
/// number came from instead of presenting one unattributable total.
struct GeminiTokenSource: Equatable {
    let id: String
    let name: String
    let usage: GeminiTokenUsage
}
