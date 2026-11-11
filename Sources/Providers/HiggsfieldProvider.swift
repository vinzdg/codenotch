import Foundation
import os

/// Reads Higgsfield AI generation credits from the official CLI (`hf workspace list --json`)
/// or from Higgsfield's developer gateway API (`https://fnf-api-gw.higgsfield.ai/fnf/developer/v2alpha/account/workspaces`).
actor HiggsfieldProvider: UsageProvider {
    nonisolated let id = "higgsfield"
    nonisolated let displayName = "Higgsfield"
    nonisolated let glyph = ProviderGlyph.higgsfield

    private let session: URLSession
    private let archive: UsageArchive
    nonisolated private let sources: HiggsfieldCredentialSources
    private let now: @Sendable () -> Date
    private var retryNoEarlierThan: Date?
    nonisolated(unsafe) private var lastKnownPlan: String?
    nonisolated(unsafe) private var lastKnownWorkspace: String?

    init(session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         sources: HiggsfieldCredentialSources = HiggsfieldCredentialSources(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.archive = archive
        self.sources = sources
        self.now = now
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: id)
    }

    nonisolated var isVisibleWhenAbsent: Bool {
        HiggsfieldCredentials.isPresent(sources)
    }

    nonisolated var signInRoute: SignInRoute {
        .command("hf auth login", name: "Higgsfield", install: URL(string: "https://github.com/higgsfield-ai/cli"))
    }

    nonisolated func account() -> ProviderAccount? {
        guard HiggsfieldCredentials.isPresent(sources) else { return nil }
        return ProviderAccount(
            label: lastKnownWorkspace,
            plan: lastKnownPlan,
            source: sources.locateBinary() != nil ? L10n.t("Higgsfield CLI") : "Higgsfield",
            manageURL: URL(string: "https://higgsfield.ai/me/settings/subscription")
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
            if let output = try? HiggsfieldCLI.run(binary: binary),
               let result = try? HiggsfieldUsage.parse(output) {
                lastKnownPlan = result.planName
                lastKnownWorkspace = result.workspaceName
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

        // 2. Fall back to developer gateway HTTP API using saved credential
        let credential = try HiggsfieldCredentials.load(sources)

        var request = URLRequest(url: URL(string: "https://fnf-api-gw.higgsfield.ai/fnf/developer/v2alpha/account/workspaces")!)
        let authHeader = credential.token.contains(":") ? "Key \(credential.token)" : "Bearer \(credential.token)"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
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
            throw UsageProviderError.apiError(L10n.t("Couldn't reach Higgsfield. Check your connection."))
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

        let result = try HiggsfieldUsage.parse(data)
        lastKnownPlan = result.planName
        lastKnownWorkspace = result.workspaceName
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
