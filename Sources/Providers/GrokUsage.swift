import Foundation

/// Parses `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`.
///
/// That is the same credits payload Grok Build's own usage UI is built from,
/// so the numbers are `.official`. The shape is not a published API: it is
/// pinned by tests, including a response recorded from a live SuperGrok Heavy
/// session, because this is the first place a change would show.
///
/// `creditUsagePercent` is already a percentage (1.0 is 1%, not "all of it").
/// Treating it as a 0…1 fraction would draw a full ring on a nearly unused
/// Heavy week. Product rows without `usagePercent` are listed by grok.com at
/// rest with no reading; dropping them beats inventing a zero.
enum GrokUsage {
    struct Payload {
        let windows: [LimitWindow]
        /// From `/v1/settings`, not this payload — the credits object does not
        /// name the plan.
        var plan: String?
    }

    struct CreditsResponse: Decodable {
        struct Config: Decodable {
            struct Period: Decodable {
                let type: String?
                let start: Date?
                let end: Date?
            }
            struct Product: Decodable {
                let product: String
                let usagePercent: Double?
            }
            let currentPeriod: Period?
            let creditUsagePercent: Double?
            let productUsage: [Product]?
            let billingPeriodEnd: Date?
        }
        let config: Config?
    }

    struct SettingsResponse: Decodable {
        let subscriptionTierDisplay: String?
    }

    static func parse(_ data: Data) throws -> Payload {
        let response = try decoder.decode(CreditsResponse.self, from: data)
        guard let config = response.config else {
            throw UsageProviderError.badResponse(status: 0)
        }
        var windows: [LimitWindow] = []

        let resetsAt = config.currentPeriod?.end ?? config.billingPeriodEnd
        if let resetsAt {
            let percent = config.creditUsagePercent ?? 0
            windows.append(LimitWindow(
                id: "weekly",
                label: label(forPeriod: config.currentPeriod?.type),
                usedFraction: percent / 100,
                resetsAt: resetsAt
            ))
        }

        for product in config.productUsage ?? [] {
            guard let percent = product.usagePercent else { continue }
            windows.append(LimitWindow(
                id: "product:\(product.product)",
                label: label(forProduct: product.product),
                usedFraction: percent / 100,
                resetsAt: resetsAt
            ))
        }

        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered("Grok did not report a usage window")
        }
        return Payload(windows: windows)
    }

    static func planName(from data: Data) -> String? {
        (try? decoder.decode(SettingsResponse.self, from: data))?.subscriptionTierDisplay
    }

    static func label(forPeriod type: String?) -> String {
        switch type {
        case "USAGE_PERIOD_TYPE_WEEKLY":  return "Weekly"
        case "USAGE_PERIOD_TYPE_MONTHLY": return "Monthly"
        default:                          return "Credits"
        }
    }

    static func label(forProduct product: String) -> String {
        switch product {
        case "GrokBuild": return "Grok Build"
        case "GrokChat":  return "Grok Chat"
        case "GrokVoice": return "Grok Voice"
        default:
            return product
                .replacingOccurrences(of: "Grok", with: "Grok ")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unparseable date \(text)")
            )
        }
        return decoder
    }()
}
