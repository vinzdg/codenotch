import Foundation

/// Token usage added up from the logs Muse Code keeps for itself.
///
/// Muse publishes no quota and no usage endpoint — what it does write, under
/// `~/.local/share/muse/sessions`, is one JSON line per runtime event, with a
/// `model_completed` event per billed request carrying that request's token
/// counts. This reads those lines back into per-day totals.
///
/// It is a local estimate, and the provider says so (`fidelity: .derived`):
/// the scan only reaches back `MuseUsageLog.windowDays`, so anything older is
/// genuinely unknown rather than zero.
enum MuseUsage {
    /// One billed request, as the log recorded it: counts and timings only.
    /// No prompt, reasoning or reply text ever enters this type.
    struct Sample: Equatable, Sendable {
        let at: Date
        let inputTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
        let cachedTokens: Int
        let duration: TimeInterval?

        init(at: Date, inputTokens: Int, outputTokens: Int, reasoningTokens: Int,
             cachedTokens: Int = 0, duration: TimeInterval? = nil) {
            self.at = at
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
            self.cachedTokens = cachedTokens
            self.duration = duration
        }

        /// Billed tokens for the request. Cached and reasoning tokens are
        /// reported separately and never added to the total.
        var totalTokens: Int { inputTokens + outputTokens }
    }

    private struct LogRecord: Decodable {
        var recordedAt: Int?
        var payload: Payload?
        struct Payload: Decodable {
            var event: Event?
            struct Event: Decodable {
                var kind: String?
                var usage: Usage?
                var durationMs: Int?
                struct Usage: Decodable {
                    var inputTokens: Int?
                    var outputTokens: Int?
                    var reasoningTokens: Int?
                    var cachedTokens: Int?
                }
            }
        }
    }

    /// Parses complete JSON lines into samples. Anything else — other events,
    /// malformed lines, records without a timestamp — is skipped: a usage
    /// total must never be padded with guesses.
    static func samples(from text: String) -> [Sample] {
        samples(fromLines: text.split(separator: "\n").map(String.init))
    }

