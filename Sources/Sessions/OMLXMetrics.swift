import Combine
import Foundation
import os

/// Everything oMLX says about its models beyond the listing, gathered from two
/// places and published as one: the admin activity endpoint for what each
/// model is doing this instant, and the server log for what every finished
/// request cost. Nothing here sends a prompt or sits in the inference traffic.
///
/// Unlike LM Studio, every oMLX response is logged with the runtime's own
/// tok/s, so there is no generation clock to keep here and no speed is ever
/// approximate.
@MainActor
final class OMLXMetrics: ObservableObject {
    @Published private(set) var status = L10n.t("Off")
    /// The activity endpoint answered; what each model is doing is being read.
    @Published private(set) var linked = false
    /// Every existing log file has been read into the ledger.
    @Published private(set) var historyLoaded = false
    /// Keyed by notch cell id.
    @Published private(set) var activities: [String: LocalModelActivity] = [:]
    @Published private(set) var performances: [String: LocalModelPerformance] = [:]
    @Published private(set) var ledger = LocalTokenLedger()

    static let providerID = OMLXIdentity.providerID
    static func cellID(instance: String) -> String { OMLXIdentity.cellID(instance: instance) }

    /// A model reading a prompt or generating counts as work in progress, the
    /// same way an agent's busy session does.
    var isBusy: Bool { !activities.isEmpty }

    private let makeLink: @MainActor (URL) -> any OMLXCalling
    private let logsDirectory: URL
    private let pollInterval: TimeInterval
    private let logInterval: TimeInterval
    private let now: () -> Date
    private let calendar: Calendar
    private var link: (any OMLXCalling)?
    private var pollTimer: Timer?
    private var logTimer: Timer?
    private var poll: Task<Void, Never>?
    private var history: Task<Void, Never>?
    private var tail: OMLXLogTail?
    private var revision = 0
    private var retryAfter = Date.distantPast

    init(makeLink: @escaping @MainActor (URL) -> any OMLXCalling = { OMLXLink(endpoint: $0) },
         logsDirectory: URL = OMLXEndpoint.serverLogsDirectory(),
         pollInterval: TimeInterval = 0.5, logInterval: TimeInterval = 1,
         now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.makeLink = makeLink
        self.logsDirectory = logsDirectory
        self.pollInterval = pollInterval
        self.logInterval = logInterval
        self.now = now
        self.calendar = calendar
        self.ledger = LocalTokenLedger(calendar: calendar)
    }

    func configure(enabled: Bool, endpoint: String) {
        revision += 1
        tearDown()
        guard enabled else { status = L10n.t("Off"); return }
        guard let url = try? OMLXEndpoint.parse(endpoint) else {
            status = OMLXError.invalidEndpoint.localizedDescription
            return
        }
        link = makeLink(url)
        status = L10n.t("Connecting…")
        startPolling()
        startLog()
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
        tail = nil
        retryAfter = .distantPast
        linked = false
        historyLoaded = false
        if !activities.isEmpty { activities = [:] }
        if !performances.isEmpty { performances = [:] }
        // In the same calendar, or a reset would quietly switch the ledger back
        // to `.current` and file the next day under a different key.
        if !ledger.isEmpty { ledger = LocalTokenLedger(calendar: calendar) }
    }

