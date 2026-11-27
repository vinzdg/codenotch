import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// What the pill by the Dock shows and sends: the Claude Code sessions running
/// in a terminal, the one it is talking to, and the line being typed.
@MainActor
final class DockChatModel: ObservableObject {
    struct Target: Identifiable, Equatable {
        let id: String
        /// The session's own name — its title, or its folder.
        let name: String
        let state: AgentSession.State
        let since: Date
        let pid: pid_t
        /// The app it runs in: "Terminal", "iTerm2", "Code".
        let app: String
        /// The Claude account it runs under — whose ring the pill shows.
        let providerID: String
        /// The repository it is working in, and the branch there.
        let repository: SessionPlace.Repository?
        /// The process and its parents — how an editor finds its terminal.
        let ancestry: [pid_t]
        let tty: String?
        /// Where its account keeps session records and transcripts.
        let sessionsDirectory: URL
        let projectsDirectory: URL
    }

    /// What the session being talked to is doing this moment, from its
    /// transcript. Nil when it is not working.
    @Published private(set) var live: ClaudeLiveActivity?
    private var liveTimer: Timer?

    /// Read once a second while the session works: a stat, and the end of
    /// its transcript only when that has grown.
    /// While the session works, a few times a second: its own status file —
    /// a few hundred bytes — and the end of its transcript, read only when
    /// that has grown. The monitor behind the notch sees a session file
    /// appear or go at once, but a change inside one only on its two-second
    /// sweep; stopped with Escape in the terminal, the pill went on saying
    /// "working" for up to that long.
    private func readLive() {
        guard let target = selected, target.state == .busy || target.state == .waiting else {
            if live != nil { live = nil }
            if question != nil { question = nil }
            return
        }
        let id = target.id
        Task {
            let found = await Task.detached(priority: .utility) {
                Self.liveActivity(pid: target.pid, sessions: target.sessionsDirectory,
                                  projects: target.projectsDirectory)
            }.value
            guard self.selected?.id == id else { return }
            let asking = found.status == .waiting ? found.question : nil
            if asking != self.question, asking?.id != self.answeredQuestion {
                self.question = asking
            } else if asking == nil, self.question != nil {
                self.question = nil
            }
            if found.status == .waiting { return }
            // Its own word that it has stopped, ahead of the sweep — if it
            // was written after whatever the pill last did: just after a
            // send the file can still say "idle" for a moment.
            let sinceAction = self.assumed[id]?.since ?? .distantPast
            if let status = found.status, status != .busy,
               (found.updated ?? .distantPast) > sinceAction {
                self.reported(status, for: id)
                if self.live != nil { self.live = nil }
                return
            }
            // Just after a send the transcript still describes the turn
            // before it: not shown, so the line starts from this turn at 0s.
            var activity = found.activity
            if let sent = self.assumed[id]?.since,
               (activity?.startedAt ?? .distantPast) < sent.addingTimeInterval(-1) {
                activity = nil
            }
            if activity != self.live { self.live = activity }
        }
    }

    /// The session has said, in its own file, that it is no longer working.
    private func reported(_ state: AgentSession.State, for id: String) {
        assumed[id] = (state, Date())
        rebuild()
    }

