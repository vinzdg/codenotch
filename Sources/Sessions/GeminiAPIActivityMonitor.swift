import Combine
import Foundation

/// What the `gemini-api` ring shows as running.
///
/// Four tools spend the same API key and each records a turn in flight in its
/// own way, so the monitor is one timer over four readers rather than four
/// monitors sharing an id: `GeminiCLIActivity` on the chat files' modification
/// dates, `OpenCodeGeminiActivity` on an assistant message with no
/// `time.completed`, `HermesGeminiActivity` on an open session's lease,
/// `AntigravityCLIGeminiActivity` on the step status in the conversation
/// database together with the tail of the transcript.
///
/// The order is fixed and matches the provider's tooltip rows. Sessions are
/// drawn in the order they arrive, so concatenating by whichever reader
/// answered first would reshuffle the ring every couple of seconds.
///
/// Antigravity CLI is the one source whose transcript can say waiting or
/// complete, so its session is not always `.busy`; the other three write no
/// "waiting for you" marker to disk and report `.busy` or nothing.
final class GeminiAPIActivityMonitor: AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let geminiRoot: URL
    private let opencodeDatabase: URL
    private let hermesDatabase: URL
    private let antigravityStores: [URL]
    private let interval: TimeInterval
    /// How recently a source must have been touched to count as live. Generous,
    /// because a model can think for a while between two lines.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(geminiRoot: URL = GeminiCLIUsage.sessionsRoot,
         opencodeDatabase: URL = OpenCodeGeminiActivity.database,
         hermesDatabase: URL = HermesGeminiUsage.database,
         antigravityStores: [URL] = AntigravityCLIGeminiUsage.stores,
         interval: TimeInterval = 2,
         staleAfter: TimeInterval = 45) {
        self.geminiRoot = geminiRoot
        self.opencodeDatabase = opencodeDatabase
        self.hermesDatabase = hermesDatabase
        self.antigravityStores = antigravityStores
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
        let found = Self.read(
            geminiRoot: geminiRoot,
            opencodeDatabase: opencodeDatabase,
            hermesDatabase: hermesDatabase,
            antigravityStores: antigravityStores,
            staleAfter: staleAfter
        )
        guard found != sessions else { return }
        sessions = found
    }

    static func read(
        geminiRoot: URL,
        opencodeDatabase: URL,
        hermesDatabase: URL,
        antigravityStores: [URL],
        staleAfter: TimeInterval,
        now: Date = Date()
    ) -> [AgentSession] {
        GeminiCLIActivity.read(root: geminiRoot, staleAfter: staleAfter, now: now)
            + OpenCodeGeminiActivity.read(
                database: opencodeDatabase, staleAfter: staleAfter, now: now)
            + HermesGeminiActivity.read(
                database: hermesDatabase, staleAfter: staleAfter, now: now)
            + AntigravityCLIGeminiActivity.read(
                stores: antigravityStores, staleAfter: staleAfter, now: now)
    }
}
