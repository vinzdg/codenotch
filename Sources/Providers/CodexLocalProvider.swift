import Foundation
import SQLite3

/// Reads live account limits using the session owned and refreshed by Codex.
actor CodexLocalProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.openai
    nonisolated let profile: CodexProfile

    private let session: URLSession
    nonisolated private let authURL: URL
    private let archive: UsageArchive
    private var retryNoEarlierThan: Date?

    init(profile: CodexProfile = .default(),
         session: URLSession = .shared,
         authURL: URL? = nil,
         archive: UsageArchive = UsageArchive()) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        self.session = session
        self.authURL = authURL ?? profile.authURL
        self.archive = archive
        // Recreating the provider or relaunching must not bypass the server's retry deadline.
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: profile.id)
    }

    nonisolated var signInRoute: SignInRoute {
        guard profile.slug != nil else { return .openApp(bundleID: "com.openai.codex", name: "Codex") }
        return .command(profile.signInCommand, name: displayName,
                        install: URL(string: "https://developers.openai.com/codex/cli"))
    }

    nonisolated func account() -> ProviderAccount? {
        CodexCredentials.account(from: authURL, source: profile.sourceName)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let now = Date()
        if let retryNoEarlierThan, retryNoEarlierThan > now {
            throw UsageProviderError.rateLimited(retryAfter: retryNoEarlierThan.timeIntervalSince(now))
        }

        // Codex can rotate its token between polls; this app never refreshes or writes it.
        let credential = try CodexCredentials.load(from: authURL)
        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            let receivedAt = Date()
            let delay = max(60, Self.retryAfter(from: http, now: receivedAt) ?? 0)
            retryNoEarlierThan = receivedAt.addingTimeInterval(delay)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        // Unused resets are a separate endpoint from the extra Spark / code-review
        // windows. Start that fetch before parsing extras so a slow or empty
        // extras payload cannot skip the credits row.
        async let resetCredits = Self.fetchResetCredits(session: session, credential: credential)

        let windows = try CodexUsage.windows(
            from: data,
            includeExtras: Preferences.storedShowCodexExtraLimits()
        )

        // The profile page's token statistics are the source for the chart and
        // totals.
        let profileUsage = try? await Self.fetchProfileUsage(
            session: session, credential: credential
        )
        retryNoEarlierThan = nil
        archive.saveBackoffUntil(nil, providerID: id)
        return ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: .ok, windows: windows,
            // Named, not positional. `windows.first` would let Spark take the
            // ring whenever primary is missing — extras are appended after the
            // main pair, but a Spark-only payload still leads with spark.
            headlineID: "primary",
            // The weekly ring is the account weekly, never Spark's own weekly.
            weeklyID: "secondary",
            tokenUsage: profileUsage,
            plan: CodexUsage.plan(from: data) ?? account()?.plan?.nonEmptyPlan,
            resetCredits: await resetCredits
        )
    }

    /// Shared with the remote provider: same account, same backend.
    static func fetchProfileUsage(
        session: URLSession,
        credential: CodexCredentials.Credential
    ) async throws -> CodexTokenUsage {
        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        return try CodexUsage.profileUsage(from: data)
    }

    /// Unused rate-limit resets on this Codex account, listed by the same
    /// backend as usage.
    /// Shared with the remote provider: same account, same backend.
    static func fetchResetCredits(
        session: URLSession,
        credential: CodexCredentials.Credential
    ) async -> UsageResetCredits? {
        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return nil }
            return try CodexUsage.resetCredits(from: data)
        } catch {
            return nil
        }
    }

    /// Shared with the remote provider: same endpoint, same rate limit.
    static func retryAfter(from response: HTTPURLResponse?, now: Date) -> TimeInterval? {
        guard let header = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        if let seconds = TimeInterval(header), seconds.isFinite { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// Shared access to Codex's local state.
enum CodexStore {
    static var stateURL: URL {
        CodexProfile.default().stateURL
    }

    /// The desktop app's own thread catalogue.
    ///
    /// Codex's *rollouts* are written by the CLI and by the VS Code extension.
    /// The desktop app — ChatGPT.app, which is what most people mean by "Codex"
    /// now — writes none of them; it keeps its threads here instead, with
    /// `source_kind = 'chatgpt'`. Watching only the rollouts meant the notch
    /// could never see the desktop app working at all.
    static var desktopStoreURL: URL {
        CodexProfile.default().desktopStoreURL
    }

    /// The most recently touched desktop thread: when, what it is called, and
    /// its id — which the desktop app shares with the `threads` table when the
    /// same conversation is also open in the CLI or VS Code, so the activity
    /// monitor can tell one conversation from two.
    static func newestDesktopThread(in url: URL)
    -> (title: String, updatedAt: Date, threadID: String)? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }

        let rows = SQLiteStore.rows(
            in: db,
            sql: """
            SELECT source_updated_at, display_title, thread_id
            FROM local_thread_catalog ORDER BY source_updated_at DESC LIMIT 1
            """,
            columns: 3
        )
        guard let row = rows.first, let seconds = Double(row[0]) else { return nil }
        // Seconds since the epoch, with a fractional part — not the
        // milliseconds the `threads` table next door uses.
        let title = row[1].isEmpty ? "Codex" : row[1]
        return (title, Date(timeIntervalSince1970: seconds), row[2])
    }

    /// The rollout of the most recently touched thread.
    static func newestRollout(in store: URL) -> URL? {
        guard let db = SQLiteStore.open(store) else { return nil }
        defer { sqlite3_close(db) }

        let paths = SQLiteStore.rows(
            in: db,
            sql: "SELECT rollout_path FROM threads WHERE archived = 0 ORDER BY updated_at_ms DESC LIMIT 8"
        )
        return paths
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The most recently touched threads, with what it takes to name them —
    /// plus every ancestor of a sub-agent among them, so a helper's work can be
    /// credited to the conversation that started it.
    ///
    /// Columns are asked for only when the table has them. `name` is recent,
    /// a store written by an older Codex does not have it, and a query naming a
    /// missing column fails outright — which would cost even the rollout path
    /// this monitor has always worked from.
    static func recentThreads(in store: URL, limit: Int = 24) -> [CodexThread] {
        guard let db = SQLiteStore.open(store) else { return [] }
        defer { sqlite3_close(db) }

        let present = Set(SQLiteStore.rows(
            in: db, sql: "SELECT name FROM pragma_table_info('threads')"))
        guard present.contains("rollout_path") else { return [] }
        func column(_ name: String) -> String { present.contains(name) ? name : "NULL" }

        // The preview is the opening of the first message; `title` is the older
        // column that held the same thing.
        let preview: String
        switch (present.contains("preview"), present.contains("title")) {
        case (true, true):  preview = "COALESCE(NULLIF(preview, ''), title)"
        case (true, false): preview = "preview"
        case (false, true): preview = "title"
        case (false, false): preview = "NULL"
        }
        // `source` is plain text for a conversation ("vscode", "exec") and JSON
        // for a sub-agent, and `json_extract` on the plain kind is an error
        // rather than a NULL. Without an `id` a parent could never be matched,
        // so it is not worth reading.
        let parent = present.contains("source") && present.contains("id")
            ? "CASE WHEN json_valid(source) THEN json_extract(source, '$.subagent.thread_spawn.parent_thread_id') END"
            : "NULL"
        // Any sub-agent at all, whether or not `source` says whose it is. A
        // guardian — the helper auto-review runs to vet each action — is
        // recorded as `{"subagent":{"other":"guardian"}}`, with no parent, and
        // taking it for a conversation drew a row of its own that chimed
        // "Complete" after every review while the real request was mid-turn.
        let helper = present.contains("source")
            ? "CASE WHEN json_valid(source) THEN json_extract(source, '$.subagent') IS NOT NULL ELSE 0 END"
            : "0"
        let select = """
            SELECT \(column("id")), rollout_path, \(column("name")), \(preview), \
            \(column("cwd")), \(parent), \(helper) FROM threads
            """
        let active = present.contains("archived") ? "WHERE archived = 0" : ""
        let order = present.contains("updated_at_ms") ? "updated_at_ms" : "rowid"

        var threads = SQLiteStore
            .rows(in: db, sql: "\(select) \(active) ORDER BY \(order) DESC LIMIT \(limit)",
                  columns: 7)
            .map(CodexThread.init(row:))
            .map(\.withParentFromRollout)

        // A sub-agent's parent is usually busy too, waiting on it, but it need
        // not be recent enough to have made the page above. Walk up and fetch
        // what is missing — a few levels at most; Codex nests helpers shallowly.
        guard present.contains("id") else { return threads }
        var known = Set(threads.map(\.id))
        for _ in 0..<4 {
            let missing = Set(threads.compactMap(\.parentID))
                .subtracting(known)
                .filter(CodexThread.isPlainID)
            guard !missing.isEmpty else { break }
            let list = missing.sorted().map { "'\($0)'" }.joined(separator: ",")
            let found = SQLiteStore
                .rows(in: db, sql: "\(select) WHERE id IN (\(list))", columns: 7)
                .map(CodexThread.init(row:))
                .map(\.withParentFromRollout)
            guard !found.isEmpty else { break }
            threads += found
            known.formUnion(found.map(\.id))
        }
        return threads
    }
}

/// One row of Codex's `threads` table — as much of it as naming a session takes.
struct CodexThread: Equatable {
    /// Empty on a store too old to have the column.
    let id: String
    let rollout: URL?
    /// Codex's own short name for the conversation — "Fix the flaky login
    /// test" — written a moment after the first turn. Nil until then, and nil
    /// for every thread `codex exec` starts, which Codex never names.
    let name: String?
    /// The opening of the first message: what is left to go on without a name.
    let preview: String?
    let cwd: String?
    /// The thread that spawned this one, when this one is a sub-agent.
    let parentID: String?
    /// Whether this thread is a sub-agent — a helper working *for* a
    /// conversation — even when nothing says which conversation.
    let isHelper: Bool

    /// What identifies the conversation when the store has no ids.
    var key: String { id.isEmpty ? (rollout?.path ?? "") : id }

    /// This thread, with its parent read from the rollout when it is a helper
    /// the store has no parent for.
    ///
    /// Every rollout opens with a `session_meta` line, and a sub-agent's names
    /// its parent — checked on a real machine for every guardian and every
    /// spawned helper. A guardian's `threads` row does not, so the rollout is
    /// the only place that says whose review it is. Read once per change of
    /// the store, and only for those threads.
    var withParentFromRollout: CodexThread {
        guard isHelper, parentID == nil, let rollout,
              let parent = Self.parent(fromRolloutHead: rollout)
        else { return self }
        return CodexThread(id: id, rollout: rollout, name: name, preview: preview,
                           cwd: cwd, parentID: parent, isHelper: isHelper)
    }

    /// The opening line is the session's whole configuration — tens of
    /// kilobytes on this machine, never near this. A file that has no newline
    /// by here is not a rollout worth reading further.
    static let longestHead = 512 * 1024

    static func parent(fromRolloutHead url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var head = Data()
        while head.count < longestHead {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                head.append(chunk[chunk.startIndex..<newline])
                break
            }
            head.append(chunk)
        }
        guard let object = try? JSONSerialization.jsonObject(with: head) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let parent = payload["parent_thread_id"] as? String,
              isPlainID(parent)
        else { return nil }
        return parent
    }

    /// What to call this conversation on the notch.
    ///
    /// Codex's own name first, because it is the one a person gave or saw.
    /// Then the first line of what was asked, which is how the desktop app
    /// titles a thread before it has a name. Then the folder, which is all a
    /// Claude session falls back to as well. Only then the provider's name,
    /// which is what every Codex row used to say — "Codex", however many
    /// conversations were running and whatever each was about.
    func label(fallback: String) -> String {
        if let name { return name }
        if let line = preview.map(Self.request(in:)).flatMap(Self.firstLine) { return line }
        if let cwd {
            let folder = (cwd as NSString).lastPathComponent
            if !folder.isEmpty, folder != "/" { return folder }
        }
        return fallback
    }

    /// What the person asked, out of a preview that may open with context
    /// Codex added to it.
    ///
    /// Codex puts attached and mentioned files, and the in-app browser's
    /// state, *ahead* of the request — "# Files mentioned by the user:", a
    /// `<in-app-browser-context …>` block — and marks where the request itself
    /// begins with a `## My request` line. That marker is Codex's own, so it is
    /// what this goes by rather than guessing at which lines look like
    /// headings: a request that opens with a `#hashtag` is still the request.
    /// Numeric character references come through literally ("&#x20;Hi") and
    /// are decoded.
    static func request(in preview: String) -> String {
        var lines = decodingNumericReferences(preview)
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        if let marker = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("## My request")
        }) {
            lines = Array(lines[(marker + 1)...])
        } else if let first = lines.firstIndex(where: {
                      !$0.trimmingCharacters(in: .whitespaces).isEmpty
                  }),
                  let tag = openingTag(lines[first]),
                  let close = lines[first...].firstIndex(where: {
                      $0.trimmingCharacters(in: .whitespaces).hasPrefix("</\(tag)")
                  }) {
            lines = Array(lines[(close + 1)...])
        }
        return lines.joined(separator: "\n")
    }

    /// `realtime_delegation` for a line that is `<realtime_delegation>` or
    /// `<in-app-browser-context source="…">`; nil for anything else.
    private static func openingTag(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<"),
              let first = trimmed.dropFirst().first, first.isLetter
        else { return nil }
        let name = trimmed.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return name.isEmpty ? nil : String(name)
    }

    /// `&#x20;` and `&#32;` as the characters they stand for. Named entities
    /// are left alone: Codex was only ever seen passing the numeric ones.
    private static func decodingNumericReferences(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var out = ""
        var rest = Substring(text)
        while let start = rest.range(of: "&#") {
            out += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            let isHex = after.first == "x" || after.first == "X"
            let digits = (isHex ? after.dropFirst() : after).prefix { $0.isHexDigit }
            let end = digits.endIndex
            if !digits.isEmpty, end < rest.endIndex, rest[end] == ";",
               let value = UInt32(digits, radix: isHex ? 16 : 10),
               let scalar = Unicode.Scalar(value) {
                out.unicodeScalars.append(scalar)
                rest = rest[rest.index(after: end)...]
            } else {
                out += "&#"
                rest = after
            }
        }
        return out + rest
    }

    /// A preview is a whole message, and a notch row is one line. Long enough
    /// to recognise a request by; the full text is one click away in Codex.
    static let longestPreview = 48

    static func firstLine(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map({ $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") })
            .first(where: { !$0.isEmpty })
        else { return nil }
        guard line.count > longestPreview else { return line }
        return line.prefix(longestPreview - 1)
            .trimmingCharacters(in: .whitespaces) + "…"
    }

    /// An id fit to put in a query: Codex's are UUIDs. The parent id comes out
    /// of JSON another program writes, so it is checked rather than trusted.
    static func isPlainID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
            && id.allSatisfy(\.isASCII)
    }
}

