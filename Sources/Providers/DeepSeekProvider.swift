import Foundation

/// The DeepSeek ring: the Codenotch sign-in or an API key, whichever is chosen
/// in Settings. The choice is re-read on every fetch, so switching applies
/// without a restart.
///
/// The sign-in reads the platform's own usage endpoints, so it is `.derived`
/// and carries spend and usage detail. The key reads the published balance
/// API, so it is `.official` and carries the balance alone — and a refused key
/// is not covered by the sign-in, which may be another account.
actor DeepSeekProvider: UsageProvider {
    nonisolated let id = "deepseek"
    nonisolated let displayName = "DeepSeek"
    nonisolated let glyph = ProviderGlyph.deepseek

    /// `nonisolated(unsafe)` for the same reason as MiniMax's: the sign-in is
    /// presented off the actor through `any UsageProvider`, and the reference
    /// never changes after init.
    nonisolated(unsafe) private let web: WebSessionProvider
    nonisolated private let source: @Sendable () -> DeepSeekSource
    private let session: URLSession
    private let loadAPIKey: @Sendable () -> String?

    init(web: WebSessionProvider,
         session: URLSession = .shared,
         source: @escaping @Sendable () -> DeepSeekSource = { Preferences.storedDeepSeekSource() },
         loadAPIKey: @escaping @Sendable () -> String? = { DeepSeekCredentials.loadAPIKey() }) {
        self.web = web
        self.session = session
        self.source = source
        self.loadAPIKey = loadAPIKey
    }

    nonisolated var signInRoute: SignInRoute {
        switch source() {
        case .web: return .modal(name: displayName)
        case .apiKey: return .guidance(L10n.t("Paste a valid DeepSeek API key in Settings, or export DEEPSEEK_API_KEY"))
        }
    }

    nonisolated func account() -> ProviderAccount? {
        switch source() {
        case .web:
            return web.account()
        case .apiKey:
            guard DeepSeekCredentials.isAPIKeyPresent() else { return nil }
            return ProviderAccount(label: nil, plan: nil, source: L10n.t("DeepSeek API key"),
                                   manageURL: URL(string: "https://platform.deepseek.com/api_keys"))
        }
    }

    nonisolated func forgetCachedCredential() {
        DeepSeekCredentials.forgetCached()
    }

    nonisolated func presentSignIn() {
        guard source() == .web else { return }
        Task { @MainActor in web.presentSignIn() }
    }

    nonisolated func presentAccountSwitch() {
        guard source() == .web else { return }
        Task { @MainActor in web.presentAccountSwitch() }
    }

    /// Ends only the chosen source's credential: the other may be a different
    /// account that is still wanted.
    func signOut() async {
        switch source() {
        case .web: await web.signOut()
        case .apiKey: DeepSeekCredentials.deleteAPIKey()
        }
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        switch source() {
        case .web:
            return try await web.fetchSnapshot()
        case .apiKey:
            guard let key = loadAPIKey() else { throw UsageProviderError.needsAuth }
            let window = try DeepSeekBalance.window(from: try await fetchBalance(key: key))
            return ProviderSnapshot(
                id: id,
                displayName: displayName,
                glyph: glyph,
                fidelity: .official,
                status: .ok,
                windows: [window],
                headlineID: window.id
            )
        }
    }

    private func fetchBalance(key: String) async throws -> Data {
        var request = URLRequest(url: DeepSeekBalance.url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        // A revoked or mistyped key. Signed out, so the old balance is dropped
        // rather than shown as if it were still true.
        case 401, 403: throw UsageProviderError.needsAuth
        case 429: throw UsageProviderError.rateLimited(retryAfter: 60)
        default: throw UsageProviderError.badResponse(status: status)
        }
    }
}
