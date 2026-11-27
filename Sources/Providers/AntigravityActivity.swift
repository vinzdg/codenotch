import Foundation

/// How much Antigravity has actually been used, counted from its own
/// transcripts.
///
/// This exists because Google publishes no usage figure. `loadCodeAssist`
/// returns tiers and nothing else, the conversation databases carry no token or
/// quota columns, and whatever metadata comes back on `streamGenerateContent`
/// is consumed by the stream and never written down. Counting locally is the
/// only honest number available.
///
/// It is a *count*, never a percentage. A fraction needs a limit and there is
/// no published limit to divide by — inventing a denominator would put a
/// confident ring on a guess.
struct AntigravityActivity: Equatable {
    let requestsToday: Int
    let lastRequest: Date?

    /// Every Antigravity install's transcripts, not just the first one found.
    ///
    /// Antigravity keeps a directory per flavour under `~/.gemini` —
    /// `antigravity`, `antigravity-ide`, `antigravity-cli`, `antigravity-backup`
    /// — and each has its own `brain`. Picking the first that *exists* looked
    /// reasonable and was not: leaving a flavour behind leaves its directory
    /// behind too, so on a machine that has run the IDE and then moved to the
    /// CLI all four exist and the first is empty. The count came out zero while
    /// the transcripts sat one directory over.
    ///
    /// So: all of them. Trajectories are UUID-named per install, so nothing is
    /// counted twice, and somebody who uses the IDE and the CLI in the same day
    /// gets one number for the day rather than whichever half was looked at.
    static var transcriptRoots: [URL] { transcriptRoots(home: URL(fileURLWithPath: NSHomeDirectory())) }

    static func transcriptRoots(home: URL) -> [URL] {
        let gemini = home.appendingPathComponent(".gemini")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: gemini.path)) ?? []
        let standard = names
            .filter { $0.hasPrefix("antigravity") }
            .sorted()
            .map { gemini.appendingPathComponent($0).appendingPathComponent("brain") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return standard + AntigravityFlavor.t3BrainDirectories(home: home)
    }

    /// Every install's activity, as one day's worth.
    static func read(roots: [URL] = transcriptRoots, now: Date = Date()) -> AntigravityActivity {
        roots.reduce(AntigravityActivity(requestsToday: 0, lastRequest: nil)) { total, root in
            let one = read(root: root, now: now)
            return AntigravityActivity(
                requestsToday: total.requestsToday + one.requestsToday,
                lastRequest: [total.lastRequest, one.lastRequest].compactMap { $0 }.max()
            )
        }
    }

    /// A step the model actually answered. User input and system checkpoints
    /// share the transcript, and counting those would inflate the number with
    /// work the model never did.
    private static let modelSource = "MODEL"

    /// One install's, which is what the combining read above is made of.
    static func read(root: URL, now: Date = Date()) -> AntigravityActivity {
        let manager = FileManager.default
        guard let trajectories = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return AntigravityActivity(requestsToday: 0, lastRequest: nil) }

        var today = 0
        var latest: Date?
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        for trajectory in trajectories {
            let transcript = trajectory
                .appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard let text = try? String(contentsOf: transcript, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let step = try? JSONDecoder().decode(Step.self, from: data),
                      step.source == modelSource,
                      let at = parse(step.created_at)
                else { continue }

                if latest == nil || at > latest! { latest = at }
                // `created_at` is UTC — the trailing Z is not decoration. The
                // comparison has to be against the *local* day, which is what
                // `isDate(_:inSameDayAs:)` on a local calendar does; treating
                // the timestamp as local instead would move every count either
                // side of midnight by the offset.
                if calendar.isDate(at, inSameDayAs: now) { today += 1 }
            }
        }
        return AntigravityActivity(requestsToday: today, lastRequest: latest)
    }

    private struct Step: Decodable {
        let created_at: String
        let source: String?
    }

    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    /// What the cell says. Deliberately a count with the limit's absence stated,
    /// rather than a number that looks like a percentage.
    var summary: String {
        guard requestsToday > 0 else { return L10n.t("no requests today") }
        if requestsToday == 1 { return L10n.t("~\(requestsToday) request today") }
        else { return L10n.t("~\(requestsToday) requests today") }
    }

    /// What the tooltip's row is called.
    ///
    /// A bare `0` on a day Antigravity has not been opened reads as the app
    /// failing to find anything rather than as an honest nothing — and that is
    /// exactly what a wrong directory looks like too, which is how this went
    /// unnoticed. Saying when it *was* last used tells the two apart.
    func label(now: Date = Date()) -> String {
        guard requestsToday == 0, let lastRequest else {
            return L10n.t("Requests today · no limit published")
        }
        return L10n.t("Requests today · last used \(Self.lastUsed(lastRequest, now: now))")
    }

    /// Counted in calendar days, not in elapsed time, because the number beside
    /// it is: `requestsToday` asks whether a timestamp falls on today's date.
    /// Measured in elapsed hours instead, a Saturday evening reads as "2 days
    /// ago" on a Tuesday morning, and the row's two halves disagree about what
    /// a day is.
    ///
    /// Inside a day it defers to `ElapsedCopy`, the same phrase the session list
    /// uses, so the two read alike. Days are added here rather than there:
    /// that helper answers "is this still working", where a span of days cannot
    /// arise and would only be noise.
    private static func lastUsed(_ date: Date, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0

        switch days {
        case ..<1:  return ElapsedCopy.ago(since: date, now: now)
        case 1:     return L10n.t("yesterday")
        default:    return L10n.t("\(days) days ago")
        }
    }
}
