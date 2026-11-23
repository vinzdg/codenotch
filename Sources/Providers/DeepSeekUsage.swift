import Foundation

/// Decodes the signed-in DeepSeek Platform responses used by the usage card.
enum DeepSeekUsage {
    struct FetchPayload: Decodable {
        let summary: String
        let amount: String
        let cost: String
        let start: Int
        let end: Int
        let timeZoneSeconds: Int

        enum CodingKeys: String, CodingKey {
            case summary, amount, cost, start, end
            case timeZoneSeconds = "time_zone_seconds"
        }
    }

    struct Reading: Equatable {
        let currency: String
        let spent: Double
        let balance: Double
        let availableTokens: Int?

        var usedFraction: Double {
            let funded = spent + balance
            guard funded > 0 else { return 0 }
            return min(max(spent / funded, 0), 1)
        }

        var formattedBalance: String {
            DeepSeekUsage.formatMoney(balance, currency: currency)
        }

        var balanceLeftText: String {
            String(format: L10n.t("%@ left"), formattedBalance)
        }

        /// The same figure as the ring prints it: the symbol and the whole
        /// units, "¥51". See `DeepSeekUsage.wholeMoney`.
        var wholeBalanceText: String {
            DeepSeekUsage.wholeMoney(balance, currency: currency)
        }
    }

    static func currencySymbol(for currency: String) -> String {
        switch currency.uppercased() {
        case "CNY", "RMB", "JPY": return "¥"
        case "USD": return "$"
        case "EUR": return "€"
        default: return "\(currency) "
        }
    }

    static func formatMoney(_ value: Double, currency: String) -> String {
        let symbol = currencySymbol(for: currency)
        return "\(symbol)\(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value))"
    }

    /// What is left, to the whole unit, with no word beside it: "¥51".
    ///
    /// For the line under the ring, which is only as wide as the notch. Its
    /// neighbour is a percentage — "39%", "100%" — and "¥51.83 left" is none:
    /// 74 pt at this size, 79 as "剩余 ¥51.83" in Chinese, against 39 for
    /// "100%". Drawn at its natural width, both ends were cut off. The exact
    /// figure is still one hover away, on the card (`balanceLeftText`); this
    /// is the one that has to sit in a percentage's width, so it is the symbol
    /// and the units and nothing else.
    ///
    /// Truncated, not rounded: "¥51" promises at least ¥51, where "¥52" would
    /// promise more than the wallet holds. Under one unit it is "<¥1" rather
    /// than "¥0", for the reason `Percent.whole` prints "<1" — the ring is
    /// still green there, and "¥0" beside it would say the opposite.
    static func wholeMoney(_ value: Double, currency: String) -> String {
        let symbol = currencySymbol(for: currency)
        // Not an amount, or one too large for a whole-unit figure — "inf",
        // "nan", 1e300 — is `formatMoney`'s business.
        guard value.isFinite, value < Double(Int.max) else { return formatMoney(value, currency: currency) }
        // Nothing left, or a negative the site should never send, is "0"; a
        // sliver is "<1". Both judged before the `Int` conversion, which a
        // balance parsed out of the site's own text must never reach trapping.
        guard value >= 1 else { return value > 0 ? "<\(symbol)1" : "\(symbol)0" }
        let whole = Int(value.rounded(.down))
        // From ten thousand it compacts the way a token count does ("¥12k"),
        // for the same reason: six digits do not fit under a ring.
        return symbol + LimitWindow.compact(whole)
    }

    static func windows(
        from reading: Reading,
        displayMode: DeepSeekDisplayMode = .balance
    ) -> [LimitWindow] {
        switch displayMode {
        case .balance:
            var windows = [
                LimitWindow(
                    id: "balance",
                    label: L10n.t("Credit balance"),
                    usedFraction: nil,
                    remaining: nil,
                    used: 0,
                    usedText: reading.wholeBalanceText,
                    detail: reading.balanceLeftText,
                    money: nil,
                    resetsAt: nil,
                    duration: nil,
                    bandOverride: reading.balance <= 0 ? .exhausted : .ample,
                    prefersUsedText: true
                ),
                LimitWindow(
                    id: "spend",
                    label: L10n.t("Account usage (\(reading.currency))"),
                    usedFraction: reading.usedFraction,
                    remaining: nil,
                    used: nil,
                    usedText: nil,
                    detail: nil,
                    money: UsageMoneyBreakdown(currency: reading.currency,
                                               spent: reading.spent,
                                               remaining: reading.balance),
                    resetsAt: nil,
                    duration: nil,
                    bandOverride: nil,
                    prefersUsedText: false
                )
            ]
            if let availableTokens = reading.availableTokens {
                windows.append(LimitWindow(
                    id: "available-tokens",
                    label: L10n.t("Available tokens (estimate)"),
                    detail: "\(LimitWindow.compact(availableTokens)) available"
                ))
            }
            return windows

        case .lifetimeSpend:
            var windows = [
                LimitWindow(
                    id: "spend",
                    label: L10n.t("Account usage (\(reading.currency))"),
                    usedFraction: reading.usedFraction,
                    money: UsageMoneyBreakdown(currency: reading.currency,
                                               spent: reading.spent,
                                               remaining: reading.balance)
                )
            ]
            if let availableTokens = reading.availableTokens {
                windows.append(LimitWindow(
                    id: "available-tokens",
                    label: L10n.t("Available tokens (estimate)"),
                    detail: "\(LimitWindow.compact(availableTokens)) available"
                ))
            }
            return windows
        }
    }

