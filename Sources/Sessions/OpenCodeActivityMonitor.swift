import Combine
import Foundation

/// Reads the opt-in OpenCode plugin's bounded state files. The journal lets a
/// busy → waiting → busy → idle sequence survive a single filesystem tick.
@MainActor
final class OpenCodeActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    nonisolated static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codenotch/OpenCode")
    }

    private let directory: URL
    private let providerID: String
    private let modelID: String
    private let isAlive: (Int32, Date) -> Bool
    private var timer: Timer?
    private var files: [String: OpenCodeActivityFile] = [:]
    private var watchingSince: Double

    init(providerID: String, modelID: String = "", directory: URL = OpenCodeActivityMonitor.directory,
         beganAt: Date = Date(),
         isAlive: @escaping (Int32, Date) -> Bool = {
             ProcessLiveness.isAlive(pid: $0, startedAt: $1)
         }) {
        self.providerID = providerID
        self.modelID = modelID
        self.directory = directory
        self.isAlive = isAlive
        self.watchingSince = beganAt.timeIntervalSince1970 * 1000
    }

    func start() {
        stop()
        watchingSince = Date().timeIntervalSince1970 * 1000
        rescan()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        files.removeAll()
        sessions = []
    }

    func rescan() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey])) ?? []
        // Crashed OpenCode processes can leave files behind. Prefer recent
        // producers and do not let dead/invalid files consume the live limit.
        let candidates = urls.filter { $0.pathExtension == "json" }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhs == rhs ? $0.path < $1.path : lhs > rhs
        }
        var found: [String: OpenCodeActivityEnvelope] = [:]
        for url in candidates.prefix(512) {
            if found.count == 64 { break }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true, let size = values.fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: url), data.count <= 1_048_576,
                  let envelope = try? JSONDecoder().decode(OpenCodeActivityEnvelope.self, from: data),
                  envelope.isValid,
                  isAlive(envelope.pid, Date(timeIntervalSince1970: envelope.startedAt / 1000))
            else { continue }
            found[url.path] = envelope
        }

        let removed = Set(files.keys).subtracting(found.keys)
        if !removed.isEmpty {
            for key in removed { files.removeValue(forKey: key) }
            publish()
        }
        for key in found.keys.sorted() {
            guard let envelope = found[key] else { continue }
            absorb(envelope, at: key)
        }
    }

    private func absorb(_ envelope: OpenCodeActivityEnvelope, at key: String) {
        var previous = files[key]
        if previous == nil, envelope.events.first?.sequence == 1,
           let first = envelope.events.first, first.at >= watchingSince {
            // A plugin file created after monitoring began is new live work,
            // not launch history. Replay even if the entire turn fit one tick.
            previous = OpenCodeActivityFile(envelope)
            previous?.sequence = 0
            previous?.sessions = [:]
        }
        if let previous, previous.instanceID == envelope.instanceID,
           previous.sequence == envelope.sequence { return }
        let pending = envelope.events.filter { $0.sequence > (previous?.sequence ?? 0) }
        let continuous = previous.map {
            $0.instanceID == envelope.instanceID && envelope.sequence > $0.sequence &&
                pending.first?.sequence == $0.sequence + 1 &&
                pending.last?.sequence == envelope.sequence
        } ?? false

        if continuous, var file = previous {
            for event in pending {
                if event.session.state == .ended {
                    file.sessions.removeValue(forKey: event.session.sessionID)
                } else {
                    file.sessions[event.session.sessionID] = event.session
                }
                file.sequence = event.sequence
                files[key] = file
                publish()
            }
        } else {
            // First sight, process restart, or journal overflow: seed the
            // current snapshot without replaying old completion alerts. A gap
            // must forget this source's previous states before reseeding.
            if previous != nil {
                files.removeValue(forKey: key)
                publish()
            }
            files[key] = OpenCodeActivityFile(envelope)
            publish()
        }
    }

    private func publish() {
        let next = files.values.flatMap { file -> [AgentSession] in
            var groups: [String: [OpenCodeActivityRecord]] = [:]
            for record in file.sessions.values {
                var root = record
                var visited: Set<String> = [record.sessionID]
                while let parent = root.parentID, let next = file.sessions[parent],
                      visited.insert(parent).inserted { root = next }
                // Orphaned helpers never masquerade as finished user requests.
                guard root.parentID == nil, root.providerID == providerID,
                      modelID.isEmpty || root.modelID == modelID else { continue }
                groups[root.sessionID, default: []].append(record)
            }
            return groups.compactMap { id, members in
                guard let root = file.sessions[id] else { return nil }
                let waiting = members.filter { $0.state == .waiting }.sorted { $0.since > $1.since }
                let busy = members.filter { $0.state == .busy }.sorted { $0.since > $1.since }
                let active = waiting.first ?? busy.first ?? root
                let state: AgentSession.State = !waiting.isEmpty ? .waiting : (!busy.isEmpty ? .busy : .idle)
                let reason: String? = state == .waiting
                    ? (active.reason == "question" ? L10n.t("Answer required") : L10n.t("Approval required")) : nil
                return AgentSession(id: "opencode.\(file.instanceID).\(id)", name: root.title,
                    detail: root.modelID.isEmpty ? "OpenCode" : "OpenCode · \(root.modelID)",
                    state: state, waitingFor: reason, since: Date(timeIntervalSince1970: active.since / 1000),
                    processID: file.pid)
            }
        }.sorted { $0.id < $1.id }
        if next != sessions { sessions = next }
    }
}

