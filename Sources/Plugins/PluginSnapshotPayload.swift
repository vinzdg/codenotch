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

    /// What a payload may say, in size and range. The plugin is code the
    /// user approved, but what it prints each poll drives layout, arithmetic
    /// and notifications, and none of those should be at the mercy of a
    /// bug — or a bad day — on the other side of the pipe. Text is cut to
    /// length, numbers are clamped or dropped, dates outside the horizon are
    /// dropped: a reading is kept readable rather than refused.
    enum Bounds {
        static let windows = 16
        /// Ids, labels, groups, currencies, plan names.
        static let shortText = 64
        /// Free text: `usedText`, `detail`, account fields.
        static let text = 200
        /// `usedFraction` is 0…1 by meaning; a little over is an overage
        /// worth showing, ten times over is not a number.
        static let fractionCeiling = 10.0
        static let moneyCeiling = 1_000_000_000.0
        /// `resetsAt` and `duration` within a year either way of now — a
        /// reset scheduled for 2099, or in 1970, would schedule nothing
        /// useful and drives the reset alerts.
        static let horizon: TimeInterval = 366 * 86_400
        /// A plugin may ask to be left alone, for up to an hour.
        static let retryAfter = 1.0...3_600.0
    }

    func snapshot(for manifest: PluginManifest, now: Date = Date()) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(
            id: manifest.id,
            displayName: manifest.displayName,
            glyph: .external,
            fidelity: resolvedFidelity,
            status: .ok,
            windows: windows.prefix(Bounds.windows).map { window in
                LimitWindow(
                    id: Self.cut(window.id, to: Bounds.shortText),
                    group: window.group.map { Self.cut($0, to: Bounds.shortText) },
                    label: Self.cut(window.label, to: Bounds.shortText),
                    usedFraction: window.usedFraction.flatMap { Self.clamp($0, to: 0...Bounds.fractionCeiling) },
                    remaining: window.remaining.map { max($0, 0) },
                    used: window.used.map { max($0, 0) },
                    usedText: window.usedText.map { Self.cut($0, to: Bounds.text) },
                    detail: window.detail.map { Self.cut($0, to: Bounds.text) },
                    money: window.money.flatMap { money in
                        guard let spent = Self.clamp(money.spent, to: 0...Bounds.moneyCeiling),
                              let remaining = Self.clamp(money.remaining, to: 0...Bounds.moneyCeiling)
                        else { return nil }
                        return UsageMoneyBreakdown(currency: Self.cut(money.currency, to: Bounds.shortText),
                                                   spent: spent, remaining: remaining)
                    },
                    resetsAt: window.resetsAt.flatMap { Self.withinHorizon($0, of: now) },
                    duration: window.duration.flatMap { Self.clamp($0, to: 0...Bounds.horizon) }
                )
            }
        )
        snapshot.headlineID = headlineID.map { Self.cut($0, to: Bounds.shortText) }
        snapshot.weeklyID = weeklyID.map { Self.cut($0, to: Bounds.shortText) }
        snapshot.plan = plan.flatMap(\.nonEmptyPlan).map { Self.cut($0, to: Bounds.shortText) }
        return snapshot
    }

    func providerAccount() -> ProviderAccount? {
        guard let account else { return nil }
        // The row hands this straight to NSWorkspace.open: https or nothing.
        let manageURL = account.manageURL.flatMap {
            $0.scheme?.lowercased() == "https" ? $0 : nil
        }
        return ProviderAccount(
            label: account.label.map { Self.cut($0, to: Bounds.text) },
            plan: account.plan.map { Self.cut($0, to: Bounds.text) },
            source: Self.cut(account.source ?? "plugin", to: Bounds.text),
            manageURL: manageURL
        )
    }

    /// The rate-limit hint, clamped: `{"retryAfterSeconds": N}` on stdout.
    static func retryAfter(in stdout: Data) -> TimeInterval? {
        struct Hint: Decodable { let retryAfterSeconds: TimeInterval }
        guard let hint = try? JSONDecoder().decode(Hint.self, from: stdout) else { return nil }
        return clamp(hint.retryAfterSeconds, to: Bounds.retryAfter)
    }

    static func cut(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }

    /// Nil for NaN and the infinities — no number at all beats a fake one.
    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double? {
        guard value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func withinHorizon(_ date: Date, of now: Date) -> Date? {
        abs(date.timeIntervalSince(now)) <= Bounds.horizon ? date : nil
    }
}
