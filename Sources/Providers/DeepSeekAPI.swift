import Foundation

/// Where the DeepSeek ring reads from. The two can be different accounts — a
/// personal sign-in on this Mac, an organisation's key — so one is chosen
/// rather than mixing their numbers on one card.
enum DeepSeekSource: String, Codable, CaseIterable {
    /// The Codenotch sign-in: balance, spend and usage detail.
    case web
    /// A pasted or exported API key: the balance only, all the public API has.
    case apiKey
}

/// The DeepSeek API key, from `DEEPSEEK_API_KEY` or the login keychain.
/// Read the way MiniMax's key is: the environment wins, and the keychain item
/// is held until it changes, because polling reaches this every minute.
enum DeepSeekCredentials {
    static let keychainService = "deepseek-api-key"
    static let keychainAccount = "codenotch"
    static let environmentKey = "DEEPSEEK_API_KEY"

    private static let cache = CredentialCache<String> { _ in false }

    private static func cachedAPIKey() -> String? {
        try? cache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: keychainService, account: keychainAccount) },
            reload: {
                guard let key = KeychainItem.read(service: keychainService, account: keychainAccount) else {
                    throw UsageProviderError.needsAuth
                }
                return key
            }
        )
    }

    static func loadAPIKey(environment: [String: String] = ProcessInfo.processInfo.environment,
                           keychain: () -> String? = cachedAPIKey) -> String? {
        nonEmpty(environment[environmentKey]) ?? nonEmpty(keychain())
    }

    /// Judged without a data read, so drawing Settings never prompts.
    static func isAPIKeyPresent(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        nonEmpty(environment[environmentKey]) != nil
            || KeychainItem.modifiedAt(service: keychainService, account: keychainAccount) != nil
    }

    static func storeAPIKey(_ key: String) {
        guard let trimmed = nonEmpty(key) else { return }
        cache.forget()
        _ = KeychainItem.store(service: keychainService, account: keychainAccount, value: trimmed)
    }

    static func deleteAPIKey() {
        cache.forget()
        _ = KeychainItem.delete(service: keychainService, account: keychainAccount)
    }

    static func forgetCached() { cache.forget() }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// `GET https://api.deepseek.com/user/balance`, the one figure an API key can
/// read. Spend and usage live only behind the platform sign-in.
enum DeepSeekBalance {
    static let url = URL(string: "https://api.deepseek.com/user/balance")!

    enum ParseError: Error { case noBalance }

    static func window(from data: Data) throws -> LimitWindow {
        let response = try JSONDecoder().decode(Response.self, from: data)
        // One entry per currency. The largest is the one that means something,
        // the same rule the web reading uses for its wallets.
        let infos = response.balanceInfos.compactMap { info -> (Info, Double)? in
            guard let total = Double(info.totalBalance) else { return nil }
            return (info, total)
        }
        guard let (info, total) = infos.max(by: { $0.1 < $1.1 }) else { throw ParseError.noBalance }

        let text = money(total, currency: info.currency)
        let toppedUp = money(Double(info.toppedUpBalance ?? "") ?? 0, currency: info.currency)
        let granted = money(Double(info.grantedBalance ?? "") ?? 0, currency: info.currency)
        // No total to measure against, so no percentage — except when there is
        // nothing left to spend, which is worth a full ring.
        let exhausted = total <= 0 || response.isAvailable == false
        return LimitWindow(
            id: "balance",
            label: L10n.t("Account balance (\(info.currency))"),
            usedFraction: exhausted ? 1 : nil,
            used: 0,
            usedText: text,
            detail: L10n.t("\(toppedUp) topped up · \(granted) granted · balance only with an API key"),
            prefersUsedText: true
        )
    }

    static func money(_ value: Double, currency: String) -> String {
        let symbol: String
        switch currency.uppercased() {
        case "CNY", "RMB": symbol = "¥"
        case "USD": symbol = "$"
        default: symbol = currency + " "
        }
        return symbol + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private struct Response: Decodable {
        let isAvailable: Bool?
        let balanceInfos: [Info]
        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    private struct Info: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String?
        let toppedUpBalance: String?
        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }
}
