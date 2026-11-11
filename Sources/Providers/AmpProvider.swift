import Foundation

actor AmpProvider: UsageProvider {
    nonisolated let id = "amp"
    nonisolated var displayName: String { L10n.t("Amp") }
    nonisolated let glyph = ProviderGlyph.amp

    private let session: URLSession
    private let archive: UsageArchive
    nonisolated private let secretsURL: URL
    private let now: @Sendable () -> Date
    private var retryNoEarlierThan: Date?

    init(session: URLSession = .shared, archive: UsageArchive = UsageArchive(),
         secretsURL: URL = AmpCredentials.secretsURL,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.archive = archive
        self.secretsURL = secretsURL
        self.now = now
        retryNoEarlierThan = archive.loadBackoffUntil(providerID: "amp")
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Run amp login in Terminal — the notch reads ~/.local/share/amp/secrets.json."))
    }

    nonisolated func account() -> ProviderAccount? {
        guard (try? AmpCredentials.load(from: secretsURL)) != nil else { return nil }
        return ProviderAccount(label: nil, plan: nil, source: L10n.t("Amp CLI"),
                               manageURL: URL(string: "https://ampcode.com/settings"))
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > now() {
            throw UsageProviderError.rateLimited(retryAfter: retryNoEarlierThan.timeIntervalSince(now()))
        }
        // Plain-file reads never prompt and follow login/key rotation without
        // copying or modifying the credential owned by Amp.
        let token = try AmpCredentials.load(from: secretsURL)
        var request = URLRequest(url: AmpUsage.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        request.httpBody = Data(#"{"jsonrpc":"2.0","method":"userDisplayBalanceInfo","params":{},"id":1}"#.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw UsageProviderError.timedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageProviderError.apiError(L10n.t("Couldn't reach Amp. Check your connection."))
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            let delay = Self.retryDelay(http?.value(forHTTPHeaderField: "Retry-After"), now: now())
            retryNoEarlierThan = now().addingTimeInterval(delay)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        guard (200..<300).contains(status) else { throw UsageProviderError.badResponse(status: status) }

        let reading = try AmpUsage.parse(data)
        retryNoEarlierThan = nil
        archive.saveBackoffUntil(nil, providerID: id)
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: reading.fidelity, status: .ok, windows: reading.windows,
                                headlineID: reading.headlineID, plan: reading.plan)
    }

    private static func retryDelay(_ header: String?, now: Date) -> TimeInterval {
        guard let header else { return 60 }
        if let seconds = Double(header), seconds.isFinite { return max(60, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return max(60, formatter.date(from: header)?.timeIntervalSince(now) ?? 0)
    }
}
