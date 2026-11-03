import Combine
import Darwin
import Foundation

/// Follows running Kimi Code CLIs, the way `ClaudeSessionMonitor` follows
/// Claude Code.
///
/// Kimi writes no live-session registry, so discovery works the other way
/// around: find the CLI's own processes (`kimi-code`) and match each one's
/// working directory to a session in `session_index.jsonl`. State comes from
/// the session's `wire.jsonl`, which records turn boundaries and approval
/// prompts with millisecond timestamps — a richer signal than Grok's
/// recency-only heuristic: a turn in flight is `busy`, an approval waiting on
/// an answer is `waiting`, a turn that just ended is `success`, and a live
/// TUI sitting at its prompt is `idle`. The pid goes into the session, so a
/// peek click raises the terminal it runs in — see `SessionFocus`.
@MainActor
final class KimiActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let root: URL
    private let interval: TimeInterval
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(
        root: URL = KimiActivity.root,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 90
    ) {
        self.root = root
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
        let found = KimiActivity.read(root: root, staleAfter: staleAfter)
        guard found != sessions else { return }
        sessions = found
    }
}

enum KimiActivity {
    /// Everything the monitor reads lives under the CLI's data root.
    static var root: URL {
        let override = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]
            ?? ProcessInfo.processInfo.environment["KIMI_K_HOME"]
        let nonOverridden = override.flatMap { value -> String? in value.isEmpty ? nil : value }
        return nonOverridden.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kimi-code")
    }

    /// A turn that has written nothing for this long is not running, whatever
    /// the last wire record says — thinking streams deltas, tools report when
    /// they finish, so silence means the CLI is gone or wedged.
    static func read(root: URL, staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        var roots = [root]
        let kRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kimi-k")
        if root != kRoot, FileManager.default.fileExists(atPath: kRoot.path) {
            roots.append(kRoot)
        }
        let byWorkDir = index(roots: roots)
        // Newest process first, so when two TUIs share a directory the newer
        // one is paired with the newer session.
        let live = processes()
            .filter { $0.cwd != nil && byWorkDir[resolve($0.cwd!)] != nil }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        var remaining = byWorkDir
        return live.compactMap { process in
            let key = resolve(process.cwd!)
            guard let sessionDir = remaining.removeValue(forKey: key) else { return nil }
            return session(sessionDir: sessionDir, pid: process.pid,
                           startedAt: process.startedAt, workDir: process.cwd!,
                           staleAfter: staleAfter, now: now)
        }
        .sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    static func session(sessionDir: URL, pid: pid_t, startedAt: Date?,
                        workDir: String, staleAfter: TimeInterval, now: Date) -> AgentSession? {
        guard ProcessLiveness.isAlive(pid: pid, startedAt: startedAt) else { return nil }

        let wireURL: URL
        let modified: Date?
        let activeAgent: String?
        if let found = activeAgentWire(in: sessionDir) {
            wireURL = found.url
            modified = found.modified
            activeAgent = found.agentName
        } else {
            let defaultWire = sessionDir.appendingPathComponent("agents/main/wire.jsonl")
            wireURL = defaultWire
            modified = (try? FileManager.default.attributesOfItem(atPath: defaultWire.path))?[.modificationDate] as? Date
            activeAgent = "main"
        }

        let wireTail = tail(of: wireURL)
        let turn = wireTail.flatMap { KimiActivity.turn(inTail: $0) }
        let model = wireTail.flatMap { KimiActivity.model(inTail: $0) }
            ?? (activeAgent != nil && isKimiKAgent(activeAgent!) ? "Kimi K" : nil)

        /// Two levels, not one: `repos/personal` says something where
        /// `personal` could be any folder on the machine.
        let url = URL(fileURLWithPath: workDir)
        let parent = url.deletingLastPathComponent().lastPathComponent
        let name = parent.isEmpty ? (url.lastPathComponent.isEmpty ? "Kimi" : url.lastPathComponent)
            : "\(parent)/\(url.lastPathComponent)"

        /// Where it is running, the way Claude's rows name the surface. The
        /// owning app is the same answer `SessionFocus` jumps to on a peek
        /// click; a CLI nobody claims is a terminal one.
        let surface = SessionFocus.owningApp(of: pid)?.localizedName ?? L10n.t("Terminal")
        let detail = model != nil ? "\(surface) · \(model!)" : surface

        let state: AgentSession.State
        var waitingFor: String?
        var since = modified ?? now
        switch turn {
        case .waiting(let at, let what):
            // An approval holds until it is answered, however long that takes —
            // no staleness ladder here.
            state = .waiting
            waitingFor = what
            since = at
        case .busy(let at):
            if let modified, now.timeIntervalSince(modified) <= staleAfter {
                state = .busy
                since = at ?? modified
            } else {
                state = .idle
            }
        case .finished(let at):
            state = now.timeIntervalSince(at) <= 10 ? .success : .idle
            since = at
        case nil:
            state = .idle
        }

        return AgentSession(
            id: "kimi.\(sessionDir.lastPathComponent)",
            name: name,
            detail: detail,
            state: state,
            waitingFor: waitingFor,
            since: since,
            processID: pid
        )
    }

    static func activeAgentWire(in sessionDir: URL) -> (url: URL, modified: Date?, agentName: String)? {
        let agentsDir = sessionDir.appendingPathComponent("agents")
        let subdirs = (try? FileManager.default.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let agentCandidates = subdirs.filter { url in
            FileManager.default.fileExists(atPath: url.appendingPathComponent("wire.jsonl").path)
        }
        if agentCandidates.isEmpty {
            let mainWire = agentsDir.appendingPathComponent("main/wire.jsonl")
            guard FileManager.default.fileExists(atPath: mainWire.path) else { return nil }
            let mod = (try? FileManager.default.attributesOfItem(atPath: mainWire.path))?[.modificationDate] as? Date
            return (mainWire, mod, "main")
        }
        let sorted = agentCandidates.sorted { a, b in
            let aIsK = isKimiKAgent(a.lastPathComponent)
            let bIsK = isKimiKAgent(b.lastPathComponent)
            if aIsK != bIsK { return aIsK }
            let aWire = a.appendingPathComponent("wire.jsonl")
            let bWire = b.appendingPathComponent("wire.jsonl")
            let aDate = ((try? FileManager.default.attributesOfItem(atPath: aWire.path))?[.modificationDate] as? Date) ?? .distantPast
            let bDate = ((try? FileManager.default.attributesOfItem(atPath: bWire.path))?[.modificationDate] as? Date) ?? .distantPast
            return aDate > bDate
        }
        if let best = sorted.first {
            let wire = best.appendingPathComponent("wire.jsonl")
            let mod = (try? FileManager.default.attributesOfItem(atPath: wire.path))?[.modificationDate] as? Date
            return (wire, mod, best.lastPathComponent)
        }
        return nil
    }

    /// The last 64 KB of the wire is enough: turn boundaries are one line
    /// each, and a turn writes dozens.
    private static let tailBytes: UInt64 = 65_536

    static func tail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    /// What the main agent is doing, read off the wire's own records.
    enum Turn {
        /// Loop records carry no timestamp of their own; the caller falls
        /// back to the wire's modification time.
        case busy(since: Date?)
        case finished(since: Date)
        case waiting(since: Date, for: String?)
    }

    /// Newest relevant record wins. Turn records are top-level
    /// (`{"type":"turn.prompt",…,"time":<ms>}`); approval records can arrive
    /// wrapped in a `context.append_loop_event` envelope, so one level of
    /// nesting is unwrapped. Subagent records are not the session's turn.
    ///
    /// Loop activity (`tool.call`, `step.begin`, …) also means busy: a long
    /// turn fills the tail with more than 64 KB of tool chatter, pushing its
    /// own `turn.prompt` out of the window, and only `turn.ended` may say it
    /// is over.
    static func turn(inTail data: Data) -> Turn? {
        /// Records that only exist while a turn runs.
        let loopActivity: Set<String> = [
            "context.append_loop_event", "content.part",
            "step.begin", "step.end", "tool.call", "tool.result",
            "think", "text", "llm.request",
        ]
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        /// Set by an `approval.resolved` seen while scanning backwards: any
        /// request further back was the one it answered.
        var approvalResolved = false
        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            var record = object
            if record["type"] as? String == "context.append_loop_event",
               let event = record["event"] as? [String: Any] {
                record = event
            }
            if let agent = record["agentId"] as? String, !isSessionAgent(agent) { continue }
            guard let type = record["type"] as? String else { continue }
            let time = (record["time"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            switch type {
            case "approval.requested":
                if approvalResolved { continue }
                return .waiting(since: time ?? Date(), for: summary(of: record))
            case "approval.resolved":
                approvalResolved = true
                continue
            case "turn.prompt", "prompt.accepted":
                return .busy(since: time)
            case "turn.ended":
                return .finished(since: time ?? Date())
            default:
                if loopActivity.contains(type) { return .busy(since: time) }
                continue
            }
        }
        return nil
    }

    static func isSessionAgent(_ agent: String) -> Bool {
        agent == "main" || isKimiKAgent(agent)
    }

    static func isKimiKAgent(_ agent: String) -> Bool {
        let lower = agent.lowercased()
        return lower == "kimi-k" || lower == "k" || lower == "k-agent" || lower.hasPrefix("kimi-k") || lower.hasPrefix("k-")
    }

    static func model(inTail data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            var record = object
            if record["type"] as? String == "context.append_loop_event",
               let event = record["event"] as? [String: Any] {
                record = event
            }
            for key in ["model", "modelId", "model_id", "selectedModel"] {
                if let raw = record[key] as? String, !raw.isEmpty {
                    return formatModelName(raw)
                }
            }
            if let agent = record["agentId"] as? String, isKimiKAgent(agent) {
                return "Kimi K"
            }
        }
        return nil
    }

    static func formatModelName(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "kimi-k" || lower == "k" { return "Kimi K" }
        if lower == "kimi-k3" || lower == "k3" { return "Kimi K3" }
        if lower == "kimi-k3.1" || lower == "k3.1" { return "Kimi K3.1" }
        if lower == "kimi-k3.1-pro" || lower == "k3.1-pro" { return "Kimi K3.1 Pro" }
        if lower.hasPrefix("kimi-k") {
            let suffix = trimmed.dropFirst("kimi-k".count).trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
            return suffix.isEmpty ? "Kimi K" : "Kimi K \(suffix.uppercased())"
        }
        return trimmed
    }

    /// What an approval is asking about, in whichever field the CLI put it.
    private static func summary(of record: [String: Any]) -> String? {
        for key in ["tool", "toolName", "name", "command", "summary"] {
            if let value = record[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// workDir → newest session directory, from the CLI's own index.
    /// `/private` prefixes are resolved on both sides before comparing.
    static func index(roots: [URL]) -> [String: URL] {
        var byWorkDir: [String: URL] = [:]
        for root in roots {
            let indexURL = root.appendingPathComponent("session_index.jsonl")
            guard let text = try? String(contentsOf: indexURL, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let workDir = record["workDir"] as? String,
                      let sessionDir = record["sessionDir"] as? String
                else { continue }
                byWorkDir[resolve(workDir)] = URL(fileURLWithPath: sessionDir)
            }
        }
        return byWorkDir
    }

    static func index(root: URL) -> [String: URL] {
        index(roots: [root])
    }

    /// Spelled the same on both sides without touching the disk. Resolving
    /// symlinks looks at every folder along the path, and this runs every two
    /// seconds on each session's working directory — a project in Documents
    /// or on a network volume then puts up macOS's "access files in
    /// Documents" prompt under Codenotch's name (#227). The one difference
    /// that matters here is macOS's own `/private` alias.
    static func resolve(_ path: String) -> String {
        // Plain text only: `standardizingPath` also consults the disk for
        // `/private` and `..`. Doubled and trailing slashes are all a working
        // directory reported by the process can differ by.
        var standard = path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        if path.hasPrefix("/") { standard = "/" + standard }
        for alias in ["/private/var", "/private/tmp", "/private/etc"] where standard == alias || standard.hasPrefix(alias + "/") {
            return String(standard.dropFirst("/private".count))
        }
        return standard
    }

    // MARK: - Process discovery

    struct Process {
        let pid: pid_t
        let startedAt: Date?
        let cwd: String?
    }

    /// Every running `kimi-code` (or `kimi`) process. The managed install is
    /// a single binary under `~/.kimi-code/bin/kimi`; either the command name
    /// or that path marks it. A `node` wrapper script would not be found —
    /// the CLI ships the binary.
    static func processes() -> [Process] {
        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.stride + 16)
        count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                              Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count) / MemoryLayout<pid_t>.stride)
            .compactMap { process(pid: $0) }
    }

    static func process(pid: pid_t) -> Process? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                                Int32(MemoryLayout<proc_bsdinfo>.size))
        guard read == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        let comm = withUnsafePointer(to: &info.pbi_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                String(cString: $0)
            }
        }
        guard isKimiProcess(comm: comm, pid: pid) else {
            return nil
        }
        let startedAt = Date(timeIntervalSince1970:
            Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
        return Process(pid: pid, startedAt: startedAt, cwd: SessionFocus.currentDirectory(of: pid))
    }

    static func isKimiProcess(comm: String, pid: pid_t) -> Bool {
        if comm == "kimi-code" || comm == "kimi" || comm == "kimi-k" || comm == "kimi-k-agent" || comm == "kimik" {
            return true
        }
        return executablePath(of: pid)
    }

    /// True when the executable is the managed binary — covers a comm the
    /// kernel truncated.
    private static func executablePath(of pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let read = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard read > 0 else { return false }
        let path = String(cString: buffer)
        return path.hasSuffix("/.kimi-code/bin/kimi")
            || path.hasSuffix("/.kimi-k/bin/kimi")
            || path.hasSuffix("/.kimi-k/bin/kimi-k")
            || path.hasSuffix("/bin/kimi-k")
            || path.hasSuffix("/bin/kimi-k-agent")
            || path.hasSuffix("/bin/kimi")
    }
}
