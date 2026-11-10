import Foundation
import os

/// Reads Xiaomi MiMo Code usage and balance from the official CLI (`mimo balance --json`)
/// or from the Xiaomi MiMo Open Platform API (`https://api.xiaomimimo.com/v1/platform/balance`).
actor MimoCodeProvider: UsageProvider {
    nonisolated let id = "mimocode"
    nonisolated let displayName = "MimoCode"
    nonisolated let glyph = ProviderGlyph.mimocode

    private let session: URLSession
    private let archive: UsageArchive
    nonisolated private let sources: MimoCodeCredentialSources
    private let now: @Sendable () -> Date
    private var retryNoEarlierThan: Date?
    nonisolated(unsafe) private var lastKnownPlan: String?
    nonisolated(unsafe) private var lastKnownAccount: String?

    init(session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         sources: MimoCodeCredentialSources = MimoCodeCredentialSources(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.archive = archive
        self.sources = sources
        self.now = now
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: id)
    }

    nonisolated var isVisibleWhenAbsent: Bool {
        MimoCodeCredentials.isPresent(sources)
    }

    nonisolated var signInRoute: SignInRoute {
        .command("mimo auth login", name: "MimoCode", install: URL(string: "https://mimo.xiaomi.com"))
    }

    nonisolated func account() -> ProviderAccount? {
        guard MimoCodeCredentials.isPresent(sources) else { return nil }
        return ProviderAccount(
            label: lastKnownAccount,
            plan: lastKnownPlan,
            source: sources.locateBinary() != nil ? L10n.t("MimoCode CLI") : "MimoCode",
            manageURL: URL(string: "https://platform.xiaomimimo.com/console/plan-manage")
        )
    }

    nonisolated func signOut() async {
        sources.deleteSettingsToken()
    }

    nonisolated func forgetCachedCredential() {
        sources.forgetCached()
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > now() {
            let delay = retryNoEarlierThan.timeIntervalSince(now())
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }

        // 1. Try asking CLI first if installed
        if let binary = sources.locateBinary() {
            if let output = try? MimoCodeCLI.run(binary: binary),
               let result = try? MimoCodeUsage.parse(output) {
                lastKnownPlan = result.planName
                lastKnownAccount = result.accountName
                return ProviderSnapshot(
                    id: id,
                    displayName: displayName,
                    glyph: glyph,
                    fidelity: .official,
                    status: .ok,
                    windows: result.windows,
                    headlineID: result.headlineID
                )
            }
        }

        // 2. Fall back to Xiaomi MiMo Open Platform API using saved credential
        let credential = try MimoCodeCredentials.load(sources)

        var request = URLRequest(url: URL(string: "https://api.xiaomimimo.com/v1/platform/balance")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.token, forHTTPHeaderField: "api-key")
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
            throw UsageProviderError.apiError(L10n.t("Couldn't reach MimoCode. Check your connection."))
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 {
            sources.forgetCached()
            throw UsageProviderError.needsAuth
        }
        if status == 429 {
            let delay: TimeInterval = 60
            retryNoEarlierThan = now().addingTimeInterval(delay)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let result = try MimoCodeUsage.parse(data)
        lastKnownPlan = result.planName
        lastKnownAccount = result.accountName
        retryNoEarlierThan = nil

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: result.windows,
            headlineID: result.headlineID
        )
    }
}
