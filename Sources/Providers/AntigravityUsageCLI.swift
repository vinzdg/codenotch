import Foundation
import os

/// Antigravity's own `agy --print /usage`, asked of the binary when the local
/// language-server bridge cannot answer.
///
/// Newer Antigravity builds (`agy` 1.5+ running `--hub`) reject tokenless
/// loopback RPCs with HTTP 401 and do not expose a `--csrf_token` on the
/// process command line, while the login keychain entry holds an access token
/// without a refresh token that ages out after the initial sign-in.
/// `agy --print /usage` reads the official quota table off Antigravity's own
/// session without touching the keychain or spawning a standalone server.
struct AntigravityUsageCLI: Sendable {
    /// Where the `agy` binary was found.
    let binary: URL
    /// How its stdout is obtained; injected so unit tests parse fixtures
    /// without spawning a real `agy` process.
    let output: @Sendable () throws -> String

    init(binary: URL, output: @escaping @Sendable () throws -> String) {
        self.binary = binary
        self.output = output
    }

    /// Slightly longer than `--print-timeout 30s` so the CLI can exit cleanly
    /// before the watchdog terminates it.
    static let timeout: TimeInterval = 35

    /// Mirrors the Windows adapter (`windows/codenotch/src/agy_cli.rs`):
    /// `--sandbox` prevents stray workspace writes, `--print-timeout` bounds
    /// hangs, and `--print /usage` outputs the quota table non-interactively.
    static let arguments = ["--sandbox", "--print-timeout", "30s", "--print", "/usage"]

    /// Updating `agy` is for Antigravity and the user's own runs to do, not a
    /// background quota poll. It accepts `"true"` and ignores `"1"`.
    static let disableAutoUpdate = ("AGY_CLI_DISABLE_AUTO_UPDATE", "true")