    nonisolated private static func liveActivity(pid: pid_t, sessions: URL, projects: URL)
        -> (status: AgentSession.State?, updated: Date?, activity: ClaudeLiveActivity?, question: ClaudePendingQuestion?) {
        let record = sessions.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: record),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil, nil, nil) }
        let updated = ((json["statusUpdatedAt"] ?? json["updatedAt"]) as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let status: AgentSession.State?
        switch json["status"] as? String {
        case "busy": status = .busy
        case "idle", "shell": status = .idle
        case "waiting": status = .waiting
        default: status = nil
        }
        guard status == .busy || status == .waiting || status == nil,
              let sessionID = json["sessionId"] as? String,
              let cwd = json["cwd"] as? String,
              let url = ClaudeTranscript.transcript(forSessionID: sessionID, cwd: cwd,
                                                    in: projects, scanning: true)
        else { return (status, updated, nil, nil) }
        if status == .waiting {
            let question = ClaudeTranscript.tail(of: url, bytes: 256 * 1024).flatMap(ClaudePendingQuestion.read(tail:))
            return (status, updated, nil, question)
        }
        return (status, updated, transcriptActivity(url), nil)
    }

    /// The transcript's reading, kept until the file changes.
    nonisolated(unsafe) private static var lastRead: (path: String, size: UInt64, date: Date, activity: ClaudeLiveActivity?)?
    private static let lastReadLock = NSLock()

    nonisolated private static func transcriptActivity(_ url: URL) -> ClaudeLiveActivity? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let date = attributes?[.modificationDate] as? Date ?? .distantPast
        lastReadLock.lock()
        if let last = lastRead, last.path == url.path, last.size == size, last.date == date {
            lastReadLock.unlock()
            return last.activity
        }
        lastReadLock.unlock()
        let activity = ClaudeTranscript.tail(of: url, bytes: 512 * 1024).flatMap(ClaudeLiveActivity.read(tail:))
        lastReadLock.lock()
        lastRead = (url.path, size, date, activity)
        lastReadLock.unlock()
        return activity
    }

    // MARK: - The conversation

    /// The session's conversation, shown in the pill grown upward while
    /// `historyOpen`, and read again as it goes on.
    @Published var historyOpen = false {
        didSet {
            guard historyOpen else { return }
            // One thing above the pill at a time: the newest one asked for.
            if listOpen { listOpen = false }
            readHistory()
        }
    }
    @Published private(set) var history: [ClaudeConversation.Message] = []

    /// The latest exchange: your last message and what Claude has written
    /// since — the conversation as it is now, not all of it.
    var latestExchange: [ClaudeConversation.Message] {
        guard let lastYou = history.lastIndex(where: { $0.role == .you }) else { return Array(history.suffix(3)) }
        return Array(history[lastYou...])
    }
    /// What has been read of the transcript: where it is, how far, and what
    /// was found. Growth is read from where it left off.
    private var historyRead: (path: String, offset: UInt64, messages: [ClaudeConversation.Message])?
    private var readingHistory = false

    func readHistory() {
        guard historyOpen, !readingHistory, let target = selected else { return }
        let id = target.id
        let previous = historyRead
        readingHistory = true
        Task {
            let found = await Task.detached(priority: .utility) {
                Self.conversation(of: target, after: previous)
            }.value
            readingHistory = false
            guard self.selected?.id == id, let found else { return }
            historyRead = found
            if found.messages != history { history = found.messages }
        }
    }

    /// The conversation's last messages. The first time, read back from the
    /// end until there are enough — screenshots make some stretches of a
    /// transcript megabytes long — and after that only what was added.
    nonisolated private static func conversation(
        of target: Target, after previous: (path: String, offset: UInt64, messages: [ClaudeConversation.Message])?
    ) -> (path: String, offset: UInt64, messages: [ClaudeConversation.Message])? {
        let record = target.sessionsDirectory.appendingPathComponent("\(target.pid).json")
        guard let data = try? Data(contentsOf: record),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = json["sessionId"] as? String, let cwd = json["cwd"] as? String,
              let url = ClaudeTranscript.transcript(forSessionID: sessionID, cwd: cwd,
                                                    in: target.projectsDirectory, scanning: true),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let limit = 40
        if let previous, previous.path == url.path, previous.offset <= size {
            guard size > previous.offset else { return previous }
            try? handle.seek(toOffset: previous.offset)
            let added = (try? handle.readToEnd()) ?? Data()
            // Only whole lines; a line still being written waits for the next read.
            guard let lastNewline = added.lastIndex(of: UInt8(ascii: "\n")) else { return previous }
            let complete = added[added.startIndex...lastNewline]
            let more = ClaudeConversation.read(tail: Data(complete), limit: limit)
            return (url.path, previous.offset + UInt64(complete.count),
                    Array((previous.messages + more).suffix(limit)))
        }
        var span: UInt64 = 1 << 20
        while true {
            let start = size > span ? size - span : 0
            try? handle.seek(toOffset: start)
            let chunk = (try? handle.readToEnd()) ?? Data()
            let messages = ClaudeConversation.read(tail: chunk, limit: limit)
            if messages.count >= limit || start == 0 || span >= 64 << 20 {
                let end = chunk.lastIndex(of: UInt8(ascii: "\n")).map { start + UInt64($0 - chunk.startIndex) + 1 } ?? size
                return (url.path, end, messages)
            }
            span *= 4
        }
    }

    // MARK: - Questions

    /// What the session is asking, while it waits on you — shown in the pill
    /// grown upward, like the slash list.
    @Published private(set) var question: ClaudePendingQuestion? {
        didSet { if question?.id != oldValue?.id { questionIndex = 0 } }
    }
    /// The highlighted answer — what Return picks.
    @Published var questionIndex = 0

    func moveQuestion(_ step: Int) {
        guard let count = question?.choices.count, count > 0 else { return }
        questionIndex = (questionIndex + step + count) % count
    }

    /// Return with nothing typed: the highlighted answer. A number key: that
    /// one, as in the terminal.
    func answerHighlighted() {
        guard let choices = question?.choices, choices.indices.contains(questionIndex) else { return }
        answer(choices[questionIndex])
    }

    func answer(key: String) -> Bool {
        guard let choice = question?.choices.first(where: { $0.key == key }) else { return false }
        answer(choice)
        return true
    }
    /// Answered from the pill: not shown again while the terminal catches up.
    private var answeredQuestion: String?

    func answer(_ choice: ClaudePendingQuestion.Choice) {
        guard let target = selected, let asked = question else { return }
        answeredQuestion = asked.id
        question = nil
        assume(.busy, for: target.id)
        let pid = target.pid
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                TerminalInput.press(choice.key, sessionPID: pid)
            }.value
            if outcome != .sent {
                answeredQuestion = nil
                unassume(target.id)
                show(L10n.t("Couldn't answer. Pick it in its terminal"))
            }
        }
    }

    /// Which terminal each session is in, by target id: "Terminal 2" in an
    /// editor window, its tty elsewhere. Filled in after the list, because
    /// an editor has to be asked.
    @Published private(set) var terminalLabels: [String: String] = [:]

    /// "Terminal 2 · Code" — where in which app.
    func place(of target: Target) -> String {
        let terminal = terminalLabels[target.id] ?? target.tty ?? L10n.t("Terminal")
        return "\(terminal) · \(target.app)"
    }

    /// The terminal's own name — "Terminal 2" — when its editor has said;
    /// nil rather than a device name like ttys001 nobody would recognise.
    func terminalName(of target: Target) -> String? {
        terminalLabels[target.id]
    }

    /// Which of its repository's sessions this is — 1, 2, … in the order
    /// they started — when the repository has more than one; nil when it is
    /// the only one, and the repository's name already says which.
    func number(of target: Target) -> Int? {
        let key = target.repository?.name
        let siblings = targets.filter { $0.repository?.name == key }
        guard siblings.count > 1 else { return nil }
        return siblings.firstIndex(of: target).map { $0 + 1 }
    }

    /// The sessions grouped by repository, for the menu.
    var groups: [(title: String, targets: [Target])] {
        var order: [String] = []
        var byRepo: [String: [Target]] = [:]
        for target in targets {
            let key = target.repository.map { repo in
                repo.branch.map { "\(repo.name) · \($0)" } ?? repo.name
            } ?? L10n.t("Other")
            if byRepo[key] == nil { order.append(key) }
            byRepo[key, default: []].append(target)
        }
        return order.map { ($0, byRepo[$0] ?? []) }
    }

    @Published private(set) var targets: [Target] = []
    /// The session being talked to. Picked by the person, it leaves a short
    /// hint of where they have landed — see `switchHint`.
    @Published private(set) var selectedID: String?

    /// The person picking a session — from the chip or the list. Only this
    /// leaves the hint: the pill choosing one by itself, at launch or as
    /// sessions come and go, says nothing.
    func pick(_ id: String) {
        blur()
        listOpen = false
        guard id != selectedID else { return }
        selectedID = id
        historyRead = nil
        history = []
        if let target = selected { hint(target) }
    }
    /// "→ Price change to $685 · Terminal 2 · Code" for a moment after
    /// switching, in place of the prompt: which session, and where it is.
    @Published private(set) var switchHint: String?
    private var hintTask: Task<Void, Never>?

    private func hint(_ target: Target) {
        // The terminal's name, and nothing else; the session's title until
        // its editor has said which terminal it is.
        // The session's title, and its terminal once its editor has said.
        switchHint = terminalName(of: target).map { "\(target.name) · \($0)" } ?? target.name
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.switchHint = nil
        }
    }
    /// The text as shown, an image counting as one character — empty or not
    /// is what the pill reads it for.
    @Published private(set) var draft = ""
    /// The text as it will be sent, each image written as its path.
    @Published private(set) var outgoing = ""
    @Published private(set) var imageCount = 0
    /// The text with its image frames, kept here rather than in the view:
    /// SwiftUI can rebuild the text view at any time, and a rebuilt one
    /// started empty — what had been typed was simply gone.
    var storedText = NSAttributedString()
    /// Whether the text has the keyboard.
    @Published var editing = false
    /// Images waiting to go into the text at the cursor.
    @Published var pendingInserts: [Attachment] = []
    /// Bumped to empty the text, and to give it the keyboard.
    @Published private(set) var clearToken = 0
    @Published private(set) var focusToken = 0

    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let thumbnail: NSImage
    }

    /// A short line after sending — "Sent", "Copied — paste with ⌘V".
    @Published private(set) var notice: String?
    @Published private(set) var isSending = false
    @Published private(set) var isStopping = false
    /// How the pill is scaled to sit level with the Dock's icons.
    @Published var scale: CGFloat = 1

    var selected: Target? {
        targets.first { $0.id == selectedID } ?? targets.first
    }

    private var sessionsByMonitor: [Int: [AgentSession]] = [:]
    private var providerByMonitor: [Int: String] = [:]
    private var profileByMonitor: [Int: ClaudeProfile] = [:]
    private var subscriptions: [AnyCancellable] = []
    private var noticeTask: Task<Void, Never>?

    /// Follows these monitors' sessions, replacing whatever was followed.
    /// Each comes with the provider id of the Claude account it watches.
    func watch(_ monitors: [(profile: ClaudeProfile, monitor: ClaudeSessionMonitor)]) {
        subscriptions = []
        sessionsByMonitor = [:]
        providerByMonitor = [:]
        profileByMonitor = [:]
        if liveTimer == nil {
            liveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.readLive()
                    self?.readHistory()
                }
            }
        }
        for (index, entry) in monitors.enumerated() {
            providerByMonitor[index] = entry.profile.id
            profileByMonitor[index] = entry.profile
            entry.monitor.sessionsPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] sessions in
                    guard let self else { return }
                    self.sessionsByMonitor[index] = sessions
                    self.rebuild()
                }
                .store(in: &subscriptions)
        }
        rebuild()
    }

    private func rebuild() {
        // Only sessions with a terminal to type into: a session hosted by the
        // Claude desktop app has no tty, and nothing here can reach it.
        let found: [Target] = sessionsByMonitor
            .flatMap { index, sessions in sessions.map { (index, $0) } }
            .sorted { $0.1.since < $1.1.since }
            .compactMap { index, session in
                guard let pid = session.processID,
                      SessionFocus.tty(of: pid) != nil,
                      let app = SessionFocus.owningApp(of: pid) else { return nil }
                let (state, since) = self.assumedState(for: session)
                return Target(id: session.id, name: session.name, state: state,
                              since: since, pid: pid,
                              app: app.localizedName ?? "Terminal",
                              providerID: self.providerByMonitor[index] ?? ClaudeProfile.defaultID,
                              repository: SessionPlace.repository(at: SessionFocus.currentDirectory(of: pid)),
                              ancestry: SessionFocus.ancestry(of: pid),
                              tty: SessionFocus.tty(of: pid),
                              sessionsDirectory: self.profileByMonitor[index]?.sessionsDirectory
                                  ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions"),
                              projectsDirectory: self.profileByMonitor[index]?.projectsDirectory
                                  ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"))
            }
        targets = found
        refreshTerminalLabels()
        if selectedID == nil || !found.contains(where: { $0.id == selectedID }) {
            // The one most likely being talked to: working or waiting, latest first.
            selectedID = (found.filter { $0.state == .busy || $0.state == .waiting }
                .max { $0.since < $1.since } ?? found.last)?.id
        }
    }

    // MARK: - What the pill just did

    /// What the pill has just done to a session — sent it a message, or
    /// stopped it — shown at once. Claude Code takes a moment to write
    /// either down, and until it had, the pill went on saying "Ready" after
    /// a send and "working" after a stop. Dropped as soon as the session's
    /// own report agrees, or after a few seconds if it never does.
    private var assumed: [String: (state: AgentSession.State, since: Date)] = [:]
    private static let assumptionLasts: TimeInterval = 6

    private func assume(_ state: AgentSession.State, for id: String) {
        assumed[id] = (state, Date())
        rebuild()
    }

    /// A message that did not go: back in the pill, and the session as it was.
    private func restore(_ text: NSAttributedString, for id: String) {
        unassume(id)
        storedText = text
        replacementAttributed = text
        replaceToken += 1
    }

    private func unassume(_ id: String) {
        assumed[id] = nil
        rebuild()
    }

    private func assumedState(for session: AgentSession) -> (AgentSession.State, Date) {
        guard let assumption = assumed[session.id] else { return (session.state, session.since) }
        // Anything the session has said since — the same state, or another:
        // sent, then stopped with Escape in the terminal before the pill's
        // guess had been confirmed, it went on showing "working" until the
        // guess ran out. Its own word, once newer than the guess, wins.
        let caughtUp = session.state == assumption.state
            || session.since > assumption.since.addingTimeInterval(0.3)
        if caughtUp || Date().timeIntervalSince(assumption.since) > Self.assumptionLasts {
            assumed[session.id] = nil
            return (session.state, session.since)
        }
        return (assumption.state, assumption.since)
    }

    /// Asks the editors which of their terminals each session is in.
    private func refreshTerminalLabels() {
        let targets = self.targets
        Task {
            let labels = await Task.detached(priority: .utility) { () -> [String: String] in
                let terminals = EditorBridge.listTerminals()
                var labels: [String: String] = [:]
                for target in targets {
                    if let terminal = terminals.first(where: { target.ancestry.contains($0.pid) }) {
                        labels[target.id] = terminal.label
                    }
                }
                return labels
            }.value
            if labels != terminalLabels { terminalLabels = labels }
        }
    }

    /// Sessions handed in directly, for tests and previews.
    func setTargetsForTesting(_ targets: [Target], selected: String?) {
        self.targets = targets
        selectedID = selected
    }

    /// Codedock switched off: nothing more is watched or read.
    func shutDown() {
        liveTimer?.invalidate()
        liveTimer = nil
        subscriptions = []
    }

    /// "Working · Terminal 2" — what it is doing, and which terminal.
    func subtitle(for target: Target) -> String {
        let state: String
        switch target.state {
        case .busy: state = L10n.t("Working")
        case .waiting: state = L10n.t("Waiting for you")
        case .success: state = L10n.t("Done")
        case .idle: state = L10n.t("Ready")
        }
        guard let terminal = terminalName(of: target) else { return state }
        return "\(state) · \(terminal)"
    }

    /// Whether the list of sessions is open above the pill.
    @Published var listOpen = false {
        didSet { if listOpen, historyOpen { historyOpen = false } }
    }

    /// The next session along, for the terminal chip.
    func cycleTarget() {
        guard targets.count > 1, let current = selected,
              let index = targets.firstIndex(of: current) else { return }
        pick(targets[(index + 1) % targets.count].id)
    }

    // MARK: - Images

    /// Image files, dropped or pasted. Anything that is not an image is left
    /// out rather than sent as a path Claude cannot look at.
    func attach(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            guard type?.conforms(to: .image) == true,
                  let image = NSImage(contentsOf: url) else { continue }
            pendingInserts.append(Attachment(url: url, thumbnail: image))
        }
    }

    /// An image with no file — a screenshot copied to the clipboard — kept
    /// as a PNG so the session has a path to open.
    func attach(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codenotch/DockChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("image-\(UUID().uuidString.prefix(8)).png")
        guard (try? png.write(to: url)) != nil else { return }
        pendingInserts.append(Attachment(url: url, thumbnail: image))
    }

    /// From the text view, on every change.
    func composed(display: String, outgoing: String, images: Int) {
        if draft != display { draft = display }
        if self.outgoing != outgoing { self.outgoing = outgoing }
        if imageCount != images { imageCount = images }
        updateSlash(display)
    }

    // MARK: - Slash commands

    /// The commands that fit what is typed, while it is a slash and a name
    /// with nothing after it. Empty otherwise — and the list is closed.
    @Published private(set) var slashMatches: [SlashCommand] = []
    @Published var slashIndex = 0
    private var slashQuery: String?
    /// Escape closes the list until the slash is typed again.
    private var slashDismissed = false
    private var commands: (pid: pid_t, list: [SlashCommand])?
    /// Bumped to set the text — a chosen command written out in full.
    @Published private(set) var replaceToken = 0
    private(set) var replacement = ""
    /// Set instead of `replacement` to put back text with its image frames.
    private(set) var replacementAttributed: NSAttributedString?

    /// The command whose choices the list is showing — /model's models.
    private var choosing: String?

    private func updateSlash(_ text: String) {
        // Choosing among a command's own options: the list narrows on what
        // is typed after the command, and goes when that is cleared.
        if let choosing {
            let prefix = "/\(choosing) "
            guard text.hasPrefix(prefix), let options = commands?.list.first(where: { $0.name == choosing })?.choices
                ?? SlashCommand.builtIn.first(where: { $0.name == choosing })?.choices else {
                self.choosing = nil
                closeSlash()
                return updateSlash(text)
            }
            let typed = text.dropFirst(prefix.count).lowercased()
            let matches = options.filter { typed.isEmpty || $0.name.dropFirst(prefix.count - 1).lowercased().hasPrefix(typed) }
            slashIndex = min(slashIndex, max(0, matches.count - 1))
            if matches != slashMatches { slashMatches = matches }
            return
        }
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace), imageCount == 0,
              let target = selected else {
            if !text.hasPrefix("/") { slashDismissed = false }
            closeSlash()
            return
        }
        guard !slashDismissed else { return }
        if commands?.pid != target.pid {
            commands = (target.pid, SlashCommand.available(cwd: SessionFocus.currentDirectory(of: target.pid)))
        }
        let query = String(text.dropFirst())
        let matches = SlashCommand.matching(query, in: commands?.list ?? [])
        if query != slashQuery { slashIndex = 0 }
        slashQuery = query
        slashIndex = min(slashIndex, max(0, matches.count - 1))
        if matches != slashMatches { slashMatches = matches }
    }

    private func closeSlash() {
        slashQuery = nil
        if !slashMatches.isEmpty { slashMatches = [] }
    }

    var slashOpen: Bool { !slashMatches.isEmpty }

    /// How tall the conversation's content is, as last measured by the view.
    @Published var historyContentHeight: CGFloat = 0

    /// The room the conversation takes: as tall as what has been said, so a
    /// short exchange is not left under a wide empty band, and never more than
    /// the room above the pill, where it scrolls instead.
    var historyExtraHeight: CGFloat {
        Self.historyExtraHeight(content: historyContentHeight)
    }

    static func historyExtraHeight(content: CGFloat) -> CGFloat {
        let most = DockChatController.roomAbove - 6
        // The view is 6 shorter than the room it is given.
        return min(most, max(DockHistory.leastHeight, content) + 6)
    }

    /// How much taller the pill is while it lists slash commands.
    var slashExtraHeight: CGFloat {
        if !slashMatches.isEmpty { return DockSlashRows.height(rows: slashMatches.count) }
        if let question { return DockQuestionRows.height(for: question) }
        if listOpen { return DockSessionRows.height(groups: groups) }
        if historyOpen { return historyExtraHeight }
        return 0
    }

    func moveSlash(_ step: Int) {
        guard !slashMatches.isEmpty else { return }
        slashIndex = (slashIndex + step + slashMatches.count) % slashMatches.count
    }

    /// The highlighted command, written out — and with `send`, sent, as
    /// Return does in Claude Code's own list.
    func acceptSlash(send: Bool, at index: Int? = nil) {
        if let index { slashIndex = index }
        guard slashMatches.indices.contains(slashIndex) else { return }
        let command = slashMatches[slashIndex]
        // A command with its own choices opens them, in the pill, in place of
        // the picker its terminal would show.
        if let choices = command.choices {
            replacement = "/\(command.name) "
            replacementAttributed = nil
            replaceToken += 1
            choosing = command.name
            slashIndex = 0
            slashMatches = choices
            return
        }
        let send = send || command.runsAsIs
        choosing = nil
        if send, command.opensInTerminal, let pid = selected?.pid {
            // Its picker is on the terminal's screen: bring that forward.
            Task { await SessionFocus.focus(pid: pid) }
        }
        closeSlash()
        slashDismissed = true
        if send {
            outgoing = "/\(command.name)"
            self.send()
        } else {
            replacement = "/\(command.name) "
            replacementAttributed = nil
            replaceToken += 1
        }
    }

    func dismissSlash() {
        choosing = nil
        slashDismissed = true
        closeSlash()
    }

    func focus() { focusToken += 1 }

    /// The text gives up the keyboard — a click on one of the pill's own
    /// controls is not typing, and the cursor should not go on blinking.
    @Published private(set) var blurToken = 0
    func blur() { blurToken += 1 }

    /// ⌘V with an image on the clipboard — a copied file or a screenshot —
    /// attaches it. Plain text is left to the field. True when it was an image.
    func pasteImage() -> Bool {
        let board = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            attach(urls)
            return true
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        if board.availableType(from: imageTypes) != nil, let image = NSImage(pasteboard: board) {
            attach(image)
            return true
        }
        return false
    }

    /// A path the way a terminal writes a dropped file: spaces and the
    /// shell's own characters escaped, so it reads as one path.
    static func escaped(_ path: String) -> String {
        var out = ""
        for character in path {
            if " ()'\"&;$`!*?[]{}<>|#~".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    func send() {
        let text = outgoing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let target = selected, !isSending else { return }
        Log.usage.info("dock chat send to \(target.app, privacy: .public)")
        // The pill answers Return at once — text gone, the session shown
        // working — rather than once the terminal has taken the line. If it
        // could not be delivered, the text comes back and the guess goes.
        let kept = storedText
        isSending = true
        clearToken += 1
        assume(.busy, for: target.id)
        let pid = target.pid
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                TerminalInput.send(text, toSessionPID: pid)
            }.value
            isSending = false
            switch outcome {
            case .sent:
                break
            case .onClipboard:
                unassume(target.id)
                show(L10n.t("Copied. Click the terminal, then ⌘V"))
            case .editorNeedsReload:
                restore(kept, for: target.id)
                show(L10n.t("Set up. Reload \(target.app) once, then send again"))
            case .failed:
                restore(kept, for: target.id)
                show(L10n.t("Couldn't reach \(target.name)"))
            }
        }
    }

    /// Stops the session mid-turn, as Escape in its terminal does. A message
    /// sent while it was busy was queued behind the turn, and runs after it:
    /// stopping the turn does not take that back, so the notice says so.
    func stop() {
        guard let target = selected, !isStopping else { return }
        isStopping = true
        // Shown stopped at once, whatever the terminal takes to answer; put
        // back if it could not be stopped.
        notice = L10n.t("Stopping…")
        noticeTask?.cancel()
        assume(.idle, for: target.id)
        live = nil
        let pid = target.pid
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                TerminalInput.interrupt(sessionPID: pid)
            }.value
            isStopping = false
            switch outcome {
            case .sent:
                show(L10n.t("Stopped \(target.name)"))
            case .editorNeedsReload:
                unassume(target.id)
                show(L10n.t("Reload \(target.app) once to stop from here. Press Esc in its terminal"))
            default:
                unassume(target.id)
                show(L10n.t("Couldn't stop \(target.name). Press Esc in its terminal"))
            }
        }
    }

    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
