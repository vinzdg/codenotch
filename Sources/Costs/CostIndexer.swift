import Foundation
import CoreServices

/// Reads Claude Code's session transcripts and extracts *only* token counts.
///
/// What it reads, per record, and nothing else:
///   timestamp, cwd, gitBranch, sessionId, requestId, version,
///   message.model, message.usage.{input,output,cache_read,cache_creation}_tokens
///
/// It never touches `message.content`, `toolUseResult`, `attachment` records, or
/// the `tool-results/` and `subagents/` sibling directories. Transcripts can hold
/// secrets an agent read from a project; this feature must never be a way for them
/// to leave the machine — and nothing here is ever sent anywhere.
///
/// Reading is incremental: each file's byte offset is stored, so later passes only
/// parse what was appended. A trailing partial line (Claude Code mid-write) is left
/// unconsumed until its newline arrives.
final class CostIndexer {
    /// Which CLI wrote the transcripts under `root`.
    enum Format { case claude, codex }

    private let store: CostStore
    private let root: URL
    private let format: Format
    /// Codex rollouts carry session id, cwd and model in earlier lines than the
    /// token counts; remember them per file across incremental reads.
    private var codexContext: [String: (sessionId: String, cwd: String, model: String)] = [:]
    private let queue = DispatchQueue(label: "com.vinz.codenotch.costs.indexer", qos: .utility)
    private var stream: FSEventStreamRef?
    private var gitRootCache: [String: String] = [:]
    private var scanScheduled = false

    /// Called on the indexer queue after a pass that changed something.
    var onChange: (() -> Void)?

    init?(store: CostStore, root: URL, format: Format = .claude) {
        self.store = store
        self.root = root
        self.format = format
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
    }

    deinit { stopWatching() }

    // MARK: Scanning

    func start() {
        scan()
        startWatching()
    }

    func scan() {
        queue.async { [weak self] in self?.performScan() }
    }