    enum ParseError: Error { case malformed, noWallet }

    static func payload(fromJSON json: String) throws -> FetchPayload {
        guard let data = json.data(using: .utf8) else { throw ParseError.malformed }
        return try JSONDecoder().decode(FetchPayload.self, from: data)
    }

    static func reading(fromJSON json: String) throws -> Reading {
        guard let data = json.data(using: .utf8) else { throw ParseError.malformed }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        // An expired or missing token comes back as HTTP 200 with one of these
        // codes and no data. Read as a parse failure, it left the last reading
        // on the card for days with nothing saying a sign-in would fix it.
        if let code = envelope.code, signedOutCodes.contains(code) {
            throw UsageProviderError.needsAuth
        }
        guard let summary = envelope.data?.bizData else { throw ParseError.noWallet }
        // One wallet per currency, and which of them is listed first is the
        // server's choice rather than anything about the account. Taking the
        // first meant an account holding a funded CNY wallet and an empty USD
        // one showed 0%: the empty wallet was chosen, and the currency it named
        // is the one `total_costs` is looked up in, so a real balance and a real
        // cost in another currency were both read as zero.
        //
        // So the wallet that is actually funded or used is chosen instead, and
        // where more than one is, the largest — one figure is all the card
        // carries, and the biggest one is the one that means something. An
        // account with nothing in any wallet still reads as zero rather than
        // failing, which is the answer it had before.
        let candidates = summary.normalWallets.compactMap { wallet -> (Wallet, Double, Double)? in
            guard var balance = Double(wallet.balance), balance >= 0 else { return nil }
            // Granted credit is spendable too, so it is part of what is left.
            balance += summary.bonusWallets?.first { $0.currency == wallet.currency }
                .flatMap { Double($0.balance) } ?? 0
            let spent = summary.totalCosts.first { $0.currency == wallet.currency }
                .flatMap { Double($0.amount) } ?? 0
            guard spent >= 0 else { return nil }
            return (wallet, spent, balance)
        }
        guard let funded = candidates.max(by: { ($0.1 + $0.2) < ($1.1 + $1.2) }) ?? candidates.first
        else { throw ParseError.noWallet }

        return Reading(currency: funded.0.currency, spent: funded.1, balance: funded.2,
                       availableTokens: summary.totalAvailableTokenEstimation.flatMap(Int.init))
    }

    static func detail(fromJSON json: String) throws -> ProviderUsageDetail? {
        let payload = try payload(fromJSON: json)
        guard let amountData = try? JSONDecoder().decode(AmountEnvelope.self, from: Data(payload.amount.utf8)),
              let costData = try? JSONDecoder().decode(CostEnvelope.self, from: Data(payload.cost.utf8)) else {
            throw ParseError.malformed
        }
        guard amountData.data?.bizData != nil || costData.data?.bizData != nil else { return nil }

        var groups = [String: GroupAccumulator]()
        for series in amountData.data?.bizData?.series ?? [] {
            let key = apiKey(for: series.apiKey)
            var group = groups[key.id + "|" + series.model]
                ?? GroupAccumulator(apiKeyID: key.id, apiKeyLabel: key.label, model: series.model)
            for bucket in series.buckets where bucket.time >= payload.start && bucket.time < payload.end {
                var day = group.days[bucket.time] ?? DayAccumulator()
                day.cacheHitTokens += integer(bucket.usage["PROMPT_CACHE_HIT_TOKEN"])
                day.cacheMissTokens += integer(bucket.usage["PROMPT_CACHE_MISS_TOKEN"])
                day.outputTokens += integer(bucket.usage["RESPONSE_TOKEN"])
                day.requests += integer(bucket.usage["REQUEST"])
                group.days[bucket.time] = day
            }
            groups[group.id] = group
        }
        let currencyData = costData.data?.bizData?.data.first
        for series in currencyData?.series ?? [] {
            let key = apiKey(for: series.apiKey)
            var group = groups[key.id + "|" + series.model]
                ?? GroupAccumulator(apiKeyID: key.id, apiKeyLabel: key.label, model: series.model)
            for bucket in series.buckets where bucket.time >= payload.start && bucket.time < payload.end {
                var day = group.days[bucket.time] ?? DayAccumulator()
                day.cost += Double(bucket.cost.value) ?? 0
                group.days[bucket.time] = day
            }
            groups[group.id] = group
        }

        var detailGroups = [UsageDetailGroup]()
        for group in groups.values {
            var days = [UsageDetailDay]()
            for timestamp in group.days.keys.sorted() {
                guard let day = group.days[timestamp] else { continue }
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                let cacheHit = day.cacheHitTokens
                let cacheMiss = day.cacheMissTokens
                let output = day.outputTokens
                let requests = day.requests
                let cost = day.cost
                days.append(UsageDetailDay(date: date, cacheHitTokens: cacheHit,
                                           cacheMissTokens: cacheMiss, outputTokens: output,
                                           requests: requests, cost: cost))
            }
            detailGroups.append(UsageDetailGroup(apiKeyID: group.apiKeyID,
                                                 apiKeyLabel: group.apiKeyLabel,
                                                 model: group.model,
                                                 days: days))
        }
        detailGroups.sort {
            $0.apiKeyLabel == $1.apiKeyLabel ? $0.model < $1.model : $0.apiKeyLabel < $1.apiKeyLabel
        }
        return ProviderUsageDetail(start: Date(timeIntervalSince1970: TimeInterval(payload.start)),
                                   end: Date(timeIntervalSince1970: TimeInterval(payload.end)),
                                   timeZoneSeconds: payload.timeZoneSeconds,
                                   currency: currencyData?.currency ?? "CNY",
                                   groups: detailGroups)
    }