extension CodexThread {
    /// A row of the query `CodexStore.recentThreads` runs, NULLs read as "".
    init(row: [String]) {
        func text(_ index: Int) -> String? {
            let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        self.init(
            id: row[0],
            rollout: text(1).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            name: text(2),
            preview: text(3),
            cwd: text(4),
            parentID: text(5),
            isHelper: row.count > 6 && row[6] == "1"
        )
    }
}

/// One monitor's memory of the two Codex stores, so a tick where neither
/// database moved costs a handful of `stat`s rather than a SQLite open and
/// scan — `state_5.sqlite` alone runs to hundreds of megabytes, and the
/// monitor asks every two seconds.
///
/// Codex's writes land in the `-wal` file before the database proper — the
/// main file's mtime does not move until a checkpoint — so a database counts
/// as changed when either file's stamp does.
final class CodexStoreCache {
    private struct Stamp: Equatable {
        let modified: Date?
        let size: UInt64
    }

    private var rolloutStamp: Stamp?
    private var rollout: URL?
    private var desktopStamp: Stamp?
    private var desktop: (title: String, updatedAt: Date, threadID: String)?
    private var threadsStamp: Stamp?
    private var threads: [CodexThread] = []
    /// Each rollout's last answer from `CodexRolloutActivity.state`, by path,
    /// with the stamp it was read at.
    private var rolloutStates: [String: (stamp: Stamp, state: CodexRolloutActivity.State?)] = [:]

