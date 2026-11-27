import SwiftUI
import UniformTypeIdentifiers

/// The pill by the Dock: Claude's mark in a ring that turns while it works,
/// what it is doing, which terminal it is in, and a line to type into it.
struct DockChatView: View {
    @ObservedObject var model: DockChatModel
    /// Where the readings come from: the same model the notch's menu reads.
    @ObservedObject var usage: NotchViewModel
    @State private var dropTargeted = false
    /// The look chosen in Settings, and the ink that reads on it.
    @AppStorage(Preferences.codedockLookKey) private var look = "dark"
    private var theme: DockTheme { DockTheme(rawValue: look) ?? .dark }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drawn this size and scaled to the Dock's height. Short for what it
    /// holds, so the ring and both lines fill the height with an even margin;
    /// at 84 the content sat in the middle of a band twice its height.
    static let size = CGSize(width: 350, height: 62)
    /// Round at the badge's end, where the ring fills the height, but only
    /// softly rounded at the other: a full half-circle there left a wide
    /// empty band beside the session chip.
    static let shape = UnevenRoundedRectangle(topLeadingRadius: 31, bottomLeadingRadius: 31,
                                              bottomTrailingRadius: 20, topTrailingRadius: 20,
                                              style: .continuous)

    /// Typing, with something typed: the status line steps aside so what is
    /// being written gets two lines beside the ring, which stays.
    /// Only for something worth showing: a stray space or blank line kept
    /// the pill in its typing view, an empty bar with a cursor and nothing
    /// else, ring and status gone.
    private var composing: Bool {
        model.imageCount > 0 || (model.editing && hasWords)
    }

    private var hasWords: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Typing a slash grows the pill upward and lists the commands inside
    /// it, above the text, rather than in a card of its own; its bottom
    /// stays level with the Dock.
    /// Laid out once at its full height — the pill's row plus the room above
    /// it — and never resized: only the pill's shape grows into the room,
    /// and the row at the bottom cannot move however the list comes and goes.
    var body: some View {
        let extra = model.slashExtraHeight
        let room = DockChatController.roomAbove
        let spring: Animation? = reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)
        ZStack(alignment: .bottomLeading) {
            // The pill's body, as tall as what it holds, from the bottom up.
            pillBackground
                .overlay {
                    shape.strokeBorder(Color.white.opacity(dropTargeted ? 0.55 : 0), lineWidth: 2)
                }
                .frame(width: Self.size.width, height: Self.size.height + extra)
                .contentShape(shape)
                .onTapGesture { model.focus() }
                // Dropped images become frames, never paths in the text.
                .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                    receive(providers)
                    return true
                }
                .animation(spring, value: extra)

            // What grows into it: the slash commands, or a question.
            Group {
                if model.slashOpen {
                    DockSlashRows(model: model)
                } else if model.question == nil, model.listOpen {
                    DockSessionRows(model: model)
                        .frame(height: model.slashExtraHeight - DockSlashRows.inset)
                } else if model.question == nil, model.historyOpen {
                    DockHistory(messages: model.latestExchange, theme: theme,
                                working: model.selected?.state == .busy
                                    ? (model.live?.doing ?? "\(ClaudeSpinner.word(session: model.selected?.id ?? "", since: model.selected?.since ?? Date()))…")
                                    : nil,
                                contentHeight: { height in
                                    // Skip sub-point changes, so measuring cannot loop.
                                    if abs(model.historyContentHeight - height) > 0.5 {
                                        model.historyContentHeight = height
                                    }
                                })
                        .frame(height: model.slashExtraHeight - 6)
                } else if let question = model.question {
                    DockQuestionRows(question: question, highlighted: model.questionIndex,
                                     highlight: { model.questionIndex = $0 },
                                     answer: { model.answer($0) })
                }
            }
            .padding(.horizontal, 8)
            .frame(width: Self.size.width, alignment: .leading)
            .padding(.bottom, Self.size.height)
            .transition(.opacity.combined(with: .offset(y: 12)))
            .animation(spring, value: model.slashMatches)
            .animation(spring, value: model.question)
            .animation(spring, value: model.historyOpen)
            .animation(spring, value: model.listOpen)

