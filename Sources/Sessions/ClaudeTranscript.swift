import Foundation

/// What a Claude Code session is doing, read from its transcript.
///
/// Claude Code writes `status` into `~/.claude/sessions/<pid>.json` from one
/// place only: an effect inside the terminal interface's render loop. A session
/// hosted by the Claude desktop app runs the same binary with no terminal
/// interface, so that effect never fires and the record carries no status at
/// all — which is why every desktop session read as permanently idle, and why
/// the usage ring never polled hard while one was working.
///
/// The transcript is the other thing Claude Code writes, and the engine writes
/// it rather than the interface, so it is there for both surfaces:
/// `~/.claude/projects/<slug>/<sessionId>.jsonl`, one JSON object per line,
/// appended as the turn goes.
enum ClaudeTranscript {
    /// Whether the session is mid-turn.
    ///
    /// Two cases and not three, deliberately. Nothing in the transcript
    /// separates a tool waiting on your permission from a tool that is simply
    /// taking its time — there is no record for a permission prompt — so this
    /// never claims `waiting`. Only the terminal interface knows that, and only
    /// the terminal interface writes it to the registry.
    enum Turn: Equatable { case inFlight, finished }

    /// How much of the end of the file to look at. The last few records settle
    /// it, and these transcripts run to megabytes.
    static let tailBytes = 64 * 1024

    // MARK: - Where the file is

    /// The directory Claude Code files a working directory's transcripts under:
    /// the path with every `/` and `.` turned into `-`, so
    /// `/Users/x/app/.claude/worktrees/y` becomes
    /// `-Users-x-app--claude-worktrees-y`.
    static func projectSlug(forCWD cwd: String) -> String {
        String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    /// The transcript for one session, or nil if it has not been written yet.
    ///
    /// `scanning` is what makes this affordable to call on a timer: the slug is
    /// derived from the session's own `cwd` and is right almost always, so the
    /// usual cost is a single `stat`. The directory scan is the fallback for a
    /// session that has moved since it started — resumed in a worktree, say —
    /// and keeps its transcript where it was first written.
    static func transcript(
        forSessionID sessionID: String,
        cwd: String,
        in projects: URL,
        scanning: Bool,
        fileManager: FileManager = .default
    ) -> URL? {
        let file = sessionID + ".jsonl"
        let direct = projects
            .appendingPathComponent(projectSlug(forCWD: cwd))
            .appendingPathComponent(file)
        if fileManager.fileExists(atPath: direct.path) { return direct }
        guard scanning else { return nil }

        let folders = (try? fileManager.contentsOfDirectory(atPath: projects.path)) ?? []
        for folder in folders {
            let candidate = projects
                .appendingPathComponent(folder)
                .appendingPathComponent(file)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - What it says

    /// The last records of the file, without reading the rest of it.
    static func tail(of url: URL, bytes: Int = tailBytes) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }

    /// The state machine, kept pure so it can be tested without a file.
    ///
    /// Only `user` and `assistant` lines are allowed to decide. The transcript
    /// also carries bookkeeping — `bridge-session`, `atis-latch`, `frame-link`,
    /// `custom-title` and more — which Claude Code keeps appending while a
    /// session sits doing nothing. That is why "was the file touched recently",
    /// which is all the Codex monitor can manage, is not good enough here: on
    /// this Mac it reported a session that had been parked for an hour as
    /// working. An allow-list rather than a list of kinds to skip, because the
    /// bookkeeping kinds are added to between releases.
    ///
    /// Nil when the tail holds no conversation at all — a session that has been
    /// opened and not yet used. The caller leaves such a session as it found it
    /// rather than guessing.
    static func turn(inTail data: Data) -> Turn? {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            // The first line of the tail is usually cut in half; it fails to
            // parse and is skipped, which is the whole handling it needs.
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line)))
                    as? [String: Any] else { continue }
            // A subagent's records are interleaved with its parent's, and the
            // parent's turn is the one being reported on.
            if json["isSidechain"] as? Bool == true { continue }

