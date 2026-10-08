import Foundation

/// Reads oMLX's own server log for the numbers each response left behind.
///
/// `~/.omlx/logs/server.log`, written by Python's `logging` with the format
/// `%(asctime)s - %(name)s - %(levelname)s - [%(request_id)s] - %(message)s`,
/// local time with no offset and comma milliseconds. Recorded from oMLX 0.7.0
/// on 2026-10-07:
///
///     2026-10-07 23:09:35,762 - omlx.server - INFO - [-] - Chat completion: model=Qwen3.8-27B-oQ8e-mtp, 430 tokens in 10.97s (42.8 tok/s), prompt: 68, finish_reason=stop, max_tokens=32768, request_max_tokens=None, stream_model_ttft=0.91s, stream_visible_ttft=0.97s
///     2026-10-07 17:12:01,118 - omlx.server - INFO - [-] - Chat completion: model=Qwen3.8-27B-oQ4e-mtp, 112 tokens in 3.41s (32.8 tok/s), prompt: 2534, finish_reason=length, max_tokens=32768, request_max_tokens=None
///
/// The other endpoints log the same `model=…, N tokens in Ns (N tok/s)` shape
/// under their own prefix (source-derived from `omlx/server.py` 0.7.0, none
/// recorded yet). Legacy completions carry `prompt:`; `/v1/messages`, which
/// Claude Code calls, and the Responses API do not, so their input is unknown:
///
///     2026-10-08 09:00:00,000 - omlx.server - INFO - [-] - Completion: model=Qwen3.8-27B-oQ8e-mtp, 96 tokens in 2.40s (40.0 tok/s), prompt: 31
///     2026-10-08 09:00:00,000 - omlx.server - INFO - [-] - Anthropic message: model=Qwen3.8-27B-oQ8e-mtp, 1200 tokens in 40.00s (30.0 tok/s)
///     2026-10-08 09:00:00,000 - omlx.server - INFO - [-] - Responses API: model=Qwen3.8-27B-oQ8e-mtp, 250 tokens in 6.25s (40.0 tok/s)
///
/// Diffusion models write `(64.0 tok/s e2e, output=80.5 tok/s, …)`; the first
/// figure is the one comparable with every other model's. Prompts and replies
/// are never logged, so a line holds nothing that must be kept out of memory.
///
/// The figure oMLX prints is completion tokens over a duration it chose: the
/// whole elapsed time (prefill included) for non-streamed requests and for
/// every Anthropic and Responses line, decode time only for streamed chat and
/// legacy completions. The printed `in Ns` is always the whole elapsed time,
/// so `generationSeconds` is derived as tokens over the printed rate rather
/// than from that or a TTFT subtraction: the speed Codenotch shows is then the
/// speed oMLX itself reported, whichever duration it used.
///
/// Most of the file is other loggers (`httpx`, `omlx.scheduler`, model
/// loading) and multi-line tracebacks. Each line is rejected on its first
/// bytes — timestamp shape, then the `omlx.server` logger name — and only a
/// candidate is decoded, the discipline `LMStudioServerLog` keeps for a log of
/// fifteen million lines.
struct OMLXServerLog {
    enum Event: Equatable {
        case prediction(LocalPrediction)
    }

    private var pending = Data()
    private let formatter: DateFormatter
    /// A line this long is not a log line; give up on it rather than grow.
    private let limit = 4 * 1024 * 1024

    /// `<stamp> - omlx.server - `, everything after the 23-byte stamp that
    /// must match before a line is worth decoding.
    private static let logger = Data(" - omlx.server - ".utf8)
    private static let separator = Data(" - ".utf8)
    /// Every per-response message oMLX 0.7.0 writes, each followed by `model=`.
    static let prefixes = ["Chat completion: ", "Completion: ", "Anthropic message: ", "Responses API: "]
    private static let markers = prefixes.map { Data(($0 + "model=").utf8) }
    private static let shortestMarker = markers.map(\.count).min() ?? 0
    private static let stampLength = 23

    init(timeZone: TimeZone = .current) {
        // oMLX stamps lines in the Mac's own zone, with no offset written.
        // One formatter, used only for lines that already passed the byte
        // checks, so its cost never scales with the log.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        self.formatter = formatter
    }

