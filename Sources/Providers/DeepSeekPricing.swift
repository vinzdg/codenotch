import Foundation

/// The currently published DeepSeek API peak/off-peak schedule.
///
/// DeepSeek publishes the schedule in UTC, so it is intentionally independent
/// of the Mac's local time zone. The UI can then show the user's local clock
/// while this type remains the single source of truth for the billing phase.
enum DeepSeekPricing {
    struct Schedule: Codable, Equatable {
        struct Window: Codable, Equatable {
            var startMinute: Int
            var endMinute: Int
        }

        /// Gregorian weekdays use Sunday = 1 ... Saturday = 7, matching
        /// Foundation's `Calendar.Component.weekday` values.
        var peakWeekdays: Set<Int>
        var windows: [Window]

        /// The currently published rule. This is the first-launch value and
        /// also the target of the reset button in Settings.
        static let current = Schedule(
            peakWeekdays: [2, 3, 4, 5, 6],
            windows: [
                Window(startMinute: 60, endMinute: 240),
                Window(startMinute: 360, endMinute: 600)
            ]
        )

        /// Keep values loaded from UserDefaults safe even if a future build
        /// changes the editor or an older build wrote malformed data. The
        /// number of windows is intentionally unbounded: DeepSeek may publish
        /// more than the two windows in today's default rule.
        var normalized: Schedule {
            let weekdays = peakWeekdays.filter { (1...7).contains($0) }
            var validWindows = windows.compactMap { window -> Window? in
                let startMinute = min(max(window.startMinute, 0), 1_440)
                let endMinute = min(max(window.endMinute, 0), 1_440)
                guard startMinute < endMinute else { return nil }
                return Window(startMinute: startMinute, endMinute: endMinute)
            }
            if validWindows.isEmpty {
                validWindows = [Self.current.windows[0]]
            }
            return Schedule(peakWeekdays: weekdays,
                            windows: validWindows)
        }
    }

    enum Phase: Equatable {
        case peak
        case offPeak
    }

    struct Transition: Equatable {
        let phase: Phase
        let date: Date
    }

    static func phase(at date: Date) -> Phase {
        phase(at: date, schedule: .current)
    }

    static func phase(at date: Date, schedule: Schedule) -> Phase {
        let calendar = utcCalendar

        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute,
              schedule.peakWeekdays.contains(weekday) else {
            return .offPeak
        }

        let minuteOfDay = hour * 60 + minute
        return schedule.windows.contains {
            $0.startMinute <= minuteOfDay && minuteOfDay < $0.endMinute
        } ? .peak : .offPeak
    }

    static func nextTransition(after date: Date) -> Transition {
        nextTransition(after: date, schedule: .current)
    }

    static func nextTransition(after date: Date, schedule: Schedule) -> Transition {
        let calendar = utcCalendar
        let start = calendar.startOfDay(for: date)

        let boundaries = Set(schedule.windows.flatMap { [$0.startMinute, $0.endMinute] })
        // Looking ahead eight days covers the Friday-to-Monday gap as well.
        for dayOffset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: start) else {
                continue
            }
            for minuteOfDay in boundaries.sorted() {
                guard let candidate = calendar.date(byAdding: .minute,
                                                    value: minuteOfDay,
                                                    to: day),
                      candidate > date else { continue }
                let nextPhase = phase(at: candidate, schedule: schedule)
                guard nextPhase != phase(at: candidate.addingTimeInterval(-1),
                                         schedule: schedule) else {
                    continue
                }
                return Transition(phase: nextPhase, date: candidate)
            }
        }

        // The loop always finds a transition, but keep a deterministic result
        // if Foundation ever behaves unexpectedly around a calendar boundary.
        return Transition(phase: .offPeak, date: date.addingTimeInterval(8 * 86_400))
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
