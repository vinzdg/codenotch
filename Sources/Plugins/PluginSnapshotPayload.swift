import Foundation

/// The JSON a plugin prints on stdout when Codenotch executes it, as specified
/// in `docs/design/plugin-protocol.md`. Identity — id, display name, glyph —
/// deliberately does not appear here: it comes from the manifest, so a plugin
/// cannot rename itself underneath its own settings row.
struct PluginSnapshotPayload: Decodable, Sendable {
    struct Money: Decodable, Sendable {
        let currency: String
        let spent: Double
        let remaining: Double
    }

    struct Window: Decodable, Sendable {
        let id: String
        let label: String
        let group: String?
        let usedFraction: Double?
        let remaining: Int?
        let used: Int?
        let usedText: String?
        let detail: String?
        let money: Money?
        let resetsAt: Date?
        let duration: TimeInterval?
    }

    struct Account: Decodable, Sendable {
        let label: String?
        let plan: String?
        let source: String?
        let manageURL: URL?
    }

    let fidelity: String?
    let plan: String?
    let headlineID: String?
    let weeklyID: String?
    let account: Account?
    let windows: [Window]

    /// Payload dates are ISO-8601; everything else the wire might say is
    /// already represented above.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO-8601 date: \(text)")
        }
        return decoder
    }

    /// `Fidelity` is how much the UI trusts the number. Omitted means
    /// `official` (the protocol's default); an unrecognised spelling must not
    /// silently upgrade to it, so it degrades to `derived` instead.
    private var resolvedFidelity: Fidelity {
        guard let fidelity else { return .official }
        return Fidelity(rawValue: fidelity) ?? .derived
    }

    func snapshot(for manifest: PluginManifest) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(
            id: manifest.id,
            displayName: manifest.displayName,
            glyph: .external,
            fidelity: resolvedFidelity,
            status: .ok,
            windows: windows.map { window in
                LimitWindow(
                    id: window.id,
                    group: window.group,
                    label: window.label,
                    usedFraction: window.usedFraction,
                    remaining: window.remaining,
                    used: window.used,
                    usedText: window.usedText,
                    detail: window.detail,
                    money: window.money.map {
                        UsageMoneyBreakdown(currency: $0.currency, spent: $0.spent, remaining: $0.remaining)
                    },
                    resetsAt: window.resetsAt,
                    duration: window.duration
                )
            }
        )
        snapshot.headlineID = headlineID
        snapshot.weeklyID = weeklyID
        snapshot.plan = plan.flatMap(\.nonEmptyPlan)
        return snapshot
    }

    func providerAccount() -> ProviderAccount? {
        guard let account else { return nil }
        return ProviderAccount(
            label: account.label,
            plan: account.plan,
            source: account.source ?? "plugin",
            manageURL: account.manageURL
        )
    }
}
