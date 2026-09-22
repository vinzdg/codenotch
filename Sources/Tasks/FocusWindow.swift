import SwiftUI
import AppKit

enum TaskColors {
    static let violet = Color(red: 0x9b/255, green: 0x7c/255, blue: 1.0)
    static let green = Color(red: 0x2f/255, green: 0xd4/255, blue: 0x87/255)
    static let orange = Color(red: 1.0, green: 0x62/255, blue: 0x2e/255)
    static let yellow = Color(red: 0xf2/255, green: 0xdf/255, blue: 0x2a/255)
}

/// Focus time by day, week or month, filtered by project, with the blocks
/// editable in place (name, project, start, end), plus add and delete.
struct FocusPane: View {
    @ObservedObject var focus: FocusStore = .shared
    @ObservedObject var todos: TodoStore = .shared

    /// "45 min", "2 h", "2 h 10 min".
    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 60 { return L10n.t("\(m) min") }
        return m % 60 == 0 ? L10n.t("\(m / 60) h") : L10n.t("\(m / 60) h \(m % 60) min")
    }

    static func dayTitle(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = L10n.locale; f.dateFormat = "EEE d MMM"
        return f.string(from: d).capitalized
    }

    enum Period: String, CaseIterable, Identifiable {
        case day, week, month
        var id: String { rawValue }
        var title: String {
            switch self { case .day: return L10n.t("Day"); case .week: return L10n.t("Week"); case .month: return L10n.t("Month") }
        }
    }
    @State private var period: Period = .week
    @State private var anchor: Date = Calendar.current.startOfDay(for: Date())
    @State private var project: String = ""
    @State private var adding = false

    private var cal: Calendar { Calendar.current }
    private var interval: DateInterval {
        switch period {
        case .day: return DateInterval(start: anchor, duration: 86_400)
        case .week: return cal.dateInterval(of: .weekOfYear, for: anchor)!
        case .month: return cal.dateInterval(of: .month, for: anchor)!
        }
    }
    private var blocks: [FocusStore.Block] { focus.blocks(in: interval, project: project.isEmpty ? nil : project) }
    private var total: TimeInterval { blocks.map(\.seconds).reduce(0, +) }
    private var projectOptions: [(String, String)] {
        let known = Set(focus.projects + todos.lists)
        return [("", L10n.t("All projects"))] + known.sorted().map { ($0, $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                stats
                if period != .day { chart }
                list
            }
            .padding(.leading, 56).padding(.trailing, 48).padding(.top, 30).padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Focus")).font(.system(size: 20, weight: .semibold))
                    Text(rangeTitle).font(.system(size: 13)).foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Button(L10n.t("Today")) { anchor = cal.startOfDay(for: Date()) }.disabled(isCurrent)
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }.disabled(isCurrent)
                    Button { focus.reload(); todos.refresh() } label: { Image(systemName: "arrow.clockwise") }
                }
                .controlSize(.small)
            }
            HStack(spacing: 12) {
                Picker("", selection: $period) { ForEach(Period.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Picker("", selection: $project) { ForEach(projectOptions, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 220)
                Spacer()
                Button { adding.toggle() } label: { Label(L10n.t("Add block"), systemImage: "plus") }.controlSize(.small)
            }
        }
    }

    private var isCurrent: Bool { interval.contains(Date()) }
    private var rangeTitle: String {
        let f = DateFormatter()
        f.locale = L10n.locale
        switch period {
        case .day: f.dateStyle = .full; return f.string(from: anchor).capitalized
        case .week:
            f.dateFormat = "d MMM"
            let end = interval.end.addingTimeInterval(-1)
            return "\(f.string(from: interval.start)) – \(f.string(from: end))"
        case .month: f.dateFormat = "LLLL yyyy"; return f.string(from: anchor).capitalized
        }
    }
    private func shift(_ n: Int) {
        let comp: Calendar.Component = period == .day ? .day : (period == .week ? .weekOfYear : .month)
        anchor = cal.date(byAdding: comp, value: n, to: anchor) ?? anchor
    }

    private var stats: some View {
        HStack(spacing: 28) {
            stat(L10n.t("Focus time"), FocusPane.duration(total))
            stat(L10n.t("Blocks"), "\(blocks.count)")
            if period != .day {
                let days = max(1, Set(blocks.map { cal.startOfDay(for: $0.start) }).count)
                stat(L10n.t("Per active day"), FocusPane.duration(total / Double(days)))
            }
            if focus.isActive {
                stat(L10n.t("In focus"), FocusStore.clock(focus.elapsed))
            }
            Spacer()
        }
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    // MARK: Chart (one bar per day)

    private var days: [Date] {
        var out: [Date] = []
        var d = interval.start
        while d < interval.end { out.append(d); d = cal.date(byAdding: .day, value: 1, to: d)! }
        return out
    }

    @State private var hoveredDay: Date?

    private var chart: some View {
        let perDay = Dictionary(grouping: blocks, by: { cal.startOfDay(for: $0.start) }).mapValues { $0.map(\.seconds).reduce(0, +) }
        let maxV = max(perDay.values.max() ?? 1, 1)
        let f = DateFormatter(); f.dateFormat = period == .week ? "EEE" : "d"
        f.locale = L10n.locale
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: period == .week ? 14 : 4) {
                ForEach(days, id: \.self) { d in
                    let v = perDay[d] ?? 0
                    VStack(spacing: 4) {
                        Text(period == .week && v > 0 ? FocusPane.duration(v) : " ")
                            .font(.system(size: 9)).foregroundColor(.secondary).monospacedDigit().lineLimit(1)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(cal.isDateInToday(d) || hoveredDay == d ? TaskColors.violet : TaskColors.violet.opacity(0.55))
                            .frame(height: max(3, 120 * CGFloat(v / maxV)))
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onHover { hoveredDay = $0 ? d : (hoveredDay == d ? nil : hoveredDay) }
                        Text(f.string(from: d).capitalized)
                            .font(.system(size: 10, weight: cal.isDateInToday(d) ? .semibold : .regular))
                            .foregroundColor(cal.isDateInToday(d) ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 160)
            HStack {
                if let d = hoveredDay {
                    Text("\(FocusPane.dayTitle(d)) · \(FocusPane.duration(perDay[d] ?? 0))")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                } else {
                    Text(L10n.t("Focus per day; hover a bar for its total")).font(.system(size: 10.5)).foregroundColor(.secondary)
                }
                Spacer()
                Text("\(L10n.t("Total")) \(FocusPane.duration(perDay.values.reduce(0, +)))")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    // MARK: Blocks

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Blocks")).font(.system(size: 13, weight: .semibold)).padding(.leading, 2)
            VStack(spacing: 0) {
                if adding {
                    NewBlockRow(defaultDay: period == .day ? anchor : cal.startOfDay(for: Date()),
                                project: project, options: projectOptions) { adding = false }
                    Divider().padding(.leading, 12)
                }
                if blocks.isEmpty && !adding {
                    Text(L10n.t("No focus blocks in this range"))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                } else {
                    let grouped = Dictionary(grouping: blocks, by: { cal.startOfDay(for: $0.start) }).sorted { $0.key > $1.key }
                    ForEach(grouped, id: \.key) { day, items in
                        if period != .day {
                            Text(dayLabel(day)).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                        }
                        ForEach(items) { b in
                            BlockRow(block: b, options: projectOptions)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.08)))
            Text(L10n.t("Times are editable: click a value, change it and press Return. The running block is shown live and cannot be edited until it stops."))
                .font(.system(size: 11)).foregroundColor(.secondary).padding(.horizontal, 2)
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .none
        f.locale = L10n.locale
        return f.string(from: d).capitalized
    }
}

/// One editable block: name, project, start and end (HH:mm), duration, delete.
struct BlockRow: View {
    let block: FocusStore.Block
    let options: [(String, String)]
    @ObservedObject var focus: FocusStore = .shared
    @State private var name = ""
    @State private var start = ""
    @State private var end = ""

    private var live: Bool { block.id == "active" }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(TaskColors.violet).frame(width: 3, height: 26)
            TextField("", text: $name, prompt: Text(L10n.t("Name")))
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .disabled(live)
                .onSubmit { var b = block; b.name = name; focus.update(b) }
                .frame(minWidth: 160)
            Picker("", selection: Binding(get: { block.project ?? "" }, set: { var b = block; b.project = $0.isEmpty ? nil : $0; focus.update(b) })) {
                ForEach([("", L10n.t("No project"))] + options.dropFirst(), id: \.0) { Text($0.1).tag($0.0) }
            }.labelsHidden().frame(width: 170).disabled(live)
            TimeField(text: $start, disabled: live) { commit() }
            Text("–").foregroundColor(.secondary)
            TimeField(text: $end, disabled: live) { commit() }
            Text(FocusPane.duration(block.seconds))
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Button { focus.delete(block.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundColor(.secondary).disabled(live).help(L10n.t("Delete block"))
                .frame(width: 24)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .onAppear(perform: load)
        .onChange(of: block) { _ in load() }
    }

    private func load() {
        name = block.name
        start = Self.hm(block.start)
        end = Self.hm(block.end)
    }

    private func commit() {
        var b = block
        if let s = Self.date(hm: start, on: block.start) { b.start = s }
        if let e = Self.date(hm: end, on: block.end) { b.end = e }
        if b.end <= b.start { load(); return }
        focus.update(b)
    }

    static func hm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
    static func date(hm: String, on day: Date) -> Date? {
        let parts = hm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }
}

struct TimeField: View {
    @Binding var text: String
    var disabled = false
    var onCommit: () -> Void
    var body: some View {
        TextField("", text: $text, prompt: Text("HH:mm"))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .multilineTextAlignment(.center)
            .frame(width: 62)
            .disabled(disabled)
            .onSubmit(onCommit)
    }
}

/// Inline form for a manual block.
struct NewBlockRow: View {
    var defaultDay: Date
    var project: String
    let options: [(String, String)]
    var onDone: () -> Void
    @ObservedObject var focus: FocusStore = .shared
    @State private var name = ""
    @State private var proj = ""
    @State private var day = Date()
    @State private var start = ""
    @State private var end = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle").foregroundColor(.secondary)
            TextField("", text: $name, prompt: Text(L10n.t("What did you focus on?")))
                .textFieldStyle(.roundedBorder).font(.system(size: 12.5)).frame(minWidth: 160)
            Picker("", selection: $proj) { ForEach([("", L10n.t("No project"))] + options.dropFirst(), id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 170)
            DatePicker("", selection: $day, displayedComponents: .date).labelsHidden().datePickerStyle(.field).frame(width: 110)
            TimeField(text: $start) { }
            Text("–").foregroundColor(.secondary)
            TimeField(text: $end) { }
            Spacer()
            Button(L10n.t("Cancel")) { onDone() }.controlSize(.small)
            Button(L10n.t("Add")) { add() }.controlSize(.small).buttonStyle(.borderedProminent).disabled(!valid)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onAppear { day = defaultDay; proj = project; let now = Date(); end = BlockRow.hm(now); start = BlockRow.hm(now.addingTimeInterval(-1500)) }
    }

    private var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let s = BlockRow.date(hm: start, on: day), let e = BlockRow.date(hm: end, on: day) else { return false }
        return e > s
    }

    private func add() {
        guard let s = BlockRow.date(hm: start, on: day), let e = BlockRow.date(hm: end, on: day) else { return }
        focus.add(name: name.trimmingCharacters(in: .whitespaces), project: proj.isEmpty ? nil : proj, start: s, end: e)
        onDone()
    }
}
