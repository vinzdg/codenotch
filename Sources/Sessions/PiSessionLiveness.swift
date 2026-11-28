import Foundation

/// Is the agent behind a Pi session still running?
///
/// The session file cannot say. An agent that exits in the middle of a tool
/// call leaves `stopReason: toolUse` as its last record, and read on its own
/// that keeps the session working forever. The file is not held open either —
/// it is appended to and closed — so no `lsof` finds its owner.
///
/// Senpi-based agents (omo) register each session they own under
/// `<agent dir>/rpc/shards/*.meta.json` with the pid that created it, and that
/// is enough to tell. Plain Pi writes no such registry: its sessions come back
/// `.unknown`, for the caller to settle some other way.
final class PiSessionLiveness {
    enum State: Equatable {
        case alive
        case ended
        case unknown
    }

    private struct Owner {
        let sessionID: String
        let pid: Int32
        let createdAt: Date
    }

    private let registry: URL
    /// Parsed by file name. A meta file is written once, so only names not
    /// seen before are read; one that fails to parse (still being written) is
    /// read again on the next look.
    private var owners: [String: Owner] = [:]

    /// An agent registers a session a few seconds after it starts, or resumes,
    /// writing it. Until then a file written this recently has a live writer.
    static let registrationGrace: TimeInterval = 15

    init(registry: URL) {
        self.registry = registry
    }

    static func registry(forSessionsDirectory sessions: URL) -> URL {
        sessions.deletingLastPathComponent()
            .appendingPathComponent("rpc", isDirectory: true)
            .appendingPathComponent("shards", isDirectory: true)
    }

    func state(sessionPath: String) -> State {
        guard let id = Self.sessionID(path: sessionPath), refresh() else { return .unknown }
        let registrations = owners.values.filter { $0.sessionID == id }
        // A resumed session is registered again by its new process, so any
        // one of them still running is enough.
        if registrations.contains(where: Self.isRunning) || Self.writtenRecently(sessionPath) {
            return .alive
        }
        return registrations.isEmpty ? .unknown : .ended
    }

    private static func writtenRecently(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < registrationGrace
    }

    /// Pi names a session file `<timestamp>_<session id>.jsonl`.
    static func sessionID(path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".jsonl"), let underscore = name.lastIndex(of: "_") else { return nil }
        let id = name[name.index(after: underscore)..<name.index(name.endIndex, offsetBy: -6)]
        return id.isEmpty ? nil : String(id)
    }

    /// Once the owner exits its pid can be handed to an unrelated process, but
    /// that process necessarily started after the owner registered. A process
    /// at least as old as the registration is the owner itself.
    private static func isRunning(_ owner: Owner) -> Bool {
        guard let started = ProcessLiveness.startTime(pid: owner.pid) else { return false }
        return started <= owner.createdAt.addingTimeInterval(1)
    }

    private func refresh() -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: registry.path) else {
            owners.removeAll()
            return false
        }
        let metas = Set(names.filter { $0.hasSuffix(".meta.json") })
        owners = owners.filter { metas.contains($0.key) }
        for name in metas where owners[name] == nil {
            owners[name] = Self.parse(registry.appendingPathComponent(name))
        }
        return true
    }

    private static func parse(_ url: URL) -> Owner? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["owner_session_id"] as? String,
              let pid = (root["created_by_pid"] as? NSNumber)?.int32Value,
              let stamp = root["created_at"] as? String,
              let createdAt = timestamp.date(from: stamp) else { return nil }
        return Owner(sessionID: id, pid: pid, createdAt: createdAt)
    }

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
