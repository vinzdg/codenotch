import Combine
import Foundation
import os

/// Everything LM Studio says about its models beyond the listing, gathered
/// from two places and published as one: the SDK socket for what each instance
/// is doing this instant, and the server log for what every finished request
/// cost. Nothing here sends a prompt or sits in the inference traffic — the
/// runtime writes both on its own, and this only reads. That is why LM Studio
/// needs no relay where Ollama does.
///
/// Speed comes from the log when the runtime clocked the response itself
/// (`/api/v0`, `/api/v1`), and otherwise from the length of the `generating`
/// phase as polled here, against the log's token count. The second figure is
/// marked approximate: the poll interval is its resolution.
@MainActor
final class LMStudioMetrics: ObservableObject {
    @Published private(set) var status = L10n.t("Off")
    /// The socket answered; what each instance is doing is being read.
    @Published private(set) var linked = false
    /// Every existing log file has been read into the ledger.
    @Published private(set) var historyLoaded = false
    /// Keyed by notch cell id.
    @Published private(set) var activities: [String: LocalModelActivity] = [:]
    @Published private(set) var performances: [String: LocalModelPerformance] = [:]
    @Published private(set) var ledger = LocalTokenLedger()

    static let providerID = "lmstudio"
    static func cellID(instance: String) -> String { "\(providerID):model:\(instance)" }

    /// A model reading a prompt or generating counts as work in progress, the
    /// same way an agent's busy session does.
    var isBusy: Bool { !activities.isEmpty }

    private let makeLink: @MainActor (URL) -> any LMStudioCalling
    private let logsDirectory: URL
    private let pollInterval: TimeInterval
    private let inventoryInterval: TimeInterval
    private let logInterval: TimeInterval
    private let now: () -> Date
    private let calendar: Calendar
    private var link: (any LMStudioCalling)?
    /// What `listLoaded` last said, and when. The state call is not written to
    /// LM Studio's log; the listing is, once per call, so it is asked rarely.
    private var instances: (at: Date, loaded: [LMStudioLoadedInstance])?
    private var pollTimer: Timer?
    private var logTimer: Timer?
    private var poll: Task<Void, Never>?
    private var history: Task<Void, Never>?
    private var tail: LMStudioLogTail?
    private var revision = 0
    private var retryAfter = Date.distantPast
    /// When each instance entered `generating`, and the last interval it spent there.
    private var generating: [String: Date] = [:]
    private var finished: [String: (start: Date, end: Date)] = [:]
    private var credentialObserver: NSObjectProtocol?

    init(makeLink: @escaping @MainActor (URL) -> any LMStudioCalling = { endpoint in
             LMStudioLink(endpoint: endpoint, token: { LMStudioCredentials.load() })
         },
         logsDirectory: URL = LMStudioEndpoint.serverLogsDirectory(),
         pollInterval: TimeInterval = 0.4, inventoryInterval: TimeInterval = 5,
         logInterval: TimeInterval = 1,
         now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.makeLink = makeLink
        self.logsDirectory = logsDirectory
        self.pollInterval = pollInterval
        self.inventoryInterval = inventoryInterval
        self.logInterval = logInterval
        self.now = now
        self.calendar = calendar
        self.ledger = LocalTokenLedger(calendar: calendar)
    }

