import Foundation

/// Parses `kiro-cli chat --no-interactive "/usage"` stdout.
///
/// The CLI paints a TUI card — ANSI, box drawing, a █ bar. A plan name
/// without a percent or `(X of Y covered in plan)` is a reading with no
/// meters, not a 0% invented for the ring. The free-tier bar sometimes
/// omits the credits line; the ring then follows the percent alone.
enum KiroUsage {
    struct Reading {
        var plan: String?
        var windows: [LimitWindow]
        var hasUsageMetrics: Bool
        var bonusUsed: Double?
        var bonusTotal: Double?
        var overageEnabled: Bool?
        var overageUsedCLI: Double?
    }

    private static let monthlyDuration: TimeInterval = 30 * 86400
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func parseCLIOutput(_ text: String, now: Date = Date()) throws -> Reading {
        let stripped = stripANSI(text)
        // ASCII phrases, POSIX folding: Turkish `I` → `ı` would miss "in" / "login".
        let lowered = stripped.lowercased(with: posix)

        let planRaw = planName(in: stripped)
        let percent = percentValue(in: stripped)
        let credits = creditPair(in: stripped)
        let resetsAt = resetDate(in: stripped, now: now)
        let bonus = bonusCredits(in: stripped)
        let overageEnabled = overageFlag(in: stripped)
        let overageUsedCLI = firstDouble(in: stripped, pattern: #"(?i)Credits used:\s*([\d,]+\.?\d*)"#)

        // Percent wins when both are present. `(X of Y covered)` is used of
        // total — the dashboard's "X used / Y covered" — not remaining.
        let usedFraction: Double? = {
            if let percent { return percent / 100 }
            guard let credits, credits.total > 0 else { return nil }
            return credits.used / credits.total
        }()
        let hasUsageMetrics = usedFraction != nil

        if planRaw == nil, !hasUsageMetrics, bonus.used == nil {
            if lowered.contains("not logged in")
                || lowered.contains("login required")
                || lowered.contains("failed to initialize auth portal")
                || lowered.contains("kiro-cli login")
                || lowered.contains("oauth error") {
                throw UsageProviderError.needsAuth
            }
            throw UsageProviderError.nothingMetered(L10n.t("Kiro CLI reported no usage"))
        }

        var windows: [LimitWindow] = []
        if let usedFraction {
            // A calendar reset, or the "Monthly credits" heading, is the
            // monthly pool; a bar with neither is not assumed to be 30 days.
            let monthly = resetsAt != nil
                || stripped.range(of: "monthly", options: .caseInsensitive) != nil
            windows.append(LimitWindow(
                id: "credits",
                label: L10n.t("Credits"),
                usedFraction: usedFraction,
                resetsAt: resetsAt,
                duration: monthly ? monthlyDuration : nil
            ))
        }

        if let used = bonus.used, let total = bonus.total, total > 0 {
            let leftover = total - used
            windows.append(LimitWindow(
                id: "bonus",
                group: L10n.t("Bonus"),
                label: L10n.t("Credits"),
                usedFraction: used / total,
                remaining: leftover >= 0 ? Int(leftover.rounded()) : nil,
                resetsAt: bonus.expiryDays.flatMap { days in
                    gregorian.date(byAdding: .day, value: days, to: now)
                }
            ))
        }

        return Reading(
            plan: planRaw.map(displayPlanName),
            windows: windows,
            hasUsageMetrics: hasUsageMetrics,
            bonusUsed: bonus.used,
            bonusTotal: bonus.total,
            overageEnabled: overageEnabled,
            overageUsedCLI: overageUsedCLI
        )
    }

    /// `KIRO FREE` → "Kiro Free"; names that do not mention KIRO stay as printed.
    static func displayPlanName(_ raw: String) -> String {
        let trimmed = stripANSI(raw)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        guard trimmed.range(of: "KIRO", options: [.caseInsensitive, .literal]) != nil else {
            return trimmed
        }
        return trimmed
            .split(separator: " ")
            .map { word -> String in
                if word.lowercased(with: posix) == "kiro" { return "Kiro" }
                let head = String(word.prefix(1)).uppercased(with: posix)
                let tail = String(word.dropFirst()).lowercased(with: posix)
                return head + tail
            }
            .joined(separator: " ")
    }

    /// CSI (`ESC [ …`, including colon-separated SGR), OSC (`ESC ] … BEL` /
    /// `ESC ] … ST`), charset (`ESC ( B`), and 2-byte C1 (`ESC` + 0x40–0x5F
    /// except `[` / `]`, which belong to CSI / OSC).
    static func stripANSI(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return ansi.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    // MARK: - Pieces

    private static let ansi = try! NSRegularExpression(
        pattern: "\u{001B}\\[[0-9;:?]*[ -/]*[@-~]"
            + "|\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)"
            + "|\u{001B}[()][0-9A-Za-z]"
            + "|\u{001B}[@-Z\\\\^_]"
    )

    /// Civil dates the CLI prints, not the user's preferred calendar.
    private static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Calendar.current.timeZone
        calendar.locale = posix
        return calendar
    }

    /// `Plan:` is not anchored at column 0 — the TUI wraps the line in box
    /// drawing. Horizontal whitespace only on the pipe form, so `| KIRO`
    /// cannot swallow the next line.
    private static func percentValue(in text: String) -> Double? {
        if let val = firstDouble(in: text, pattern: #"[█▓▒░■#=\-─━]+\s*(\d+(?:\.\d+)?)\s*%"#) {
            return val
        }
        if let val = firstDouble(in: text, pattern: #"(?i)Credits[^\n%]*?\s+(\d+(?:\.\d+)?)\s*%"#) {
            return val
        }
        if let val = firstDouble(in: text, pattern: #"(?:^|\n)[^\n%]*?[█▓▒░■#=\-─━\s]{3,}\s*(\d+(?:\.\d+)?)\s*%"#) {
            return val
        }
        return nil
    }

    /// `Plan:` is not anchored at column 0 — the TUI wraps the line in box
    /// drawing. Horizontal whitespace only on the pipe form, so `| KIRO`
    /// cannot swallow the next line.
    private static func planName(in text: String) -> String? {
        if let name = firstCapture(
            in: text,
            pattern: #"(?i)Plan:[ \t]*([^|│┃\r\n]+?)[ \t]*[|│┃][ \t]*[0-9]+[ \t]+usage breakdowns?"#
        ), !name.isEmpty {
            return name
        }
        if let line = text.components(separatedBy: .newlines).first(where: {
            $0.range(of: "Estimated Usage", options: .caseInsensitive) != nil
        }) {
            let parts = line.split(whereSeparator: { $0 == "|" || $0 == "│" || $0 == "┃" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for part in parts.dropFirst() {
                if part.range(of: "resets on", options: .caseInsensitive) == nil {
                    return part
                }
            }
        }
        if let name = firstCapture(
            in: text,
            pattern: #"(?i)(?:^|\n)[ \t]*[|│┃][ \t]*((?:KIRO)(?:[ \t]+[A-Za-z0-9+]+)+)"#
        ), !name.isEmpty {
            return name
        }
        if let name = firstCapture(
            in: text,
            pattern: #"(?i)Plan:[ \t]*([^|│┃\r\n]+)"#
        ), !name.isEmpty {
            return name
        }
        return nil
    }

    private static func creditPair(in text: String) -> (used: Double, total: Double)? {
        let values = captures(
            in: text,
            pattern: #"(?:\(|\b)([\d,]+\.?\d*)\s*(?:of|/)\s*([\d,]+\.?\d*)\s*(?:credits\s+)?covered"#
        )
        guard values.count >= 2,
              let used = parseNumber(values[0]),
              let total = parseNumber(values[1])
        else { return nil }
        return (used, total)
    }

    private static func parseNumber(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }

    private static func bonusCredits(in text: String) -> (used: Double?, total: Double?, expiryDays: Int?) {
        let pair = captures(in: text, pattern: #"(?i)Bonus credits:\s*([\d,]+\.?\d*)\s*(?:/|of)\s*([\d,]+\.?\d*)"#)
        let used = pair.count >= 2 ? parseNumber(pair[0]) : nil
        let total = pair.count >= 2 ? parseNumber(pair[1]) : nil
        let expiryDays = firstCapture(in: text, pattern: #"(?i)expires in (\d+) days?"#).flatMap(Int.init)
        return (used, total, expiryDays)
    }

    private static func overageFlag(in text: String) -> Bool? {
        guard let status = firstCapture(in: text, pattern: #"(?i)Overages?:\s*([^\n]+)"#) else {
            return nil
        }
        let lower = status.lowercased(with: posix)
        if lower.hasPrefix("disabled") { return false }
        if lower.hasPrefix("enabled") { return true }
        return nil
    }

    /// `YYYY-MM-DD` as printed; `MM/DD` is this year when that day is still
    /// ahead (or today), otherwise next — a January reset read in December
    /// is next year's. Compared on the start of the local day so a reset
    /// read *on* that date is not pushed a year out.
    private static func resetDate(in text: String, now: Date) -> Date? {
        guard let stamp = firstCapture(
            in: text,
            pattern: #"(?i)resets on\s*:?\s*(\d{4}[-/]\d{2}[-/]\d{2}|\d{1,2}/\d{1,2})"#
        ) else { return nil }

        let calendar = gregorian
        if stamp.contains("-") || stamp.count >= 8 {
            let normalized = stamp.replacingOccurrences(of: "/", with: "-")
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = posix
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: normalized)
        }

        let parts = stamp.split(separator: "/")
        guard parts.count == 2,
              let month = Int(parts[0]), (1...12).contains(month),
              let day = Int(parts[1]), (1...31).contains(day)
        else { return nil }

        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: today)
        var components = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                        year: year, month: month, day: day)
        if let date = calendar.date(from: components), date >= today {
            return date
        }
        components.year = year + 1
        return calendar.date(from: components)
    }

    private static func firstDouble(in text: String, pattern: String) -> Double? {
        firstCapture(in: text, pattern: pattern).flatMap(parseNumber)
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        captures(in: text, pattern: pattern).first
    }

    private static func captures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let slice = Range(range, in: text) else { return nil }
            return String(text[slice]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
