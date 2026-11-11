import Foundation

/// The `cedar_ember` block in Claude's usage response. The block is opt-in
/// (`?cedar_ember=1`); an ordinary usage response can leave it null.
struct ClaudeResetCredits: Decodable, Equatable, Sendable {
    struct Grant: Decodable, Equatable, Sendable {
        let id: String
        let resetsLeft: Int
        let startsAt: Date
        let endsAt: Date
        let paused: Bool
    }

    let eligible: Bool
    let ineligibleReason: String?
    let grants: [Grant]

    private enum CodingKeys: String, CodingKey {
        case eligible, ineligibleReason, grants
    }

    private struct GrantEntry: Decodable {
        let value: Grant?
        init(from decoder: Decoder) throws {
            value = try? Grant(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eligible = try container.decode(Bool.self, forKey: .eligible)
        ineligibleReason = try? container.decodeIfPresent(String.self, forKey: .ineligibleReason)
        grants = try container.decode([GrantEntry].self, forKey: .grants).compactMap(\.value)
    }

    func credits(at now: Date) -> UsageResetCredits? {
        // OAuth currently refuses this surface even for an eligible account.
        // That is unknown, not evidence that Desktop's unused reset is gone.
        if !eligible && ineligibleReason == "surface" { return nil }
        let available = eligible ? grants.filter {
            $0.resetsLeft > 0 && !$0.paused && $0.startsAt <= now && $0.endsAt > now
        } : []
        var count = 0
        for grant in available {
            let (total, overflow) = count.addingReportingOverflow(grant.resetsLeft)
            guard !overflow else { return nil }
            count = total
        }
        return UsageResetCredits(availableCount: count, credits: available.map {
            .init(id: $0.id, status: "available", expiresAt: $0.endsAt, count: $0.resetsLeft)
        })
    }
}
