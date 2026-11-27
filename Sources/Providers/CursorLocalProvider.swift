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

    private let summaryEndpoint = URL(string: "https://cursor.com/api/usage-summary")!
    private let currentPeriodEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!
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
        do {
            return try await fetchSnapshot(using: credentials)
        } catch UsageProviderError.needsAuth {
            // A rejected CLI session must be read again on the next fetch.
            CursorCredentials.forgetCachedAgent()
            throw UsageProviderError.needsAuth
        }
    }

    private func fetchSnapshot(using credentials: CursorCredentials) async throws -> ProviderSnapshot {
        let cachedPlan = account()?.plan?.nonEmptyPlan
        // The editor reports the allowance's actual cycle. Some plan names,
        // including Ultra, are shared by monthly and weekly subscriptions.
        let weekly: LimitWindow?
        if CursorUsage.requiresWeeklyAllowance(cachedPlan) {
            weekly = try await fetchWeeklyWindow(using: credentials)
            guard weekly != nil else { throw weeklyUnavailable() }
        } else {
            weekly = try? await fetchWeeklyWindow(using: credentials)
            try Task.checkCancellation()
        }
        if let weekly {
            return ProviderSnapshot(
                id: id, displayName: displayName, glyph: glyph, fidelity: .official,
                status: .ok, windows: [weekly], headlineID: weekly.id, weeklyID: weekly.id,
                plan: cachedPlan
            )
        }

        var request = URLRequest(url: summaryEndpoint)
        request.setValue(credentials.sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let data = try await fetchData(request)
        let body = String(data: data, encoding: .utf8) ?? ""
        Log.usage.debug("cursor usage -> \(body.prefix(900), privacy: .public)")

        let plan = CursorUsage.plan(fromJSON: body) ?? cachedPlan
        guard !CursorUsage.requiresWeeklyAllowance(plan) else { throw weeklyUnavailable() }
        let windows = try CursorUsage.windows(fromJSON: body)
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: CursorUsage.headlineID(in: windows),
            plan: plan
        )
    }

    private func fetchWeeklyWindow(using credentials: CursorCredentials) async throws -> LimitWindow? {
        var request = URLRequest(url: currentPeriodEndpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let data = try await fetchData(request)
        return try CursorUsage.weeklyWindow(from: data)
    }

    private func fetchData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        guard (200..<300).contains(status) else { throw UsageProviderError.badResponse(status: status) }
        return data
    }

    private func weeklyUnavailable() -> UsageProviderError {
        .apiError(L10n.t("Cursor weekly usage is unavailable."))
    }
}
