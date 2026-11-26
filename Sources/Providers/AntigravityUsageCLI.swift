import Foundation
import os

/// Reads Antigravity usage from the official `agy` CLI (`agy --print /usage`)
/// without requiring or launching Antigravity IDE.
///
/// Mirrors `ClaudeUsageCLI` on macOS and `windows/codenotch/src/agy_cli.rs` on
/// Windows: runs `agy` in a dedicated scratch directory with auto-update
/// disabled, strips ANSI escape codes, and parses the quota report into
/// standard `LimitWindow` values.
struct AntigravityUsageCLI: Sendable {
    let binary: URL
    let output: @Sendable () throws -> String

    init(binary: URL, output: @escaping @Sendable () throws -> String) {
        self.binary = binary
        self.output = output
    }

    static let timeout: TimeInterval = 35
    static let maxOutputBytes = 65_536
    static let arguments = ["--sandbox", "--print-timeout", "30s", "--print", "/usage"]

    /// Disables `agy`'s background auto-updater during quota polls.
    static let disableAutoUpdateEnv = ("AGY_CLI_DISABLE_AUTO_UPDATE", "true")

    private static let homeRelativePaths = [
        ".local/bin/agy",
        ".gemini/bin/agy",
    ]

    private static let systemPaths = [
        "opt/homebrew/bin/agy",
        "usr/local/bin/agy",
    ]

