import AppKit
import Combine
import Foundation

/// Reports whether Codex is mid-turn.
///
/// Codex publishes no status field — no equivalent of Claude Code's `status` or
/// Cursor's `unfinishedRunAt`. What it does do is append to a thread's rollout
/// log continuously while a turn runs, so a rollout written moments ago means
/// work is happening now.
///
/// **That is a heuristic, and it is labelled as one.** It cannot tell a turn
/// that is thinking from one that finished a second ago, so it errs short: the
/// ring stops spinning `staleAfter` seconds after the last write rather than
/// claiming activity it cannot see. If Codex grows a real status field this
/// should be replaced by it.
@MainActor
final class CodexActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let stateStore: URL
    private let desktopStore: URL
    private let interval: TimeInterval
    /// How long after the last write a turn is still considered in flight.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(
        stateStore: URL = CodexStore.stateURL,
        desktopStore: URL = CodexStore.desktopStoreURL,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 8
    ) {
        self.stateStore = stateStore
        self.desktopStore = desktopStore
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
        let found = Self.read(stateStore: stateStore, desktopStore: desktopStore,
                              staleAfter: staleAfter)
        guard found != sessions else { return }
        sessions = found
    }

    static func read(stateStore: URL, desktopStore: URL,
                     staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        // Both surfaces, because "Codex" is two programs that record their work
        // in different places: the CLI and the VS Code extension append to a
        // rollout, and the desktop app writes to its own catalogue. Whichever
        // moved last is the one that is working.
        var candidates: [(id: String, name: String, at: Date, focusTarget: AgentSession.FocusTarget?)] = []

        if let rollout = CodexStore.newestRollout(in: stateStore),
           let modified = (try? FileManager.default
               .attributesOfItem(atPath: rollout.path))?[.modificationDate] as? Date {
            candidates.append((id: "codex.\(rollout.lastPathComponent)",
                               name: "Codex", at: modified, focusTarget: nil))
        }
        if let desktop = CodexStore.newestDesktopThread(in: desktopStore) {
            candidates.append((id: "codex.desktop", name: desktop.title,
                               at: desktop.updatedAt,
                               focusTarget: .application(bundleID: "com.openai.chat")))
        }

        guard let newest = candidates.max(by: { $0.at < $1.at }),
              let session = session(id: newest.id, name: newest.name,
                                    modified: newest.at, staleAfter: staleAfter, now: now,
                                    focusTarget: newest.focusTarget)
        else { return [] }
        return [session]
    }

    /// Only work recorded within the window counts. Anything older is a
    /// finished turn, and reporting it as work in progress would be a guess
    /// dressed as a fact.
    static func session(
        id: String, name: String, modified: Date, staleAfter: TimeInterval, now: Date,
        focusTarget: AgentSession.FocusTarget? = nil
    ) -> AgentSession? {
        guard now.timeIntervalSince(modified) <= staleAfter else { return nil }
        return AgentSession(
            id: id,
            name: name,
            detail: "Working",
            state: .busy,
            waitingFor: nil,
            since: modified,
            focusTarget: focusTarget
        )
    }
}
