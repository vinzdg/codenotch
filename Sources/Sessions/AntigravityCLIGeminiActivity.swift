import Foundation

/// Notices when Antigravity CLI is working on a Gemini API key.
///
/// It reuses `AntigravityActivityMonitor.read(root:...)` because the transcript
/// is the same format, and that reader was written against real state. Which
/// ring the turn belongs to is the store's settings, not the transcript: the
/// transcript says nothing about who pays for the call, so `usesAPIKey` decides
/// and the Antigravity ring drops the same stores.
///
/// Main-actor because the reader it reuses lives on `AntigravityActivityMonitor`,
/// whose class is isolated through `AgentActivityMonitor`.
@MainActor
enum AntigravityCLIGeminiActivity {
    static func read(stores: [URL], staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        let newest = stores
            .filter { AntigravityCLIGeminiUsage.usesAPIKey(store: $0) }
            .flatMap {
                AntigravityActivityMonitor.read(
                    root: $0.appendingPathComponent("brain"), staleAfter: staleAfter, now: now)
            }
            .max { $0.since < $1.since }
        guard let session = newest else { return [] }
        return [AgentSession(
            id: "gemini-api.\(session.id)",
            name: "Antigravity CLI",
            detail: session.detail,
            state: session.state,
            waitingFor: session.waitingFor,
            since: session.since
        )]
    }
}