    /// DeepSeek's own codes for a missing (40002) or invalid (40003) token.
    private static let signedOutCodes: Set<Int> = [40002, 40003]

    private struct Envelope: Decodable { let code: Int?; let data: DataContainer? }
    private struct DataContainer: Decodable {
        let bizData: Summary
        enum CodingKeys: String, CodingKey { case bizData = "biz_data" }
    }
    private struct Summary: Decodable {
        let normalWallets: [Wallet]
        let bonusWallets: [Wallet]?
        let totalCosts: [Cost]
        let totalAvailableTokenEstimation: String?
        enum CodingKeys: String, CodingKey {
            case normalWallets = "normal_wallets"
            case bonusWallets = "bonus_wallets"
            case totalCosts = "total_costs"
            case totalAvailableTokenEstimation = "total_available_token_estimation"
        }
    }
    private struct Wallet: Decodable { let currency: String; let balance: String }
    private struct Cost: Decodable { let currency: String; let amount: String }
    private struct AmountEnvelope: Decodable { let data: AmountData? }
    private struct AmountData: Decodable {
        let bizData: AmountSummary?
        enum CodingKeys: String, CodingKey { case bizData = "biz_data" }
    }
    private struct AmountSummary: Decodable { let series: [AmountSeries] }
    private struct AmountSeries: Decodable {
        let apiKey: APIKey?
        let model: String
        let buckets: [AmountBucket]
        enum CodingKeys: String, CodingKey { case apiKey = "api_key"; case model, buckets }
    }
    private struct AmountBucket: Decodable {
        let time: Int
        let usage: [String: ScalarString]
    }
    private struct CostEnvelope: Decodable { let data: CostData? }
    private struct CostData: Decodable {
        let bizData: CostSummary?
        enum CodingKeys: String, CodingKey { case bizData = "biz_data" }
    }
    private struct CostSummary: Decodable { let data: [CostCurrency] }
    private struct CostCurrency: Decodable {
        let currency: String
        let series: [CostSeries]
    }
    private struct CostSeries: Decodable {
        let apiKey: APIKey?
        let model: String
        let buckets: [CostBucket]
        enum CodingKeys: String, CodingKey { case apiKey = "api_key"; case model, buckets }
    }
    private struct CostBucket: Decodable { let time: Int; let cost: ScalarString }
    private struct ScalarString: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { value = "0" }
            else if let string = try? container.decode(String.self) { value = string }
            else if let int = try? container.decode(Int.self) { value = String(int) }
            else if let double = try? container.decode(Double.self) { value = String(double) }
            else { throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected scalar")) }
        }
    }
    private struct APIKey: Decodable {
        let name: String?
        let trackingID: String?
        enum CodingKeys: String, CodingKey { case name; case trackingID = "tracking_id" }
    }
    private struct DayAccumulator {
        var cacheHitTokens = 0
        var cacheMissTokens = 0
        var outputTokens = 0
        var requests = 0
        var cost = 0.0
    }
    private struct GroupAccumulator {
        let apiKeyID: String
        let apiKeyLabel: String
        let model: String
        var days = [Int: DayAccumulator]()
        var id: String { apiKeyID + "|" + model }
    }
    private static func apiKey(for key: APIKey?) -> (id: String, label: String) {
        if let name = key?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let id = key?.trackingID?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (id?.isEmpty == false ? id! : name, name)
        }
        if let id = key?.trackingID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return (id, "Unnamed API key")
        }
        return ("unknown", "Unnamed API key")
    }
    private static func integer(_ value: ScalarString?) -> Int {
        guard let value else { return 0 }
        return Int(value.value) ?? Int(Double(value.value) ?? 0)
    }
}
