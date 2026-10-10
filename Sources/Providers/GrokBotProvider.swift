import AppKit
import Foundation
import os

/// Reads Grok Bot's weekly usage from the cache it keeps on this Mac.
///
/// No endpoint is called and no credential is borrowed: the number is Grok
/// Bot's own last reading, parsed out of its `sand-client-persistence` blobs.
/// That is also the honest limit of it — the cache only moves while Grok Bot
/// runs, so a reading past its `expiresAtMs` is shown dimmed as stale rather
/// than as the present truth. Hidden until Grok Bot has been signed in at
/// least once: a permanent sign-in placeholder for an app never installed
/// would be noise on every Mac without it.
actor GrokBotProvider: UsageProvider {
    nonisolated let id = "grokbot"
    nonisolated let displayName = "Grok Bot"
    nonisolated let glyph = ProviderGlyph.grokbot

    private let persistenceDir: URL

    init(persistenceDir: URL = GrokBotCache.persistenceURL) {
        self.persistenceDir = persistenceDir
    }

    nonisolated var isVisibleWhenAbsent: Bool { false }

    nonisolated var signInRoute: SignInRoute {
        // Bundle-id lookup, not a hard-coded /Applications path: Grok Bot can
        // live in ~/Applications, and a miss here would hide the Open button
        // from someone who does have it.
        let installed = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: GrokBotCache.bundleID
        ) != nil
        if installed {
            return .openApp(bundleID: GrokBotCache.bundleID, name: "Grok Bot")
        }
        return .guidance(L10n.t(
            "Install Grok Bot and sign in — the notch reads the weekly usage it keeps on this Mac."
        ))
    }

    nonisolated func account() -> ProviderAccount? {
        GrokBotCache.account(persistenceDir: persistenceDir)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let reading = try GrokBotCache.load(persistenceDir: persistenceDir)
        Log.usage.debug(
            "grokbot weekly -> \(reading.percentUsed, privacy: .public)%"
        )
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: reading.isExpired ? .stale(since: reading.asOf) : .ok,
            windows: GrokBotUsage.windows(from: reading),
            headlineID: "weekly",
            weeklyID: "weekly",
            plan: reading.planLabel
        )
    }
}