            mainRow
                .frame(width: Self.size.width, height: Self.size.height)
                // On the row itself: on the shape under it, the row took the
                // clicks first and "Chat here…" could not be clicked into.
                .contentShape(Rectangle())
                .onTapGesture { model.focus() }
        }
        .frame(width: Self.size.width, height: Self.size.height + room, alignment: .bottomLeading)
        // Drawn at one size and scaled to the Dock's own height, from the
        // bottom, which is where the Dock is.
        .scaleEffect(model.scale, anchor: .bottomLeading)
        .frame(width: Self.size.width * model.scale, height: (Self.size.height + room) * model.scale,
               alignment: .bottomLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// Rounder at the ring's end while it is one row; grown with the slash
    /// list, a card's corner at the top.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: model.slashExtraHeight > 0 ? 20 : 31, bottomLeadingRadius: 31,
                               bottomTrailingRadius: 20, topTrailingRadius: 20, style: .continuous)
    }

    /// The pill's own row: the ring, what the session is doing, the text.
    private var mainRow: some View {
        HStack(spacing: 12) {
            // Always there, typing or not: the pill never goes blank, and
            // the ring says which session the words are going to.
            badge
            VStack(alignment: .leading, spacing: 4) {
                if !composing {
                    HStack(spacing: 8) {
                        ClaudeSpinnerGlyph(active: model.selected?.state == .busy || model.isSending)
                            .fixedSize()
                            .layoutPriority(3)
                        Group {
                            if let notice = model.notice {
                                Text(notice)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.ink.opacity(0.75))
                                    .truncationMode(.middle)
                                    .transition(.opacity)
                            } else if let hint = model.switchHint {
                                // Where you have just landed, for a moment, in
                                // place of what it is doing — working or not.
                                Text(hint)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.ink.opacity(0.9))
                                    .truncationMode(.tail)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity))
                            } else {
                                statusLine.transition(.opacity)
                            }
                        }
                        .lineLimit(1)
                        .layoutPriority(2)
                        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88),
                                   value: model.switchHint)
                        if let usageText, model.selected?.state != .busy {
                            Text(usageText)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(theme.ink.opacity(0.55))
                                .lineLimit(1)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                        Spacer(minLength: 4)
                        if let target = model.selected {
                            // Only while it works: Escape for its terminal.
                            if target.state == .busy {
                                Button(action: {}) { DockStopGlyph(busy: model.isStopping) }
                                    .buttonStyle(.plain)
                                    .highPriorityGesture(TapGesture().onEnded { model.blur(); model.stop() })
                                    .help(L10n.t("Stop (Esc)"))
                                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                            historyButton
                            chip(target)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let target = model.selected {
                    // Typing: where it is going, small and quiet, so the
                    // words still have their two lines.
                    destination(target)
                        .transition(.opacity)
                }
                field
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86), value: composing)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82), value: model.selectedID)
        .padding(.leading, 5)
        .padding(.trailing, 12)
    }

    // MARK: - Parts

    /// Opens the conversation above the pill, and closes it.
    private var historyButton: some View {
        Button(action: {}) {
            Image(systemName: model.historyOpen ? "text.bubble.fill" : "text.bubble")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.ink.opacity(model.historyOpen ? 0.95 : 0.7))
                .frame(width: 19, height: 19)
                .background(Circle().fill(theme.ink.opacity(model.historyOpen ? 0.2 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(TapGesture().onEnded { model.blur(); model.historyOpen.toggle() })
        .help(model.historyOpen ? L10n.t("Hide the conversation") : L10n.t("Show the conversation"))
    }

    /// "codenotch · Terminal 1" — the repository, and the terminal once its
    /// editor has said, or the session's title.
    private func destination(_ target: DockChatModel.Target) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 8, weight: .semibold))
            if let repo = target.repository?.name {
                Text(repo).fontWeight(.semibold)
                if let number = model.number(of: target) { Text("\(number)") }
                Text("·")
            }
            Text(model.terminalName(of: target) ?? target.name)
                .truncationMode(.tail)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(theme.ink.opacity(0.5))
        .lineLimit(1)
        .frame(height: 12)
    }

    private func receive(_ providers: [NSItemProvider]) {
        model.focus()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.attach([url]) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    DispatchQueue.main.async { model.attach(image) }
                }
            }
        }
    }

    /// The session's account's own ring, exactly as the notch draws it —
    /// usage, weekly ring, pace and the activity turn. Until a reading has
    /// arrived, a plain ring that turns while Claude works.
    private var badge: some View {
        ZStack {
            Circle().fill(Color.black)
            if let snapshot = usageSnapshot {
                ProviderCell(
                    snapshot: snapshot,
                    // The account's activity is any of its sessions working;
                    // the ring turns only for the session this pill is on,
                    // never on an idle one while another works elsewhere.
                    activity: ringActivity(for: snapshot),
                    isRefreshing: usage.isRefreshing(snapshot),
                    weeklyRing: usage.weeklyRing,
                    showsReading: false,
                    showsRemaining: usage.showsRemainingInNotch,
                    shutRingsWhenSpent: usage.shutRingsWhenSpent
                )
                .frame(width: NotchLayout.ringDiameter, height: NotchLayout.cellExtent)
                .scaleEffect(49 / NotchLayout.ringDiameter)
                .frame(width: 49, height: 49)
            } else {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 3.5)
                    .padding(7)
                Circle()
                    .trim(from: 0, to: isWorking ? 0.72 : (model.selected == nil ? 0 : 1))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(7)
                    .modifier(Spin(active: isWorking && !reduceMotion))
                // White on the ring's own black disc, whatever the pill's look.
                ProviderGlyphView(glyph: .claude, size: 22)
                    .foregroundStyle(.white)
            }
        }
        // Just round the ring, and the same margin on every side of it: a
        // wider black disc plus the pill's own padding left a band on the
        // left twice what was above and below.
        .frame(width: 52, height: 52)
        // Another session's ring comes in, rather than the old one's numbers
        // jumping in place.
        .id(model.selected?.id)
        .transition(.asymmetric(insertion: .scale(scale: 0.7).combined(with: .opacity),
                                removal: .opacity))
    }

    /// The ring turns while this session works — from the moment the pill
    /// sends it something, not from whenever the notch's own sweep catches up.
    private func ringActivity(for snapshot: ProviderSnapshot) -> ActivitySummary? {
        guard let target = model.selected, target.state == .busy else { return nil }
        if let notch = usage.activity(for: snapshot), notch.state == .working { return notch }
        return ActivitySummary(sessions: [AgentSession(id: target.id, name: target.name, detail: "",
                                                       state: .busy, waitingFor: nil, since: target.since,
                                                       processID: target.pid)])
    }

    private var usageSnapshot: ProviderSnapshot? {
        let id = model.selected?.providerID ?? ClaudeProfile.defaultID
        return usage.snapshots.first { $0.id == id }
            ?? usage.snapshots.first { $0.providerID == id }
    }

    /// "73% used" / "27% left", the way the notch says it.
    private var usageText: String? {
        guard let snapshot = usageSnapshot, snapshot.hasReading,
              let fraction = snapshot.ringFraction else { return nil }
        let used = Int((min(max(fraction, 0), 1) * 100).rounded())
        // The figure alone: the ring beside it already says used or left.
        return usage.showsRemainingInNotch ? "\(100 - used)%" : "\(used)%"
    }

    /// The session being talked to, as its repository and name; a menu of
    /// every session, grouped by repository, to pick another.
    /// Two controls side by side: the chip itself steps to the next session
    /// in one click, and the arrow beside it opens every session, grouped by
    /// repository, to jump to any of them.
    private func chip(_ target: DockChatModel.Target) -> some View {
        HStack(spacing: 3) {
            Button(action: {}) {
                HStack(spacing: 4) {
                    // The repository alone: with the session's title as well
                    // the chip took half the pill. The title is in the list
                    // and on hover.
                    Text(Self.shortened(target.repository?.name ?? target.name, limit: 14))
                    // Two sessions in one repository look alike by name;
                    // the number is the same one the list shows.
                    if let number = model.number(of: target) {
                        Text("\(number)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(theme == .white ? Color.white : Color.black.opacity(0.85))
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Circle().fill(theme.ink.opacity(0.8)))
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 7)
                .padding(.trailing, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(DockChipStyle(edge: .leading))
            // Taken before the pill's own tap, which would otherwise also
            // give the text the keyboard and fold the chip away mid-click.
            .highPriorityGesture(TapGesture().onEnded { model.blur(); model.cycleTarget() })
            .help(model.targets.count > 1
                  ? L10n.t("\(target.name). Click for the next session")
                  : target.name)

            // Codedock's own list rather than a system menu, which cannot
            // be animated: it springs up above the pill — see DockSessionList.
            Button(action: {}) {
                DockChipArrow(open: model.listOpen)
            }
            .buttonStyle(.plain)
            .highPriorityGesture(TapGesture().onEnded { model.blur(); model.listOpen.toggle() })
            .fixedSize()
            .help(L10n.t("All sessions"))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(theme.ink.opacity(0.8))
    }




    /// A long session title cut down to fit the chip, at a word where it can.
    static func shortened(_ name: String, limit: Int = 22) -> String {
        guard name.count > limit else { return name }
        let cut = String(name.prefix(limit))
        let word = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        return (word.count >= limit / 2 ? word : cut) + "…"
    }

    private var field: some View {
        ZStack(alignment: .leading) {
            // The text box is always here — a notice goes in the status line
            // above, so typing can start the moment after a send or a stop.
            do {
                // Text and images inline, two lines while composing.
                ZStack(alignment: .topLeading) {
                    // Gone the moment the text has the keyboard: the cursor
                    // is the invitation then, not the words.
                    if !hasWords && model.imageCount == 0 && !model.editing {
                        Text(placeholder)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(theme.ink.opacity(0.45))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    DockChatComposer(model: model, fontSize: 13,
                                     enabled: model.selected != nil)
                }
                .frame(height: composing ? DockChatComposer.lineHeight * 2 : DockChatComposer.lineHeight)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.notice)
    }

    @ViewBuilder
    private var pillBackground: some View {
        let shape = self.shape
        ZStack {
            theme.fill(shape)
            shape.strokeBorder(theme.edge, lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.25), value: look)
        .background {
            if theme.isGlass {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
        }
    }

    // MARK: - Copy

    private var isWorking: Bool { model.selected?.state == .busy || model.isSending }

    /// Busy, the terminal's own kind of line — "Perambulating… 42s" —
    /// counting up; otherwise what the session is waiting on.
    @ViewBuilder
    private var statusLine: some View {
        if let target = model.selected, target.state == .busy, !model.isSending {
            let live = model.live
            let started = live?.startedAt ?? target.since
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let words = live?.doing ?? "\(ClaudeSpinner.word(session: target.id, since: started))…"
                let time = ClaudeSpinner.elapsed(since: started, now: context.date)
                // What it is doing comes first. With little room the tokens
                // go, then the time — never the words down to a letter.
                ViewThatFits(in: .horizontal) {
                    working(words, timing(since: started, now: context.date, tokens: live?.tokens))
                    working(words, time)
                    working(words, nil)
                }
                .animation(.easeInOut(duration: 0.2), value: live?.doing)
            }
        } else {
            Text(status)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink)
        }
    }

    private func working(_ words: String, _ detail: String?) -> some View {
        HStack(spacing: 5) {
            Text(words)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.working)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 72, alignment: .leading)
            if let detail {
                Text(detail)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.ink.opacity(0.5))
                    .contentTransition(.numericText())
                    .fixedSize()
            }
        }
    }

    /// "42s · ↓ 2.3k", as the terminal counts a turn.
    private func timing(since: Date, now: Date, tokens: Int?) -> String {
        let time = ClaudeSpinner.elapsed(since: since, now: now)
        guard let tokens, tokens > 0 else { return time }
        return "\(time) · \(ClaudeLiveActivity.tokensText(tokens))"
    }

    private var status: String {
        guard let target = model.selected else { return L10n.t("No Claude session in a terminal") }
        if model.isSending { return L10n.t("Sending…") }
        switch target.state {
        case .busy: return L10n.t("Clauding…")
        case .waiting: return L10n.t("Waiting for you")
        case .success: return L10n.t("Done")
        case .idle: return L10n.t("Ready")
        }
    }

    private var placeholder: String {
        guard model.selected != nil else { return L10n.t("Start claude in a terminal") }
        return L10n.t("Chat here…")
    }
}

/// A steady turn while Claude works.
private struct Spin: ViewModifier {
    let active: Bool
    @State private var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onAppear { restart() }
            .onChange(of: active) { restart() }
    }

    private func restart() {
        if active {
            angle = 0
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { angle = 360 }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { angle = 0 }
        }
    }
}