    static func samples(fromLines lines: [String]) -> [Sample] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return lines.compactMap { line in
            // Most lines are tool calls and transcripts, not usage: one
            // substring check before paying for the decoder. A line can
            // mention the event without being one, so the decode still
            // verifies the shape.
            guard line.contains("model_completed"),
                  let data = line.data(using: .utf8),
                  let record = try? decoder.decode(LogRecord.self, from: data),
                  let micro = record.recordedAt,
                  record.payload?.event?.kind == "model_completed",
                  let usage = record.payload?.event?.usage
            else { return nil }
            // `recorded_at` is microseconds since the epoch.
            return Sample(at: Date(timeIntervalSince1970: Double(micro) / 1_000_000),
                          inputTokens: usage.inputTokens ?? 0,
                          outputTokens: usage.outputTokens ?? 0,
                          reasoningTokens: usage.reasoningTokens ?? 0,
                          cachedTokens: usage.cachedTokens ?? 0,
                          duration: record.payload?.event?.durationMs.map { Double($0) / 1000 })
        }
    }

    /// The `yyyy-MM-dd` key the daily buckets file under — the same key
    /// `CodexTokenUsage.last30Days` reads back, so the chart fills its gaps.
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private struct DayTotals {
        var input = 0
        var output = 0
        var reasoning = 0
        var requests = 0
        var longestTurn: TimeInterval?
    }

    private static func totalsByDay(from samples: [Sample], calendar: Calendar) -> [String: DayTotals] {
        var days: [String: DayTotals] = [:]
        for sample in samples {
            let key = dayKey(for: sample.at, calendar: calendar)
            var day = days[key] ?? DayTotals()
            day.input += sample.inputTokens
            day.output += sample.outputTokens
            day.reasoning += sample.reasoningTokens
            day.requests += 1
            if let turn = sample.duration {
                day.longestTurn = max(day.longestTurn ?? 0, turn)
            }
            days[key] = day
        }
        return days
    }

    static func dailyBuckets(from samples: [Sample], now: Date,
                             calendar: Calendar) -> [CodexTokenUsage.DailyBucket] {
        var days = totalsByDay(from: samples, calendar: calendar)
        // Local logs are complete: an unsampled today is a real zero, not pending.
        let todayKey = dayKey(for: now, calendar: calendar)
        days[todayKey] = days[todayKey] ?? DayTotals()
        return days.map {
            CodexTokenUsage.DailyBucket(startDate: $0.key, tokens: $0.value.input + $0.value.output)
        }.sorted { $0.startDate < $1.startDate }
    }

    static func summary(from samples: [Sample], now: Date,
                        calendar: Calendar) -> CodexTokenUsage.Summary {
        let days = totalsByDay(from: samples, calendar: calendar)
        let activeDays = Set(samples.filter { $0.totalTokens > 0 }
            .map { calendar.startOfDay(for: $0.at) })
        return CodexTokenUsage.Summary(
            // A bounded scan cannot know it; blank, not zero.
            lifetimeTokens: nil,
            peakDailyTokens: days.values.map { $0.input + $0.output }.max(),
            longestRunningTurnSeconds: days.values.compactMap(\.longestTurn).max(),
            currentStreakDays: currentStreak(activeDays: activeDays, now: now, calendar: calendar),
            longestStreakDays: longestStreak(activeDays: activeDays, calendar: calendar))
    }

    /// Active days back from today — starting at yesterday when today is idle,
    /// so a day without prompts pauses the streak instead of ending it.
    private static func currentStreak(activeDays: Set<Date>, now: Date, calendar: Calendar) -> Int {
        var cursor = calendar.startOfDay(for: now)
        if !activeDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    /// The longest run of active days in the scan window. Bounded like
    /// everything else here: a run still going at the oldest scanned day may
    /// run further back than the logs reach.
    private static func longestStreak(activeDays: Set<Date>, calendar: Calendar) -> Int {
        var longest = 0
        for day in activeDays {
            // Only count from run starts.
            if let previous = calendar.date(byAdding: .day, value: -1, to: day),
               activeDays.contains(previous) { continue }
            var run = 0
            var cursor = day
            while activeDays.contains(cursor) {
                run += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            longest = max(longest, run)
        }
        return longest
    }

    /// The quota payload out of a `/v1/responses` SSE stream: the data of the
    /// `response.subscription_usage` event, which is the only place Meta
    /// publishes the 5-hour and weekly percentages. Nil when the stream
    /// carried none.
    static func subscriptionPayload(fromSSE text: String) -> Data? {
        var armed = false
        var parts: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // SSE allows \r\n; the comparison below must not depend on it.
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if line == "event: response.subscription_usage" {
                armed = true
                parts = []
                continue
            }
            guard armed else { continue }
            if line.hasPrefix("data: ") {
                parts.append(String(line.dropFirst("data: ".count)))
            } else if line.isEmpty {
                break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n").data(using: .utf8)
    }

    private struct SubscriptionPayload: Decodable {
        var subscription: Subscription
        struct Subscription: Decodable {
            var weekly: Weekly
            var window: Window
            struct Weekly: Decodable {
                /// Epoch seconds, as the provider sends them.
                var resetsAt: TimeInterval
                var usedPercent: Double
            }
            struct Window: Decodable {
                var resetsAt: TimeInterval
                var usedPercent: Double
                var windowDurationMins: Double
            }
        }
    }

    /// The 5-hour and weekly quota windows, verbatim: percentages over 100
    /// stay over 100, the way the provider sent them.
    static func quotaWindows(from data: Data) throws -> [LimitWindow] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(SubscriptionPayload.self, from: data)
        let window = payload.subscription.window
        let weekly = payload.subscription.weekly
        return [
            LimitWindow(id: "window", label: L10n.t("5-hour"),
                        usedFraction: window.usedPercent / 100,
                        resetsAt: Date(timeIntervalSince1970: window.resetsAt),
                        duration: window.windowDurationMins * 60),
            LimitWindow(id: "weekly", label: L10n.t("Weekly"),
                        usedFraction: weekly.usedPercent / 100,
                        resetsAt: Date(timeIntervalSince1970: weekly.resetsAt),
                        duration: 7 * 86400),
        ]
    }

    static func windows(from samples: [Sample], now: Date,
                        calendar: Calendar) -> [LimitWindow] {
        let today = totalsByDay(from: samples, calendar: calendar)[dayKey(for: now, calendar: calendar)]
            ?? DayTotals()
        let share = today.output > 0 ? Double(today.reasoning) / Double(today.output) : nil
        return [
            LimitWindow(id: "today", label: L10n.t("Tokens today"),
                        used: today.input + today.output,
                        detail: "\(LimitWindow.compact(today.input)) in · \(LimitWindow.compact(today.output)) out"),
            LimitWindow(id: "requests", label: L10n.t("Requests today"), used: today.requests),
            LimitWindow(id: "reasoning", label: L10n.t("Reasoning share"),
                        detail: share.map { "\(Percent.text(for: $0))%" } ?? "—"),
        ]
    }
}

/// The running read of muse's session logs.
///
/// Logs only ever grow — a session's file is appended to until the session
/// ends — so each scan re-reads only the bytes past the last complete line
/// seen. Re-parsing months of logs every minute would be absurd; the
/// remembered offsets make a refresh cost the kilobytes written since. Files
/// untouched for longer than the window are never reopened, and samples older
/// than the window are dropped: the notch reports the recent past, and
/// anything older is out of the question rather than slowly accumulated.
struct MuseUsageLog: Sendable {
    /// How far back a scan reaches, in days. Past this the logs are not
    /// opened and their samples are dropped.
    static let windowDays = 32

    private struct FileState: Sendable {
        /// Bytes consumed through the last complete line.
        var offset: UInt64
        var samples: [MuseUsage.Sample]
    }

    private var files: [String: FileState] = [:]

    mutating func scan(at sessionsURL: URL, now: Date = Date()) -> [MuseUsage.Sample] {
        let cutoff = now.addingTimeInterval(-Double(Self.windowDays) * 86400)
        var seen: Set<String> = []
        let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == "session.jsonl" else { continue }
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                values.isRegularFile == true,
                let mtime = values.contentModificationDate,
                let size = values.fileSize, size >= 0
            else { continue }
            let key = url.path
            seen.insert(key)
            // Untouched past the window: not reopened, whatever it holds.
            guard mtime >= cutoff else {
                files.removeValue(forKey: key)
                continue
            }
            var state = files[key] ?? FileState(offset: 0, samples: [])
            if UInt64(size) < state.offset {
                // Truncated or replaced: the old samples describe bytes that
                // are no longer there.
                state = FileState(offset: 0, samples: [])
            }
            if UInt64(size) > state.offset,
               let data = try? readBytes(from: url, offset: state.offset) {
                let (complete, consumed) = completeLines(in: data)
                // Only the lines carrying a completed call are decoded — a few
                // thousand among millions. Materialising whole logs as text
                // first made a cold scan take eleven seconds; searching bytes
                // keeps it near one.
                state.samples += MuseUsage.samples(fromLines: candidateLines(in: complete))
                state.offset += UInt64(consumed)
            }
            state.samples.removeAll { $0.at < cutoff }
            files[key] = state
        }
        // Sessions deleted from disk take their samples with them: the reading
        // mirrors what is there.
        files = files.filter { seen.contains($0.key) }
        return files.values.flatMap(\.samples)
    }

    /// The bytes through the last newline — an unterminated tail is still
    /// being written, so it waits for the next scan rather than being parsed
    /// half. The offset always advances past what was consumed, even when the
    /// bytes refuse to decode: garbage must not wedge the reader.
    private func completeLines(in data: Data) -> (complete: Data, consumed: Int) {
        guard let last = data.lastIndex(of: 0x0A) else { return (Data(), 0) }
        let consumed = data.distance(from: data.startIndex, to: data.index(after: last))
        return (Data(data[data.startIndex...last]), consumed)
    }

    private static let marker = Data("model_completed".utf8)

    /// The complete lines mentioning a completed call, expanded from the raw
    /// bytes so undecodable neighbours never wedge the reader — only these
    /// lines pay for UTF-8 and JSON. A line mentioning the event twice still
    /// yields one candidate; the decoder verifies the shape.
    private func candidateLines(in data: Data) -> [String] {
        var lines: [String] = []
        var cursor = data.startIndex
        while cursor < data.endIndex,
              let hit = data.range(of: Self.marker, in: cursor..<data.endIndex) {
            var start = hit.lowerBound
            while start > data.startIndex {
                let prev = data.index(before: start)
                guard data[prev] != 0x0A else { break }
                start = prev
            }
            var end = hit.upperBound
            while end < data.endIndex, data[end] != 0x0A {
                end = data.index(after: end)
            }
            if let line = String(data: data[start..<end], encoding: .utf8) {
                lines.append(line)
            }
            cursor = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
        return lines
    }

    private func readBytes(from url: URL, offset: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    }
}
