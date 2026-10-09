import AppKit
import Combine
import Foundation

/// Watches one profile's `sessions` directory — `~/.claude/sessions` by
/// default — and publishes the Claude Code sessions that are actually running.
/// One monitor per `ClaudeProfile`; see `AppDelegate`.
///
/// The directory is watched rather than polled, because a session file appears
/// and disappears the moment a session starts and stops. The timer alongside it
/// covers the two things no file event will report: a process that died without
/// touching the directory, and — for sessions the Claude desktop app hosts —
/// what the session is *doing*, which is not in the directory at all and has to
/// be read from the transcript. See `ClaudeTranscript` for why.
@MainActor
final class ClaudeSessionMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let directory: URL
    private let livenessInterval: TimeInterval
    /// Nil leaves the monitor reading nothing but the registry, which is what
    /// the tests that only care about the registry want.
    private let transcripts: ClaudeTranscriptReader?

    /// Sessions to leave out because Codenotch started them, not the user.
    ///
    /// Renewing the OAuth token runs the Claude CLI, and the CLI registers a
    /// session file for the second or so it is alive, exactly like any other
    /// session. Without this the notch grows a seventh row that nobody asked
    /// for, and — worse — `isBusy` can read it as work in progress and start
    /// polling usage hard on the strength of it.
    ///
    /// The pid alone is enough: checked on this machine, the file the CLI
    /// writes carries the pid of the process Codenotch spawned, with no fork in
    /// between. See `ClaudeTokenRefresher`.
    var ignoredPIDs: () -> Set<Int32> = { [] }

    /// Working directories whose sessions are Codenotch's own, matched as a
    /// second net under the pids: the `/usage` probe runs in
    /// `ClaudeUsageCLI.scratchDirectory`, and a session filed from there is
    /// never the user's, whichever process wrote it.
    var ignoredWorkingDirectories: Set<String> = []

    /// Who owns a session the Claude desktop app hosts, when there is more than
    /// one Claude account on the machine. Nil leaves every record with the
    /// directory it was found in, which is what a single-profile machine and
    /// every test that predates this want. See `ClaudeSessionOwnership`.
    ///
    /// Only this profile's own directory is *watched*; a session adopted from
    /// another profile's directory arrives on the next liveness tick instead,
    /// two seconds later. Deliberate: a second descriptor per profile per
    /// profile is a lot of machinery to save a delay nobody can see, and the
    /// timer is already what covers everything a file event cannot report.
    var ownership: ClaudeSessionOwnership?

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var livenessTimer: Timer?
    private var debounce: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    /// `livenessInterval` doubles as how often a running session's transcript
    /// is looked at, so it matches the Codex monitor's two seconds rather than
    /// the five it used when the registry was the only thing being read. The
    /// cost of a tick is a `stat` per live session; the tail is read only when
    /// the file has grown.
    init(
        directory: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/sessions"),
        projects: URL? = nil,
        livenessInterval: TimeInterval = 2
    ) {
        self.directory = directory
        self.livenessInterval = livenessInterval
        self.transcripts = projects.map { ClaudeTranscriptReader(projects: $0) }
    }

    func start() {
        // Not idempotent by construction: a second descriptor and a second
        // timer would stack on the first pair, so stop whatever is running.
        // (`AntigravityActivityMonitor` does the same.)
        stop()
        rescan()
        watchDirectory()

        let timer = Timer(timeInterval: livenessInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        livenessTimer = timer
    }

    func stop() {
        livenessTimer?.invalidate()
        livenessTimer = nil
        debounce?.cancel()
        source?.cancel()
        source = nil
    }

    private func watchDirectory() {
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }   // no directory yet; the timer still covers us

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source.resume()
        self.source = source
    }

    /// A single state change can produce several file events; coalesce them.
    private func scheduleRescan() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func rescan() {
        let found = Self.read(directory: directory, transcripts: transcripts,
                              ignoring: ignoredPIDs(),
                              ignoringDirectories: ignoredWorkingDirectories,
                              ownership: ownership)
        guard found != sessions else { return }   // don't churn SwiftUI for nothing
        // Only on a change, so this is a handful of lines an hour rather than a
        // firehose. It is the one way to see what the notch thinks is running
        // without hovering over it:
        //
        //     log stream --predicate 'category == "sessions"' --level debug
        let summary = found.map { "\($0.name)=\($0.state)" }.joined(separator: " ")
        Log.sessions.debug("\(ClaudeProfile.tilde(self.directory.path), privacy: .public): \(summary, privacy: .public)")
        sessions = found
    }

    /// Every session this profile should draw.
    ///
    /// With no `ownership` this is exactly what it always was: the records in
    /// `directory`, nothing else. With one, the registry files of *every*
    /// profile are read and each desktop-hosted record goes to the profile
    /// whose account actually hosts it — which is not the profile whose
    /// directory it sits in, because the desktop app files them all under the
    /// default. A record whose account cannot be established is left exactly
    /// where it was found, so an unreadable index costs nothing but the
    /// old behaviour.
    static func read(directory: URL,
                     transcripts: ClaudeTranscriptReader? = nil,
                     ignoring: Set<Int32> = [],
                     ignoringDirectories: Set<String> = [],
                     ownership: ClaudeSessionOwnership? = nil,
                     isAttended: (Int32) -> Bool = ClaudeSessionMonitor.isAttended(pid:))
    -> [AgentSession] {
        let sources = ownership?.directories ?? [directory]

        var live: [ClaudeSessionRecord] = []
        /// Which directory each record came from: an adopted session's
        /// transcript stays where the session writes it, not where its ring is.
        var origin: [Int32: URL] = [:]

        for source in sources {
            for record in records(in: source, ignoring: ignoring,
                                  ignoringDirectories: ignoringDirectories,
                                  isAttended: isAttended) {
                if let ownership, !ownership.claims(record, foundIn: source) { continue }
                live.append(record)
                origin[record.pid] = source
            }
        }

        return deduplicated(live)
            .map { record in
                let reader = origin[record.pid].flatMap { ownership?.reader(for: $0) }
                    ?? transcripts
                return state(of: record, transcripts: reader)
            }
            // The id breaks ties so the order cannot flicker between two ticks
            // that read the same thing.
            .sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    /// The live records in one profile's `sessions` directory.
    ///
    /// `ignoringDirectories` is the second net under the pids: a session filed
    /// from Codenotch's own `/usage` scratch directory is never the user's,
    /// whichever profile's directory it turns up in. `isAttended` is asked only
    /// of the sessions a program started, and leaves out the ones nobody is at.
    ///
    /// A session suspended with ctrl-Z is left out until it is resumed. Its
    /// file stays and its process is alive, but nobody has it open: one seen on
    /// a real machine sat stopped for a day behind the session resumed in the
    /// same tab, drawn as an idle row nobody could find.
    static func records(in directory: URL, ignoring: Set<Int32> = [],
                        ignoringDirectories: Set<String> = [],
                        isAttended: (Int32) -> Bool = ClaudeSessionMonitor.isAttended(pid:))
    -> [ClaudeSessionRecord] {
        let ignoredDirectories = Set(ignoringDirectories.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> ClaudeSessionRecord? in
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let record = ClaudeSessionRecord(json: json),
                      !ignoring.contains(record.pid),
                      !ignoredDirectories.contains(URL(fileURLWithPath: record.cwd).standardizedFileURL.path),
                      ProcessLiveness.isAlive(pid: record.pid, startedAt: record.startedAt),
                      !ProcessLiveness.isStopped(pid: record.pid),
                      !record.isFromSDK || isAttended(record.pid)
                else { return nil }
                return record
            }
    }

    /// Whether somebody can be at this session: it has a terminal, or an
    /// application somewhere above it.
    ///
    /// Asked only of the sessions a program started (`isFromSDK`), because those
    /// are not always anybody's. claude-mem's worker runs a headless Claude Code
    /// for every session it observes, with no terminal and a daemon parented to
    /// launchd above it. Each of those ran `busy`, fell `idle` and was announced
    /// as a turn of yours that finished — seven times in a hundred seconds on a
    /// real machine. `claude -p` typed into a terminal has that terminal, and an
    /// editor driving Claude Code through the SDK has its own application above
    /// it, so both stay.
    nonisolated static func isAttended(pid: Int32) -> Bool {
        SessionFocus.tty(of: pid) != nil || SessionFocus.owningApp(of: pid) != nil
    }

    /// The record's own answer where it has one, the transcript's where it does
    /// not. Desktop sessions always take the second path; terminal ones never
    /// do, which is what keeps their `waiting` state — the one thing only the
    /// terminal interface knows — exactly as it was.
    static func state(of record: ClaudeSessionRecord,
                      transcripts: ClaudeTranscriptReader?) -> AgentSession {
        guard !record.reportsStatus,
              let sessionID = record.sessionID,
              let activity = transcripts?.activity(sessionID: sessionID, cwd: record.cwd)
        else { return record.session }
        return record.session(state: activity.turn == .inFlight ? .busy : .idle,
                              since: activity.since)
    }

    /// One session can hold two registry records at once: resuming after a
    /// crash registers a new pid while the old process is still winding down,
    /// and for a moment both files pass the liveness check. Claude Code settles
    /// this by keeping the most recently started record, so the notch does the
    /// same rather than drawing one session twice.
    static func deduplicated(_ records: [ClaudeSessionRecord]) -> [ClaudeSessionRecord] {
        var newest: [String: ClaudeSessionRecord] = [:]
        var unidentified: [ClaudeSessionRecord] = []
        for record in records {
            guard let id = record.sessionID else { unidentified.append(record); continue }
            let candidate = record.startedAt ?? .distantPast
            if let held = newest[id], (held.startedAt ?? .distantPast) >= candidate { continue }
            newest[id] = record
        }
        return Array(newest.values) + unidentified
    }
}
