import SwiftUI
import AppKit
import Combine

/// One day of work: which sessions ran, in which project (client), for how long,
/// and what they cost. A lane chart over the hours of the day, then the detail.
enum ActivityPeriod: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var title: String {
        switch self { case .day: return L10n.t("Day"); case .week: return L10n.t("Week"); case .month: return L10n.t("Month") }
    }
}

struct TimelinePane: View {
    @ObservedObject var accounts: CostAccountStore = .shared
    @ObservedObject var prices: PriceTable = .shared
    @State private var day: Date = Calendar.current.startOfDay(for: Date())
    @State private var rows: [Row] = []
    @State private var loading = false
    @State private var hovered: String?
    @State private var period: ActivityPeriod = .day
    @State private var accountFilter = ""          // account id, "" = all

    private var cal: Calendar { Calendar.current }
    private var interval: DateInterval {
        switch period {
        case .day: return DateInterval(start: day, duration: 86_400)
        case .week: return cal.dateInterval(of: .weekOfYear, for: day)!
        case .month: return cal.dateInterval(of: .month, for: day)!
        }
    }
    private var filtered: [Row] { accountFilter.isEmpty ? rows : rows.filter { $0.accountID == accountFilter } }

    struct Row: Identifiable {
        var id: String { account + sessionID }
        var sessionID: String
        var account: String
        var accountID: String = ""
        var accountIndex: Int
        var project: String
        var cwd: String
        var model: String
        var first: Date
        var last: Date
        var turns: Int
        var tokens: Int
        var cost: Double?
        var title: String?
        var duration: TimeInterval { max(120, last.timeIntervalSince(first)) }
    }

    struct Group: Identifiable {
        var id: String { project }
        var project: String
        var rows: [Row]
        var cost: Double
        var time: TimeInterval
        var name: String { ProjectCost(project: project, pct: 0).displayName }
    }

