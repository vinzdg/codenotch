import SwiftUI

/// Settings for the locally maintained DeepSeek billing schedule.
///
/// DeepSeek publishes the rule in UTC, so the editor intentionally says UTC
/// rather than silently converting the stored values to the Mac's timezone.
struct DeepSeekPricingSettingsView: View {
    @ObservedObject var preferences: Preferences

    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    private var schedule: DeepSeekPricing.Schedule {
        preferences.deepSeekPricingSchedule.normalized
    }

    var body: some View {
        Form {
            Section(L10n.t("Peak/off-peak pricing")) {
                Toggle(L10n.t("Show DeepSeek pricing"),
                       isOn: $preferences.deepSeekPricingEnabled)

                Text(L10n.t("Shows the current billing phase and the next peak/off-peak change on the DeepSeek usage card."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.t("Peak rule")) {
                Text(L10n.t("The schedule is maintained locally because it cannot be read reliably from an official API. Times below are UTC; the card converts the next change to your local time."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("Peak days"))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                              alignment: .leading, spacing: 6) {
                        ForEach(Self.weekdayOrder, id: \.self) { weekday in
                            Toggle(weekdayTitle(weekday), isOn: weekdayBinding(weekday))
                                .toggleStyle(.checkbox)
                        }
                    }
                }

                ForEach(schedule.windows.indices, id: \.self) { index in
                    PeakWindowRow(
                        title: String(format: L10n.t("Window %lld"), index + 1),
                        start: timeBinding(window: index, start: true),
                        end: timeBinding(window: index, start: false),
                        canRemove: schedule.windows.count > 1,
                        onRemove: { removeWindow(at: index) }
                    )
                }

                Button {
                    addWindow()
                } label: {
                    Label(L10n.t("Add peak window"), systemImage: "plus")
                }
            }
            .disabled(!preferences.deepSeekPricingEnabled)

            Section {
                Button(L10n.t("Restore current default rule")) {
                    preferences.resetDeepSeekPricingSchedule()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func weekdayTitle(_ weekday: Int) -> String {
        switch weekday {
        case 1: return L10n.t("Sun")
        case 2: return L10n.t("Mon")
        case 3: return L10n.t("Tue")
        case 4: return L10n.t("Wed")
        case 5: return L10n.t("Thu")
        case 6: return L10n.t("Fri")
        default: return L10n.t("Sat")
        }
    }

    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { schedule.peakWeekdays.contains(weekday) },
            set: { enabled in
                var next = schedule
                if enabled {
                    next.peakWeekdays.insert(weekday)
                } else {
                    next.peakWeekdays.remove(weekday)
                }
                preferences.deepSeekPricingSchedule = next
            }
        )
    }

    private func timeBinding(window index: Int, start: Bool) -> Binding<Int> {
        Binding(
            get: {
                let window = schedule.windows.indices.contains(index)
                    ? schedule.windows[index]
                    : .init(startMinute: 0, endMinute: 30)
                return start ? window.startMinute : window.endMinute
            },
            set: { value in
                var next = schedule
                guard next.windows.indices.contains(index) else { return }
                var window = next.windows[index]
                if start {
                    window.startMinute = min(max(value, 0), max(0, window.endMinute - 1))
                } else {
                    window.endMinute = max(min(value, 1_440), min(1_440, window.startMinute + 1))
                }
                next.windows[index] = window
                preferences.deepSeekPricingSchedule = next
            }
        )
    }

    private func addWindow() {
        var next = schedule
        let duration = 60
        let sortedWindows = next.windows.sorted { $0.startMinute < $1.startMinute }
        var candidateStart = 0

        for window in sortedWindows {
            if window.startMinute - candidateStart >= duration { break }
            candidateStart = max(candidateStart, window.endMinute)
        }

        if candidateStart + duration > 1_440 {
            candidateStart = 1_440 - duration
        }
        next.windows.append(.init(startMinute: candidateStart,
                                  endMinute: candidateStart + duration))
        preferences.deepSeekPricingSchedule = next
    }

    private func removeWindow(at index: Int) {
        guard schedule.windows.count > 1,
              schedule.windows.indices.contains(index) else { return }
        var next = schedule
        next.windows.remove(at: index)
        preferences.deepSeekPricingSchedule = next
    }
}

private struct PeakWindowRow: View {
    let title: String
    @Binding var start: Int
    @Binding var end: Int
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            PeakTimePicker(label: L10n.t("Start"), minuteOfDay: $start)
            Text(L10n.t("to"))
                .foregroundStyle(.secondary)
            PeakTimePicker(label: L10n.t("End"), minuteOfDay: $end)
            if canRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.t("Remove peak window"))
            }
        }
    }
}

private struct PeakTimePicker: View {
    let label: String
    @Binding var minuteOfDay: Int

    var body: some View {
        HStack(spacing: 6) {
            DatePicker(label, selection: dateBinding, displayedComponents: [.hourAndMinute])
                .datePickerStyle(.stepperField)
                .labelsHidden()
                .environment(\.timeZone, Self.utcTimeZone)
        }
    }

    private static let utcTimeZone = TimeZone(secondsFromGMT: 0)!

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone
        return calendar
    }

    private static let anchorDate = Date(timeIntervalSince1970: 0)

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                let minute = min(max(minuteOfDay, 0), 1_440)
                if minute == 1_440 {
                    return Self.utcCalendar.date(byAdding: .day, value: 1,
                                                 to: Self.anchorDate) ?? Self.anchorDate
                }
                return Self.utcCalendar.date(bySettingHour: minute / 60,
                                             minute: minute % 60,
                                             second: 0,
                                             of: Self.anchorDate) ?? Self.anchorDate
            },
            set: { date in
                let components = Self.utcCalendar.dateComponents([.hour, .minute], from: date)
                minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }
}
