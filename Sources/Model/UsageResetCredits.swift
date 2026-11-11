import Foundation

/// Unused rate-limit resets reported by a provider.
struct UsageResetCredits: Equatable, Sendable {
    struct Credit: Equatable, Sendable, Identifiable {
        let id: String
        let status: String
        let expiresAt: Date?
        let count: Int

        init(id: String, status: String, expiresAt: Date? = nil, count: Int = 1) {
            self.id = id
            self.status = status
            self.expiresAt = expiresAt
            self.count = count
        }
    }

    let availableCount: Int
    let credits: [Credit]
    /// A cached observation must stay dated even when usage itself refreshes.
    var checkedAt: Date? = nil

    init(availableCount: Int, credits: [Credit] = [], checkedAt: Date? = nil) {
        self.availableCount = availableCount
        self.credits = credits
        self.checkedAt = checkedAt
    }

    /// Credits still available, soonest expiry first.
    var available: [Credit] {
        credits.filter { $0.status == "available" }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// Expiry still applies while UsageStore is showing the last good reading.
    /// Keep the reported total: Codex can return a truncated list of credits.
    func unexpired(at now: Date) -> UsageResetCredits {
        let expired = available.filter { ($0.expiresAt ?? .distantFuture) <= now }
        return UsageResetCredits(
            availableCount: max(0, availableCount - expired.reduce(0) { $0 + $1.count }),
            credits: credits.filter { ($0.expiresAt ?? .distantFuture) > now },
            checkedAt: checkedAt
        )
    }

    var nextExpiry: Date? { available.compactMap(\.expiresAt).min() }
}