/// The repository half of the chip: brighter under the pointer, a touch
/// dimmer while pressed.
private struct DockChipStyle: ButtonStyle {
    @AppStorage(Preferences.codedockLookKey) private var look = "dark"
    private var theme: DockTheme { DockTheme(rawValue: look) ?? .dark }
    var edge: HorizontalEdge
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                               bottomTrailingRadius: 3, topTrailingRadius: 3,
                                               style: .continuous)
                .fill(theme.ink.opacity(configuration.isPressed ? 0.06 : hovered ? 0.2 : 0.1)))
            .foregroundStyle(theme.ink.opacity(hovered ? 0.95 : 0.8))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// The arrow half, which opens the list of sessions: the same hover.
private struct DockChipArrow: View {
    @AppStorage(Preferences.codedockLookKey) private var look = "dark"
    private var theme: DockTheme { DockTheme(rawValue: look) ?? .dark }
    var open: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.up")
            // Points the way the list opens, and turns back as it closes.
            .rotationEffect(.degrees(open ? 180 : 0))
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.7), value: open)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(theme.ink.opacity(hovered ? 0.95 : 0.7))
            .frame(width: 18, height: 19)
            .background(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                                               bottomTrailingRadius: 10, topTrailingRadius: 10,
                                               style: .continuous)
                .fill(theme.ink.opacity(open ? 0.24 : hovered ? 0.2 : 0.1)))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A small square in a circle: stop, the way a media control says it.
