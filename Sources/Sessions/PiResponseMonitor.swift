import CoreServices
import Darwin
import Foundation

/// Watches Pi's persisted session stream. Completed Codex/Grok responses refresh
/// their matching quota; active turns drive the matching built-in provider ring.
@MainActor
final class PiResponseMonitor {
    static var defaultSessionsDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        let agentDirectory = environment["PI_CODING_AGENT_DIR"]
            .map { NSString(string: $0).expandingTildeInPath }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pi/agent").path
        return URL(fileURLWithPath: agentDirectory).appendingPathComponent("sessions")
    }

    private let directory: URL
    private let reader: PiSessionTailReader
    private let onResponse: (String) -> Void
    private let onActivity: (String, [PiActivitySnapshot]) -> Void
    private var stream: FSEventStreamRef?
    private var pending: Set<String> = []
    private var debounce: DispatchWorkItem?
    private var active: [String: PiActiveTurn] = [:]
    private let livePiDirectories: () -> Set<String>
    private var sweepTimer: Timer?

    init(directory: URL? = nil,
         startedAt: Date = Date(),
         livePiDirectories: @escaping () -> Set<String> = PiProcesses.workingDirectories,
         onResponse: @escaping (String) -> Void,
         onActivity: @escaping (String, [PiActivitySnapshot]) -> Void = { _, _ in }) {
        self.directory = directory ?? Self.defaultSessionsDirectory
        self.reader = PiSessionTailReader(startedAt: startedAt)
        self.livePiDirectories = livePiDirectories
        self.onResponse = onResponse
        self.onActivity = onActivity
    }

    func start() {
        stop()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<PiResponseMonitor>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            Task { @MainActor in monitor.consume(Array(changed.prefix(count))) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    func stop() {
        sweepTimer?.invalidate()
        sweepTimer = nil
        debounce?.cancel()
        debounce = nil
        pending.removeAll()
        let providers = Set(active.values.map(\.providerID))
        active.removeAll()
        for provider in providers { onActivity(provider, []) }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    func consume(_ paths: [String]) {
        var affected: Set<String> = []
        for path in paths where path.hasSuffix(".jsonl") {
            let result = reader.consume(URL(fileURLWithPath: path))
            pending.formUnion(result.completedUsageProviderIDs)
            for event in result.activityEvents {
                if let previous = active[event.sessionPath]?.providerID {
                    affected.insert(previous)
                }
                if event.isBusy {
                    let cwd = active[event.sessionPath]?.cwd
                        ?? PiSessionTailReader.workingDirectory(
                            of: URL(fileURLWithPath: event.sessionPath))
                    active[event.sessionPath] = PiActiveTurn(
                        providerID: event.providerID,
                        model: event.model,
                        since: event.timestamp,
                        cwd: cwd
                    )
                    affected.insert(event.providerID)
                } else {
                    active.removeValue(forKey: event.sessionPath)
                    affected.insert(event.providerID)
                }
            }
        }
        publish(affected)

        guard !pending.isEmpty else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let providers = self.pending
            self.pending.removeAll()
            for provider in providers.sorted() { self.onResponse(provider) }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Pi writes nothing when it quits mid-turn, so the turn it left open
    /// would read as working forever. Drop every turn no running Pi can own:
    /// none in the session's directory, or none at all when that is unknown.
    func sweep() {
        guard !active.isEmpty else { return }
        let live = livePiDirectories()
        var affected: Set<String> = []
        for (path, turn) in active {
            let owned = turn.cwd.map(live.contains) ?? !live.isEmpty
            guard !owned else { continue }
            active.removeValue(forKey: path)
            affected.insert(turn.providerID)
        }
        publish(affected)
    }

    private func publish(_ providers: Set<String>) {
        for provider in providers {
            let sessions = active.compactMap { path, turn -> PiActivitySnapshot? in
                guard turn.providerID == provider else { return nil }
                return PiActivitySnapshot(id: "pi.\(path)", model: turn.model, since: turn.since)
            }
            onActivity(provider, sessions)
        }
    }
}

private struct PiActiveTurn {
    let providerID: String
    let model: String
    let since: Date
    /// Where the session was started, from its header. Nil when unreadable.
    let cwd: String?
}

/// Running Pi processes. Pi retitles itself `pi` (`pi-rpc` in RPC mode), so
/// that is its argv[0] — while the kernel still calls it `node`.
enum PiProcesses {
    static func workingDirectories() -> Set<String> {
        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.stride + 16)
        count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                              Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        return Set(pids.prefix(Int(count) / MemoryLayout<pid_t>.stride)
            .filter(isPi)
            .compactMap(SessionFocus.currentDirectory(of:))
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
    }

    static func isPi(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                           Int32(MemoryLayout<proc_bsdinfo>.size))
                == Int32(MemoryLayout<proc_bsdinfo>.size)
        else { return false }
        let comm = withUnsafePointer(to: &info.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                String(cString: $0)
            }
        }
        // Only runtimes Pi ships on: reading every process's arguments every
        // few seconds would cost far more than this check.
        guard comm == "pi" || comm.hasPrefix("node") || comm == "bun" else { return false }
        // The block opens with the executable path; argv[0] follows it.
        guard let argv0 = TerminalTabFocus.environment(of: pid).dropFirst().first else {
            return false
        }
        return ["pi", "pi-rpc"].contains((argv0 as NSString).lastPathComponent)
    }
}

struct PiActivitySnapshot {
    let id: String
    let model: String
    let since: Date
}

struct PiSessionRead {
    var completedUsageProviderIDs: Set<String> = []
    var activityEvents: [PiActivityEvent] = []
}

struct PiActivityEvent {
    let sessionPath: String
    let providerID: String
    let model: String
    let timestamp: Date
    let isBusy: Bool
}

/// Incremental JSONL reader kept separate from FSEvents so boundary behavior is testable.
final class PiSessionTailReader {
    private struct Cursor {
        var offset: UInt64
        var remainder = Data()
        var provider: String?
        var model: String?
    }

    private static let firstReadLimit: UInt64 = 512 * 1024
    private let startedAt: TimeInterval
    private var cursors: [String: Cursor] = [:]
    private var seen = Set<String>()
    private var seenOrder: [String] = []

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt.timeIntervalSince1970
    }

    func consume(_ url: URL) -> PiSessionRead {
        guard let size = fileSize(url), let handle = try? FileHandle(forReadingFrom: url) else {
            return PiSessionRead()
        }
        defer { try? handle.close() }

        let existing = cursors[url.path]
        let start: UInt64
        var cursor: Cursor
        var discardFirstFragment = false
        if let existing, size >= existing.offset {
            start = existing.offset
            cursor = existing
        } else {
            start = size > Self.firstReadLimit ? size - Self.firstReadLimit : 0
            cursor = Cursor(offset: start)
            discardFirstFragment = start > 0
        }
        guard start <= size, (try? handle.seek(toOffset: start)) != nil else {
            return PiSessionRead()
        }
        let byteCount = Int(size - start)
        var appended = Data()
        appended.reserveCapacity(byteCount)
        while appended.count < byteCount {
            guard let chunk = try? handle.read(upToCount: byteCount - appended.count),
                  !chunk.isEmpty else { break }
            appended.append(chunk)
        }
        guard appended.count == byteCount else { return PiSessionRead() }

        var bytes = cursor.remainder
        bytes.append(appended)
        let parts = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        var lines = parts.dropLast(1).map { Data($0) }
        cursor.remainder = parts.last.map { Data($0) } ?? Data()
        if discardFirstFragment, !lines.isEmpty { lines.removeFirst() }

        var result = PiSessionRead()
        for line in lines {
            guard let record = PiSessionRecord(line: line) else { continue }
            if let provider = record.provider { cursor.provider = provider }
            if let model = record.model { cursor.model = model }
            guard record.timestamp >= startedAt, remember(record.id) else { continue }

            let provider = record.provider ?? cursor.provider
            let model = record.model ?? cursor.model
            guard let provider, let model,
                  let activityProvider = PiProviderMapping.activityProviderID(
                    provider: provider, model: model
                  ) else { continue }

            switch record.kind {
            case .user:
                result.activityEvents.append(PiActivityEvent(
                    sessionPath: url.path,
                    providerID: activityProvider,
                    model: model,
                    timestamp: Date(timeIntervalSince1970: record.timestamp),
                    isBusy: true
                ))
            case let .assistant(stopReason):
                let isBusy = stopReason == "toolUse" || stopReason == "pending"
                result.activityEvents.append(PiActivityEvent(
                    sessionPath: url.path,
                    providerID: activityProvider,
                    model: model,
                    timestamp: Date(timeIntervalSince1970: record.timestamp),
                    isBusy: isBusy
                ))
                if !isBusy,
                   let usageProvider = PiProviderMapping.usageProviderID(provider: provider) {
                    result.completedUsageProviderIDs.insert(usageProvider)
                }
            case .modelChange:
                break
            }
        }
        cursor.offset = size
        cursors[url.path] = cursor
        return result
    }

    /// The directory the session was started in, from its opening `session` line.
    static func workingDirectory(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024),
              let line = head.split(separator: UInt8(ascii: "\n")).first,
              let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              root["type"] as? String == "session"
        else { return nil }
        guard let cwd = root["cwd"] as? String else { return nil }
        // The kernel reports a process's directory with its symlinks
        // resolved (/private/tmp, not /tmp), so the header's has to be too,
        // or a Pi still running there reads as gone.
        return URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
    }

    private func fileSize(_ url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value
    }

    private func remember(_ id: String) -> Bool {
        guard seen.insert(id).inserted else { return false }
        seenOrder.append(id)
        if seenOrder.count > 512 {
            let evicted = seenOrder.prefix(seenOrder.count - 512)
            seen.subtract(evicted)
            seenOrder.removeFirst(evicted.count)
        }
        return true
    }
}

