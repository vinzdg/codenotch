import AppKit
import Foundation
import os

/// Reads Cursor usage as the account already signed in on this Mac.
///
/// This replaced a WebView sign-in, and the reason is worth keeping: signing
/// into cursor.com inside the app created a second, empty account, so the notch
/// faithfully reported zero usage for someone who was not the user. Borrowing
/// the editor's own session — or, when that is missing, the `cursor-agent`
/// login — removes the question. There is only ever one account, the one
/// actually being used.
actor CursorLocalProvider: UsageProvider {
    nonisolated let id = "cursor"
    nonisolated let displayName = "Cursor"
    nonisolated let glyph = ProviderGlyph.cursor

    private let endpoint = URL(string: "https://cursor.com/api/usage-summary")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        // Bundle-id lookup, not a hard-coded /Applications path: Cursor can
        // live in ~/Applications, and a miss here would hide the Open button
        // from someone who does have the editor.
        let installed = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: CursorCredentials.bundleID
        ) != nil
        return CursorCredentials.signInRoute(editorInstalled: installed)
    }

    nonisolated func account() -> ProviderAccount? { CursorCredentials.account() }

    nonisolated func forgetCachedCredential() { CursorCredentials.forgetCachedAgent() }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // Re-read every time: the editor rotates this, and holding a stale copy
        // would mean signing ourselves out for no reason. The agent token is
        // cached inside `CursorAgentKeychain` so the keychain is not.
        let credentials = try CursorCredentials.load()

        var request = URLRequest(url: endpoint)
        request.setValue(credentials.sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 {
            // A rejected token is the one signal the copy in hand is wrong
            // despite not having expired — signing into a different CLI
            // account replaces the keychain item. Drop it so the next read
            // asks macOS again.
            CursorCredentials.forgetCachedAgent()
            throw UsageProviderError.needsAuth
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        Log.usage.debug("cursor usage -> \(body.prefix(900), privacy: .public)")

        let windows = try CursorUsage.windows(fromJSON: body)
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: CursorUsage.headlineID(in: windows)
        )
    }
}
