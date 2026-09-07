import AppKit
import Combine
import Foundation

/// Watches one profile's `sessions` directory — `~/.claude/sessions` by
/// default — and publishes the Claude Code sessions that are actually running.
/// One monitor per `ClaudeProfile`; see `AppDelegate`.
///
/// The directory is watched rather than polled, because Claude Code writes a
/// session file the moment its state changes — so "Claude just finished" shows
/// up immediately. A slow timer runs alongside purely to notice processes that
/// died without touching the directory, which no file event will ever report.
@MainActor
final class ClaudeSessionMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let directory: URL
    private let livenessInterval: TimeInterval

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var livenessTimer: Timer?
    private var debounce: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    init(
        directory: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/sessions"),
        livenessInterval: TimeInterval = 5
    ) {
        self.directory = directory
        self.livenessInterval = livenessInterval
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
        let found = Self.read(directory: directory)
        guard found != sessions else { return }   // don't churn SwiftUI for nothing
        sessions = found
    }

    static func read(directory: URL) -> [AgentSession] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> AgentSession? in
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let record = ClaudeSessionRecord(json: json),
                      ProcessLiveness.isAlive(pid: record.pid, startedAt: record.startedAt)
                else { return nil }
                return record.session
            }
            .sorted { $0.since > $1.since }
    }
}