    private func performScan() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return }
        var files: [(url: URL, mtime: Date)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            files.append((url, m ?? .distantPast))
        }
        // Newest first: the current period becomes correct before the backfill finishes.
        files.sort { $0.mtime > $1.mtime }

        var changed = false
        for f in files where indexFile(f.url) { changed = true }
        if changed { onChange?() }
    }

    /// Returns true when new rows were written.
    @discardableResult
    private func indexFile(_ url: URL) -> Bool {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        let size = (attrs[.size] as? Int) ?? 0
        let inode = (attrs[.systemFileNumber] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        var offset = 0
        if let cursor = store.fileCursor(path) {
            if cursor.inode != inode || size < cursor.offset {
                offset = 0                          // rotated or truncated: re-read
            } else if size == cursor.offset {
                return false                        // nothing appended
            } else {
                offset = cursor.offset
            }
        }
        guard size > offset else { return false }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(offset)) } catch { return false }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return false }

        // The directory name encodes the folder the session was started in, which
        // is a better project key than a deep cwd when the git root is gone.
        let folder = format == .claude ? url.deletingLastPathComponent().lastPathComponent : ""
        if format == .codex, offset > 0, codexContext[path] == nil { primeCodexContext(url) }
        var events: [UsageEvent] = []
        var malformed = 0
        var consumed = 0

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let buf = UnsafeBufferPointer(start: base, count: raw.count)
            var start = 0
            for i in 0..<buf.count {
                guard buf[i] == 0x0A else { continue }
                if i > start {
                    let slice = UnsafeBufferPointer(rebasing: buf[start..<i])
                    switch format == .claude ? parse(slice, folder: folder) : parseCodex(slice, path: path) {
                    case .event(let e): events.append(e)
                    case .malformed:    malformed += 1
                    case .skip:         break
                    }
                }
                start = i + 1
                consumed = start          // only advance past complete lines
            }
        }

        guard consumed > 0 else { return false }   // no complete line yet
        store.commit(events: events, path: path, inode: inode, size: size,
                     offset: offset + consumed, mtime: mtime)
        store.recordParseErrors(path: path, count: malformed, reason: "malformed line")
        return !events.isEmpty
    }

    // MARK: Parsing

    private enum ParseResult {
        case event(UsageEvent)
        case skip          // not an assistant turn, or synthetic — expected, not an error
        case malformed     // broken JSON or a missing field we require
    }

    private static let marker = Array("\"assistant\"".utf8)

    private lazy var isoWithMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private lazy var isoPlain = ISO8601DateFormatter()

    private func parse(_ line: UnsafeBufferPointer<UInt8>, folder: String) -> ParseResult {
        // Cheap pre-filter: most lines are user turns or attachments and never
        // reach the JSON parser.
        guard Self.contains(line, Self.marker) else { return .skip }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
            return .malformed
        }
        guard obj["type"] as? String == "assistant" else { return .skip }

        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String else { return .malformed }
        // Synthetic turns are local error placeholders, not billed requests.
        guard model != "<synthetic>" else { return .skip }

        guard let cwd = obj["cwd"] as? String,
              let sessionId = obj["sessionId"] as? String ?? obj["session_id"] as? String,
              let stamp = obj["timestamp"] as? String,
              let date = isoWithMillis.date(from: stamp) ?? isoPlain.date(from: stamp),
              let input = int(usage["input_tokens"]),
              let output = int(usage["output_tokens"]) else { return .malformed }

        let cacheRead = int(usage["cache_read_input_tokens"]) ?? 0
        let cacheWrite = int(usage["cache_creation_input_tokens"]) ?? 0
        let ts = Int(date.timeIntervalSince1970)

        // Claude Code appends the same turn several times while streaming, each
        // write carrying a larger output count. Collapse them by request id and
        // keep the maximum (see CostStore.commit).
        let key: String
        if let requestId = obj["requestId"] as? String, !requestId.isEmpty {
            key = "r:\(requestId)"
        } else {
            key = "s:\(sessionId):\(ts):\(input):\(output):\(cacheRead):\(cacheWrite)"
        }

        var branch = obj["gitBranch"] as? String
        if branch?.isEmpty ?? false { branch = nil }

        return .event(UsageEvent(
            ts: ts,
            sessionId: sessionId,
            dedupeKey: key,
            project: projectRoot(for: cwd, folder: folder),
            cwd: cwd,
            branch: branch,
            model: model,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            ccVersion: obj["version"] as? String
        ))
    }

    // MARK: Codex rollouts
    //
    // Lines: {"timestamp","type":"session_meta","payload":{"id","cwd",…}},
    //        {"type":"response_item"|"event_msg","payload":{"type":"turn_context","cwd","model"}},
    //        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{…}}}}.
    // Only the token counts become events; the other two feed the per-file context.

    private static let codexMarkers: [[UInt8]] = [Array("token_count".utf8), Array("session_meta".utf8), Array("turn_context".utf8)]

    /// When resuming mid-file, read the head line for the session id and cwd.
    private func primeCodexContext(_ url: URL) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 64 * 1024)
        for line in head.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if obj["type"] as? String == "session_meta", let p = obj["payload"] as? [String: Any] {
                codexContext[url.path] = (p["id"] as? String ?? p["session_id"] as? String ?? url.deletingPathExtension().lastPathComponent,
                                          p["cwd"] as? String ?? "", "")
                return
            }
        }
    }

    private static let modelMarker = Array("\"model\":\"".utf8)
    private static let modelRegex = try! NSRegularExpression(pattern: "\"model\":\"([^\"]+)\"")

    private func parseCodex(_ line: UnsafeBufferPointer<UInt8>, path: String) -> ParseResult {
        // The model name travels in several record kinds (turn context, task
        // start, item events); any line naming one updates the file's context.
        if Self.contains(line, Self.modelMarker) {
            let text = String(decoding: line, as: UTF8.self)
            if let m = Self.modelRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                var ctx = codexContext[path] ?? ("", "", "")
                ctx.model = String(text[r])
                codexContext[path] = ctx
            }
        }
        guard Self.codexMarkers.contains(where: { Self.contains(line, $0) }) else { return .skip }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return .malformed }
        let type = obj["type"] as? String ?? ""
        if type == "session_meta" {
            codexContext[path] = (payload["id"] as? String ?? payload["session_id"] as? String
                                    ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                                  payload["cwd"] as? String ?? "", codexContext[path]?.model ?? "")
            return .skip
        }
        if payload["type"] as? String == "turn_context" {
            var ctx = codexContext[path] ?? ("", "", "")
            if let c = payload["cwd"] as? String, !c.isEmpty { ctx.cwd = c }
            if let m = payload["model"] as? String, !m.isEmpty { ctx.model = m }
            codexContext[path] = ctx
            return .skip
        }
        guard payload["type"] as? String == "token_count" else { return .skip }
        guard let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else { return .skip }   // rate-limit-only ticks
        guard let stamp = obj["timestamp"] as? String,
              let date = isoWithMillis.date(from: stamp) ?? isoPlain.date(from: stamp),
              let inputAll = int(last["input_tokens"]), let output = int(last["output_tokens"]) else { return .malformed }
        let ctx = codexContext[path] ?? ("", "", "")
        let sessionId = ctx.sessionId.isEmpty ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : ctx.sessionId
        let cwd = ctx.cwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : ctx.cwd
        let cached = int(last["cached_input_tokens"]) ?? 0
        let cacheWrite = int(last["cache_write_input_tokens"]) ?? 0
        let ts = Int(date.timeIntervalSince1970)
        guard inputAll + output > 0 else { return .skip }
        return .event(UsageEvent(
            ts: ts, sessionId: sessionId,
            dedupeKey: "c:\(sessionId):\(ts):\(inputAll):\(output)",
            project: projectRoot(for: cwd, folder: ""), cwd: cwd, branch: nil,
            model: ctx.model.isEmpty ? "codex" : ctx.model,
            input: max(0, inputAll - cached), output: output, cacheRead: cached, cacheWrite: cacheWrite,
            ccVersion: nil))
    }

    private func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        let last = haystack.count - needle.count
        for i in 0...last where haystack[i] == needle[0] {
            var match = true
            for j in 1..<needle.count where haystack[i + j] != needle[j] { match = false; break }
            if match { return true }
        }
        return false
    }

    // MARK: Project grouping

    /// Sessions started from subfolders of one repo should read as one project, so
    /// the cwd is walked up to its git root. A folder in one project directory can
    /// hold dozens of distinct cwds, which would otherwise fill the list with
    /// `Sources`, `windows`, `docs` rows. Falls back to the cwd itself.
    private func projectRoot(for cwd: String, folder: String) -> String {
        let key = folder + "\u{0}" + cwd
        if let cached = gitRootCache[key] { return cached }

        var result: String?

        // 1. The git root, when the project is still on disk.
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                result = dir.path
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || parent.path == "/" { break }
            dir = parent
        }

        // 2. Otherwise the transcript's directory name, which Claude Code derives
        //    from where the session started by replacing every non-alphanumeric
        //    character with "-". Matching it against the same transform of the cwd
        //    recovers the real prefix without decoding anything, and rescues
        //    deleted projects that would otherwise show up as a deep subfolder.
        if result == nil, !folder.isEmpty, folder.count < cwd.count {
            let normalized = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            if normalized.hasPrefix(folder) {
                result = String(cwd.prefix(folder.count))
            }
        }

        let resolved = result ?? cwd
        gitRootCache[key] = resolved
        return resolved
    }

    // MARK: Watching

    private func startWatching() {
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<CostIndexer>.fromOpaque(info).takeUnretainedValue().coalescedScan()
        }
        guard let s = FSEventStreamCreate(nil, callback, &context,
                                          [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          2.0,   // latency doubles as debounce
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// FSEvents can fire repeatedly while a session is being written; collapse
    /// bursts into one pass.
    private func coalescedScan() {
        queue.async { [weak self] in
            guard let self, !self.scanScheduled else { return }
            self.scanScheduled = true
            self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.scanScheduled = false
                self.performScan()
            }
        }
    }
}
