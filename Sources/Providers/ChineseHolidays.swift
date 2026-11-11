import Foundation
import Combine

/// Days off under China's statutory holiday arrangement, keyed by the Beijing
/// calendar day.
///
/// DeepSeek bills these days at the off-peak rate even when they fall on a
/// weekday. The State Council publishes each year's arrangement around
/// November and there is no official API for it, so the dates come from
/// holiday-cn (github.com/NateScarlet/holiday-cn), which turns each notice into
/// one JSON file per year. Make-up working days are ignored on purpose: they
/// always fall on a weekend, and DeepSeek bills weekends off-peak regardless.
struct ChineseHolidayCalendar: Equatable, Sendable {
    /// "yyyy-MM-dd" in Beijing time.
    private(set) var offDays: Set<String>
    /// Years whose arrangement is known. A year can be published with no
    /// make-up days, but never with no days off, so an empty file means the
    /// notice is not out yet.
    private(set) var years: Set<Int>

    static let empty = ChineseHolidayCalendar(offDays: [], years: [])

    func isOffDay(_ date: Date) -> Bool {
        offDays.contains(Self.dayKey(date))
    }

    func covers(_ date: Date) -> Bool {
        years.contains(Self.beijingCalendar.component(.year, from: date))
    }

    /// One holiday-cn year file merged over this calendar, replacing whatever
    /// was known about that year. Nil when the file is not a usable year.
    func merging(holidayCNJSON data: Data) -> ChineseHolidayCalendar? {
        guard let file = try? JSONDecoder().decode(HolidayCNFile.self, from: data) else { return nil }
        let prefix = String(format: "%04d-", file.year)
        let days = file.days.filter { $0.isOffDay && $0.date.hasPrefix(prefix) }.map(\.date)
        guard !days.isEmpty else { return nil }
        var next = self
        next.offDays = offDays.filter { !$0.hasPrefix(prefix) }.union(days)
        next.years.insert(file.year)
        return next
    }

    static func dayKey(_ date: Date) -> String {
        let c = beijingCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Fixed +8 rather than Asia/Shanghai: China has not observed DST since
    /// 1991, and a fixed offset keeps the result independent of tzdata.
    static var beijingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }

    private struct HolidayCNFile: Decodable {
        struct Day: Decodable {
            let date: String
            let isOffDay: Bool
        }
        let year: Int
        let days: [Day]
    }
}

/// Keeps the holiday calendar current: the years shipped in the bundle, then
/// whatever a daily check of holiday-cn has added since, so a new year's
/// arrangement arrives without a release.
@MainActor
final class ChineseHolidays: ObservableObject {
    static let shared = ChineseHolidays()

    @Published private(set) var calendar: ChineseHolidayCalendar

    /// A static file on a public CDN: no account, and nothing about the user
    /// is sent beyond the request itself.
    nonisolated static func remoteURL(year: Int) -> URL {
        URL(string: "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/\(year).json")!
    }

    static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Codenotch/holidays-cn", isDirectory: true)
    }()

    /// Every holiday-cn file shipped in Resources, named holiday-cn-<year>.json.
    static let bundled: ChineseHolidayCalendar = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("holiday-cn-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .reduce(ChineseHolidayCalendar.empty) { calendar, url in
                guard let data = try? Data(contentsOf: url) else { return calendar }
                return calendar.merging(holidayCNJSON: data) ?? calendar
            }
    }()

    private static let checkedAtKey = "chineseHolidaysCheckedAt"
    private let defaults: UserDefaults
    private var timer: Timer?
    private var fetching = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var calendar = Self.bundled
        // A cached year replaces the bundled one: it is at least as new, and
        // the State Council has amended a published arrangement before.
        let cached = (try? FileManager.default.contentsOfDirectory(at: Self.cacheDirectory,
                                                                   includingPropertiesForKeys: nil)) ?? []
        for url in cached.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let merged = calendar.merging(holidayCNJSON: data) {
                calendar = merged
            }
        }
        self.calendar = calendar
    }

    /// Only checks the network while someone is looking at DeepSeek's pricing
    /// with the holiday rule on; everyone else never makes the request.
    func setActive(_ active: Bool) {
        guard active else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        refreshIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshIfDue() }
        }
    }

    func refreshIfDue(now: Date = Date()) {
        let checkedAt = defaults.object(forKey: Self.checkedAtKey) as? Date
        guard !fetching, checkedAt.map({ now.timeIntervalSince($0) > 24 * 3_600 }) ?? true else { return }
        fetching = true
        // This year, and next year once the November notice is out.
        let year = ChineseHolidayCalendar.beijingCalendar.component(.year, from: now)
        Task.detached(priority: .utility) {
            var files: [(year: Int, data: Data)] = []
            var failed = false
            for candidate in [year, year + 1] {
                do {
                    let (data, response) = try await URLSession.shared.data(from: Self.remoteURL(year: candidate))
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        // Next year's file may not exist before the notice; that is not a failure.
                        if candidate == year { failed = true }
                        continue
                    }
                    files.append((candidate, data))
                } catch {
                    if candidate == year { failed = true }
                }
            }
            let fetched = files
            let anyFailed = failed
            await MainActor.run { self.apply(fetched, failed: anyFailed, at: now) }
        }
    }

    private func apply(_ files: [(year: Int, data: Data)], failed: Bool, at now: Date) {
        fetching = false
        var calendar = self.calendar
        for file in files {
            // An unpublished year comes back as an empty list; keep what we have.
            guard let merged = calendar.merging(holidayCNJSON: file.data) else { continue }
            calendar = merged
            try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            try? file.data.write(to: Self.cacheDirectory.appendingPathComponent("\(file.year).json"),
                                 options: .atomic)
        }
        if calendar != self.calendar { self.calendar = calendar }
        if failed {
            // Retried on the next timer tick rather than a day later: the
            // bundled years still answer in the meantime.
            Log.usage.info("holiday-cn refresh failed; keeping \(calendar.years.sorted(), privacy: .public)")
        } else {
            defaults.set(now, forKey: Self.checkedAtKey)
        }
    }
}