    func configure(enabled: Bool, endpoint: String) {
        revision += 1
        tearDown()
        guard enabled else { status = L10n.t("Off"); return }
        guard let url = try? LMStudioEndpoint.parse(endpoint) else {
            status = LMStudioError.invalidEndpoint.localizedDescription
            return
        }
        link = makeLink(url)
        status = L10n.t("Connecting…")
        startPolling()
        startLog()
        // A token pasted into Settings should take effect now, not at relaunch:
        // dropping the socket makes the next poll authenticate afresh.
        credentialObserver = NotificationCenter.default.addObserver(
            forName: LMStudioCredentials.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relink() }
        }
    }

    func stop() {
        revision += 1
        tearDown()
        status = L10n.t("Off")
    }

    private func tearDown() {
        pollTimer?.invalidate()
        pollTimer = nil
        logTimer?.invalidate()
        logTimer = nil
        poll?.cancel()
        poll = nil
        history?.cancel()
        history = nil
        if let link { Task { await link.close() } }
        link = nil
        if let credentialObserver { NotificationCenter.default.removeObserver(credentialObserver) }
        credentialObserver = nil
        tail = nil
        instances = nil
        generating = [:]
        finished = [:]
        retryAfter = .distantPast
        linked = false
        historyLoaded = false
        if !activities.isEmpty { activities = [:] }
        if !performances.isEmpty { performances = [:] }
        // In the same calendar, or a reset would quietly switch the ledger back
        // to `.current` and file the next day under a different key.
        if !ledger.isEmpty { ledger = LocalTokenLedger(calendar: calendar) }
    }

    private func relink() {
        guard let link else { return }
        Task { await link.close() }
        retryAfter = .distantPast
    }

    // MARK: - What each instance is doing

    private func startPolling() {
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollNow()
    }

    private func pollNow() {
        guard poll == nil, let link, now() >= retryAfter else { return }
        let revision = self.revision
        let known = instances.flatMap { now().timeIntervalSince($0.at) < inventoryInterval ? $0.loaded : nil }
        poll = Task { [weak self] in
            let outcome = await Self.read(link, known: known)
            guard let self else { return }
            self.poll = nil
            guard self.revision == revision else { return }
            switch outcome {
            case .success(let (instances, states)):
                if known == nil { self.instances = (now(), instances) }
                observe(instances: instances, states: states, at: now())
                if !linked { linked = true }
                let loaded = instances.filter(\.isLanguageModel).count
                let text = L10n.t("Connected · \(loaded) loaded")
                if status != text {
                    Log.usage.debug("lmstudio: \(text, privacy: .public)")
                    status = text
                }
            case .failure(let error):
                if linked { linked = false }
                instances = nil
                observe(instances: [], states: [:], at: now())
                let text = (error as? LMStudioLinkError)?.errorDescription
                    ?? LMStudioError.unavailable.localizedDescription
                if status != text {
                    Log.usage.notice("lmstudio: \(text, privacy: .public)")
                    status = text
                }
                // A server that is down costs a connection attempt per poll;
                // wait a moment rather than hammer it at the poll rate.
                retryAfter = now().addingTimeInterval(2)
            }
        }
    }

    /// `known`: a recent listing to reuse, or nil to ask for one.
    private static func read(_ link: any LMStudioCalling, known: [LMStudioLoadedInstance]?) async
        -> Result<([LMStudioLoadedInstance], [String: LMStudioProcessingState]), Error> {
        do {
            let instances: [LMStudioLoadedInstance]
            if let known {
                instances = known
            } else {
                instances = LMStudioLoadedInstance.parse(try await link.call("listLoaded", parameter: nil))
            }
            var states: [String: LMStudioProcessingState] = [:]
            for instance in instances where instance.isLanguageModel {
                let result = try await link.call("getInstanceProcessingState", parameter:
                    LMStudioWire.processingStateParameter(instanceReference: instance.instanceReference))
                if let state = LMStudioProcessingState(result) { states[instance.identifier] = state }
            }
            return .success((instances, states))
        } catch {
            return .failure(error)
        }
    }

    /// One poll's answer, folded into the published activity and the
    /// generation clock. Separate from the socket so a test can drive it.
    func observe(instances: [LMStudioLoadedInstance], states: [String: LMStudioProcessingState], at: Date) {
        var next: [String: LocalModelActivity] = [:]
        var loaded = Set<String>()
        for instance in instances where instance.isLanguageModel {
            loaded.insert(instance.identifier)
            guard let state = states[instance.identifier] else { continue }
            let cell = Self.cellID(instance: instance.identifier)
            if let phase = state.phase {
                // A phase that continues keeps its start; a new one starts now.
                let since = activities[cell]?.phase == phase ? activities[cell]!.since : at
                next[cell] = LocalModelActivity(phase: phase, queued: state.queued, since: since)
            }
            if state.status == .generating {
                if generating[instance.identifier] == nil { generating[instance.identifier] = at }
            } else if let start = generating.removeValue(forKey: instance.identifier) {
                finished[instance.identifier] = (start, at)
            }
        }
        generating = generating.filter { loaded.contains($0.key) }
        guard activities != next else { return }
        // Only on a change, like the session monitors: the one way to see what
        // the notch thinks a model is doing without hovering over it.
        let summary = next.map { "\($0.key.split(separator: ":").last ?? "")=\($0.value.phase) q\($0.value.queued)" }
            .sorted().joined(separator: " ")
        Log.sessions.debug("lmstudio: \(summary.isEmpty ? "idle" : summary, privacy: .public)")
        activities = next
    }

    // MARK: - What each request cost

    private func startLog() {
        let directory = logsDirectory
        let revision = self.revision
        history = Task.detached(priority: .utility) { [weak self] in
            let started = Date()
            let tail = LMStudioLogTail(directory: directory)
            let events = tail.loadHistory()
            let predictions = events.filter { if case .prediction = $0 { return true } else { return false } }.count
            Log.usage.debug("lmstudio: read \(predictions) logged responses in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            // `[weak self]` again: Swift 5.10 will not bind a captured `weak
            // self` var from inside this nested concurrently-executing closure.
            await MainActor.run { [weak self] in
                guard let self, self.revision == revision else { return }
                self.tail = tail
                self.absorb(events, live: false)
                self.historyLoaded = true
                self.startLogTimer()
            }
        }
    }

    private func startLogTimer() {
        let timer = Timer(timeInterval: logInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readLog() }
        }
        RunLoop.main.add(timer, forMode: .common)
        logTimer = timer
    }

    private func readLog() {
        guard let tail else { return }
        let events = tail.poll()
        guard !events.isEmpty else { return }
        Log.usage.debug("lmstudio: \(events.count) new log event(s)")
        absorb(events, live: true)
    }

    /// Fold logged events into the ledger and the per-model speed. `live` says
    /// the lines were just written, so the generation clock may be paired with
    /// them; history is dated by the log's own stamps.
    func absorb(_ events: [LMStudioServerLog.Event], live: Bool) {
        var ledger = self.ledger
        var performances = self.performances
        var recorded = false
        let readAt = now()
        for case .prediction(let prediction) in events {
            let cell = Self.cellID(instance: prediction.instance)
            ledger.record(prediction, as: cell)
            recorded = true
            guard let measured = performance(for: prediction, live: live, readAt: readAt),
                  (performances[cell]?.measuredAt ?? .distantPast) <= measured.measuredAt
            else { continue }
            performances[cell] = measured
        }
        if recorded { self.ledger = ledger }
        if performances != self.performances {
            for (cell, measured) in performances where measured != self.performances[cell] {
                Log.usage.debug("lmstudio: \(cell.split(separator: ":").last ?? "", privacy: .public) \(measured.speedText, privacy: .public) from \(measured.outputTokens) tokens")
            }
            self.performances = performances
        }
    }

    private func performance(for prediction: LocalPrediction, live: Bool, readAt: Date) -> LocalModelPerformance? {
        guard let output = prediction.outputTokens, output > 0 else { return nil }
        let at = live ? readAt : prediction.at
        if let rate = prediction.tokensPerSecond {
            return LocalModelPerformance(outputTokens: output, tokensPerSecond: rate, measuredAt: at)
        }
        if let seconds = prediction.generationSeconds {
            return LocalModelPerformance(outputTokens: output, seconds: seconds, measuredAt: at)
        }
        // The OpenAI-shaped response has no clock. The one this poll kept is
        // used once, and only for a response that has just ended.
        guard live, let interval = finished.removeValue(forKey: prediction.instance),
              readAt.timeIntervalSince(interval.end) < 5 else { return nil }
        return LocalModelPerformance(outputTokens: output,
                                     seconds: interval.end.timeIntervalSince(interval.start),
                                     measuredAt: at, isApproximate: true)
    }
}