    /// One fixed working directory kept for the life of the install so probes
    /// never scatter workspace state under whatever directory the app launched
    /// from.
    static func scratchDirectory(
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask)[0],
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = applicationSupport
            .appendingPathComponent("Codenotch", isDirectory: true)
            .appendingPathComponent("agy-usage-scratch", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Finding the binary

    /// Fixed user-home install paths, bundled Antigravity IDE binary first.
    ///
    /// Finder-launched apps inherit only `/usr/bin:/bin:/usr/sbin:/sbin`, so
    /// `PATH` lookup misses `~/.gemini/bin/agy` and `~/.local/bin/agy`.
    private static let searchPaths = [
        ".gemini/bin/agy", // installed by Antigravity IDE 2.x and VS Code extension
        ".local/bin/agy"
    ]

    /// Relative to `root` so tests can redirect the whole search to a temporary
    /// directory instead of picking up whatever the host happens to have.
    private static let systemPaths = [
        "opt/homebrew/bin/agy",
        "usr/local/bin/agy"
    ]

    static func locate(home: URL = AntigravityProfile.homeDirectory,
                       root: URL = URL(fileURLWithPath: "/"),
                       fileManager: FileManager = .default) -> AntigravityUsageCLI? {
        let candidates = searchPaths.map { home.appendingPathComponent($0) }
            + systemPaths.map { root.appendingPathComponent($0) }
        guard let found = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else { return nil }
        return AntigravityUsageCLI(binary: found) { try run(binary: found) }
    }

    // MARK: - Asking it

    /// Runs `agy --print /usage` off the cooperative pool so reading the pipe
    /// to EOF cannot block the provider actor.
    func read(timeZone: TimeZone = .current) async throws -> [LimitWindow] {
        let text = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try self.output() })
            }
        }
        return try Self.parse(text, timeZone: timeZone)
    }

    private static func run(binary: URL) throws -> String {
        let scratch = try scratchDirectory()

        var environment = ProcessInfo.processInfo.environment
        environment[disableAutoUpdate.0] = disableAutoUpdate.1
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

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            Log.usage.debug("agy /usage exited \(process.terminationStatus)")
            throw UsageProviderError.needsAuth
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return text
    }

    // MARK: - Parsing

    /// Strips CSI, OSC and two-character ANSI escapes and normalizes line
    /// endings, matching `windows/codenotch/src/agy_cli.rs`.
    private static let ansiSequence = try! NSRegularExpression(
        pattern: #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])"#
    )

    static func sanitize(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = ansiSequence.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Parses `agy --print /usage` output into the canonical macOS window IDs
    /// (`gemini-hourly`, `gemini-weekly`, `3p-hourly`, `3p-weekly`).
    static func parse(_ text: String, timeZone: TimeZone = .current) throws -> [LimitWindow] {
        let clean = sanitize(text)
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hasHeader = lines.contains { $0.trimmingCharacters(in: .whitespaces) == "Quota:" }
        let hasTSVRows = lines.contains {
            $0.contains("\t") && ($0.contains("Limit Remaining") || ($0.contains("Argon") && $0.contains("Limit")))
        }
        guard hasHeader || hasTSVRows else {
            throw UsageProviderError.badResponse(status: 0)
        }

        var windows: [LimitWindow] = []
        var indexByID: [String: Int] = [:]

        for line in lines where line.contains("Limit Remaining") || (line.contains("Argon") && line.contains("Limit")) {
            guard let percentIndex = line.lastIndex(of: "%") else {
                throw UsageProviderError.badResponse(status: 0)
            }
            let left = line[..<percentIndex].trimmingCharacters(in: .whitespaces)
            let resetText = line[line.index(after: percentIndex)...].trimmingCharacters(in: .whitespaces)

            guard let splitIndex = left.lastIndex(where: \.isWhitespace) else {
                throw UsageProviderError.badResponse(status: 0)
            }
            let rawLabel = String(left[..<splitIndex])
            let remainingString = String(left[left.index(after: splitIndex)...])
            guard let remaining = Double(remainingString),
                  remaining.isFinite,
                  (0.0...100.0).contains(remaining) else {
                throw UsageProviderError.badResponse(status: 0)
            }

            let resetsAt: Date?
            switch parseReset(resetText, timeZone: timeZone) {
            case .date(let date): resetsAt = date
            case .untouched: resetsAt = nil
            case .invalid: throw UsageProviderError.badResponse(status: 0)
            }

            let label = rawLabel.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let usedFraction = min(max((100.0 - remaining) / 100.0, 0.0), 1.0)
            let window = try makeWindow(label: label, usedFraction: usedFraction, resetsAt: resetsAt)

            if let existing = indexByID[window.id] {
                windows[existing] = window
            } else {
                indexByID[window.id] = windows.count
                windows.append(window)
            }
        }

        guard !windows.isEmpty else {
            throw UsageProviderError.badResponse(status: 0)
        }

        let canonicalOrder = ["gemini-hourly", "gemini-weekly", "3p-hourly", "3p-weekly"]
        return windows.enumerated().sorted { lhs, rhs in
            let lRank = canonicalOrder.firstIndex(of: lhs.element.id) ?? canonicalOrder.count
            let rRank = canonicalOrder.firstIndex(of: rhs.element.id) ?? canonicalOrder.count
            return lRank == rRank ? lhs.offset < rhs.offset : lRank < rRank
        }.map(\.element)
    }

    private static func makeWindow(label: String, usedFraction: Double, resetsAt: Date?) throws -> LimitWindow {
        let lower = label.lowercased()
        if lower.contains("argon") {
            let isWeekly = lower.contains("weekly")
            let isFiveHour = lower.contains("five hour") || lower.contains("5-hour") || lower.contains("5h")
            let duration: TimeInterval? = isFiveHour ? 5 * 3600 : (isWeekly ? 7 * 86400 : 7 * 86400)
            // Keep Argon outside the `gemini-` and `3p-` id prefixes so its
            // separate weekly allowance never displaces either family's ring.
            return LimitWindow(
                id: isFiveHour ? "argon-hourly" : "argon-weekly",
                group: L10n.t("Claude and GPT models"),
                label: "Argon",
                usedFraction: usedFraction,
                resetsAt: resetsAt,
                duration: duration
            )
        }

        guard label.hasSuffix(" Remaining") else {
            throw UsageProviderError.badResponse(status: 0)
        }
        let trimmed = String(label.dropLast(" Remaining".count))
        let trimmedLower = trimmed.lowercased()
        let isFiveHour = trimmedLower.contains("five hour") || trimmedLower.contains("5-hour") || trimmedLower.contains("5h")
        let isWeekly = trimmedLower.contains("weekly")
        let duration: TimeInterval? = isFiveHour ? 5 * 3600 : (isWeekly ? 7 * 86400 : nil)
        let laneLabel = isFiveHour ? L10n.t("5-hour Limit") : (isWeekly ? L10n.t("Weekly Limit") : trimmed)

        if trimmedLower.hasPrefix("gemini") {
            let id = isFiveHour ? "gemini-hourly" : (isWeekly ? "gemini-weekly" : trimmedLower.replacingOccurrences(of: " ", with: "-"))
            return LimitWindow(
                id: id,
                group: L10n.t("Gemini Models"),
                label: laneLabel,
                usedFraction: usedFraction,
                resetsAt: resetsAt,
                duration: duration
            )
        }
        if trimmedLower.hasPrefix("claude") || trimmedLower.contains("gpt") {
            let id = isFiveHour ? "3p-hourly" : (isWeekly ? "3p-weekly" : "3p-\(trimmedLower.replacingOccurrences(of: " ", with: "-"))")
            return LimitWindow(
                id: id,
                group: L10n.t("Claude and GPT models"),
                label: laneLabel,
                usedFraction: usedFraction,
                resetsAt: resetsAt,
                duration: duration
            )
        }

        return LimitWindow(
            id: trimmed,
            group: nil,
            label: laneLabel,
            usedFraction: usedFraction,
            resetsAt: resetsAt,
            duration: duration
        )
    }

    // MARK: - Reset timestamps

    private enum ParsedReset {
        case date(Date)
        /// `agy` 1.5.16 prints the Unix epoch (`1970-01-01T00:00:00Z`) for an
        /// untouched lane that has not started a window yet; omit `resetsAt`
        /// instead of rejecting the whole quota snapshot.
        case untouched
        case invalid
    }

    static func parseResetDate(_ text: String, timeZone: TimeZone = .current) -> Date? {
        switch parseReset(text, timeZone: timeZone) {
        case .date(let date): return date
        case .untouched, .invalid: return nil
        }
    }

    private static func parseReset(_ text: String, timeZone: TimeZone) -> ParsedReset {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }

        if let iso = AntigravityCredentials.parse(trimmed) {
            return iso.timeIntervalSince1970 <= 0 ? .untouched : .date(iso)
        }

        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 3 else { return .invalid }
        guard let (year, month, day) = parseDatePart(parts[0]),
              let (hour, minute) = parseTimePart(parts[1]) else {
            return .invalid
        }

        let zone = parts[2]
        let resolvedZone: TimeZone
        if zone == "UTC" || zone == "GMT" || zone == "Z" {
            resolvedZone = TimeZone(secondsFromGMT: 0)!
        } else if zone.hasPrefix("+") || zone.hasPrefix("-") {
            guard let fixed = numericTimeZone(zone) else { return .invalid }
            resolvedZone = fixed
        } else if !zone.isEmpty && zone.allSatisfy({ $0.isASCII && $0.isLetter }) {
            // Abbreviations like CST are not globally unique; `agy` runs on
            // this host, so the host timezone is authoritative.
            resolvedZone = timeZone
        } else {
            return .invalid
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: resolvedZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: 0
        )
        guard let date = calendar.date(from: components) else { return .invalid }

        // Reject nonexistent wall-clock dates (such as Feb 30 or a DST gap)
        // that `Calendar.date(from:)` would otherwise roll forward silently.
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day,
              roundTrip.hour == hour,
              roundTrip.minute == minute else {
            return .invalid
        }

        return date.timeIntervalSince1970 <= 0 ? .untouched : .date(date)
    }

    private static func parseDatePart(_ text: String) -> (Int, Int, Int)? {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-") else {
            return nil
        }
        guard let year = asciiInt(bytes[0..<4]),
              let month = asciiInt(bytes[5..<7]), (1...12).contains(month),
              let day = asciiInt(bytes[8..<10]), (1...31).contains(day) else {
            return nil
        }
        return (year, month, day)
    }

    private static func parseTimePart(_ text: String) -> (Int, Int)? {
        let bytes = Array(text.utf8)
        guard bytes.count == 5, bytes[2] == UInt8(ascii: ":") else { return nil }
        guard let hour = asciiInt(bytes[0..<2]), (0...23).contains(hour),
              let minute = asciiInt(bytes[3..<5]), (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
    }

    /// Reads a `±HH` or `±HHMM` zone label such as `+07`, `-03`, or `+0530`.
    private static func numericTimeZone(_ zone: String) -> TimeZone? {
        let bytes = Array(zone.utf8)
        guard bytes.count == 3 || bytes.count == 5 else { return nil }
        let sign: Int
        if bytes[0] == UInt8(ascii: "+") {
            sign = 1
        } else if bytes[0] == UInt8(ascii: "-") {
            sign = -1
        } else {
            return nil
        }
        guard let hours = asciiInt(bytes[1..<3]) else { return nil }
        let minutes: Int
        if bytes.count == 5 {
            guard let parsedMinutes = asciiInt(bytes[3..<5]) else { return nil }
            minutes = parsedMinutes
        } else {
            minutes = 0
        }
        guard hours <= 14, minutes <= 59, !(hours == 14 && minutes != 0) else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }

    private static func asciiInt(_ slice: ArraySlice<UInt8>) -> Int? {
        guard !slice.isEmpty else { return nil }
        var value = 0
        for byte in slice {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }
}
