import Combine
import Foundation

/// Notices when Gemini CLI is working.
///
/// Its chat recordings hold no pid — nothing in the JSONL names the process —
/// so `ProcessLiveness` has nothing to verify and recency is the only signal
/// there is. It is a good one: the CLI appends a `$set lastUpdated` patch on
/// every message, so a file written moments ago is a turn in progress. Cursor
/// and Antigravity stand on the same substitute.
///
/// Only Gemini CLI gets a monitor. OpenCode and Hermes keep their token counts
/// in databases that are written for reasons that have nothing to do with a
/// Gemini call, so their modification dates would report work that is not this
/// provider's.
final class GeminiCLIActivityMonitor: AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let root: URL
    private let interval: TimeInterval
    /// How recently a session file must have been written to count as live.
    /// Generous, because a model can think for a while between two lines.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(root: URL = GeminiCLIUsage.sessionsRoot,
         interval: TimeInterval = 2,
         staleAfter: TimeInterval = 45) {
        self.root = root
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        stop()
        poll()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let found = Self.read(root: root, staleAfter: staleAfter)
        guard found != sessions else { return }
        sessions = found
    }

    static func read(root: URL, staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        var newest: (session: URL, project: URL, modified: Date)?
        for project in projects {
            let chats = project.appendingPathComponent("chats")
            guard let files = try? manager.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let modified = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate else { continue }
                if newest == nil || modified > newest!.modified {
                    newest = (file, project, modified)
                }
            }
        }

        // An older session is a finished turn, and showing it as work in
        // progress would be a guess dressed as a fact.
        guard let newest, now.timeIntervalSince(newest.modified) <= staleAfter else { return [] }
        return [AgentSession(
            id: "gemini-api.\(newest.session.deletingPathExtension().lastPathComponent)",
            name: "Gemini CLI",
            detail: "Working in \(projectName(of: newest.project))",
            state: .busy,
            waitingFor: nil,
            since: newest.modified
        )]
    }

    /// The directory is named after a hash of the working directory, which says
    /// nothing to whoever reads the tooltip; the CLI writes the path that hash
    /// stands for beside it, and the last component of that path is the folder
    /// the user knows the project by.
    private static func projectName(of project: URL) -> String {
        let marker = project.appendingPathComponent(".project_root")
        if let text = try? String(contentsOf: marker, encoding: .utf8) {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return URL(fileURLWithPath: path).lastPathComponent }
        }
        return project.lastPathComponent
    }
}