    // MARK: - What each model is doing

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
        poll = Task { [weak self] in
            let outcome: Result<OMLXActivity, Error>
            do { outcome = .success(try await link.activity()) } catch { outcome = .failure(error) }
            guard let self else { return }
            self.poll = nil
            guard self.revision == revision else { return }
            switch outcome {
            case .success(let activity):
                observe(activity, at: now())
                if !linked { linked = true }
                let loaded = activity.models.filter { !$0.isLoading }.count
                let text = L10n.t("Connected · \(loaded) loaded")
                if status != text {
                    Log.usage.debug("omlx: \(text, privacy: .public)")
                    status = text
                }
            case .failure(let error):
                if linked { linked = false }
                observe(OMLXActivity(models: []), at: now())
                let failure = error as? OMLXError ?? .unavailable
                let text = failure.localizedDescription
                if status != text {
                    Log.usage.notice("omlx: \(text, privacy: .public)")
                    status = text
                }
                // A refused key is refused again until the user changes it, and
                // every refused login is a warning in oMLX's own log; a server
                // that is down costs a connection attempt. Neither is worth the
                // poll rate.
                retryAfter = now().addingTimeInterval(failure == .needsKey ? 10 : 2)
            }
        }
    }

    /// One poll's answer, folded into the published activity. Separate from
    /// the link so a test can drive it.
    func observe(_ activity: OMLXActivity, at: Date) {
        var next: [String: LocalModelActivity] = [:]
        for model in activity.models {
            let phase: LocalModelActivity.Phase
            if model.prefilling > 0 {
                phase = .processingPrompt
            } else if !model.generating.isEmpty || model.activities > 0 {
                phase = .generating
            } else {
                // Idle, or only queued behind nothing: no cell decoration, so
                // `isBusy` stays the plain "anything in `activities`".
                continue
            }
            let cell = Self.cellID(instance: model.id)
            // A phase that continues keeps its start; a new one starts now.
            let since = activities[cell]?.phase == phase ? activities[cell]!.since : at
            next[cell] = LocalModelActivity(phase: phase, queued: model.waiting, since: since)
        }
        guard activities != next else { return }
        // Only on a change, like the session monitors: the one way to see what
        // the notch thinks a model is doing without hovering over it.
        let summary = next.map { "\($0.key.split(separator: ":").last ?? "")=\($0.value.phase) q\($0.value.queued)" }
            .sorted().joined(separator: " ")
        Log.sessions.debug("omlx: \(summary.isEmpty ? "idle" : summary, privacy: .public)")
        activities = next
    }

    // MARK: - What each request cost

    private func startLog() {
        let directory = logsDirectory
        let timeZone = calendar.timeZone
        let revision = self.revision
        history = Task.detached(priority: .utility) { [weak self] in
            let started = Date()
            let tail = OMLXLogTail(directory: directory, timeZone: timeZone)
            let events = tail.loadHistory()
            Log.usage.debug("omlx: read \(events.count) logged responses in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            await MainActor.run {
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
        Log.usage.debug("omlx: \(events.count) new log event(s)")
        absorb(events, live: true)
    }

    /// Fold logged events into the ledger and the per-model speed. `live` says
    /// the lines were just written, so the speed is dated by when it was read;
    /// history is dated by the log's own stamps.
    func absorb(_ events: [OMLXServerLog.Event], live: Bool) {
        var ledger = self.ledger
        var performances = self.performances
        var recorded = false
        let readAt = now()
        for case .prediction(let prediction) in events {
            let cell = Self.cellID(instance: prediction.instance)
            ledger.record(prediction, as: cell)
            recorded = true
            guard let measured = Self.performance(for: prediction, at: live ? readAt : prediction.at),
                  (performances[cell]?.measuredAt ?? .distantPast) <= measured.measuredAt
            else { continue }
            performances[cell] = measured
        }
        if recorded { self.ledger = ledger }
        if performances != self.performances {
            for (cell, measured) in performances where measured != self.performances[cell] {
                Log.usage.debug("omlx: \(cell.split(separator: ":").last ?? "", privacy: .public) \(measured.speedText, privacy: .public) from \(measured.outputTokens) tokens")
            }
            self.performances = performances
        }
    }

    /// oMLX's own rate, so never approximate. The parser derives
    /// `generationSeconds` from that rate; either gives the same figure.
    private static func performance(for prediction: LocalPrediction, at: Date) -> LocalModelPerformance? {
        guard let output = prediction.outputTokens, output > 0 else { return nil }
        if let rate = prediction.tokensPerSecond {
            return LocalModelPerformance(outputTokens: output, tokensPerSecond: rate, measuredAt: at)
        }
        guard let seconds = prediction.generationSeconds else { return nil }
        return LocalModelPerformance(outputTokens: output, seconds: seconds, measuredAt: at, isApproximate: false)
    }
}
