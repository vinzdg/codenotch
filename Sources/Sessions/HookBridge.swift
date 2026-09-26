import Combine
import Foundation

/// The requests Claude Code is waiting on the notch for, oldest first.
///
/// Owns the `HookBridgeServer` and the one reply each request is owed. A
/// request leaves the list exactly once: answered here, cancelled by Claude
/// Code closing the connection, or handed back to the terminal after
/// `giveUpAfter` — a card nobody looks at must not hold a session forever.
@MainActor
final class HookBridge: ObservableObject {
    @Published private(set) var pending: [PermissionRequest] = []

    // ponytail: fixed; a preference if five minutes turns out wrong for someone.
    private let giveUpAfter: TimeInterval
    private var replies: [UUID: HookBridgeServer.Reply] = [:]
    private var server: HookBridgeServer?
    private var watch: Timer?
    /// Every profile's `sessions` directory, where a request's session id is
    /// matched to the process that asked — see `processID(forSession:)`.
    private let sessionDirectories: [URL]

    init(giveUpAfter: TimeInterval = 300, sessionDirectories: [URL] = []) {
        self.giveUpAfter = giveUpAfter
        self.sessionDirectories = sessionDirectories
    }

    /// The transcript of `sessionID`, for hosts whose hook payload leaves
    /// `transcript_path` out (Zed's did). Every session writes
    /// `<profile>/projects/<folder>/<session id>.jsonl`, whatever launched it;
    /// the profile is the parent of each `sessions` directory.
    nonisolated static func transcript(forSession sessionID: String, in sessionDirectories: [URL]) -> String? {
        guard !sessionID.isEmpty else { return nil }
        let fileManager = FileManager.default
        for sessions in sessionDirectories {
            let projects = sessions.deletingLastPathComponent().appendingPathComponent("projects")
            let folders = (try? fileManager.contentsOfDirectory(atPath: projects.path)) ?? []
            for folder in folders {
                let candidate = projects.appendingPathComponent(folder).appendingPathComponent("\(sessionID).jsonl")
                if fileManager.fileExists(atPath: candidate.path) { return candidate.path }
            }
        }
        return nil
    }

    /// The pid of the Claude Code process running `sessionID`, from its
    /// registry file (`<pid>.json`, which records `sessionId`). A handful of
    /// small files, read once per request.
    nonisolated static func processID(forSession sessionID: String, in directories: [URL]) -> pid_t? {
        guard !sessionID.isEmpty else { return nil }
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["sessionId"] as? String == sessionID,
                      let pid = (json["pid"] as? NSNumber)?.int32Value else { continue }
                return pid
            }
        }
        return nil
    }

    func start(port: Int = HookBridgeServer.defaultPort) {
        guard server == nil else { return }
        let server = HookBridgeServer(
            onRequest: { [weak self] request, reply in
                Task { @MainActor in self?.receive(request, reply: reply) }
            },
            onCancel: { [weak self] id in
                Task { @MainActor in self?.remove(id) }
            }
        )
        self.server = server
        Task {
            do {
                let bound = try await server.start(port: port)
                Log.sessions.info("hook bridge listening on \(bound, privacy: .public)")
            } catch {
                Log.sessions.error("hook bridge failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() async {
        for id in replies.keys { answer(id, .passThrough) }
        await server?.stop()
        server = nil
    }

    func answer(_ id: UUID, _ decision: PermissionDecision) {
        replies[id]?(decision)
        remove(id)
    }

    func receive(_ request: PermissionRequest, reply: @escaping HookBridgeServer.Reply) {
        var request = request
        request.processID = Self.processID(forSession: request.sessionID, in: sessionDirectories)
        request.appName = request.processID.flatMap { SessionFocus.owningApp(of: $0)?.localizedName }
        if request.transcriptPath == nil {
            request.transcriptPath = Self.transcript(forSession: request.sessionID, in: sessionDirectories)
        }
        Log.sessions.info("permission request \(request.id, privacy: .public): session=\(request.sessionID, privacy: .public) project=\(request.project, privacy: .public) pid=\(request.processID ?? -1) app=\(request.appName ?? "none", privacy: .public) transcript=\(request.transcriptPath ?? "none", privacy: .public)")
        replies[request.id] = reply
        pending.append(request)
        watchForAnswersElsewhere()
        DispatchQueue.main.asyncAfter(deadline: .now() + giveUpAfter) { [weak self] in
            MainActor.assumeIsolated { self?.answer(request.id, .passThrough) }
        }
    }

    private func remove(_ id: UUID) {
        replies[id] = nil
        pending.removeAll { $0.id == id }
        if pending.isEmpty {
            watch?.invalidate()
            watch = nil
        }
    }

    /// Answering in the terminal does not close the hook's connection — Claude
    /// Code only drops it when the process exits (checked against 2.1.282) —
    /// so the card would outlive the prompt by minutes. What does happen, the
    /// instant it is answered anywhere, is a `tool_result` for that tool call
    /// in the transcript. Checked once a second, and only while something is
    /// pending.
    private func watchForAnswersElsewhere() {
        guard watch == nil else { return }
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for request in self.pending where Self.answeredElsewhere(request) {
                    Log.sessions.info("permission request \(request.id, privacy: .public) answered elsewhere")
                    self.answer(request.id, .passThrough)
                }
            }
        }
    }

    nonisolated static func answeredElsewhere(_ request: PermissionRequest) -> Bool {
        guard let path = request.transcriptPath,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        // The result lands at the end; the tail is all that needs reading.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let tail = try? handle.readToEnd(),
              let id = request.toolUseID ?? toolUseID(in: tail, input: request.toolInput) else { return false }
        return tail.range(of: Data("\"tool_use_id\":\"\(id)\"".utf8)) != nil
    }

    /// Under the Agent SDK (Zed, and checked against 2.1.280) the payload has
    /// no `tool_use_id`, and the hook's connection stays open until the whole
    /// session ends. The call is found instead by its input: the latest
    /// `tool_use` in the transcript whose input is exactly the one asked about.
    nonisolated static func toolUseID(in transcript: Data, input: [String: JSONValue]) -> String? {
        let decoder = JSONDecoder()
        for line in transcript.split(separator: UInt8(ascii: "\n")).reversed()
        where line.range(of: Data("\"tool_use\"".utf8)) != nil {
            guard case .object(let row)? = try? decoder.decode(JSONValue.self, from: Data(line)),
                  case .object(let message)? = row["message"],
                  case .array(let content)? = message["content"] else { continue }
            for case .object(let block) in content
            where block["type"]?.string == "tool_use" && block["input"] == .object(input) {
                if let id = block["id"]?.string { return id }
            }
        }
        return nil
    }
}
