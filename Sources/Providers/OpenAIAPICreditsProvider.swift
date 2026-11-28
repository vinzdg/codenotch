import Foundation

struct OpenAIAPICreditGrant: Codable, Equatable, Sendable {
    let issued: String
    let expires: String
    let granted: Decimal
    let available: Decimal
    let costAtSnapshot: Decimal

    static func midnight(_ value: String, timeZone: TimeZone) -> Date? {
        let chunks = value.split(separator: "-")
        guard chunks.count == 3, chunks.map(\.count) == [4, 2, 2],
              let year = Int(chunks[0]), let month = Int(chunks[1]), let day = Int(chunks[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return date
    }

    static func validated(issued: String, expires: String, granted: String, available: String,
                          now: Date = Date()) -> Self? {
        let utc = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        guard let start = midnight(issued, timeZone: utc), start <= now,
              let end = midnight(expires, timeZone: .current), end > now,
              granted.range(of: #"^[0-9]{1,12}(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              available.range(of: #"^[0-9]{1,12}(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let granted = Decimal(string: granted, locale: locale),
              let available = Decimal(string: available, locale: locale),
              granted > 0, available >= 0, available <= granted else { return nil }
        return Self(issued: issued, expires: expires, granted: granted, available: available, costAtSnapshot: 0)
    }

    func withBaseline(_ cost: Decimal) -> Self {
        Self(issued: issued, expires: expires, granted: granted, available: available, costAtSnapshot: cost)
    }

    func available(at cost: Decimal) -> Decimal {
        max(0, available - max(0, cost - costAtSnapshot))
    }
    func windows(at cost: Decimal) -> [LimitWindow] {
        let left = available(at: cost)
        let used = granted - left
        let usd = { (value: Decimal) in NSDecimalNumber(decimal: value).doubleValue }
        return [
            LimitWindow(id: "credit-grant", label: L10n.t("Credit grant"),
                        usedFraction: usd(used / granted), resetDateLabel: expires)
        ]
    }

}

enum OpenAIAPICosts {
    static let endpoint = URL(string: "https://api.openai.com/v1/organization/costs")!

    struct Page: Decodable {
        struct Bucket: Decodable {
            struct Result: Decodable {
                struct Amount: Decodable {
                    let value: Decimal
                    let currency: String
                }
                let amount: Amount
            }
            let startTime: Int
            let endTime: Int
            let results: [Result]
        }
        let data: [Bucket]
        let hasMore: Bool
        let nextPage: String?
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func page<T: Decodable>(from endpoint: URL, key: String, start: Date, end: Date,
                                    cursor: String?, session: URLSession) async throws -> T {
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(max(Int(end.timeIntervalSince1970), Int(start.timeIntervalSince1970) + 1))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31")
        ]
        if let cursor { url.queryItems?.append(URLQueryItem(name: "page", value: cursor)) }
        var request = URLRequest(url: url.url!, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw UsageProviderError.needsAuth }
        if status == 403 { throw UsageProviderError.apiError(L10n.t("This key cannot read organization usage.")) }
        if status == 429 { throw UsageProviderError.rateLimited(retryAfter: 300) }
        guard (200..<300).contains(status), data.count <= 2_000_000 else {
            throw UsageProviderError.badResponse(status: status)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    static func total(key: String, start: Date, end: Date, session: URLSession = .shared) async throws -> Decimal {
        try await total(start: Int(start.timeIntervalSince1970)) { cursor in
            try await page(from: endpoint, key: key, start: start, end: end, cursor: cursor, session: session)
        }
    }

    static func total(start: Int, fetch: (String?) async throws -> Page) async throws -> Decimal {
        var sum: Decimal = 0
        var previous = start
        var cursor: String?
        var seen = Set<String>()
        for _ in 0..<10 {
            let page = try await fetch(cursor)
            for bucket in page.data {
                guard bucket.startTime >= previous, bucket.endTime > bucket.startTime else {
                    throw UsageProviderError.apiError(L10n.t("OpenAI returned overlapping cost buckets."))
                }
                previous = bucket.endTime
                for row in bucket.results {
                    guard row.amount.currency.lowercased() == "usd", !row.amount.value.isNaN else {
                        throw UsageProviderError.apiError(L10n.t("OpenAI returned an invalid amount or currency."))
                    }
                    sum += row.amount.value
                }
            }
            if !page.hasMore { return sum }
            guard let next = page.nextPage, !next.isEmpty, seen.insert(next).inserted else { break }
            cursor = next
        }
        throw UsageProviderError.apiError(L10n.t("OpenAI returned an incomplete cost period."))
    }
}

actor OpenAIAPICreditsProvider: UsageProvider {
    nonisolated static let providerID = "openai-api-credits"
    nonisolated static let keychainService = "openai-api-credits-admin-key"
    nonisolated static let keychainAccount = "codenotch"
    nonisolated static let preference = "openAIAPICreditGrant"
    nonisolated static let grantsURL = URL(string: "https://platform.openai.com/settings/organization/billing/credit-grants")!
    nonisolated let id = OpenAIAPICreditsProvider.providerID
    nonisolated let displayName = "ChatGPT API"
    nonisolated let glyph: ProviderGlyph = .openaiAPI

    private var lastMetrics: (grant: OpenAIAPICreditGrant, usage: CodexTokenUsage)?
    private var retryUntil: Date?

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Enter a read-only OpenAI organization Admin key and the current grant below."))
    }

    nonisolated func account() -> ProviderAccount? {
        guard Self.configuredGrant() != nil else { return nil }
        return ProviderAccount(label: nil, plan: nil, source: "OpenAI API", manageURL: Self.grantsURL)
    }

    nonisolated static func configuredGrant() -> OpenAIAPICreditGrant? {
        guard let data = UserDefaults.standard.data(forKey: preference) else { return nil }
        return try? JSONDecoder().decode(OpenAIAPICreditGrant.self, from: data)
    }

    nonisolated static func configure(_ grant: OpenAIAPICreditGrant, key supplied: String) async throws {
        let key = supplied.isEmpty
            ? (KeychainItem.read(service: keychainService, account: keychainAccount) ?? "")
            : supplied
        guard key.hasPrefix("sk-admin-"),
              let start = OpenAIAPICreditGrant.midnight(grant.issued, timeZone: TimeZone(secondsFromGMT: 0)!) else {
            throw UsageProviderError.needsAuth
        }
        let cost = try await OpenAIAPICosts.total(key: key, start: start, end: Date())
        let data = try JSONEncoder().encode(grant.withBaseline(cost))
        if !supplied.isEmpty {
            guard KeychainItem.store(service: keychainService, account: keychainAccount, value: key) else {
                throw UsageProviderError.apiError(L10n.t("Could not save the Admin key to Keychain."))
            }
        }
        UserDefaults.standard.set(data, forKey: preference)
    }

    nonisolated func signOut() async {
        _ = KeychainItem.delete(service: Self.keychainService, account: Self.keychainAccount)
        UserDefaults.standard.removeObject(forKey: Self.preference)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let grant = Self.configuredGrant() else { throw UsageProviderError.needsAuth }
        return try await fetchSnapshot(grant: grant, now: Date()) { start, end in
            guard let key = KeychainItem.read(service: Self.keychainService, account: Self.keychainAccount) else {
                throw UsageProviderError.needsAuth
            }
            let cost = try await OpenAIAPICosts.total(key: key, start: start, end: end)
            let metrics = try? await OpenAIAPIUsage.metrics(key: key, now: end)
            return (cost, metrics)
        }
    }

    func fetchSnapshot(grant: OpenAIAPICreditGrant, now: Date,
                       read: (Date, Date) async throws -> (Decimal, CodexTokenUsage?)) async throws -> ProviderSnapshot {
        guard let expiry = OpenAIAPICreditGrant.midnight(grant.expires, timeZone: .current),
              let start = OpenAIAPICreditGrant.midnight(grant.issued, timeZone: TimeZone(secondsFromGMT: 0)!) else {
            throw UsageProviderError.needsAuth
        }
        if now >= expiry {
            let window = LimitWindow(id: "credit-expiry", label: L10n.t("Resets"), usedText: grant.expires,
                                     detail: L10n.t("Check Credit Grants for expiration or renewal."), prefersUsedText: true)
            return snapshot([window])
        }
        if let retryUntil, retryUntil > now {
            throw UsageProviderError.rateLimited(retryAfter: retryUntil.timeIntervalSince(now))
        }

        let (cost, metrics): (Decimal, CodexTokenUsage?)
        do {
            (cost, metrics) = try await read(start, now)
        } catch let UsageProviderError.rateLimited(retryAfter) {
            retryUntil = now.addingTimeInterval(max(60, retryAfter))
            throw UsageProviderError.rateLimited(retryAfter: retryAfter)
        }

        if let metrics { lastMetrics = (grant, metrics) }
        var result = snapshot(grant.windows(at: cost))
        result.tokenUsage = lastMetrics.flatMap { $0.grant == grant ? $0.usage : nil }
        return result
    }

    private func snapshot(_ windows: [LimitWindow]) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                         fidelity: .derived, status: .ok, windows: windows,
                         headlineID: windows.first?.id)
    }
}
