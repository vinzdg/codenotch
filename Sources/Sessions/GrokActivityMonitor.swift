import Combine
import Foundation

/// Notices when Grok CLI is mid-turn.
///
/// Grok publishes no session status field. What it does do is list open TUIs
/// in `~/.grok/active_sessions.json` and append to that session's
/// `updates.jsonl` while a turn runs. A file written moments ago, whose pid is
/// still alive, is work happening now — the same heuristic Codex uses, with
/// the same caveat: it cannot tell thinking from a turn that finished a
/// second ago, so it errs short.
@MainActor
final class GrokActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let activeURL: URL
    private let sessionsRoot: URL
    private let interval: TimeInterval
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(
        activeURL: URL = GrokActivity.activeURL,
        sessionsRoot: URL = GrokActivity.sessionsRoot,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 45
    ) {
        self.activeURL = activeURL
        self.sessionsRoot = sessionsRoot
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        rescan()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func rescan() {
        let found = GrokActivity.read(activeURL: activeURL, sessionsRoot: sessionsRoot,
                                      staleAfter: staleAfter)
        guard found != sessions else { return }
        sessions = found
    }
}

enum GrokActivity {
    static var activeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/active_sessions.json")
    }

    static var sessionsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/sessions")
    }

    static func read(activeURL: URL, sessionsRoot: URL,
                     staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        guard let data = try? Data(contentsOf: activeURL),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row in
            session(row: row, sessionsRoot: sessionsRoot, staleAfter: staleAfter, now: now)
        }
    }

    static func session(row: [String: Any], sessionsRoot: URL,
                        staleAfter: TimeInterval, now: Date) -> AgentSession? {
        guard let id = row["session_id"] as? String, !id.isEmpty else { return nil }
        let pid = (row["pid"] as? NSNumber)?.int32Value
        if let pid, !ProcessLiveness.isAlive(pid: pid, startedAt: GrokCredentials.date(row["opened_at"])) {
            return nil
        }

        guard let directory = sessionDirectory(id: id, cwd: row["cwd"] as? String,
                                               under: sessionsRoot)
        else { return nil }
        let updates = directory.appendingPathComponent("updates.jsonl")
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: updates.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(modified) <= staleAfter
        else { return nil }

        let cwd = (row["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Grok"
        return AgentSession(
            id: "grok.\(id)",
            name: cwd,
            detail: "Grok",
            state: .busy,
            waitingFor: nil,
            since: modified,
            processID: pid
        )
    }

    /// The on-disk layout is `sessions/<percent-encoded-cwd>/<session-id>/`.
    /// The encoding is Grok's, so the cwd is only a hint; the session id is
    /// the directory name and is enough to find it.
    static func sessionDirectory(id: String, cwd: String?, under root: URL) -> URL? {
        if let cwd {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            let encoded = cwd.addingPercentEncoding(withAllowedCharacters: allowed) ?? cwd
            let candidate = root.appendingPathComponent(encoded).appendingPathComponent(id)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return nil }
        return folders.map { $0.appendingPathComponent(id) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
