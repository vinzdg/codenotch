import Foundation

actor GrokBotProvider: UsageProvider {
    nonisolated let id = "grokbot"
    nonisolated let displayName = "Grok Bot"
    nonisolated let glyph = ProviderGlyph.grok
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: GrokBotCredentials.bundleID, name: "Grok Bot")
    }
    nonisolated func account() -> ProviderAccount? { GrokBotCredentials.account() }
    nonisolated func forgetCachedCredential() { GrokBotCredentials.forgetCached() }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let credentials = try GrokBotCredentials.load()
        var request = URLRequest(url: URL(string:
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let team = credentials.teamID {
            request.setValue(team, forHTTPHeaderField: "x-cursor-team-id")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 { throw UsageProviderError.credentialExpired }
        if status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            throw UsageProviderError.rateLimited(
                retryAfter: Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        return try GrokBotUsage.snapshot(from: data)
    }
}

/// Field names and percentage semantics from Grok Bot 0.44's DashboardService.
enum GrokBotUsage {
    static func snapshot(from data: Data) throws -> ProviderSnapshot {
        struct Response: Decodable {
            let usagePercent: Double?
            let nextResetTimestampUtc: String?
            let usesPooledEnterpriseAllowance: Bool?
            let includedLimitZero: Bool?
            let hasAvailableUsage: Bool?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        if response.usesPooledEnterpriseAllowance == true {
            throw UsageProviderError.nothingMetered("Team uses a pooled allowance — check Grok Bot for usage")
        }
        guard let percent = response.usagePercent, percent.isFinite, percent >= 0 else {
            if response.includedLimitZero == true {
                throw UsageProviderError.nothingMetered("No included Grok Bot allowance on this account")
            }
            throw UsageProviderError.badResponse(status: 0)
        }
        let reset = response.nextResetTimestampUtc.flatMap(AntigravityCredentials.parse)
        return ProviderSnapshot(
            id: "grokbot", displayName: "Grok Bot", glyph: .grok,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "included", label: "Included usage",
                                  usedFraction: percent / 100, resetsAt: reset)],
            headlineID: "included",
            block: response.hasAvailableUsage == false
                ? UsageBlock(reason: "Grok Bot usage limit reached", resetsAt: reset) : nil)
    }
}