    private var isToday: Bool { interval.contains(Date()) }
    private var groups: [Group] {
        Dictionary(grouping: filtered, by: \.project).map { key, list in
            Group(project: key, rows: list.sorted { $0.first < $1.first },
                  cost: list.compactMap(\.cost).reduce(0, +), time: list.map(\.duration).reduce(0, +))
        }.sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.time > $1.time }
    }
    private var totalCost: Double { filtered.compactMap(\.cost).reduce(0, +) }
    private var totalTime: TimeInterval { filtered.map(\.duration).reduce(0, +) }
    private var totalTurns: Int { filtered.map(\.turns).reduce(0, +) }

    /// Account colours: the first account keeps Claude's orange, the rest get
    /// distinct hues so lanes read at a glance.
    static let accountColors: [Color] = [
        Color(red: 0.85, green: 0.47, blue: 0.34),
        Color(red: 0x2a/255, green: 0x9d/255, blue: 0x8f/255),
        Color(red: 0x7c/255, green: 0x6f/255, blue: 0xe0/255),
        Color(red: 0x2f/255, green: 0x80/255, blue: 0xed/255),
        Color(red: 0xd9/255, green: 0x53/255, blue: 0x8a/255),
    ]
    private func color(_ r: Row) -> Color { Self.accountColors[r.accountIndex % Self.accountColors.count] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if filtered.isEmpty {
                    empty
                } else {
                    if period == .day { lanes } else { dayBars }
                    ForEach(groups) { g in projectBlock(g) }
                }
            }
            .padding(.leading, 56).padding(.trailing, 48).padding(.top, 30).padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: load)
        .onChange(of: day) { _ in load() }
        .onChange(of: period) { _ in load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Activity")).font(.system(size: 20, weight: .semibold))
                    Text(dayTitle).font(.system(size: 13)).foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Button(L10n.t("Today")) { day = Calendar.current.startOfDay(for: Date()) }.disabled(isToday)
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }.disabled(isToday)
                    Button { load() } label: { Image(systemName: "arrow.clockwise") }
                }
                .controlSize(.small)
            }
            HStack(spacing: 12) {
                Picker("", selection: $period) { ForEach(ActivityPeriod.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Picker("", selection: $accountFilter) {
                    Text(L10n.t("All accounts")).tag("")
                    ForEach(accounts.accounts) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(width: 220)
                Spacer()
            }
            HStack(spacing: 28) {
                stat(L10n.t("Sessions"), "\(filtered.count)")
                stat(L10n.t("Active time"), Self.duration(totalTime))
                stat(L10n.t("Turns"), "\(totalTurns)")
                stat(L10n.t("Estimated cost"), MoneyFormat.string(totalCost, currency: prices.currency))
                Spacer()
                if accounts.accounts.count > 1 {
                    HStack(spacing: 10) {
                        ForEach(Array(accounts.accounts.enumerated()), id: \.element.id) { i, a in
                            HStack(spacing: 4) {
                                Circle().fill(Self.accountColors[i % Self.accountColors.count]).frame(width: 7, height: 7)
                                Text(a.name).font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loading ? L10n.t("Loading…") : L10n.t("No sessions on this day")).font(.system(size: 13, weight: .medium))
            if !loading {
                Text(L10n.t("Turns are read from the transcripts each account writes; the first ones show up a few minutes after a session starts."))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Lane chart

    private var hourRange: (from: Int, to: Int) {
        let cal = Calendar.current
        let firsts = filtered.map { cal.component(.hour, from: $0.first) }
        let lasts = filtered.map { cal.component(.hour, from: $0.last) }
        let from = max(0, (firsts.min() ?? 8) - 1)
        let to = min(24, (lasts.max() ?? 18) + 2)
        return (from, max(to, from + 4))
    }

    private var lanes: some View {
        let range = hourRange
        let hours = Array(range.from...range.to)
        return VStack(alignment: .leading, spacing: 0) {
            // Hour axis.
            GeometryReader { geo in
                let w = geo.size.width - 150
                ZStack(alignment: .topLeading) {
                    ForEach(hours, id: \.self) { h in
                        let x = 150 + w * CGFloat(h - range.from) / CGFloat(range.to - range.from)
                        Text(String(format: "%02d", h))
                            .font(.system(size: 10)).monospacedDigit().foregroundColor(.secondary)
                            .position(x: x, y: 8)
                    }
                }
            }
            .frame(height: 18)
            ForEach(groups) { g in
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(Self.duration(g.time)).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .frame(width: 140, alignment: .leading)
                    .padding(.trailing, 10)
                    GeometryReader { geo in
                        let w = geo.size.width
                        ZStack(alignment: .leading) {
                            // Hour grid.
                            ForEach(hours, id: \.self) { h in
                                let x = w * CGFloat(h - range.from) / CGFloat(range.to - range.from)
                                Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1).offset(x: x)
                            }
                            ForEach(g.rows) { r in
                                let x0 = w * fraction(r.first, range)
                                let x1 = w * fraction(r.last, range)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(color(r).opacity(hovered == nil || hovered == r.id ? 0.9 : 0.35))
                                    .frame(width: max(4, x1 - x0), height: 14)
                                    .offset(x: x0)
                                    .help("\(r.title ?? r.sessionID) · \(Self.time(r.first))–\(Self.time(r.last))")
                                    .onHover { hovered = $0 ? r.id : nil }
                            }
                        }
                    }
                    .frame(height: 22)
                }
                .padding(.vertical, 5)
                Divider()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private func fraction(_ d: Date, _ range: (from: Int, to: Int)) -> CGFloat {
        let secs = d.timeIntervalSince(day)
        let f = (secs / 3600 - Double(range.from)) / Double(range.to - range.from)
        return CGFloat(min(max(f, 0), 1))
    }

    // MARK: Detail

    private func projectBlock(_ g: Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(g.name).font(.system(size: 13, weight: .semibold))
                Text(Self.duration(g.time)).font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                Text(MoneyFormat.string(g.cost, currency: prices.currency))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(Array(g.rows.enumerated()), id: \.element.id) { i, r in
                    sessionRow(r)
                    if i < g.rows.count - 1 { Divider().padding(.leading, 12) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.08)))
        }
    }

    private func sessionRow(_ r: Row) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(color(r)).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.time(r.first)) – \(Self.time(r.last))")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text(Self.duration(r.duration)).font(.system(size: 10.5)).foregroundColor(.secondary)
            }
            .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title ?? String(r.sessionID.prefix(8))).font(.system(size: 12)).lineLimit(1)
                HStack(spacing: 6) {
                    if accounts.accounts.count > 1 {
                        Text(r.account).font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(color(r).opacity(0.15)))
                    }
                    Text(Self.shortModel(r.model)).font(.system(size: 10.5)).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text(L10n.t("\(r.turns) turns")).font(.system(size: 10.5)).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text(MoneyFormat.tokens(r.tokens) + " tok").font(.system(size: 10.5)).foregroundColor(.secondary)
                }
            }
            Spacer()
            Text(r.cost.map { MoneyFormat.string($0, currency: prices.currency) } ?? "—")
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovered == r.id ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovered = $0 ? r.id : nil }
    }

    // MARK: Data

    private func shift(_ n: Int) {
        let comp: Calendar.Component = period == .day ? .day : (period == .week ? .weekOfYear : .month)
        day = cal.date(byAdding: comp, value: n, to: day) ?? day
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.locale = L10n.locale
        switch period {
        case .day: f.dateStyle = .full; f.timeStyle = .none; return f.string(from: day).capitalized
        case .week:
            f.dateFormat = "d MMM"
            return "\(f.string(from: interval.start)) – \(f.string(from: interval.end.addingTimeInterval(-1)))"
        case .month: f.dateFormat = "LLLL yyyy"; return f.string(from: day).capitalized
        }
    }

    // MARK: Bars per day (week / month)

    @State private var hoveredDay: Date?

    static func dayTitle(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = L10n.locale; f.dateFormat = "EEE d MMM"
        return f.string(from: d).capitalized
    }

    private var dayBars: some View {
        var d = interval.start
        var days: [Date] = []
        while d < interval.end { days.append(d); d = cal.date(byAdding: .day, value: 1, to: d)! }
        let perDay = Dictionary(grouping: filtered, by: { cal.startOfDay(for: $0.first) })
        let cost = perDay.mapValues { $0.compactMap(\.cost).reduce(0, +) }
        let time = perDay.mapValues { $0.map(\.duration).reduce(0, +) }
        let maxV = max(cost.values.max() ?? 0, 0.01)
        let f = DateFormatter(); f.dateFormat = period == .week ? "EEE" : "d"
        f.locale = L10n.locale
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: period == .week ? 14 : 4) {
                ForEach(days, id: \.self) { dd in
                    let c = cost[dd] ?? 0
                    VStack(spacing: 4) {
                        // A month of bars has no room for a label each: the
                        // hovered bar reads out in the caption instead.
                        Text(period == .week && c > 0 ? MoneyFormat.string(c, currency: prices.currency) : " ")
                            .font(.system(size: 9)).foregroundColor(.secondary).monospacedDigit().lineLimit(1)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(cal.isDateInToday(dd) || hoveredDay == dd ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.55))
                            .frame(height: max(3, 120 * CGFloat(c / maxV)))
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onHover { hoveredDay = $0 ? dd : (hoveredDay == dd ? nil : hoveredDay) }
                        Text(f.string(from: dd).capitalized)
                            .font(.system(size: 10, weight: cal.isDateInToday(dd) ? .semibold : .regular))
                            .foregroundColor(cal.isDateInToday(dd) ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 160)
            HStack {
                if let dd = hoveredDay {
                    Text("\(Self.dayTitle(dd)) · \(MoneyFormat.string(cost[dd] ?? 0, currency: prices.currency)) · \(Self.duration(time[dd] ?? 0))")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                } else {
                    Text(L10n.t("Estimated cost per day; hover a bar for active time")).font(.system(size: 10.5)).foregroundColor(.secondary)
                }
                Spacer()
                Text("\(L10n.t("Total")) \(MoneyFormat.string(cost.values.reduce(0, +), currency: prices.currency)) · \(Self.duration(time.values.reduce(0, +)))")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private func load() {
        loading = true
        let from = Int(interval.start.timeIntervalSince1970)
        let to = Int(interval.end.timeIntervalSince1970) - 1
        let pricer = prices.pricer
        let allAccounts = accounts.accounts
        let models = CostModels.all.compactMap { m -> (CostAccount, Double, Double?, Int, CostStore)? in
            guard let s = m.store_, let idx = allAccounts.firstIndex(where: { $0.id == m.account.id }) else { return nil }
            let creditPoint: Double? = (m.creditBacked && m.account.creditLimit != nil)
                ? m.account.creditLocal(rate: pricer.rate).map { $0 * m.account.creditLimit! / 100 } : nil
            return (m.account, m.account.monthlyLocal(rate: pricer.rate), creditPoint, idx, s)
        }
        let now = Int(Date().timeIntervalSince1970)
        Task.detached(priority: .userInitiated) {
            var out: [Row] = []
            for (account, monthly, creditPoint, idx, store) in models {
                let window: CostWindow = creditPoint != nil ? .credits : .weekly
                let periods = store.periods(window: window).map { p in
                    (start: p.start, end: p.end, usedPct: p.usedPct, weight: store.totalWeight(from: p.start, to: min(p.end, now)))
                }
                let est = CostEstimator(billing: account.billing, monthlyPrice: monthly, creditPointValue: creditPoint, periods: periods,
                                        monthWeight: store.totalWeight(from: CostEstimator.monthStart(), to: now), pricer: pricer)
                for a in store.sessions(from: from, to: to) {
                    let w = CostEstimator.weight(input: a.input, output: a.output, cacheRead: a.cacheRead, cacheWrite: a.cacheWrite)
                    let cost = est.cost(at: a.first, weight: w, model: a.model, input: a.input, output: a.output,
                                        cacheRead: a.cacheRead, cacheWrite: a.cacheWrite)
                    out.append(Row(sessionID: a.sessionID, account: account.name, accountID: account.id, accountIndex: idx, project: a.project, cwd: a.cwd,
                                   model: a.model, first: Date(timeIntervalSince1970: TimeInterval(a.first)),
                                   last: Date(timeIntervalSince1970: TimeInterval(a.last)),
                                   turns: a.turns, tokens: a.tokens, cost: cost,
                                   title: TranscriptTitles.title(sessionID: a.sessionID, cwd: a.cwd)))
                }
            }
            let done = out.sorted { $0.first < $1.first }
            await MainActor.run { rows = done; loading = false }
        }
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 60 { return L10n.t("\(m) min") }
        return m % 60 == 0 ? L10n.t("\(m / 60) h") : L10n.t("\(m / 60) h \(m % 60) min")
    }
    static func shortModel(_ m: String) -> String {
        m.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: "[1m]", with: "").replacingOccurrences(of: "openai/", with: "")
    }
}

/// First prompt of a session, from any Claude account's transcripts (cached).
enum TranscriptTitles {
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func title(sessionID: String, cwd: String) -> String? {
        lock.lock(); if let hit = cache[sessionID] { lock.unlock(); return hit }; lock.unlock()
        var found: String?
        let enc = String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [home.appendingPathComponent(".claude/projects")]
        if let dirs = try? FileManager.default.contentsOfDirectory(atPath: home.path) {
            roots += dirs.filter { $0.hasPrefix(".claude-") }.map { home.appendingPathComponent($0).appendingPathComponent("projects") }
        }
        for root in roots {
            let file = root.appendingPathComponent(enc).appendingPathComponent(sessionID + ".jsonl")
            guard let fh = try? FileHandle(forReadingFrom: file) else { continue }
            let head = fh.readData(ofLength: 256 * 1024); try? fh.close()
            for line in String(decoding: head, as: UTF8.self).split(separator: "\n") {
                guard line.contains("\"type\":\"user\""),
                      let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let msg = row["message"] as? [String: Any], let c = msg["content"] as? String else { continue }
                let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("<") { continue }
                found = String(t.replacingOccurrences(of: "\n", with: " ").prefix(70)); break
            }
            if found != nil { break }
        }
        lock.lock(); cache[sessionID] = found; lock.unlock()
        return found
    }
}
