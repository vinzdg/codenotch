import Foundation

/// Tokens Gemini CLI recorded for itself, read out of its chat recordings.
///
/// The files are append-only JSONL under `~/.gemini/tmp/<projectHash>/chats/`.
/// Line one is a header; everything after it is either a message record or a
/// patch:
///
/// ```
/// {"sessionId":"6f0a…","projectHash":"9d2c…","startTime":"2026-09-01T09:12:33.104Z",
///  "lastUpdated":"2026-09-01T09:41:02.881Z","kind":"main"}
/// {"id":"c7f2…","timestamp":"2026-09-01T09:12:41.402Z","type":"gemini","model":"gemini-2.5-pro",
///  "content":"…","tokens":{"input":12345,"output":218,"cached":11000,"thoughts":64,
///  "tool":0,"total":12627}}
/// {"$set":{"lastUpdated":"2026-09-01T09:41:02.881Z"}}
/// {"$rewindTo":"c7f2…"}
/// ```
///
/// Two rules the file's shape forces, both verified against Gemini CLI
/// 0.58.0's `ChatRecordingService`:
///
/// - A `gemini` record is written the moment the turn starts, without
///   `tokens`, and written *again* with the same `id` once `usageMetadata`
///   arrives. Counting lines instead of ids double-counts every answered call:
///   26 lines in a real session are 15 calls.
/// - `$rewindTo` un-does the transcript, not the bill. Google charged for the
///   rewound call, so it stays counted.
///
/// `total` is the field to read: it already is input + output + thoughts +
/// tool, and `cached` is a subset of `input`, so summing the parts would count
/// the cache twice.
enum GeminiCLIUsage {
    static var sessionsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/tmp")
    }

    /// `nil` means Gemini CLI has no state on disk at all, which is a different
    /// answer from "it ran and spent nothing" — the provider drops the row
    /// entirely rather than showing a zero for a tool that was never installed.
    static func read(
        root: URL = GeminiCLIUsage.sessionsRoot,
        now: Date = Date()
    ) -> GeminiTokenUsage? {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return nil }

        let startOfMonth = GeminiTokenUsage.startOfMonth(now: now)
        var entries: [(at: Date, tokens: Int, calls: Int)] = []

        for project in projects {
            let chats = project.appendingPathComponent("chats")
            guard let sessions = try? manager.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for session in sessions where session.pathExtension == "jsonl" {
                // Append-only: no record inside can be newer than the file
                // itself, so a file last written before this month cannot
                // contribute. After a few months of sessions that is most of
                // them, and each one would otherwise be parsed line by line.
                let modified = try? session.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                if let modified, modified < startOfMonth { continue }

                guard let text = try? String(contentsOf: session, encoding: .utf8) else { continue }
                entries.append(contentsOf: calls(in: text))
            }
        }
        return GeminiTokenUsage.bucket(entries, now: now)
    }

    private static func calls(in text: String) -> [(at: Date, tokens: Int, calls: Int)] {
        var answered: [String: Record] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  let id = record.id,
                  record.type == "gemini",
                  record.tokens != nil
            else { continue }
            // Later line wins: the second write of an id is the one that
            // carries the usage the API reported.
            answered[id] = record
        }

        return answered.values.compactMap { record in
            guard let stamp = record.timestamp, let at = parse(stamp) else { return nil }
            return (at: at, tokens: record.tokens?.total ?? 0, calls: 1)
        }
    }

    /// Everything is optional because the same file holds headers, `$set`
    /// patches and `$rewindTo` markers; those decode into a record of all nils
    /// and are dropped by the filter rather than by a second decoder.
    private struct Record: Decodable {
        let id: String?
        let type: String?
        let timestamp: String?
        let tokens: Tokens?
    }

    private struct Tokens: Decodable {
        let total: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        }

        private enum CodingKeys: String, CodingKey { case total }
    }

    /// The CLI writes fractional seconds, but not on every record, and
    /// `ISO8601DateFormatter` rejects the string when the option does not match
    /// the text exactly.
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