struct OpenCodeActivityRecord: Codable {
    enum State: String, Codable { case busy, waiting, idle, ended }
    let sessionID: String
    let parentID: String?
    let title: String
    let providerID: String
    let modelID: String
    let state: State
    let reason: String?
    let since: Double

    var isValid: Bool {
        !sessionID.isEmpty && sessionID.count <= 200 && (parentID?.count ?? 0) <= 200 &&
            title.count <= 200 && providerID.count <= 200 && modelID.count <= 200 &&
            since.isFinite && since > 0 && (reason == nil || reason == "approval" || reason == "question")
    }
}

struct OpenCodeActivityEnvelope: Codable {
    struct Event: Codable { let sequence: Int; let at: Double; let session: OpenCodeActivityRecord }
    let version: Int
    let instanceID: String
    let pid: Int32
    let startedAt: Double
    let sequence: Int
    let sessions: [OpenCodeActivityRecord]
    let events: [Event]

    var isValid: Bool {
        guard version == 1, UUID(uuidString: instanceID) != nil, pid > 0,
              startedAt.isFinite, startedAt > 0, sequence >= 0,
              sessions.count <= 64, events.count <= 256,
              Set(sessions.map(\.sessionID)).count == sessions.count,
              sessions.allSatisfy({ $0.isValid && $0.state != .ended }),
              events.allSatisfy({ $0.sequence > 0 && $0.sequence <= sequence && $0.at.isFinite && $0.at > 0 && $0.session.isValid })
        else { return false }
        for (a, b) in zip(events, events.dropFirst()) where b.sequence != a.sequence + 1 { return false }
        return events.isEmpty ? sequence == 0 : events.last?.sequence == sequence
    }
}

private struct OpenCodeActivityFile {
    let instanceID: String
    let pid: Int32
    var sequence: Int
    var sessions: [String: OpenCodeActivityRecord]

    init(_ envelope: OpenCodeActivityEnvelope) {
        instanceID = envelope.instanceID
        pid = envelope.pid
        sequence = envelope.sequence
        sessions = Dictionary(uniqueKeysWithValues: envelope.sessions.map { ($0.sessionID, $0) })
    }
}

/// Custom Endpoints can be added, edited and disconnected after launch. Keep
/// their opt-in monitors separate from the fixed built-in monitor dictionary.
@MainActor
final class OpenCodeActivityBridge {
    private var monitors: [String: OpenCodeActivityMonitor] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]
    private var configurations: [String: String] = [:]
    private let onSessions: (String, [AgentSession]) -> Void

    init(onSessions: @escaping (String, [AgentSession]) -> Void) {
        self.onSessions = onSessions
    }

    func configure(endpoints: [CustomEndpoint], enabled: Set<String>) {
        let wanted = endpoints.filter {
            $0.isEnabled && enabled.contains($0.providerID) && !($0.openCodeProviderID ?? "").isEmpty
        }
        let ids = Set(wanted.map(\.providerID))
        for id in Set(monitors.keys).subtracting(ids) { remove(id) }
        for endpoint in wanted {
            let id = endpoint.providerID
            let provider = endpoint.openCodeProviderID ?? ""
            let configuration = provider + "\u{1}" + endpoint.selectedModel
            guard configurations[id] != configuration else { continue }
            remove(id)
            let monitor = OpenCodeActivityMonitor(providerID: provider, modelID: endpoint.selectedModel)
            monitors[id] = monitor
            configurations[id] = configuration
            subscriptions[id] = monitor.sessionsPublisher.sink { [weak self] in self?.onSessions(id, $0) }
            monitor.start()
        }
    }

    func stop() { for id in Array(monitors.keys) { remove(id) } }

    private func remove(_ id: String) {
        subscriptions.removeValue(forKey: id)?.cancel()
        monitors.removeValue(forKey: id)?.stop()
        configurations.removeValue(forKey: id)
        onSessions(id, [])
    }
}
