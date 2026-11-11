import Foundation

/// Amp's internal API returns display text, not structured quota fields.
/// Unknown wording must fail visibly rather than turn a missing match into 0%.
enum AmpUsage {
    static let endpoint = URL(string: "https://ampcode.com/api/internal")!

    struct Reading {
        let plan: String
        let windows: [LimitWindow]
        let headlineID: String
        let fidelity: Fidelity
    }

    static func parse(_ data: Data) throws -> Reading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] == nil || root["ok"] as? Bool == true,
              root["error"] == nil || root["error"] is NSNull,
              let payload = (root["result"] as? [String: Any]) ?? (root["result"] == nil ? root : nil),
              let displayText = payload["displayText"] as? String
        else { throw invalidResponse }

        let text = displayText.replacingOccurrences(of: "**", with: "")
        let number = #"([0-9]+(?:\.[0-9]+)?)"#
        let subscription = #"^\s*Amp[ \t]+([^\r\n:]+?)[ \t]+Subscription:[ \t]+"#
            + number + #"%[ \t]+(?:other|agent)[ \t]+usage[ \t]+and[ \t]+"#
            + number + #"%[ \t]+orb[ \t]+usage[ \t]+remaining\b"#
        let amount = #"([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)"#
        let tier = #"^\s*Amp[ \t]+([^\r\n:]+?)[ \t]+Tier:[ \t]+agent usage \$"#
            + amount + #" of \$"# + amount + #" remaining \("# + number
            + #"%\), orb usage "# + amount + #"h of "# + amount
            + #"h (?:[a-z0-9._-]+ )?orb hours remaining \("# + number + #"%\)"#
        let subscriptionFields: [String]?
        if let fields = captures(tier, in: text) {
            guard validBalance(remaining: fields[1], total: fields[2]),
                  validBalance(remaining: fields[4], total: fields[5]) else { throw invalidResponse }
            // The current CLI includes dollars and orb hours alongside its
            // rounded percentages. Use those percentages so the ring agrees
            // with Amp, rather than deriving a more precise-looking number.
            subscriptionFields = [fields[0], fields[3], fields[6]]
        } else {
            subscriptionFields = captures(subscription, in: text)
        }
        if let fields = subscriptionFields,
           let agent = Double(fields[1]), let orb = Double(fields[2]),
           (0...100).contains(agent), (0...100).contains(orb) {
            var windows = [
                LimitWindow(id: "agent", label: L10n.t("Agent usage"), usedFraction: (100 - agent) / 100),
                LimitWindow(id: "orb", label: L10n.t("Orb usage"), usedFraction: (100 - orb) / 100)
            ]
            // Integer days are too coarse for a reset timestamp or pace ring.
            // Keep the vendor's approximation as text instead of a moving date.
            if let renewal = captures(#"resets upon renewal in ([0-9]+) days?\b"#, in: text),
               let days = Int(renewal[0]) {
                windows.append(LimitWindow(
                    id: "renewal", label: L10n.t("Renewal"),
                    detail: days == 1 ? L10n.t("About 1 day") : L10n.t("About \(days) days")
                ))
            }
            return Reading(plan: fields[0], windows: windows, headlineID: "agent", fidelity: .official)
        }

        // Do not fall through to a Free allowance if a subscription was
        // present but malformed; that would silently change the ring's meaning.
        guard !text.localizedCaseInsensitiveContains("Subscription:"),
              !text.localizedCaseInsensitiveContains("Tier:") else { throw invalidResponse }
        let free = #"^\s*Amp Free:[ \t]+\$"# + number + #"/\$"# + number
            + #"[ \t]+remaining[ \t]+\(replenishes[ \t]+\+\$"# + number + #"/hour\)"#
        if let fields = captures(free, in: text),
           let remaining = Double(fields[0]), let total = Double(fields[1]),
           let rate = Double(fields[2]),
           remaining.isFinite, total.isFinite, rate.isFinite,
           total > 0, remaining <= total {
            let balance = money(remaining)
            let allowance = money(total)
            let hourly = money(rate)
            return Reading(plan: L10n.t("Free"), windows: [
                LimitWindow(id: "free", label: L10n.t("Free allowance"),
                            usedFraction: (total - remaining) / total),
                LimitWindow(id: "freeBalance", label: L10n.t("Free balance"),
                            detail: L10n.t("\(balance) of \(allowance) left")),
                LimitWindow(id: "replenishment", label: L10n.t("Replenishment"),
                            detail: L10n.t("\(hourly)/hour"))
            ], headlineID: "free", fidelity: .derived)
        }
        throw invalidResponse
    }

    private static var invalidResponse: UsageProviderError {
        .apiError(L10n.t("Amp returned an unrecognized usage response. Try again later."))
    }

    private static func validBalance(remaining: String, total: String) -> Bool {
        guard let remaining = Double(remaining.replacingOccurrences(of: ",", with: "")),
              let total = Double(total.replacingOccurrences(of: ",", with: "")) else { return false }
        return remaining.isFinite && total.isFinite && total > 0 && remaining <= total
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).map { (text as NSString).substring(with: match.range(at: $0)) }
    }

    private static func money(_ value: Double) -> String {
        String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