            switch json["type"] as? String {
            case "assistant":
                // `tool_use` is the only stop reason that means the turn goes
                // on; `end_turn`, `stop_sequence` and `max_tokens` all end it.
                let message = json["message"] as? [String: Any]
                return message?["stop_reason"] as? String == "tool_use" ? .inFlight : .finished
            case "user":
                return isInterruption(json) ? .finished : .inFlight
            default:
                continue
            }
        }
        return nil
    }

    /// What the session is called: the name given with `/rename` if it has
    /// one, the title Claude Code wrote for it otherwise. Nil when the tail
    /// holds neither.
    ///
    /// The registry's own `name` is only the folder and two characters —
    /// `marketing-hub-e0` — for every session started outside the desktop app,
    /// so three sessions in one project read as three of the same row. Claude
    /// Code keeps appending both kinds of title line as the session goes, so
    /// the tail that already settles `turn` holds the current one too.
    ///
    /// A rename beats a generated title even when the generated one is newer:
    /// Claude Code goes on writing `ai-title` after a `/rename`, and the name
    /// somebody chose is the one they will look for.
    static func title(inTail data: Data) -> String? {
        // Most of a tail is conversation. Only a line that names one of the two
        // kinds is worth decoding.
        let marker = Data(#"-title""#.utf8)
        var generated: String?
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard line.range(of: marker) != nil,
                  let json = (try? JSONSerialization.jsonObject(with: Data(line)))
                    as? [String: Any] else { continue }
            switch json["type"] as? String {
            case "custom-title":
                if let title = trimmed(json["customTitle"]) { return title }
            case "ai-title":
                if generated == nil { generated = trimmed(json["aiTitle"]) }
            default:
                continue
            }
        }
        return generated
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// Pressing Esc writes a user turn saying so, which is what makes "stopped"
    /// something the notch can know rather than wait out with a timeout. Two
    /// wordings exist, and both start the same way.
    private static let interruption = "[Request interrupted by user"

    static func isInterruption(_ json: [String: Any]) -> Bool {
        guard let message = json["message"] as? [String: Any] else { return false }
        switch message["content"] {
        case let text as String:
            return text.hasPrefix(interruption)
        case let blocks as [Any]:
            return blocks.contains { block in
                ((block as? [String: Any])?["text"] as? String)?.hasPrefix(interruption) == true
            }
        default:
            return false
        }
    }
}

/// Reads transcripts on a timer, and remembers enough not to read them twice.
///
/// One instance per monitor. A tick that finds a transcript untouched since the
/// last one costs a `stat` and nothing else — the tail is read only when the
/// file has actually grown.
final class ClaudeTranscriptReader {
    private struct Cached {
        let modified: Date
        let size: UInt64
        let turn: ClaudeTranscript.Turn?
        let title: String?
    }

    private let projects: URL
    private let fileManager: FileManager
    /// Where each session's transcript turned out to be. Sessions come and go;
    /// this is bounded by how many have run since the app launched.
    private var paths: [String: URL] = [:]
    private var cache: [String: Cached] = [:]
    /// When each session last changed what it was doing.
    ///
    /// The transcript's timestamp is when it was last *appended to*, which
    /// moves every few seconds through a long turn. Reported as-is it would
    /// hold the tooltip's elapsed time at zero for as long as the session
    /// worked, and hand the notch a new value to animate on every tick. What
    /// the notch means by `since` is when the state was entered, so the moment
    /// of the change is kept and the appends in between are ignored.
    private var entered: [String: (turn: ClaudeTranscript.Turn, at: Date)] = [:]
    /// Sessions already looked for the hard way and not found. The directory
    /// scan is worth doing once for a session that has moved, and never worth
    /// repeating every two seconds for one that simply has no transcript.
    private var scanned: Set<String> = []

    init(projects: URL, fileManager: FileManager = .default) {
        self.projects = projects
        self.fileManager = fileManager
    }

    /// What the session is doing, and when it last moved. Nil when there is no
    /// transcript to read, or nothing said in it yet.
    func activity(sessionID: String, cwd: String) -> (turn: ClaudeTranscript.Turn, since: Date)? {
        guard let read = current(sessionID: sessionID, cwd: cwd),
              let turn = read.turn else { return nil }
        if let previous = entered[sessionID], previous.turn == turn {
            return (turn, previous.at)
        }
        // First sight of a change, so the file's own timestamp is the closest
        // thing there is to when it happened.
        entered[sessionID] = (turn, read.modified)
        return (turn, read.modified)
    }

    /// The session's title, or nil when there is no transcript or no title in
    /// it yet. See `ClaudeTranscript.title(inTail:)`.
    func title(sessionID: String, cwd: String) -> String? {
        current(sessionID: sessionID, cwd: cwd)?.title
    }

    /// One read of the tail answers both questions, and an unchanged file is
    /// not read at all.
    private func current(sessionID: String, cwd: String) -> Cached? {
        guard let url = path(sessionID: sessionID, cwd: cwd),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

        if let cached = cache[sessionID], cached.modified == modified, cached.size == size {
            return cached
        }
        let tail = ClaudeTranscript.tail(of: url)
        let read = Cached(modified: modified, size: size,
                          turn: tail.flatMap(ClaudeTranscript.turn(inTail:)),
                          title: tail.flatMap(ClaudeTranscript.title(inTail:)))
        cache[sessionID] = read
        return read
    }

    private func path(sessionID: String, cwd: String) -> URL? {
        if let known = paths[sessionID] { return known }
        let scanning = !scanned.contains(sessionID)
        guard let found = ClaudeTranscript.transcript(
            forSessionID: sessionID, cwd: cwd, in: projects,
            scanning: scanning, fileManager: fileManager
        ) else {
            if scanning { scanned.insert(sessionID) }
            return nil
        }
        paths[sessionID] = found
        return found
    }
}
