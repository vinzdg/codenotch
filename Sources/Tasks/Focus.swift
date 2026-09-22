import Foundation
import Combine
import UserNotifications

/// One task in focus at a time: a timer against a target, the name shown on
/// the panel and in the main window, and an editable log of focus blocks, each
/// linked to a project (a Things project/area or a Reminders list).
@MainActor
final class FocusStore: ObservableObject {
    static let shared = FocusStore()

    struct Block: Codable, Identifiable, Equatable {
        var id: String = UUID().uuidString
        var taskID: String
        var name: String
        var project: String?
        var start: Date
        var end: Date
        var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }

        enum CodingKeys: String, CodingKey { case id, taskID, name, project, start, end }
        init(taskID: String, name: String, project: String?, start: Date, end: Date) {
            self.taskID = taskID; self.name = name; self.project = project; self.start = start; self.end = end
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            taskID = try c.decode(String.self, forKey: .taskID)
            name = try c.decode(String.self, forKey: .name)
            project = try c.decodeIfPresent(String.self, forKey: .project)
            start = try c.decode(Date.self, forKey: .start)
            end = try c.decode(Date.self, forKey: .end)
        }
    }

    @Published private(set) var taskID: String?
    @Published private(set) var taskName: String?
    @Published private(set) var project: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var paused: TimeInterval = 0     // accumulated before the current run
    @Published private(set) var isRunning = false
    @Published private(set) var log: [Block] = []
    @Published private(set) var now = Date()

    /// Target length of one focus block, minutes (Settings).
    static let targetKey = "focusTargetMinutes"
    var targetMinutes: Int {
        get { max(5, UserDefaults.standard.integer(forKey: Self.targetKey) == 0 ? 25 : UserDefaults.standard.integer(forKey: Self.targetKey)) }
        set { UserDefaults.standard.set(newValue, forKey: Self.targetKey); objectWillChange.send() }
    }

    var elapsed: TimeInterval {
        paused + (isRunning ? now.timeIntervalSince(startedAt ?? now) : 0)
    }
    var fraction: Double { min(1, elapsed / Double(targetMinutes * 60)) }
    var isActive: Bool { taskID != nil }

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Codenotch/tasks/focus-log.json")
    }()

    private var ticker: Timer?
    private var notifiedTarget = false
    /// Long-running alert: first at 2 h, then every extra hour.
    static let longAfter: TimeInterval = 2 * 3600
    private var longAlerts = 0

    /// The active task survives a restart (the timer keeps counting from startedAt).
    private struct Active: Codable {
        var taskID: String; var taskName: String; var project: String?; var startedAt: Date?; var paused: TimeInterval; var isRunning: Bool
        var notifiedTarget: Bool; var longAlerts: Int
    }
    private static let activeKey = "focusActive"

    private init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.fileURL), let list = try? dec.decode([Block].self, from: data) { log = list }
        if let data = UserDefaults.standard.data(forKey: Self.activeKey),
           let a = try? JSONDecoder().decode(Active.self, from: data) {
            taskID = a.taskID; taskName = a.taskName; project = a.project; startedAt = a.startedAt; paused = a.paused
            isRunning = a.isRunning && a.startedAt != nil
            notifiedTarget = a.notifiedTarget; longAlerts = a.longAlerts
            now = Date()
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func persistActive() {
        guard let id = taskID, let name = taskName else {
            UserDefaults.standard.removeObject(forKey: Self.activeKey); return
        }
        let a = Active(taskID: id, taskName: name, project: project, startedAt: startedAt, paused: paused, isRunning: isRunning,
                       notifiedTarget: notifiedTarget, longAlerts: longAlerts)
        if let data = try? JSONEncoder().encode(a) { UserDefaults.standard.set(data, forKey: Self.activeKey) }
    }

    private func tick() {
        guard isRunning else { return }
        now = Date()
        if !notifiedTarget, elapsed >= Double(targetMinutes * 60) {
            notifiedTarget = true
            FocusNotify.post(title: L10n.t("Focus block done"), body: taskName ?? L10n.t("Time's up."))
            persistActive()
        }
        let due = Int((elapsed - Self.longAfter) / 3600) + 1
        if elapsed >= Self.longAfter, due > longAlerts {
            longAlerts = due
            FocusNotify.post(title: L10n.t("Still in focus after \(Int(elapsed / 3600)) h"), body: taskName ?? L10n.t("Same task? Pause or stop it from the card."))
            persistActive()
        }
    }

    // MARK: Timer

    /// Start (or switch to) a task. Switching closes the previous block.
    func start(id: String, name: String, project: String? = nil) {
        if let current = taskID, current != id { stop() }
        if taskID == id, isRunning { return }
        taskID = id
        taskName = name
        self.project = project
        startedAt = Date()
        now = startedAt!
        isRunning = true
        notifiedTarget = elapsed >= Double(targetMinutes * 60)
        longAlerts = 0
        persistActive()
    }

    func pause() {
        guard isRunning, let s = startedAt else { return }
        paused += Date().timeIntervalSince(s)
        isRunning = false
        startedAt = nil
        persistActive()
    }

    func resume() {
        guard !isRunning, taskID != nil else { return }
        startedAt = Date(); now = startedAt!; isRunning = true
        persistActive()
    }

    /// Ends the block and writes it to the log.
    func stop() {
        guard let id = taskID else { return }
        if isRunning { pause() }
        if paused >= 30, let name = taskName {
            let end = Date()
            log.append(Block(taskID: id, name: name, project: project, start: end.addingTimeInterval(-paused), end: end))
            save()
        }
        taskID = nil; taskName = nil; project = nil; startedAt = nil; paused = 0; isRunning = false; notifiedTarget = false; longAlerts = 0
        persistActive()
    }

    /// Re-read the log from disk (edited elsewhere, or synced).
    func reload() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.fileURL), let list = try? dec.decode([Block].self, from: data) { log = list }
        objectWillChange.send()
    }

    // MARK: Log editing

    func add(name: String, project: String?, start: Date, end: Date) {
        guard end > start else { return }
        log.append(Block(taskID: "manual-\(Int(start.timeIntervalSince1970))", name: name, project: project, start: start, end: end))
        log.sort { $0.start < $1.start }
        save()
    }

    func update(_ block: Block) {
        guard let i = log.firstIndex(where: { $0.id == block.id }), block.end > block.start else { return }
        log[i] = block
        log.sort { $0.start < $1.start }
        save()
    }

    func delete(_ id: String) {
        log.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(log.suffix(5000)) {
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: Queries

    /// The running block as a Block (for views), when any.
    var activeBlock: Block? {
        guard let id = taskID, let name = taskName, elapsed > 0 else { return nil }
        var b = Block(taskID: id, name: name, project: project, start: Date().addingTimeInterval(-elapsed), end: Date())
        b.id = "active"
        return b
    }

    func blocks(on day: Date) -> [Block] {
        let cal = Calendar.current
        var out = log.filter { cal.isDate($0.start, inSameDayAs: day) }
        if cal.isDateInToday(day), let a = activeBlock { out.append(a) }
        return out
    }

    func blocks(in interval: DateInterval, project filter: String?) -> [Block] {
        var out = log.filter { interval.contains($0.start) }
        if let a = activeBlock, interval.contains(a.start) { out.append(a) }
        if let filter, !filter.isEmpty { out = out.filter { ($0.project ?? "") == filter } }
        return out.sorted { $0.start < $1.start }
    }

    /// Every project name seen in the log (for the filter).
    var projects: [String] { Array(Set(log.compactMap(\.project))).sorted() }

    static func clock(_ s: TimeInterval) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }
}


/// The focus timer's notifications: the block reaching its length, and a
/// block that has run long. A banner, with its own switch in Settings › Tasks.
enum FocusNotify {
    static let enabledKey = "focusNotifies"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static func post(title: String, body: String) {
        guard isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let deliver = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                center.add(UNNotificationRequest(identifier: "focus-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil))
            }
            switch settings.authorizationStatus {
            case .notDetermined: center.requestAuthorization(options: [.alert, .sound]) { ok, _ in if ok { deliver() } }
            case .denied: break
            default: deliver()
            }
        }
    }
}
