import AppKit
import Combine
import Foundation
import SQLite3

/// Reads what Cursor's agents are doing from the editor's own state store.
///
/// Cursor publishes no session registry the way Claude Code does, but its
/// `composerHeaders` rows carry the two facts that matter:
///
/// - `unfinishedRunAt` — set while a run is in flight, cleared when it finishes.
/// - `hasBlockingPendingActions` / `hasPendingPlan` — set when it wants you.
///
/// The database is in **WAL mode**, so it must be opened without `immutable`:
/// that flag tells SQLite to ignore the write-ahead log, which means reading
/// whatever was true at the last checkpoint. It is the difference between a
/// spinner that tracks the agent and one that lags minutes behind.
@MainActor
final class CursorActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let store: URL
    private let interval: TimeInterval
    /// How long a conversation may go without being written to before its run
    /// is treated as over.
    ///
    /// Measured over 33,484 gaps between consecutive writes inside a run on a
    /// real store: p50 0.7s, p99 38.1s, p99.9 239.3s, longest 826.0s. So the
    /// window has to clear fourteen minutes to never cut a live run, and the
    /// asymmetry says to clear it: dropping the spinner on an agent that is
    /// still working is visible on the headline surface, while an abandoned run
    /// lingering another five minutes is not — and the killed-editor case,
    /// which is the one that used to linger for ever, is now retired instantly
    /// by the launch check rather than by waiting this out.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(store: URL = CursorCredentials.storeURL,
         interval: TimeInterval = 2,
         staleAfter: TimeInterval = 15 * 60) {
        self.store = store
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        rescan()
        // Polled rather than watched: the interesting writes land in the WAL
        // sidecar, and a directory event tells us a byte moved, not that a run
        // started. Two seconds is well inside "did that finish yet?".
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
        let found = Self.read(store: store, cursorLaunchedAt: Self.cursorLaunchDate(),
                              staleAfter: staleAfter)
        guard found != sessions else { return }
        sessions = found
    }

    /// When the running editor started, or nil if Cursor is not running at all.
    ///
    /// The same question `ProcessLiveness` answers for agents that write a pid —
    /// "does the process that claimed this still exist?" — asked the only way a
    /// composer row allows, since it records no pid: against the editor as a
    /// whole. `session(fromHeader:...)` below says what it is needed for.
    ///
    /// A bundle-id miss would be indistinguishable from a closed editor and
    /// would silently retire every Cursor row for ever, so fall back to the
    /// bundle name. `launchDate` needs the same care for a different reason: it
    /// is optional and usually absent — of 123 running applications on the
    /// machine this was written on, 105 had none, Finder and Chrome among them.
    /// "Running, start time unknown" must not collapse into "not running", so it
    /// answers `.distantPast`: every row then predates it and the staleness
    /// window alone decides, which is the behaviour we had before this check.
    static func cursorLaunchDate() -> Date? {
        let running = NSWorkspace.shared.runningApplications
        let cursor = running.first { $0.bundleIdentifier == CursorCredentials.bundleID }
            ?? running.first { $0.bundleURL?.lastPathComponent == "Cursor.app" }
        return launchDate(found: cursor != nil, launchDate: cursor?.launchDate)
    }

    /// The two-state answer above, split out because `NSRunningApplication`
    /// cannot be built in a test and this is the half worth pinning.
    static func launchDate(found: Bool, launchDate: Date?) -> Date? {
        guard found else { return nil }
        return launchDate ?? .distantPast
    }

    static func read(store: URL, cursorLaunchedAt: Date?,
                     staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        guard let db = SQLiteStore.open(store) else { return [] }
        defer { sqlite3_close(db) }

        let values = SQLiteStore.rows(
            in: db,
            sql: "SELECT value FROM composerHeaders WHERE isArchived = 0 ORDER BY recency DESC LIMIT 40"
        )
        return values
            .compactMap {
                session(fromHeader: $0, cursorLaunchedAt: cursorLaunchedAt,
                        staleAfter: staleAfter, now: now)
            }
            .sorted { $0.since > $1.since }
    }

    /// Only sessions that are *doing* something are worth a row — an editor
    /// with forty idle chats in its history is not forty things happening.
    ///
    /// `unfinishedRunAt` is set when a run begins and cleared when it ends, but
    /// two things leave it set on a run that is over and neither clears it: the
    /// editor killed mid-run, and a run abandoned with the editor still up.
    ///
    /// It cannot date either of them. Measured against a real store, its value
    /// is the *composer's creation time*, not the current run's: one row there
    /// has two user turns seven minutes apart, was killed during the second,
    /// and still reports the first. So it is a flag, and the timestamp that
    /// answers "is this still going" has to be
    /// `conversationCheckpointLastUpdatedAt`, which Cursor moves on every
    /// message and tool result (falling back to `lastUpdatedAt`, which a
    /// quarter of rows carry instead).
    ///
    /// That one timestamp settles both cases:
    ///
    /// - Written before the editor's current launch, it belongs to a process
    ///   that is already gone — as does everything, when Cursor is not running
    ///   at all and `cursorLaunchedAt` is nil.
    /// - Written longer than `staleAfter` ago, the conversation has stopped
    ///   being written to, which is the only evidence an abandoned run leaves.
    static func session(fromHeader json: String,
                        cursorLaunchedAt: Date?,
                        staleAfter: TimeInterval,
                        now: Date = Date()) -> AgentSession? {
        guard let data = json.data(using: .utf8),
              let head = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = head["composerId"] as? String
        else { return nil }

        let blocked = (head["hasBlockingPendingActions"] as? Bool) == true
            || (head["hasPendingPlan"] as? Bool) == true
        let runStart = date(head["unfinishedRunAt"])
        // A quarter of rows carry `lastUpdatedAt` and no checkpoint at all.
        let lastWrite = date(head["conversationCheckpointLastUpdatedAt"])
            ?? date(head["lastUpdatedAt"])

        let isRunning: Bool = {
            guard let runStart, let cursorLaunchedAt else { return false }
            // Nothing written yet means the composer was only just created, and
            // since `unfinishedRunAt` *is* its creation time that is the most
            // recent thing to have happened to it. The same value on a chat
            // opened last week is correctly stale.
            let touched = lastWrite ?? runStart
            guard touched >= cursorLaunchedAt else { return false }
            return now.timeIntervalSince(touched) <= staleAfter
        }()

        let state: AgentSession.State
        if blocked { state = .waiting }
        else if isRunning { state = .busy }
        else { return nil }

        // `runStart` is the composer's creation time, so it dates a busy row the
        // way it always has — from when the chat began. A row that is merely
        // waiting must not borrow it: a session blocked since this morning did
        // not start waiting when the chat was opened last week.
        let since = (isRunning ? runStart : nil)
            ?? lastWrite
            ?? date(head["createdAt"])
            ?? now

        return AgentSession(
            id: "cursor.\(id)",
            name: (head["name"] as? String) ?? "Untitled chat",
            detail: (head["subtitle"] as? String) ?? "Cursor",
            state: state,
            waitingFor: blocked ? "needs your input" : nil,
            since: since,
            focusTarget: .application(bundleID: CursorCredentials.bundleID)
        )
    }

    /// Cursor writes its timestamps as milliseconds since the epoch.
    private static func date(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }
}
