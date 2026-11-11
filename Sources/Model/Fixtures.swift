import Foundation

/// The three providers from the design frame, at the levels it shows, plus a
/// local model for the busy indicator.
/// These stand in until the adapters in M4 land.
enum Fixtures {
    static func snapshots(now: Date = Date(), calendar: Calendar = .current) -> [ProviderSnapshot] {
        let sessionReset = now.addingTimeInterval(51 * 60)
        let midnight = calendar.startOfDay(for: now.addingTimeInterval(24 * 60 * 60))

        return [
            ProviderSnapshot(
                id: "claude",
                displayName: "Claude",
                glyph: .claude,
                fidelity: .derived,
                status: .ok,
                windows: [
                    LimitWindow(id: "claude.session", label: L10n.t("Current session"),
                                usedFraction: 0.73, resetsAt: sessionReset),
                    LimitWindow(id: "claude.all", label: L10n.t("All models"),
                                usedFraction: 0.07, resetsAt: midnight)
                ]
            ),
            ProviderSnapshot(
                id: "openai",
                displayName: "OpenAI",
                glyph: .openai,
                fidelity: .manual,
                status: .stale(since: now.addingTimeInterval(-20 * 60)),
                windows: [
                    LimitWindow(id: "openai.session", label: L10n.t("Current session"),
                                usedFraction: 0.21, resetsAt: now.addingTimeInterval(3 * 60 * 60))
                ]
            ),
            ProviderSnapshot(
                id: "third",
                displayName: "Perplexity",
                glyph: .third,
                fidelity: .manual,
                status: .ok,
                windows: [
                    LimitWindow(id: "third.daily", label: L10n.t("Daily quota"),
                                usedFraction: 0.52, resetsAt: midnight)
                ]
            ),
            // A runtime snapshot, split into the `lmstudio:model:<name>` cell
            // by `notchSnapshots` on its way to the notch, as a live poll is.
            ProviderSnapshot(
                id: "lmstudio",
                displayName: "LM Studio",
                glyph: .lmstudio,
                fidelity: .official,
                status: .ok,
                windows: [],
                kind: .localRuntime,
                localRuntime: LocalRuntimeReading(models: [
                    LocalRuntimeReading.Model(name: "qwen3-coder-30b",
                                              memoryBytes: 18 * 1024 * 1024 * 1024,
                                              contextLength: 32768,
                                              quantizationLevel: "Q4_K_M",
                                              memoryKind: .modelSize)
                ])
            )
        ]
    }

    /// The demo's local model is generating with two requests queued behind
    /// it, the case the busy indicator draws differently.
    static func localActivities(now: Date = Date()) -> [String: LocalModelActivity] {
        ["lmstudio:model:qwen3-coder-30b": LocalModelActivity(phase: .generating, queued: 2,
                                                              since: now.addingTimeInterval(-12))]
    }

    /// Demo mode must show a working ring or the busy indicator cannot be
    /// eyeballed. "third" gets no session so one idle cell stays for comparison.
    static func sessions(now: Date = Date()) -> [String: [AgentSession]] {
        [
            "claude": [
                AgentSession(id: "demo.claude", name: "Claude Code", detail: "~/Projects/codenotch",
                             state: .busy, waitingFor: nil, since: now.addingTimeInterval(-90))
            ],
            "openai": [
                AgentSession(id: "demo.openai", name: "Codex", detail: "~/Projects/site",
                             state: .busy, waitingFor: nil, since: now.addingTimeInterval(-30))
            ]
        ]
    }
}
