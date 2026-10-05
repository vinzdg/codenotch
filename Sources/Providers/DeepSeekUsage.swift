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
    }

    enum ParseError: Error { case malformed, noWallet }

    static func payload(fromJSON json: String) throws -> FetchPayload {
        guard let data = json.data(using: .utf8) else { throw ParseError.malformed }
        return try JSONDecoder().decode(FetchPayload.self, from: data)
    }

    /// Prefer the wallet with the largest funded+spent total so a zero USD
    /// wallet listed first does not hide a funded CNY balance (#413).
    private static func preferredWallet(in summary: Summary) -> (wallet: Wallet, spent: Double)? {
        var best: (Wallet, Double, Double)?
        for wallet in summary.normalWallets {
            guard let balance = Double(wallet.balance), balance >= 0 else { continue }
            let spent = summary.totalCosts.first(where: { $0.currency == wallet.currency })
                .flatMap { Double($0.amount) } ?? 0
            guard spent >= 0 else { continue }
            let score = spent + balance
            if let current = best {
                if score > current.2 { best = (wallet, spent, score) }
            } else {
                best = (wallet, spent, score)
            }
        }
        guard let chosen = best else { return nil }
        return (chosen.0, chosen.1)
    }

    static func reading(fromJSON json: String) throws -> Reading {
        guard let data = json.data(using: .utf8) else { throw ParseError.malformed }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let summary = envelope.data?.bizData,
              let chosen = preferredWallet(in: summary) else { throw ParseError.noWallet }
        let wallet = chosen.wallet
        let spent = chosen.spent
        guard let balance = Double(wallet.balance), spent >= 0, balance >= 0 else {
            throw ParseError.malformed
        }
        return Reading(currency: wallet.currency, spent: spent, balance: balance,
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

    private struct Envelope: Decodable { let data: DataContainer? }
    private struct DataContainer: Decodable {
        let bizData: Summary
        enum CodingKeys: String, CodingKey { case bizData = "biz_data" }
    }
    private struct Summary: Decodable {
        let normalWallets: [Wallet]
        let totalCosts: [Cost]
        let totalAvailableTokenEstimation: String?
        enum CodingKeys: String, CodingKey {
            case normalWallets = "normal_wallets"
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