    /// Feed bytes as they arrive; a line split across two reads is held until
    /// its newline comes. One pass over the buffer: nothing is shifted per line.
    mutating func append(_ data: Data) -> [Event] {
        var events: [Event] = []
        let buffer = pending.isEmpty ? data : pending + data
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart..<buffer.endIndex].firstIndex(of: 10) {
            if let event = consume(buffer[lineStart..<newline]) { events.append(event) }
            lineStart = newline + 1
        }
        pending = lineStart < buffer.endIndex ? Data(buffer[lineStart..<buffer.endIndex]) : Data()
        if pending.count > limit { pending.removeAll() }
        return events
    }

    /// The end of a file: whatever is buffered is a whole line.
    mutating func finish() -> [Event] {
        guard !pending.isEmpty else { return [] }
        let line = pending
        pending = Data()
        return consume(line).map { [$0] } ?? []
    }

    private func consume(_ rawLine: Data) -> Event? {
        let line = rawLine.last == 13 ? rawLine.dropLast() : rawLine
        guard let message = Self.responseMessage(in: line),
              let at = formatter.date(from: String(decoding: line.prefix(Self.stampLength), as: UTF8.self)),
              let prediction = Self.prediction(from: String(decoding: message, as: UTF8.self), at: at)
        else { return nil }
        return .prediction(prediction)
    }

    // MARK: - Lines

    /// The message of an `omlx.server` per-response line, as bytes, or nil
    /// for any other line. Nothing is decoded here.
    private static func responseMessage(in line: Data) -> Data? {
        let s = line.startIndex, e = line.endIndex
        guard line.count > stampLength + logger.count + shortestMarker,
              line[s + 4] == 0x2D, line[s + 7] == 0x2D, line[s + 10] == 0x20,      // - - space
              line[s + 13] == 0x3A, line[s + 16] == 0x3A, line[s + 19] == 0x2C,    // : : ,
              line[(s + stampLength)...].starts(with: logger)
        else { return nil }
        // The level, then ` - `.
        var i = s + stampLength + logger.count
        guard let levelEnd = line[i..<e].firstRange(of: separator) else { return nil }
        i = levelEnd.upperBound
        // `[request-id] - ` is present with oMLX's default format and absent
        // when it is configured without request ids; accept both.
        if i < e, line[i] == 0x5B, let close = line[i..<e].firstIndex(of: 0x5D),
           line[(close + 1)...].starts(with: separator) {
            i = close + 1 + separator.count
        }
        let message = line[i..<e]
        return markers.contains(where: { message.starts(with: $0) }) ? message : nil
    }

    /// `<prefix>model=<id>, <n> tokens in <t>s (<r> tok/s…)[, prompt: <n>, …]`
    static func prediction(from message: String, at: Date) -> LocalPrediction? {
        guard let prefix = prefixes.first(where: { message.hasPrefix($0 + "model=") }) else { return nil }
        let body = message.dropFirst(prefix.count + "model=".count)
        guard let modelEnd = body.range(of: ", ") else { return nil }
        let instance = String(body[body.startIndex..<modelEnd.lowerBound])
        let rest = body[modelEnd.upperBound...]
        guard !instance.isEmpty,
              let tokensEnd = rest.range(of: " tokens in "),
              let output = Int(rest[rest.startIndex..<tokensEnd.lowerBound]), output > 0,
              let open = rest[tokensEnd.upperBound...].firstIndex(of: "("),
              let rateEnd = rest[open...].range(of: " tok/s"),
              let rate = Double(rest[rest.index(after: open)..<rateEnd.lowerBound]),
              rate.isFinite, rate > 0
        else { return nil }
        // Fields after the parenthesis; the diffusion variant's `prompt=… tok/s`
        // sits inside it and is not the prompt count.
        let fields = rest[rateEnd.upperBound...].firstIndex(of: ")").map { rest[$0...] } ?? rest[rateEnd.upperBound...]
        return LocalPrediction(
            instance: instance, at: at,
            inputTokens: field("prompt: ", in: fields).flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil },
            outputTokens: output,
            tokensPerSecond: rate,
            timeToFirstToken: seconds(field("stream_model_ttft=", in: fields)),
            generationSeconds: Double(output) / rate
        )
    }

    /// The text after `, <name>` up to the next comma, or nil when absent.
    private static func field(_ name: String, in text: Substring) -> Substring? {
        guard let start = text.range(of: ", " + name) else { return nil }
        let value = text[start.upperBound...]
        return value[value.startIndex..<(value.firstIndex(of: ",") ?? value.endIndex)]
    }

    /// `0.91s` → 0.91; `unavailable` or anything else → nil.
    private static func seconds(_ value: Substring?) -> TimeInterval? {
        guard let value, value.hasSuffix("s"), let number = Double(value.dropLast()),
              number.isFinite, number > 0 else { return nil }
        return number
    }
}

