import Foundation
import os

/// The Xiaomi MiMo ring: reads Token Plan quotas from the platform console
/// (via `WebSessionProvider`) or account balances from the Xiaomi MiMo Open
/// Platform balance API (`/v1/platform/balance`) using official CLI credentials
/// (`~/.local/share/mimocode/auth.json`), environment variables, or Settings.
actor MiMoProvider: UsageProvider {
    nonisolated let id = "mimo"
    nonisolated let displayName = "MiMo"
    nonisolated let glyph = ProviderGlyph.mimo

    nonisolated(unsafe) private let web: WebSessionProvider?
    private let session: URLSession
    private let archive: UsageArchive
    private let loadAPIKey: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private var retryNoEarlierThan: Date?

    init(web: WebSessionProvider? = nil,
         session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         loadAPIKey: @escaping @Sendable () -> String? = { MiMoCredentials.loadAPIKey() },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.web = web
        self.session = session
        self.archive = archive
        self.loadAPIKey = loadAPIKey
        self.now = now
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: id)
    }

    nonisolated var signInRoute: SignInRoute {
        if let web {
            return web.signInRoute
        }
        return .guidance(L10n.t("Sign in to MiMo or paste an API key in Settings."))
    }

    nonisolated func account() -> ProviderAccount? {
        if let webAccount = web?.account() {
            return webAccount
        }
        guard MiMoCredentials.isAPIKeyPresent() else { return nil }
        return ProviderAccount(
            label: nil,
            plan: nil,
            source: MiMoCredentials.isCLICredentialPresent() ? "MiMo Code" : L10n.t("MiMo API key"),
            manageURL: URL(string: "https://platform.xiaomimimo.com/console/plan-manage")
        )
    }

    nonisolated func forgetCachedCredential() {
        MiMoCredentials.forgetCached()
    }

    nonisolated func presentSignIn() {
        guard let web else { return }
        Task { @MainActor in web.presentSignIn() }
    }

    nonisolated func presentAccountSwitch() {
        guard let web else { return }
        Task { @MainActor in web.presentAccountSwitch() }
    }

    func signOut() async {
        MiMoCredentials.deleteAPIKey()
        if let web {
            await web.signOut()
        }
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > now() {
            let delay = retryNoEarlierThan.timeIntervalSince(now())
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }

        let key = loadAPIKey()
        var balanceWindows: [LimitWindow]?

        if let key {
            do {
                let data = try await fetchBalance(key: key)
                balanceWindows = try MiMoUsage.balanceWindows(from: data)
                retryNoEarlierThan = nil
            } catch let error as UsageProviderError {
                if case .needsAuth = error {
                    MiMoCredentials.forgetCached()
                    if web == nil { throw error }
                } else if case .rateLimited(let delay) = error {
                    retryNoEarlierThan = now().addingTimeInterval(delay)
                    archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
                    if web == nil { throw error }
                } else {
                    if web == nil { throw error }
                }
            } catch {
                if web == nil {
                    throw UsageProviderError.apiError(L10n.t("Couldn't reach MiMo. Check your connection."))
                }
            }
        }

        // If web session is available, try fetching Token Plan
        var webSnapshot: ProviderSnapshot?
        if let web {
            do {
                webSnapshot = try await web.fetchSnapshot()
            } catch {
                // If we got balance windows, don't fail just because web session failed
                if balanceWindows == nil {
                    throw error
                }
            }
        }

        if let balanceWindows {
            if let webSnapshot {
                // Combine Token Plan from web and balance windows
                let combinedWindows = webSnapshot.windows + balanceWindows
                return ProviderSnapshot(
                    id: id,
                    displayName: displayName,
                    glyph: glyph,
                    fidelity: .official,
                    status: .ok,
                    windows: combinedWindows,
                    headlineID: webSnapshot.headlineID ?? "month"
                )
            } else {
                return ProviderSnapshot(
                    id: id,
                    displayName: displayName,
                    glyph: glyph,
                    fidelity: .official,
                    status: .ok,
                    windows: balanceWindows,
                    headlineID: "balance"
                )
            }
        }

        if let webSnapshot {
            return webSnapshot
        }

        throw UsageProviderError.needsAuth
    }

    private func fetchBalance(key: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.xiaomimimo.com/v1/platform/balance")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw UsageProviderError.timedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageProviderError.apiError(L10n.t("Couldn't reach MiMo. Check your connection."))
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw UsageProviderError.needsAuth
        }
        if status == 429 {
            throw UsageProviderError.rateLimited(retryAfter: 60)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        return data
    }
}