enum PiProviderMapping {
    static func usageProviderID(provider: String) -> String? {
        ["openai-codex": "codex", "xai": "grok"][provider]
    }

    static func activityProviderID(provider: String, model: String) -> String? {
        let direct = [
            "anthropic": "claude",
            "deepseek": "deepseek",
            "github-copilot": "copilot",
            "google": "gemini-api",
            "google-gemini-cli": "gemini-api",
            "kimi-coding": "kimi",
            "minimax": "minimax",
            "moonshot": "kimi",
            "ollama": "ollama-local",
            "openai-codex": "codex",
            "xai": "grok",
            "z-ai": "glm",
            "zai": "glm",
        ]
        if let mapped = direct[provider] { return mapped }

        let name = model.lowercased()
        let families = [
            ("claude", "claude"),
            ("deepseek", "deepseek"),
            ("gemini", "gemini-api"),
            ("glm", "glm"),
            ("gpt", "codex"),
            ("grok", "grok"),
            ("kimi", "kimi"),
            ("minimax", "minimax"),
        ]
        return families.first { name.contains($0.0) }?.1
    }
}

private struct PiSessionRecord {
    enum Kind {
        case modelChange
        case user
        case assistant(stopReason: String)
    }

    let id: String
    let kind: Kind
    let provider: String?
    let model: String?
    let timestamp: TimeInterval

    init?(line: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = root["type"] as? String,
              let id = root["id"] as? String else { return nil }
        self.id = id

        if type == "model_change",
           let provider = root["provider"] as? String,
           let model = root["modelId"] as? String {
            kind = .modelChange
            self.provider = provider
            self.model = model
            timestamp = 0
            return
        }

        guard type == "message",
              let message = root["message"] as? [String: Any],
              let role = message["role"] as? String,
              let milliseconds = message["timestamp"] as? NSNumber else { return nil }
        provider = message["provider"] as? String
        model = message["model"] as? String
        timestamp = milliseconds.doubleValue / 1000
        switch role {
        case "user":
            kind = .user
        case "assistant":
            guard let stopReason = message["stopReason"] as? String else { return nil }
            kind = .assistant(stopReason: stopReason)
        default:
            return nil
        }
    }
}