/// The server log as one stream: every rotated file, then whatever
/// `server.log` grows by.
///
/// A class of its own rather than a generalised `LMStudioLogTail`: LM Studio
/// starts a new file and leaves the old one where it was, so following "the
/// newest file" is enough there. oMLX's `TimedRotatingFileHandler` renames
/// `server.log` to `server.log.YYYY-MM-DD` at midnight and starts a fresh
/// `server.log` under the same name, so the tail has to notice the live file
/// was replaced and finish the renamed one from where it stopped reading.
final class OMLXLogTail {
    private let directory: URL
    private let timeZone: TimeZone
    private var parser: OMLXServerLog
    private(set) var file: URL?
    private(set) var offset: UInt64 = 0
    /// The live file's identity when it was last read; a different one means
    /// it was rotated even if the new file has already outgrown the offset.
    private var inode: UInt64?
    /// Rotated files already read in full, so a rotation is matched to the
    /// one file it produced.
    private var seen: Set<String> = []
    /// Read in slices this size, the same as LM Studio's tail.
    private let chunk = 4 << 20

    static let liveName = "server.log"

    init(directory: URL, timeZone: TimeZone = .current) {
        self.directory = directory
        self.timeZone = timeZone
        parser = OMLXServerLog(timeZone: timeZone)
    }

    /// Oldest first: `server.log.YYYY-MM-DD` by date (the names sort as
    /// written), then `server.log`. Anything else in the directory, such as
    /// `crash.log`, is not this log.
    static func logFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let rotated = names.filter(isRotatedName).sorted()
        let live = names.contains(liveName) ? [liveName] : []
        return (rotated + live).map { directory.appendingPathComponent($0) }
    }

    private static func isRotatedName(_ name: String) -> Bool {
        let prefix = liveName + "."
        guard name.hasPrefix(prefix) else { return false }
        let date = Array(name.utf8.dropFirst(prefix.utf8.count))
        guard date.count == 10, date[4] == 0x2D, date[7] == 0x2D else { return false }
        return date.enumerated().allSatisfy { $0.offset == 4 || $0.offset == 7 || (0x30...0x39).contains($0.element) }
    }

    /// Everything logged so far. Leaves the tail at the end of `server.log`,
    /// so `poll` continues from there.
    func loadHistory() -> [OMLXServerLog.Event] {
        var events: [OMLXServerLog.Event] = []
        for url in Self.logFiles(in: directory) {
            var fileParser = OMLXServerLog(timeZone: timeZone)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let read = Self.read(handle, from: 0, chunk: chunk) { events += fileParser.append($0) }
            try? handle.close()
            if url.lastPathComponent == Self.liveName {
                // A half-written last line stays with the parser for the next poll.
                parser = fileParser
                file = url
                offset = read
                inode = Self.inode(of: url)
            } else {
                events += fileParser.finish()
                seen.insert(url.lastPathComponent)
            }
        }
        return events
    }

    /// Whatever was written since the last look.
    func poll() -> [OMLXServerLog.Event] {
        var events: [OMLXServerLog.Event] = []
        let live = directory.appendingPathComponent(Self.liveName)
        guard let handle = try? FileHandle(forReadingFrom: live) else { return events }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let current = Self.inode(of: live)
        if file != nil, size < offset || (inode != nil && current != inode) {
            events += finishRotated()
        }
        file = live
        inode = current
        guard size > offset else { return events }
        offset += Self.read(handle, from: offset, chunk: chunk) { events += parser.append($0) }
        return events
    }

    /// `server.log` was replaced. Every rotated file present at `loadHistory`
    /// was marked seen, so the oldest one not yet read is what the live file
    /// was renamed to: read it on from the old offset and close it. Usually
    /// that is also the newest; when the Mac slept through more than one
    /// midnight, the later ones were whole days never read and are read in full.
    private func finishRotated() -> [OMLXServerLog.Event] {
        var events: [OMLXServerLog.Event] = []
        let unseen = Self.logFiles(in: directory).filter {
            $0.lastPathComponent != Self.liveName && !seen.contains($0.lastPathComponent)
        }
        var start = offset
        for url in unseen {
            if let handle = try? FileHandle(forReadingFrom: url) {
                let size = (try? handle.seekToEnd()) ?? 0
                if size >= start {
                    _ = Self.read(handle, from: start, chunk: chunk) { events += parser.append($0) }
                }
                try? handle.close()
            }
            events += parser.finish()
            parser = OMLXServerLog(timeZone: timeZone)
            seen.insert(url.lastPathComponent)
            start = 0
        }
        events += parser.finish()
        parser = OMLXServerLog(timeZone: timeZone)
        offset = 0
        return events
    }

    private static func inode(of url: URL) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// Bytes from `start` to the end, a chunk at a time. Returns how many.
    private static func read(_ handle: FileHandle, from start: UInt64, chunk: Int,
                             _ body: (Data) -> Void) -> UInt64 {
        guard (try? handle.seek(toOffset: start)) != nil else { return 0 }
        var total: UInt64 = 0
        while let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            body(data)
            total += UInt64(data.count)
        }
        return total
    }
}