    /// `CodexStore.newestRollout`, or the last answer when the store has not
    /// changed. A cached path whose file has since gone away is asked for
    /// again — the next row down may still exist.
    func newestRollout(in store: URL) -> URL? {
        let stamp = Self.stamp(of: store)
        if stamp == rolloutStamp, let rollout,
           FileManager.default.fileExists(atPath: rollout.path) {
            return rollout
        }
        let found = CodexStore.newestRollout(in: store)
        rolloutStamp = stamp
        rollout = found
        return found
    }

    /// `CodexStore.newestDesktopThread`, or the last answer when the
    /// catalogue has not changed.
    func newestDesktopThread(in store: URL) -> (title: String, updatedAt: Date, threadID: String)? {
        let stamp = Self.stamp(of: store)
        if stamp == desktopStamp { return desktop }
        let found = CodexStore.newestDesktopThread(in: store)
        desktopStamp = stamp
        desktop = found
        return found
    }

    /// `CodexStore.recentThreads`, or the last answer while the store has not
    /// changed. Which threads exist changes rarely; whether one is *working*
    /// is decided from its rollout's own stamp on every tick, so holding the
    /// list costs no liveness.
    func recentThreads(in store: URL) -> [CodexThread] {
        let stamp = Self.stamp(of: store)
        if stamp == threadsStamp { return threads }
        threads = CodexStore.recentThreads(in: store)
        threadsStamp = stamp
        return threads
    }