    static func locate(
        home: URL = AntigravityProfile.homeDirectory,
        root: URL = URL(fileURLWithPath: "/"),
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        fileManager: FileManager = .default
    ) -> AntigravityUsageCLI? {
        var candidates = homeRelativePaths.map { home.appendingPathComponent($0) }
            + systemPaths.map { root.appendingPathComponent($0) }

        if let path {
            for entry in path.split(separator: ":") {
                let dir = String(entry)
                guard dir.hasPrefix("/") else { continue }
                candidates.append(URL(fileURLWithPath: dir).appendingPathComponent("agy"))
            }
        }

        guard let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            return nil
        }
        return AntigravityUsageCLI(binary: found) { try run(binary: found) }
    }

    static func scratchDirectory(
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"),
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = applicationSupport
            .appendingPathComponent("Codenotch", isDirectory: true)
            .appendingPathComponent("antigravity-quota-work", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func read() async throws -> [LimitWindow] {
        let text = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try self.output() })
            }
        }
        return try Self.parse(text)
    }

    private static func run(binary: URL) throws -> String {
        let scratch = try scratchDirectory()

        var environment = ProcessInfo.processInfo.environment
        environment[disableAutoUpdateEnv.0] = disableAutoUpdateEnv.1
        environment["PWD"] = scratch.path

        let process = Process()
        process.executableURL = binary
        process.arguments = Self.arguments
        process.currentDirectoryURL = scratch
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let reader = output.fileHandleForReading
        var data = Data()
        var exceededLimit = false
        while true {
            let chunk = reader.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            if data.count + chunk.count > maxOutputBytes {
                exceededLimit = true
                if process.isRunning { process.terminate() }
                break
            }
            data.append(chunk)
        }
        process.waitUntilExit()

        guard !exceededLimit else {
            throw UsageProviderError.badResponse(status: 0)
        }
        guard process.terminationStatus == 0 else {
            Log.usage.debug("agy /usage exited \(process.terminationStatus)")
            throw UsageProviderError.needsAuth
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return text
    }

    // MARK: - Output Sanitization & Parsing

    /// Strips ANSI escape sequences (CSI, OSC, 2-char Fe) and normalizes line endings.
    static func sanitize(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        let scalars = Array(input.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c.value == 0x1B {
                if i + 1 < scalars.count {
                    let next = scalars[i + 1]
                    if next == "[" {
                        i += 2
                        while i < scalars.count {
                            let b = scalars[i].value
                            i += 1
                            if (0x40...0x7E).contains(b) { break }
                        }
                        continue
                    } else if next == "]" {
                        i += 2
                        while i < scalars.count {
                            let b = scalars[i].value
                            i += 1
                            if b == 0x07 { break }
                            if b == 0x1B, i < scalars.count, scalars[i] == "\\" {
                                i += 1
                                break
                            }
                        }
                        continue
                    } else if (0x40...0x5F).contains(next.value) {
                        i += 2
                        continue
                    }
                }
                i += 1
            } else if c == "\r" {
                if i + 1 < scalars.count, scalars[i + 1] == "\n" {
                    i += 1
                } else {
                    out.append("\n")
                    i += 1
                }
            } else {
                out.unicodeScalars.append(c)
                i += 1
            }
        }
        return out
    }

    static func parse(
        _ text: String,
        resolveLocal: ((DateComponents) -> Date?)? = nil
    ) throws -> [LimitWindow] {
        let clean = sanitize(text)
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hasHeader = lines.contains { $0.trimmingCharacters(in: .whitespaces) == "Quota:" }
        let hasTSVRows = lines.contains { line in
            line.contains("\t") && (line.contains("Limit Remaining") || (line.contains("Argon") && line.contains("Limit")))
        }
        guard hasHeader || hasTSVRows else {
            throw UsageProviderError.badResponse(status: 0)
        }

        let quotaLines = lines.filter { line in
            line.contains("Limit Remaining") || (line.contains("Argon") && line.contains("Limit"))
        }

        var windows: [LimitWindow] = []
        for line in quotaLines {
            guard let pctIndex = line.lastIndex(of: "%") else {
                throw UsageProviderError.badResponse(status: 0)
            }
            let left = String(line[..<pctIndex]).trimmingCharacters(in: .whitespaces)
            let resetText = String(line[line.index(after: pctIndex)...])

            guard let splitIdx = left.lastIndex(where: { $0.isWhitespace }) else {
                throw UsageProviderError.badResponse(status: 0)
            }
            let rawLabel = String(left[..<splitIdx])
            let remainingStr = String(left[splitIdx...]).trimmingCharacters(in: .whitespaces)

            guard let remaining = Double(remainingStr),
                  remaining.isFinite,
                  (0.0...100.0).contains(remaining) else {
                throw UsageProviderError.badResponse(status: 0)
            }

            guard let resetDate = parseResetTime(resetText, resolveLocal: resolveLocal),
                  resetDate.timeIntervalSince1970 > 0 else {
                throw UsageProviderError.badResponse(status: 0)
            }

            let collapsedLabel = rawLabel.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let usedFraction = min(max((100.0 - remaining) / 100.0, 0.0), 1.0)

            if collapsedLabel.lowercased().contains("argon") {
                windows.append(LimitWindow(
                    id: "3p-argon-weekly",
                    group: L10n.t("Claude and GPT models"),
                    label: "Argon",
                    usedFraction: usedFraction,
                    resetsAt: resetDate,
                    duration: laneDuration(for: collapsedLabel) ?? (7 * 86_400)
                ))
                continue
            }

            guard collapsedLabel.hasSuffix(" Remaining") else {
                throw UsageProviderError.badResponse(status: 0)
            }
            let baseLabel = String(collapsedLabel.dropLast(" Remaining".count))
            let lower = baseLabel.lowercased()

            let isGemini = lower.contains("gemini")
            let isThirdParty = lower.contains("claude") || lower.contains("gpt") || lower.contains("openai")
            let duration = laneDuration(for: baseLabel)
            let isWeekly = duration == 7 * 86_400
            let isFiveHour = duration == 5 * 3600

            let id: String
            if isGemini {
                id = isWeekly ? "gemini-weekly" : (isFiveHour ? "gemini-5h" : "gemini-other")
            } else if isThirdParty {
                id = isWeekly ? "3p-weekly" : (isFiveHour ? "3p-5h" : "3p-other")
            } else {
                id = baseLabel.lowercased().replacingOccurrences(of: " ", with: "-")
            }

            let group: String?
            if isGemini {
                group = L10n.t("Gemini Models")
            } else if isThirdParty {
                group = L10n.t("Claude and GPT models")
            } else {
                group = nil
            }

            let displayLabel: String
            if isFiveHour {
                displayLabel = L10n.t("5-hour Limit")
            } else if isWeekly {
                displayLabel = L10n.t("Weekly Limit")
            } else {
                displayLabel = baseLabel
            }

            windows.append(LimitWindow(
                id: id,
                group: group,
                label: displayLabel,
                usedFraction: usedFraction,
                resetsAt: resetDate,
                duration: duration
            ))
        }

        guard !windows.isEmpty else {
            throw UsageProviderError.badResponse(status: 0)
        }

        return orderLanes(windows)
    }

    private static func laneDuration(for label: String) -> TimeInterval? {
        let lower = label.lowercased()
        if lower.contains("five hour") || lower.contains("5-hour") || lower.contains("5h") {
            return 5 * 3600
        }
        if lower.contains("weekly") {
            return 7 * 86_400
        }
        return nil
    }

    private static func orderLanes(_ windows: [LimitWindow]) -> [LimitWindow] {
        let rank: [String: Int] = [
            "gemini-5h": 0,
            "gemini-weekly": 1,
            "3p-5h": 2,
            "3p-weekly": 3,
            "3p-argon-weekly": 4,
        ]
        return windows.enumerated().sorted { lhs, rhs in
            let lr = rank[lhs.element.id] ?? 99
            let rr = rank[rhs.element.id] ?? 99
            if lr != rr { return lr < rr }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Parses RFC3339 timestamps as well as `agy`'s wall-clock format:
    /// `YYYY-MM-DD HH:MM UTC|GMT|Z`, `YYYY-MM-DD HH:MM ±HH[MM]`, or
    /// `YYYY-MM-DD HH:MM <TZ_ABBR>`.
    static func parseResetTime(
        _ raw: String,
        resolveLocal: ((DateComponents) -> Date?)? = nil
    ) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let iso = AntigravityCredentials.parse(text) {
            return iso
        }

        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 3 else { return nil }

        let datePart = parts[0]
        let timePart = parts[1]
        let zone = parts[2]

        guard datePart.count == 10, timePart.count == 5,
              let components = parsePaddedDateTime(date: datePart, time: timePart) else {
            return nil
        }

        if zone == "UTC" || zone == "GMT" || zone == "Z" {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar.date(from: components)
        }

        if zone.hasPrefix("+") || zone.hasPrefix("-") {
            guard let offsetSeconds = numericZoneOffsetSeconds(zone),
                  let tz = TimeZone(secondsFromGMT: offsetSeconds) else {
                return nil
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = tz
            return calendar.date(from: components)
        }

        guard !zone.isEmpty, zone.unicodeScalars.allSatisfy({ ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }) else {
            return nil
        }

        if let resolveLocal {
            return resolveLocal(components)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: components)
    }

    private static func parsePaddedDateTime(date: String, time: String) -> DateComponents? {
        let dParts = date.split(separator: "-", omittingEmptySubsequences: false)
        let tParts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard dParts.count == 3, tParts.count == 2,
              dParts[0].count == 4, dParts[1].count == 2, dParts[2].count == 2,
              tParts[0].count == 2, tParts[1].count == 2,
              let year = Int(dParts[0]),
              let month = Int(dParts[1]), (1...12).contains(month),
              let day = Int(dParts[2]), (1...31).contains(day),
              let hour = Int(tParts[0]), (0...23).contains(hour),
              let minute = Int(tParts[1]), (0...59).contains(minute) else {
            return nil
        }
        return DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
    }

    static func numericZoneOffsetSeconds(_ zone: String) -> Int? {
        let sign: Int
        let digits: Substring
        if zone.hasPrefix("+") {
            sign = 1
            digits = zone.dropFirst()
        } else if zone.hasPrefix("-") {
            sign = -1
            digits = zone.dropFirst()
        } else {
            return nil
        }
        guard (digits.count == 2 || digits.count == 4),
              digits.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            return nil
        }
        let hourEnd = digits.index(digits.startIndex, offsetBy: 2)
        guard let hours = Int(digits[..<hourEnd]) else { return nil }
        let minutes = digits.count == 4 ? (Int(digits[hourEnd...]) ?? -1) : 0
        guard hours <= 14, (0...59).contains(minutes), !(hours == 14 && minutes != 0) else {
            return nil
        }
        return sign * (hours * 3600 + minutes * 60)
    }
}
