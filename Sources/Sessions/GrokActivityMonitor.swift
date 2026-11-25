import Combine
import Darwin
import Foundation

/// Notices when Grok CLI is mid-turn.
///
/// Grok publishes no session status field. What it does do is list open TUIs
/// in `~/.grok/active_sessions.json` and append to that session's
/// `updates.jsonl` while a turn runs. A file written moments ago, whose pid is
/// still alive, is work happening now — the same heuristic Codex uses, with
/// the same caveat: it cannot tell thinking from a turn that finished a
/// second ago, so it errs short.
///
/// A headless run (`grok -p`, which is how scripts and other agents drive
/// Grok) is never listed there, so it is found the way `KimiActivity` finds
/// Kimi: from the running process. The run holds its own session's
/// `events.jsonl` open, which names the session exactly, and the session
/// records `turn_completed` when the turn is over, so the turn is read rather
/// than guessed from how recently a file was written.
@MainActor
final class GrokActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let activeURL: URL
    private let sessionsRoot: URL
    private let interval: TimeInterval
    private let staleAfter: TimeInterval
    private var timer: Timer?
    /// One scan at a time: a slow one is not stacked on by the next tick.
    private var isScanning = false
    private static let scanQueue = DispatchQueue(label: "codenotch.grok-activity", qos: .utility)

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

    /// Off the main thread. Finding headless `grok -p` runs lists every
    /// process on the Mac and asks the kernel about each — hundreds of calls a
    /// tick — which is not work to put between the notch and its next frame.
    private func rescan() {
        guard !isScanning else { return }
        isScanning = true
        let activeURL = activeURL, sessionsRoot = sessionsRoot, staleAfter = staleAfter
        Self.scanQueue.async { [weak self] in
            // Bound here, not inside the nested `DispatchQueue.main.async`:
            // both are concurrently-executing closures, and Swift 5.10 refuses
            // to read a captured `weak self` var from one nested inside
            // another. The same shape as PhoneLinkServer's path handler.
            guard let self else { return }
            let found = GrokActivity.read(activeURL: activeURL, sessionsRoot: sessionsRoot,
                                          staleAfter: staleAfter)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isScanning = false
                    guard found != self.sessions else { return }
                    self.sessions = found
                }
            }
        }
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
                     staleAfter: TimeInterval, now: Date = Date(),
                     processes: (() -> [Process])? = nil) -> [AgentSession] {
        let rows = (try? Data(contentsOf: activeURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let tuis = rows.compactMap { row in
            session(row: row, sessionsRoot: sessionsRoot, staleAfter: staleAfter, now: now)
        }

        return tuis + headless(processes: processes?() ?? GrokActivity.processes(under: sessionsRoot))
    }

    // MARK: - Headless runs

    struct Process {
        let pid: pid_t
        let startedAt: Date
        let cwd: String?
        /// The session folders whose `events.jsonl` the process holds open.
        /// Grok keeps its own session's open for the whole run, so this names
        /// the run's session outright: no pairing by folder or start time,
        /// which a leftover session in the same directory, or a cwd spelled
        /// through a symlink or `/var` rather than `/private/var`, would fool.
        let openSessions: [URL]
    }

    /// The headless runs among `processes` that are mid-turn.
    static func headless(processes: [Process]) -> [AgentSession] {
        processes.compactMap { process in
            // Only a session that says it is headless. A TUI's says nothing (it
            // is read from the registry above, registered yet or not), and a
            // subagent's, which its run also holds open, says "subagent".
            // Grok writes the kind as it opens the session (checked live), so
            // requiring it costs no part of the turn.
            guard let directory = process.openSessions.first(where: { kind(of: $0) == "headless" })
            else { return nil }
            let updates = directory.appendingPathComponent("updates.jsonl")
            guard turnIsOpen(inTail: tail(of: updates) ?? Data()) else { return nil }
            return AgentSession(
                id: "grok.\(directory.lastPathComponent)",
                name: process.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Grok",
                detail: "Grok",
                state: .busy,
                waitingFor: nil,
                since: process.startedAt,
                processID: process.pid
            )
        }
    }

    /// `summary.json`'s `session_kind`: "headless", "subagent", or nil for a
    /// TUI or a summary not written yet.
    static func kind(of session: URL) -> String? {
        (try? Data(contentsOf: session.appendingPathComponent("summary.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["session_kind"] as? String
    }

    /// Whether the newest update in `data` leaves the turn running.
    ///
    /// Hook runs are bookkeeping, not the turn: Grok fires `stop` hooks both
    /// mid-turn and after `turn_completed`, so they are skipped. A fragment
    /// the tail window cut is not a record either. With nothing else to go
    /// on, a live headless run is mid-turn: it exits once its one turn ends.
    static func turnIsOpen(inTail data: Data) -> Bool {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        for line in lines.reversed() {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let params = record["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  let kind = update["sessionUpdate"] as? String,
                  kind != "hook_execution"
            else { continue }
            return kind != "turn_completed"
        }
        return true
    }

    /// The last 64 KB is enough: a turn's end is one line, written last.
    private static let tailBytes: UInt64 = 65_536

    static func tail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        return try? handle.readToEnd()
    }

    /// Every running Grok CLI, TUI or headless, with the sessions it holds.
    /// TUIs pass through harmlessly: none of their sessions says headless.
    /// The managed install is a versioned binary under `~/.grok/downloads/`
    /// that `~/.grok/bin/grok` and its `agent` alias link to: the process
    /// name is the link's, the executable path the binary's. The name is
    /// checked first, so only Grok's own processes cost the path and file
    /// descriptor lookups. Same listing as `KimiActivity.processes`.
    static func processes(under sessionsRoot: URL) -> [Process] {
        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.stride + 16)
        count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                              Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count) / MemoryLayout<pid_t>.stride).compactMap { pid in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                               Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size)
            else { return nil }
            let comm = withUnsafePointer(to: &info.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
            }
            guard isGrokName(comm), isGrokBinary(pid: pid) else { return nil }
            return Process(
                pid: pid,
                startedAt: Date(timeIntervalSince1970:
                    Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000),
                cwd: SessionFocus.currentDirectory(of: pid),
                openSessions: openSessions(of: pid, under: sessionsRoot)
            )
        }
    }

    /// The name a Grok process runs under: the link it was started through
    /// (`grok`, or the `agent` alias), or the versioned binary's own,
    /// truncated by the kernel. Only a cheap first cut; the path decides.
    static func isGrokName(_ comm: String) -> Bool {
        comm.hasPrefix("grok") || comm == "agent"
    }

    static func isGrokBinary(path: String) -> Bool {
        path.contains("/.grok/downloads/grok-")
    }

    private static func isGrokBinary(pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return isGrokBinary(path: String(cString: buffer))
    }

    /// The session folders under `root` whose `events.jsonl` `pid` has open.
    static func openSessions(of pid: pid_t, under root: URL) -> [URL] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(),
                                count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
        let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                                Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard read > 0 else { return [] }

        // The kernel reports the path with symlinks resolved, so a root
        // reached through one (a moved home, `/var` for `/private/var`) is
        // matched in both spellings. `realpath`, not `resolvingSymlinksInPath`,
        // which strips a leading `/private` instead of resolving it.
        var resolved = root.path
        if let real = realpath(root.path, nil) {
            resolved = String(cString: real)
            free(real)
        }
        let prefixes = Set([root.path, resolved]).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return fds.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size
            else { return nil }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard prefixes.contains(where: path.hasPrefix), path.hasSuffix("/events.jsonl") else { return nil }
            return URL(fileURLWithPath: path).deletingLastPathComponent()
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
