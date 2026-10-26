import Foundation
import os

/// Reads Krea AI generation credits / compute units from the official CLI (`krea balance --json`)
/// or from Krea's MCP API (`https://api.krea.ai/mcp`).
actor KreaProvider: UsageProvider {
    nonisolated let id = "krea"
    nonisolated let displayName = "Krea"
    nonisolated let glyph = ProviderGlyph.krea

    private let session: URLSession
    private let archive: UsageArchive
    nonisolated private let sources: KreaCredentialSources
    private let now: @Sendable () -> Date
    private var retryNoEarlierThan: Date?
    nonisolated(unsafe) private var lastKnownPlan: String?
    nonisolated(unsafe) private var lastKnownWorkspace: String?

    init(session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         sources: KreaCredentialSources = KreaCredentialSources(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.archive = archive
        self.sources = sources
        self.now = now
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: id)
    }

    nonisolated var isVisibleWhenAbsent: Bool {
        KreaCredentials.isPresent(sources)
    }

    nonisolated var signInRoute: SignInRoute {
        .command("krea auth login", name: "Krea", install: URL(string: "https://github.com/krea-ai/cli"))
    }

    nonisolated func account() -> ProviderAccount? {
        guard KreaCredentials.isPresent(sources) else { return nil }
        return ProviderAccount(
            label: lastKnownWorkspace,
            plan: lastKnownPlan,
            source: sources.locateBinary() != nil ? L10n.t("Krea CLI") : "Krea",
            manageURL: URL(string: "https://www.krea.ai/settings/api-keys")
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
            if let output = try? KreaCLI.run(binary: binary),
               let result = try? KreaUsage.parse(output) {
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

        // 2. Fall back to Krea MCP API using saved credential
        let credential = try KreaCredentials.load(sources)

        var request = URLRequest(url: URL(string: "https://api.krea.ai/mcp")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": [
                "name": "get_balance",
                "arguments": [:] as [String: Any]
            ],
            "id": 1
        ])
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
            throw UsageProviderError.apiError(L10n.t("Couldn't reach Krea. Check your connection."))
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

        let result = try KreaUsage.parse(data)
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