private struct DockStopGlyph: View {
    @AppStorage(Preferences.codedockLookKey) private var look = "dark"
    private var theme: DockTheme { DockTheme(rawValue: look) ?? .dark }
    var busy: Bool
    @State private var hovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(theme.ink.opacity(hovered ? 1 : 0.8))
            .frame(width: 6.5, height: 6.5)
            .frame(width: 19, height: 19)
            .background(Circle().fill(hovered ? Color.red.opacity(0.55) : theme.ink.opacity(0.12)))
            .opacity(busy ? 0.4 : 1)
            .contentShape(Circle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// The conversation inside the pill: yours on the right, Claude's on the
/// left, newest at the bottom, scrolled there as it grows.
struct DockHistory: View {
    let messages: [ClaudeConversation.Message]
    let theme: DockTheme
    /// While the session works, what it is doing this moment — shown under
    /// the last message, so the conversation is visibly alive between the
    /// pieces Claude Code writes down.
    var working: String? = nil
    /// Told how tall everything said is, so the pill can be just that tall.
    var contentHeight: (CGFloat) -> Void = { _ in }

    /// The least room the conversation is given: one line and its margins.
    static let leastHeight: CGFloat = 40

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                // A plain stack, so the whole of it is measured and the end
                // can be reached; a lazy one stopped short of a long reply.
                VStack(alignment: .leading, spacing: 8) {
                    if messages.isEmpty {
                        Text(L10n.t("Nothing said yet."))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.ink.opacity(0.45))
                            .padding(.top, 8)
                    }
                    ForEach(messages) { message in
                        bubble(message).id(message.id)
                    }
                    if let working {
                        HStack(spacing: 6) {
                            ClaudeSpinnerGlyph(active: true, size: 11)
                            Text(working)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.working)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight($0) }
            }
            // Starts, and stays, at the bottom by the text box, like a chat.
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.automatic)
            .onAppear { reader.scrollTo(Self.end, anchor: .bottom) }
            .onChange(of: messages) { withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(Self.end, anchor: .bottom) } }
            .onChange(of: working) { reader.scrollTo(Self.end, anchor: .bottom) }
        }
    }

    private static let end = "end"

    /// For previews and tests, outside the scroll view.
    func bubblePreview(_ message: ClaudeConversation.Message) -> some View { bubble(message) }

    @ViewBuilder
    private func bubble(_ message: ClaudeConversation.Message) -> some View {
        switch message.role {
        case .you:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink.opacity(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.ink.opacity(0.12)))
                    .textSelection(.enabled)
            }
        case .claude:
            HStack(alignment: .top, spacing: 6) {
                Text("✻").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.working)
                Text(LocalizedStringKey(message.text))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink.opacity(0.85))
                    .textSelection(.enabled)
                Spacer(minLength: 20)
            }
        }
    }
}