    /// `CodexRolloutActivity.state`, parsed again only when the file has
    /// changed since the last parse.
    ///
    /// That parse walks up to a megabyte backwards and runs on the main actor.
    /// It used to happen for one rollout per tick; with a row per conversation
    /// it happens for every live one, every two seconds — measured at up to
    /// ~12 ms each on this machine — though a rollout that has not moved since
    /// the last tick cannot have a different answer in it.
    ///
    /// Entries for rollouts no longer asked about are dropped, so a long-lived
    /// app does not hold one per conversation it has ever seen.
    func rolloutState(of url: URL, keeping live: Set<String>) -> CodexRolloutActivity.State? {
        let stamp = Self.stamp(ofFile: url)
        if let held = rolloutStates[url.path], held.stamp == stamp {
            return held.state
        }
        let state = CodexRolloutActivity.state(from: url)
        rolloutStates = rolloutStates.filter { live.contains($0.key) }
        rolloutStates[url.path] = (stamp, state)
        return state
    }

    /// `(mtime, size)` of the database merged with its `-wal`, either of
    /// which moves first. A missing file contributes nothing — an absent
    /// store is also an answer worth remembering rather than re-paying for.
    private static func stamp(of url: URL) -> Stamp {
        func pair(_ url: URL) -> (Date?, UInt64) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.modificationDate] as? Date,
                    (attributes?[.size] as? NSNumber)?.uint64Value ?? 0)
        }
        let db = pair(url)
        let wal = pair(URL(fileURLWithPath: url.path + "-wal"))
        return Stamp(modified: [db.0, wal.0].compactMap { $0 }.max(),
                     size: db.1 + wal.1)
    }

    /// `(mtime, size)` of a plain file — a rollout, which has no `-wal`.
    private static func stamp(ofFile url: URL) -> Stamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Stamp(modified: attributes?[.modificationDate] as? Date,
                     size: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0)
    }
}
