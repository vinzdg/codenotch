import AppKit
import CoreTransferable
import SwiftUI
import Combine

/// A Liquid Glass background that falls back to a regular material on macOS
/// 15, where `glassEffect` does not exist. The visual difference is minor — the
/// sidebar gets a standard vibrancy material instead of the glass tint — and
/// the layout and interactions are unchanged.
extension View {
    @ViewBuilder
    func glassBackground(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            background { Color.clear.glassEffect(.regular, in: shape) }
        } else {
            background {
                shape.fill(.regularMaterial)
            }
        }
    }
}

/// One entry in the sidebar. Grouped by subject rather than by how each
/// setting is stored — a mute toggle for a provider's threshold alerts lives
/// on that provider's own row in Accounts, not repeated here, but the
/// crossing-and-notification machinery it switches is Notifications' to
/// explain.
private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case accounts, phone, deepseek, ollama, lmstudio, customEndpoints, appearance, notifications, general

    /// The sections the sidebar lists; Phone only once pairing is offered.
    static var visible: [SettingsSection] {
        allCases.filter { $0 != .phone || PhoneLink.isAvailable }
    }

    var id: String { rawValue }

    /// The sidebar's groups: where readings come from, the notch itself,
    /// and the app.
    enum Group: String, CaseIterable, Identifiable {
        case sources, notch, app
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sources: return L10n.t("Sources")
            case .notch:   return L10n.t("Notch")
            case .app:     return L10n.t("App")
            }
        }
    }

    /// The symbol's colour in the sidebar: one hue per subject, on the
    /// symbol itself rather than on a badge behind it.
    var tint: Color {
        switch self {
        case .accounts:      return .blue
        case .phone:         return .green
        case .deepseek:      return .orange
        case .ollama:        return .teal
        case .lmstudio:      return .purple
        case .customEndpoints: return .indigo
        case .appearance:    return .indigo
        case .notifications: return .red
        case .general:       return .gray
        }
    }

    var group: Group {
        switch self {
        case .accounts, .phone, .deepseek, .ollama, .lmstudio, .customEndpoints: return .sources
        case .appearance, .notifications: return .notch
        case .general: return .app
        }
    }

    /// One line under the pane's title: what is decided here.
    var subtitle: String {
        switch self {
        case .accounts:      return L10n.t("The logins the notch reads, and the order of its rings.")
        case .phone:         return L10n.t("Your usage on a phone, over the local network.")
        case .deepseek:      return L10n.t("Per-token prices and the off-peak discount.")
        case .ollama:        return L10n.t("The local runtime and what its models report.")
        case .lmstudio:      return L10n.t("The local runtime and what its models report.")
        case .customEndpoints: return L10n.t("OpenAI-compatible APIs, local runtimes and custom proxies.")
        case .appearance:    return L10n.t("Where the notch sits, how big it is, and what it shows.")
        case .notifications: return L10n.t("Sounds, cards and banners when something finishes, stalls or resets.")
        case .general:       return L10n.t("Launch at login, updates and language.")
        }
    }

    var title: String {
        switch self {
        case .accounts:      return L10n.t("Accounts")
        case .phone:         return L10n.t("Phone")
        case .deepseek:      return "DeepSeek"
        case .ollama:        return "Ollama"   // a product name, the same in every language
        case .lmstudio:      return "LM Studio"
        case .customEndpoints: return L10n.t("Custom Endpoints")
        case .appearance:    return L10n.t("Appearance")
        case .notifications: return L10n.t("Notifications")
        case .general:       return L10n.t("General")
        }
    }

    var icon: String {
        switch self {
        case .accounts:      return "person.crop.circle"
        case .phone:         return "iphone"
        case .deepseek:      return "chart.line.uptrend.xyaxis"
        case .ollama:        return "desktopcomputer"
        case .lmstudio:      return "cpu"
        case .customEndpoints: return "network"
        case .appearance:    return "paintbrush"
        case .notifications: return "bell.badge"
        case .general:       return "gearshape"
        }
    }

}

/// Real window vibrancy, which SwiftUI's own `Material` cannot give here.
///
/// A `Material` blends against what is *inside* the window; this blends
/// against what is behind it, which is the whole point — the desktop and
/// whatever is stacked under the panel show through it, and the sidebar and
/// the pane can take different materials so they read as two surfaces rather
/// than one flat fill.
private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        apply(to: view, context: context)
        // `.followsWindowActiveState` would drain the colour out of the panel
        // whenever focus went elsewhere, which for a settings window that is
        // read while another app is in front is most of the time.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        apply(to: view, context: context)
    }

    private func apply(to view: NSVisualEffectView, context: Context) {
        if context.environment.codenotchReduceTransparency {
            view.material = .windowBackground
            view.blendingMode = .withinWindow
        } else {
            view.material = material
            view.blendingMode = .behindWindow
        }
    }
}

/// A rounded-square badge behind a white symbol — the icon style System
/// Settings' own sidebar uses, rather than a plain monochrome glyph.
private struct SidebarIcon: View {
    let systemName: String
    let tint: Color

    /// System Settings' own badge: 20pt square, rounded to a little over a
    /// quarter of its side, with the symbol at 12pt inside it.
    var body: some View {
        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

/// The settings sheet, reached from the orb below the notch.
///
/// A sidebar of subjects rather than one long scroll, the way macOS's own
/// System Settings groups a much bigger list of the same kind of thing:
/// switches and pickers with a sentence or two beside them. The account rows
/// are the one section long enough on their own to want somewhere apart from
/// everything else.
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let providers: () -> [ProviderSummary]
    var phoneLinkPairing: PhoneLinkPairing?
    var phoneLinkRegistry: PhoneLinkRegistry?
    var phoneLinkServerStatus: PhoneLinkServerStatus?

    /// Re-read whenever the sheet comes forward. Switching account happens in
    /// another app, so the user is always coming *back* here to see it — which
    /// makes returning focus the exact moment the old value is wrong.
    @State private var accounts: [ProviderSummary] = []
    @State private var displays: [DisplayOption] = []
    @State private var menuBarChoices: [MenuBarChoice] = []
    @State private var selection: SettingsSection = .accounts
    /// The provider being dragged right now.
    ///
    /// Held here rather than read off the drop, because the rows have to move
    /// *during* the drag and `dropDestination` only hands over its payload once
    /// the pointer is released. See `DragState` for why it is a reference.
    @State private var drag = DragState()
    /// Bumped on every drop, purely to make the rows' cursor rects re-evaluate.
    ///
    /// A re-render per drop, which is a discrete action and cheap — unlike the
    /// per-drag state this replaced.
    @State private var cursorRefresh = 0
    /// The credit link lights up under the pointer. A `Link` gives no hover
    /// feedback of its own on macOS, so without this the only sign it is
    /// clickable is the cursor.
    @State private var authorLinkHovered = false
    /// A gesture for this sitting, not a setting: the sidebar comes back on
    /// the next open, the same way a window's own sidebar toggle behaves.
    @State private var isSidebarVisible = true
    /// A short-lived acknowledgement for the recenter action. The notch may
    /// already be centred, in which case the action has no visible movement;
    /// the acknowledgement keeps the button from feeling inert.
    @State private var didRecentre = false
    /// Switching off has to reach the store's archive, not just the preference
    /// — see `UsageStore.signOut(providerID:)`.
    let signOut: (String) -> Void
    /// Switching on takes the user to wherever that account is signed in.
    /// Returns false when there was nothing to open.
    let signIn: (String) -> Bool
    let switchAccount: (String) -> Bool
    /// Re-reads a provider's credential. For a declined keychain prompt that is
    /// the whole remedy: asking again is what puts the prompt back on screen.
    let retry: (String) -> Void
    /// Put the notch back in the middle of its edge. A closure rather than a
    /// write to `preferences`, because the stored offset is not `@Published` —
    /// nothing would tell the notch to move, and the setting would only take
    /// effect the next time the edge changed.
    let resetPosition: () -> Void
    let quit: () -> Void
    @ObservedObject var updater: Updater
    var ollamaRelay: OllamaActivityRelay? = nil
    var lmstudioMetrics: LMStudioMetrics? = nil
    var usageStore: UsageStore? = nil
    var previewResetAlert: (() -> Void)? = nil
    var previewSessionLimitAlert: (() -> Void)? = nil
    var previewWeeklyLimitAlert: (() -> Void)? = nil
    @Environment(\.codenotchReduceTransparency) private var reduceTransparency

    var body: some View {
        // A plain HStack rather than `NavigationSplitView`: the sidebar here
        // is never meant to collapse, but AppKit still installs its own
        // "toggle sidebar" title bar button for a split view regardless of
        // `.toolbar(.hidden, for:)` or `.toolbar(removing: .sidebarToggle)`
        // — neither reliably suppresses it (see the note in
        // `SettingsWindowController.show()`). A fixed-width list beside the
        // pane gets the same look with no toggle to remove.
        HStack(spacing: 0) {
            if isSidebarVisible {
                sidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            pane(for: selection)
                // A fixed subject per window, not a document — nothing here
                // is titled the way a sidebar of documents would be.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Rebuild the whole pane when the language changes.
        //
        // A segmented `Picker` draws its options through `ForEach`, which
        // identifies each row by its tag — the enum case. Switching language
        // changes only the title that row renders, not its identity, so the
        // rows compare equal, AppKit's segmented control is told nothing has
        // changed, and it keeps the segment labels it was first built with.
        // The result was a pane where every plain `Text` had switched back to
        // English and every picker was still in Chinese.
        //
        // Re-identifying here rather than on each picker: there are eleven of
        // them across four panes, and a twelfth added later would arrive with
        // the bug and no way to notice.
        .id(preferences.language)
        .tint(preferences.accentColor.color)
        .environment(\.codenotchAccentColor, preferences.accentColor.color)
        // Fills the window rather than claiming a fixed size. Under
        // `fullSizeContentView` the content view is the whole frame — title
        // bar included — so a view sized to `SettingsView.height` left the
        // title bar's worth of transparent window above it, with the traffic
        // lights floating in the hole.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // What actually draws the panel: the window itself is transparent
        // (see `SettingsWindowController.show()`), so this material is the
        // whole visible surface, and clipping it is what rounds all four
        // corners rather than only the two macOS rounds for a titled window.
        .background(SettingsChrome.paneFill)
        .clipShape(RoundedRectangle(cornerRadius: SettingsView.cornerRadius,
                                    style: .continuous))
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: SettingsView.cornerRadius,
                                 style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        // Without this SwiftUI insets the content by the title bar's height
        // even though the window has none to speak of, and the panel's own
        // rounded top is pushed down leaving a transparent band with the
        // traffic lights stranded in it.
        .ignoresSafeArea()
        .onAppear { refreshVisibleState() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )) { _ in refreshVisibleState() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in displays = DisplayOption.connected }
        .onReceive(preferences.$customEndpoints.receive(on: RunLoop.main)) { _ in
            accounts = providers()
        }
        .onReceive((usageStore?.$snapshots.eraseToAnyPublisher()
                    ?? Empty<[ProviderSnapshot], Never>().eraseToAnyPublisher())
            .receive(on: RunLoop.main)) { snapshots in
                // Every reading lands here. The rows only change when who can
                // be listed does, not whenever a figure moves.
                let choices = MenuBarChoice.listed(in: snapshots)
                if choices != menuBarChoices { menuBarChoices = choices }
            }
        .onReceive(NotificationCenter.default.publisher(for: SettingsView.openSection)) { note in
            if let raw = note.userInfo?["section"] as? String,
               let section = SettingsSection(rawValue: raw) {
                selection = section
            }
        }
        .onReceive((usageStore?.$notchSnapshots.eraseToAnyPublisher()
                    ?? Empty<[ProviderSnapshot], Never>().eraseToAnyPublisher())
            .receive(on: RunLoop.main)) { _ in
                // The sheet stays open while models load and unload. Update
                // those rows without re-reading cloud credentials on each poll.
                guard let usageStore else { return }
                let models = usageStore.localModelSummaries
                let updated = accounts.filter { $0.localModel == nil }.flatMap { account in
                    [account] + models.filter { $0.sourceProviderID == account.id }
                }
                accounts = ProviderOrder.arrange(updated, by: preferences.providerOrder, id: \.id)
            }
        .onReceive((usageStore?.$providerAccountRevision.eraseToAnyPublisher()
                    ?? Empty<Int, Never>().eraseToAnyPublisher())
            .receive(on: RunLoop.main)) { _ in
                // Authentication can finish in a separate WebView window while
                // this pane remains alive. Re-read only the account summaries
                // for that explicit event, not on every usage poll.
                accounts = providers()
            }
    }

    /// The subject list, drawn as a card floating inside the window rather
    /// than as a full-height column welded to its left edge.
    ///
    /// The inset is what makes it read as floating: the window's own
    /// background runs around all four of its sides, so the card has an edge
    /// everywhere instead of only on the one side facing the pane. The
    /// traffic lights land inside it, which is why the rows start a clear
    /// `trafficLightClearance` below the top rather than at it.
    @State private var sidebarQuery = ""

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The band the traffic lights sit in; the toggle takes its far end.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                sidebarToggle
            }
            .padding(.trailing, 12)
            .frame(height: SettingsView.headerHeight)

            // Finds a subject by name, the way a long settings list is used.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("", text: $sidebarQuery, prompt: Text(L10n.t("Search settings…")))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(SettingsSection.Group.allCases) { group in
                        let rows = SettingsSection.visible.filter {
                            $0.group == group && (sidebarQuery.isEmpty
                                || $0.title.localizedCaseInsensitiveContains(sidebarQuery))
                        }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 10)
                                    .padding(.bottom, 4)
                                ForEach(rows) { section in
                                    sidebarRow(section)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)

            Button(role: .destructive, action: quit) {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(Color.red.gradient))
                    Text(L10n.t("Quit Codenotch"))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .frame(width: SettingsView.sidebarWidth)
        .background(SettingsChrome.sidebarFill)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
        }
    }

    /// One subject: its symbol in its own colour, the name, and a quiet grey
    /// pill when it is the one open.
    private func sidebarRow(_ section: SettingsSection) -> some View {
        let selected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(section.tint)
                    .frame(width: 20, height: 20)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.09) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Folds the sidebar away, from inside the sidebar itself: a bare symbol,
    /// because the card it sits on is already a surface of its own.
    private var sidebarToggle: some View {
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("Hide Sidebar"))
    }

    /// And brings it back, from the pane's own header.
    ///
    /// A glass disc rather than a bare symbol: with the card gone there is no
    /// surface under it any more, and a lone glyph floating on the pane reads
    /// as decoration rather than as the control that undoes what just
    /// happened.
    private var collapsedSidebarToggle: some View {
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background {
                    if reduceTransparency {
                        Circle()
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                    } else if #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.regular, in: Circle())
                    } else {
                        Circle().fill(.regularMaterial)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("Show Sidebar"))
    }

    private func toggleSidebar() {
        withAnimation(.snappy(duration: 0.22)) { isSidebarVisible.toggle() }
    }

    /// A title fixed above the scrolling `Form`, the way System Settings
    /// itself names the pane once at the top rather than repeating it as a
    /// group header that would scroll away with everything else.
    private func pane(for section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // One row across the top of the window, and the title rides it.
            // With the sidebar folded away the traffic lights are over this
            // pane instead, so the row starts clear of them and the toggle
            // takes the place the sidebar's own copy had — all three on the
            // same line rather than stacked down the corner.
            HStack(spacing: 16) {
                if !isSidebarVisible {
                    Color.clear
                        .frame(width: SettingsView.trafficLightWidth, height: 1)
                    collapsedSidebarToggle
                }
                Text(section.title)
                    .font(.system(size: 22, weight: .bold))
                Spacer(minLength: 0)
                if section == .accounts, !addableAccounts.isEmpty {
                    addSourceMenu
                        .padding(.trailing, SettingsView.paneGutter)
                }
            }
            .frame(height: SettingsView.headerHeight)
            .padding(.top, 36)
            .padding(.leading, isSidebarVisible ? SettingsView.paneGutter : 12)
            .frame(maxWidth: SettingsChrome.measure + 2 * SettingsChrome.gutter, alignment: .leading)
            .frame(maxWidth: .infinity)
            Text(section.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.leading, isSidebarVisible ? SettingsView.paneGutter : 12)
                .padding(.bottom, 10)
                .frame(maxWidth: SettingsChrome.measure + 2 * SettingsChrome.gutter, alignment: .leading)
                .frame(maxWidth: .infinity)
            paneContent(for: section)
                .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func paneContent(for section: SettingsSection) -> some View {
        switch section {
        case .accounts:      accountsPane
        case .phone:         phonePane
        case .deepseek:      DeepSeekPricingSettingsView(preferences: preferences)
        case .customEndpoints: CustomEndpointsSettingsView(preferences: preferences)
        case .ollama:
            if let usageStore {
                SettingsPage {
                    SettingsGroup(title: L10n.t("Connection")) {
                        SettingsCell { OllamaSettingsRow(preferences: preferences, store: usageStore, relay: ollamaRelay) }
                    }
                }
            }
        case .lmstudio:
            if let usageStore {
                SettingsPage {
                    SettingsGroup(title: L10n.t("Connection")) {
                        SettingsCell { LMStudioSettingsRow(preferences: preferences, store: usageStore, metrics: lmstudioMetrics) }
                    }
                }
            }
        case .appearance:    appearancePane
        case .notifications: notificationsPane
        case .general:       generalPane
        }
    }

    /// Everything that is off, as a menu: what is not connected is a choice
    /// to make, not a list to read past.
    private var addSourceMenu: some View {
        Menu {
            ForEach(addableAccounts) { account in
                Button {
                    addSource(account.id)
                } label: {
                    Label {
                        Text(account.name)
                    } icon: {
                        Image(nsImage: account.glyph.menuImage)
                    }
                }
            }
        } label: {
            Label(L10n.t("Add"), systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .tint(.primary)
        .fixedSize()
        .help(L10n.t("Connect another source. It joins the end of the list with a ring of its own."))
    }

    private var accountsPane: some View {
        SettingsPage {
            if needsSetup {
                SettingsGroup { SettingsCell { setupNote } }
            }
            VStack(alignment: .leading, spacing: 0) {
                let rows = listedAccounts
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, account in
                    let isOn = preferences.isConnected(account.id)
                    AccountRow(provider: account, preferences: preferences,
                               signOut: signOut, signIn: signIn,
                               switchAccount: switchAccount, retry: retry,
                               refresh: { usageStore?.reevaluate(providerID: $0) },
                               isOrderable: isOn,
                               drag: drag,
                               cursorRefresh: cursorRefresh,
                               onDrop: { cursorRefresh += 1 },
                               takePlaceOf: { move($0, onto: account.id) },
                               didConnect: { setListed(account.id, true); connect(account.id) },
                               onRemove: isOn ? nil : { setListed(account.id, false) })
                        .padding(.vertical, 12)
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 60)
                    }
                }
                if rows.isEmpty {
                    Text(L10n.t("Nothing is connected, so the notch has no rings to draw."))
                        .font(SettingsChrome.bodyFont)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
            }
            Text(connected.isEmpty
                 ? L10n.t("Most readings are borrowed from a tool that already holds the account. DeepSeek and MiniMax are the exceptions: clicking Sign in opens a Codenotch window for that account, and signing out here clears only that session and its saved reading.")
                 : L10n.t("The notch draws these in this order. Drag one by its handle to move it."))
                .font(SettingsChrome.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.snappy(duration: 0.25), value: preferences.connectedProviders)
        .animation(.snappy(duration: 0.25), value: preferences.disabledModels)
        // Everything on when the pane opens is kept, so the first switch-off
        // leaves a row rather than removing one; and a row switched off is
        // marked kept at that moment, whatever the list said before.
        .onAppear {
            if listedSourcesRaw.isEmpty { seedListed() }
            previouslyConnected = Set(connected.map(\.id))
        }
        .onChange(of: preferences.connectedProviders) { _, _ in
            let now = Set(connected.map(\.id))
            for id in previouslyConnected.subtracting(now) { setListed(id, true) }
            previouslyConnected = now
        }
    }

    @State private var previouslyConnected: Set<String> = []

    private func seedListed() {
        listedSourcesRaw = connected.map(\.id).sorted().joined(separator: ",")
    }

    private var appearancePane: some View {
        SettingsPage {
            SettingsGroup(title: L10n.t("Notch")) {
                SettingsRow(title: L10n.t("Show"), description: preferences.notchVisibility.explanation) {
                    Picker("", selection: $preferences.notchVisibility) {
                        ForEach(NotchVisibility.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                SettingsToggleRow(title: L10n.t("Fold for full-screen apps"),
                                  description: L10n.t("The notch folds away while a full-screen app is frontmost, and returns when you leave it. Off keeps it in place over full-screen apps."),
                                  isOn: $preferences.foldsForFullScreen)
                SettingsRow(title: L10n.t("Edge"), description: preferences.notchEdge.explanation) {
                    Picker("", selection: $preferences.notchEdge) {
                        ForEach(NotchEdge.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: L10n.t("Displays"), description: preferences.notchScope.explanation) {
                    Picker("", selection: $preferences.notchScope) {
                        ForEach(NotchScreenScope.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                if preferences.notchScope == .mainDisplay {
                    SettingsRow(title: L10n.t("Display"), description: displayExplanation) {
                        Picker("", selection: $preferences.displayPreference) {
                            Text(L10n.t("Follow active window")).tag(DisplayPreference.followActiveWindow)
                            ForEach(displays) { display in
                                Text(display.name).tag(DisplayPreference.display(display.id))
                            }
                            if case .display(let id) = preferences.displayPreference,
                               !displays.contains(where: { $0.id == id }) {
                                Text(L10n.t("Unavailable display")).tag(DisplayPreference.display(id))
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                }
                if #available(macOS 26.0, *) {
                    SettingsRow(title: L10n.t("Surface"), description: preferences.notchSurfaceStyle.explanation) {
                        Picker("", selection: $preferences.notchSurfaceStyle) {
                            ForEach(NotchSurfaceStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                }
                SettingsRow(title: L10n.t("Size"),
                            description: preferences.usesCustomNotchScale
                                ? L10n.t("Scales the whole surface — rings, text and tooltip together — so the proportions stay as drawn. 100% is the size the notch was designed at.")
                                : preferences.notchSize.explanation) {
                    HStack(spacing: 10) {
                        if preferences.usesCustomNotchScale {
                            Slider(value: $preferences.customNotchScale, in: Preferences.customScaleRange)
                                .frame(width: 160)
                            Text(Self.scalePercent(preferences.customNotchScale))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                        } else {
                            Picker("", selection: $preferences.notchSize) {
                                ForEach(NotchSize.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.segmented).fixedSize()
                        }
                        Picker("", selection: Binding(
                            get: { preferences.usesCustomNotchScale },
                            set: { preferences.usesCustomNotchScale = $0 }
                        )) {
                            Text(L10n.t("Preset")).tag(false)
                            Text(L10n.t("Custom")).tag(true)
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                }
                SettingsRow(title: L10n.t("Position"),
                            description: L10n.t("Hold ⌥ and drag the notch to slide it along its edge. Each edge remembers where you left it.")) {
                    Button {
                        resetPosition()
                        withAnimation(.easeInOut(duration: 0.15)) { didRecentre = true }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeInOut(duration: 0.15)) { didRecentre = false }
                        }
                    } label: {
                        Label(L10n.t("Recentre"), systemImage: didRecentre ? "checkmark" : "arrow.counterclockwise")
                    }
                }
                SettingsToggleRow(title: L10n.t("Show move handle"),
                                  description: L10n.t("The arc above the notch. Hold it to carry the notch to another edge — Edge above does the same."),
                                  isOn: $preferences.showsMoveHandle)
            }

            SettingsGroup(title: L10n.t("Rings")) {
                SettingsRow(title: L10n.t("Reset time"), description: preferences.resetTimeFormat.explanation) {
                    Picker("", selection: $preferences.resetTimeFormat) {
                        ForEach(ResetTimeFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                SettingsToggleRow(title: L10n.t("Show usage pace"),
                                  description: L10n.t("Compares each timed allowance with the time left until reset, showing quota in deficit or held in reserve."),
                                  isOn: $preferences.showUsagePace)
                SettingsToggleRow(title: L10n.t("Show Spark and code review"),
                                  description: L10n.t("The ring still follows the main Codex window. Spark and code review stay in the hover card."),
                                  isOn: $preferences.showCodexExtraLimits)
                    .onChange(of: preferences.showCodexExtraLimits) { _ in
                        for account in providers() where CodexProfile.isCodex(providerID: account.id) {
                            usageStore?.refresh(providerID: account.id)
                        }
                    }
                SettingsRow(title: L10n.t("Weekly ring"), description: preferences.weeklyRing.explanation) {
                    Picker("", selection: $preferences.weeklyRing) {
                        ForEach(WeeklyRing.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                if preferences.weeklyRing != .off {
                    SettingsToggleRow(title: L10n.t("Dashed weekly ring"), isOn: $preferences.weeklyRingDashed)
                }
                SettingsToggleRow(title: L10n.t("Claude daily pace ring"),
                                  description: L10n.t("Claude's main ring shows today's share of the weekly limit — a seventh a day, counted from the weekly reset — instead of the session. The session moves to the thin ring and the card; alerts follow the daily ring."),
                                  isOn: $preferences.claudeDailyPaceRing)
            }

            SettingsGroup(title: L10n.t("Usage Limits"),
                          footer: L10n.t("Rings turn amber at the watch limit and red at the critical one.")) {
                SettingsRow(title: L10n.t("Watch limit"), stacked: true) {
                    HStack(spacing: 12) {
                        Slider(value: $preferences.watchLimit, in: 0.01...0.99)
                        Text("\(Int(preferences.watchLimit * 100))%")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                SettingsRow(title: L10n.t("Critical limit"), stacked: true) {
                    HStack(spacing: 12) {
                        Slider(value: $preferences.criticalLimit, in: 0.01...1.00)
                        Text("\(Int(preferences.criticalLimit * 100))%")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                SettingsRow(title: L10n.t("Reset to defaults"), description: "50% · 70%") {
                    Button(L10n.t("Reset")) {
                        preferences.criticalLimit = 0.70
                        preferences.watchLimit = 0.50
                    }
                }
            }

            if preferences.appPresence == .menuBar {
                SettingsGroup(title: L10n.t("Menu bar"),
                              footer: menuBarChoices.isEmpty
                                  ? L10n.t("Nothing Codenotch reads has a five-hour limit to show yet. Claude and Codex do — switch one on in Accounts.")
                                  : L10n.t("Leaving a provider out keeps it off the menu bar only — Codenotch still reads it. With none chosen, the icon comes back.")) {
                    SettingsToggleRow(title: L10n.t("Show limit information in menu bar"),
                                      description: L10n.t("Swaps the icon for each chosen provider's five-hour limit — how much is used and how long until it resets."),
                                      isOn: $preferences.showsLimitsInMenuBar)
                    if preferences.showsLimitsInMenuBar {
                        SettingsToggleRow(title: L10n.t("Show weekly limit in menu bar"),
                                          description: L10n.t("Adds a compact weekly-usage ring around each chosen provider that publishes it."),
                                          isOn: $preferences.showsWeeklyLimitInMenuBar)
                        ForEach(menuBarChoices) { choice in
                            SettingsRow(title: choice.name) {
                                HStack(spacing: 10) {
                                    ProviderGlyphView(glyph: choice.glyph, size: 16).accessibilityHidden(true)
                                    Toggle("", isOn: Binding(
                                        get: { preferences.isInMenuBar(choice.id) },
                                        set: { preferences.setInMenuBar($0, for: choice.id, among: menuBarChoices.map(\.id)) }
                                    ))
                                    .labelsHidden().toggleStyle(.switch)
                                }
                            }
                        }
                        if menuBarChoices.filter({ preferences.isInMenuBar($0.id) }).count > StatusItemSummary.fullEntryLimit {
                            SettingsNote(text: L10n.t("Past two, each shows its share alone and the countdowns move to the tooltip. Past four, the rest are in the menu."))
                        }
                    }
                }
            }

            SettingsGroup(title: L10n.t("App")) {
                SettingsRow(title: L10n.t("Accent color")) {
                    HStack(spacing: 2) {
                        ForEach(AccentColorChoice.allCases) { choice in
                            AccentColorSwatch(choice: choice, isSelected: preferences.accentColor == choice) {
                                preferences.accentColor = choice
                            }
                        }
                    }
                }
                SettingsRow(title: L10n.t("App icon"), description: preferences.appPresence.explanation) {
                    Picker("", selection: $preferences.appPresence) {
                        ForEach(AppPresence.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                SettingsRow(title: L10n.t("Language"), description: preferences.language.explanation) {
                    Picker("", selection: $preferences.language) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
        }
    }

    private var notificationsPane: some View {
        SettingsPage {
            SettingsGroup(title: L10n.t("Peek")) {
                SettingsRow(title: L10n.t("How long the notch stays open"),
                            description: preferences.peekDuration.explanation) {
                    Picker("", selection: $preferences.peekDuration) {
                        ForEach(PeekDuration.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }

            SettingsGroup(title: L10n.t("Events"),
                          footer: L10n.t("A system notification the moment a provider's headline limit crosses 80%, and again at 100% — once per crossing, and again only after the window rolls over. Mute one from the bell beside its row in Accounts.")) {
                NotificationEventHeader()
                NotificationEventRow(title: L10n.t("Session finished"),
                                     description: L10n.t("The agent's turn is done."),
                                     isOn: $preferences.announceSessionEnd,
                                     sound: soundChoice(enabled: $preferences.sessionEndSound, name: $preferences.sessionEndSoundName))
                NotificationEventRow(title: L10n.t("Session waiting on you"),
                                     description: L10n.t("The agent stopped to ask you something."),
                                     isOn: $preferences.announceSessionEnd,
                                     sound: soundChoice(enabled: $preferences.sessionEndSound, name: $preferences.sessionBlockedSoundName))
                NotificationEventRow(title: L10n.t("Session limit reached"),
                                     description: L10n.t("The 5-hour allowance of a provider is spent."),
                                     isOn: $preferences.announceSessionLimitReached,
                                     sound: soundChoice(enabled: $preferences.limitReachedSound, name: $preferences.limitReachedSoundName))
                NotificationEventRow(title: L10n.t("Weekly limit reached"),
                                     description: L10n.t("The weekly allowance of a provider is spent."),
                                     isOn: $preferences.announceWeeklyLimitReached,
                                     sound: soundChoice(enabled: $preferences.limitReachedSound, name: $preferences.limitReachedSoundName))
                NotificationEventRow(title: L10n.t("Limit reset"),
                                     description: L10n.t("A limit is available again."),
                                     isOn: $preferences.announceUsageReset,
                                     sound: soundChoice(enabled: $preferences.usageResetSound, name: $preferences.usageResetSoundName))
            }
        }
    }

    /// "Don't play" is the empty name; choosing a sound switches the sound on.
    private func soundChoice(enabled: Binding<Bool>, name: Binding<String>) -> Binding<String> {
        Binding(
            get: { enabled.wrappedValue ? name.wrappedValue : "" },
            set: { chosen in
                if chosen.isEmpty {
                    enabled.wrappedValue = false
                } else {
                    name.wrappedValue = chosen
                    enabled.wrappedValue = true
                }
            }
        )
    }

    private var generalPane: some View {
        SettingsPage {
            SettingsGroup {
                SettingsToggleRow(title: L10n.t("Open Codenotch at login"),
                                  description: preferences.launchAtLoginProblem,
                                  isOn: $preferences.launchAtLogin)
                SettingsToggleRow(title: L10n.t("Install updates automatically"),
                                  description: L10n.t("Version \(updater.currentVersion). Updates install in the background and apply next time Codenotch starts."),
                                  isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 }))
                SettingsRow(title: L10n.t("Check for updates"),
                            description: updater.outcome.message) {
                    Button(L10n.t("Check now")) { updater.checkNow() }
                }
            }

            SettingsGroup {
                SettingsCell {
                    HStack(spacing: 4) {
                        Text(L10n.t("App designed and developed by"))
                        Link("@hivinz_", destination: SettingsView.authorURL)
                            .foregroundStyle(authorLinkHovered
                                             ? preferences.accentColor.color : .primary)
                            .underline(authorLinkHovered)
                            .animation(.easeOut(duration: 0.12), value: authorLinkHovered)
                            .onHover { inside in
                                authorLinkHovered = inside
                                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                    }
                    .font(SettingsChrome.bodyFont)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func refreshVisibleState() {
        accounts = providers()
        displays = DisplayOption.connected
    }

    private var displayExplanation: String {
        switch preferences.displayPreference {
        case .followActiveWindow:
            return L10n.t("Moves to the display containing the window receiving keyboard input.")
        case .display(let id):
            if let display = displays.first(where: { $0.id == id }) {
                return L10n.t("Pinned to \(display.name).")
            }
            return L10n.t("That display is disconnected. Codenotch follows the active window until it returns.")
        }
    }


    /// The slider's multiplier as a percentage, which is how people think
    /// about "a bit bigger" — 1.15 means nothing, 115% is immediate.
    static func scalePercent(_ scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    static let authorURL = URL(string: "https://x.com/hivinz_")!

    /// The band across the top of the panel that the traffic lights sit in.
    ///
    /// Everything at the top of the window is centred on it — the lights, the
    /// sidebar's toggle, and the pane's own title — so the three read as one
    /// row rather than as three things that happen to be near the top.
    /// `SettingsWindowController` positions the lights against this too.
    static let headerHeight: CGFloat = 52
    /// The pane's left gutter, and the widest a form is allowed to run.
    static let paneGutter: CGFloat = 40
    static let paneMaxWidth: CGFloat = 900
    /// The grouped form's own leading margin, measured on the rendered pane.
    static let formInset: CGFloat = 78

    /// How much room the three lights take across, for the one layout that
    /// has to start to the right of them: the collapsed pane's header.
    static let trafficLightWidth: CGFloat = 66

    /// The panel's corner rounding. All four corners, not the two macOS gives
    /// a titled window — the window is transparent and the content draws the
    /// shape.
    static let cornerRadius: CGFloat = 20

    /// How far the floating sidebar card sits in from the window's edges.
    /// Small on purpose: enough for the window's background to show around
    /// it, not so much that it reads as a separate panel that came adrift.
    static let sidebarInset: CGFloat = 4
    static let sidebarCornerRadius: CGFloat = 14
    static let sidebarWidth: CGFloat = 196

    /// The sidebar plus a detail pane wide enough for an account row's name,
    /// buttons and switch without crowding.
    static let width: CGFloat = 1040
    static let minWidth: CGFloat = 820
    static let minHeight: CGFloat = 600
    /// Posted with a "section" raw value to open the window on that section.
    static let openSection = Notification.Name("CodenotchSettingsOpenSection")
    /// Each pane scrolls on its own now, so this no longer has to fit every
    /// section in the app at once — just a comfortable account list.
    static let height: CGFloat = 760

    /// The rows the notch actually draws, in the order it draws them.
    ///
    /// Model switches control visibility; their shared runtime has its own
    /// connection row and must remain enabled for its models to appear.
    private var ringAccounts: [ProviderSummary] {
        accounts.filter {
            $0.kind == .usage || ($0.localModel != nil && preferences.isConnected($0.sourceProviderID ?? $0.id))
        }
    }

    private var connected: [ProviderSummary] {
        ringAccounts.filter { preferences.isConnected($0.id) }
    }

    private var notConnected: [ProviderSummary] {
        ringAccounts.filter { !preferences.isConnected($0.id) }
    }

    /// Sources kept on the list while switched off. A ring switched off is
    /// still yours; only Remove sends it back to the Add menu. Stored as a
    /// joined string so `AppStorage` can hold it; empty means "never set",
    /// which lists whatever is connected.
    @AppStorage("brinkListedSources") private var listedSourcesRaw = ""

    private var listedSources: Set<String> {
        Set(listedSourcesRaw.split(separator: ",").map(String.init)).subtracting(["-"])
    }

    private func setListed(_ id: String, _ listed: Bool) {
        var set = listedSources
        // The first change seeds the set with what is on, so nothing vanishes.
        if listedSourcesRaw.isEmpty { set.formUnion(connected.map(\.id)) }
        if listed { set.insert(id) } else { set.remove(id) }
        // Never back to empty: empty means "never set" and would re-seed.
        listedSourcesRaw = set.isEmpty ? "-" : set.sorted().joined(separator: ",")
    }

    /// What the Accounts list shows: everything on, plus what was added and
    /// later switched off.
    private var listedAccounts: [ProviderSummary] {
        connected + notConnected.filter { listedSources.contains($0.id) }
    }

    /// What the Add menu offers: whatever is neither on nor kept.
    private var addableAccounts: [ProviderSummary] {
        notConnected.filter { !listedSources.contains($0.id) }
    }

    /// Nothing to read from anywhere. On a first launch that is the normal
    /// state, and it is the only moment the sheet has something to explain.
    private var needsSetup: Bool {
        guard !connected.contains(where: { $0.localModel != nil }) else { return false }
        let usageAccounts = accounts.filter { $0.kind == .usage }
        return !usageAccounts.isEmpty && usageAccounts.allSatisfy { $0.account == nil }
    }

    /// Names the tools rather than saying "tools already signed in on this
    /// Mac". Someone who uses Claude in a browser reads that sentence, installs
    /// this, sees four blank rings and concludes it is broken — and the
    /// distinction that catches them out is Claude *Code*, not the Claude app.
    static var setupCopy: String {
        L10n.t("Codenotch reads usage from tools already signed in on this Mac — it never asks for your password. Install and sign in to any of Claude Code (the terminal tool, not the Claude app), Cursor (the editor or cursor-agent), Codex, Antigravity, GLM, Grok, OpenCode, Command Code, GitHub Copilot, Kimi Code, Kiro or a Gemini API key (via Gemini CLI, OpenCode or Hermes), and its ring appears in the notch.")
    }

    /// Said before it happens rather than after. A system dialogue asking to
    /// read a *credential*, from an app installed a minute ago, looks alarming
    /// unless it was expected — and choosing Allow instead of Always Allow makes
    /// it return on every read, which is what "it asks every time" turns out to
    /// be.
    static var keychainCopy: String {
        L10n.t("macOS may ask before Codenotch reads Claude Code's, Antigravity's or cursor-agent's saved login. Background refreshes never show that question; it appears only when you click Allow access…, and Deny stops Codenotch reading that login until you ask again.")
    }

    /// A provider has just been switched on: put it after the ones already
    /// connected.
    ///
    /// Done here rather than in `Preferences` because the full list of
    /// providers lives here — `providerOrder` is empty until someone drags
    /// something, and "the end of the connected ones" cannot be expressed
    /// against an order that does not exist yet.
    /// The menu's version of switching a row on: connect, place it, and open
    /// wherever it signs in.
    private func addSource(_ providerID: String) {
        setListed(providerID, true)
        preferences.setConnected(true, for: providerID)
        connect(providerID)
        if let summary = accounts.first(where: { $0.id == providerID }), summary.localModel == nil {
            _ = signIn(providerID)
        }
        usageStore?.refresh(providerID: providerID)
    }

    private func connect(_ providerID: String) {
        let ids = ProviderOrder.joiningConnected(providerID,
                                                 in: accounts.map(\.id),
                                                 isConnected: preferences.isConnected)
        accounts = ProviderOrder.arrange(accounts, by: ids, id: \.id)
        preferences.setProviderOrder(ids)
    }

    /// Put the dragged provider where the one under the pointer sits, while the
    /// drag is still in the air.
    ///
    /// Written through the preference on every crossing rather than batched
    /// until the drop: a drag released outside the window fires no drop at all,
    /// and a list left visibly reordered but unsaved would disagree with the
    /// notch until the window was next opened.
    ///
    /// Returns whether both ids are ours — anything dragged in from another app
    /// is a string too.
    @discardableResult
    private func move(_ movedID: String, onto targetID: String) -> Bool {
        guard let from = accounts.firstIndex(where: { $0.id == movedID }),
              let to = accounts.firstIndex(where: { $0.id == targetID })
        else { return false }
        guard from != to else { return true }

        var reordered = accounts
        reordered.insert(reordered.remove(at: from), at: to)
        accounts = reordered
        // Every row, connected or not — the order is a fact about the list, and
        // a provider switched off today still has a place to come back to.
        preferences.setProviderOrder(accounts.map(\.id))
        return true
    }

    private var setupNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("Connect an assistant to get started"))
                    .font(.callout.weight(.medium))
                Text(SettingsView.setupCopy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(SettingsView.keychainCopy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            reduceTransparency ? .orange.opacity(0.18) : .orange.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.orange.opacity(0.4), lineWidth: 1)
            }
        }
    }


}

/// A grab cursor AppKit can be forced to re-evaluate on the spot.
///
/// `.pointerStyle` rides the pointer-tracking system, which AppKit consults only
/// on a mouse move — so a drag ending with the pointer held still leaves an
/// arrow on the grip. `invalidateCursorRects(for:)` is the escape hatch the
/// pointer system lacks, and owning a cursor rect is what puts it within reach.
private struct GrabCursor: NSViewRepresentable {
    /// Bumped by the parent on each drop. Its only purpose is to make
    /// `updateNSView` run, which is where the rects are invalidated — the value
    /// itself is never read.
    let refreshToken: Int

    func makeNSView(context: Context) -> CursorRectView { CursorRectView() }

    func updateNSView(_ view: CursorRectView, context: Context) {
        // The pointer is sitting on a grip whose cursor AppKit reset to an arrow
        // when the drag ended, and it will not ask again on its own. This asks.
        view.window?.invalidateCursorRects(for: view)
    }

    /// A transparent view whose whole job is to declare "an open hand belongs
    /// here", so `resetCursorRects` — which AppKit calls on its own and on every
    /// `invalidateCursorRects` — has something to re-establish.
    final class CursorRectView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

/// What is being dragged, shared by every row without any of them observing it.
///
/// A class on purpose. As `@State`/`@Binding` this was SwiftUI state, so setting
/// it re-rendered every row twice per drag — once to start, once to finish — and
/// the second rebuild arrived after the drop and reset the pointer. A plain
/// reference is read the same way and changes nothing on screen.
@MainActor
final class DragState {
    var id: String?
}

/// A compact macOS-style colour choice. The outer ring makes pale colours and
/// the selected state visible against either appearance.
private struct AccentColorSwatch: View {
    let choice: AccentColorChoice
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.codenotchReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: select) {
            ZStack {
                Circle()
                    .fill(choice.color)
                    .frame(width: 16, height: 16)
                    .overlay {
                        Circle().strokeBorder(.primary.opacity(reduceTransparency ? 0.35 : 0.18), lineWidth: 1)
                    }

                Circle()
                    .strokeBorder(.primary, lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                    .opacity(isSelected ? 1 : 0)
            }
            // Exactly the selection ring, and no more. The frame was 24pt
            // around a 15pt dot, so every swatch carried 4.5pt of blank on
            // each side *before* the row's own spacing — which is what
            // spread eleven of them out across the pane.
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(choice.title)
        .accessibilityLabel(choice.title)
        .accessibilityValue(isSelected ? L10n.t("Selected") : L10n.t("Not selected"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One provider: whether Codenotch reads it, whose account that is, and where
/// to go if there is nothing to read.
/// One sound choice, with a preview button.
/// The column titles over the event rows.
private struct NotificationEventHeader: View {
    var body: some View {
        HStack(spacing: 16) {
            Text(L10n.t("Event"))
            Spacer(minLength: 0)
            Text(L10n.t("Notify")).frame(width: NotificationEventRow.toggleWidth)
            Text(L10n.t("Sound")).frame(width: NotificationEventRow.soundWidth, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, SettingsChrome.rowPaddingH)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// One event: whether it notifies, and with which sound ("Don't play" is
/// one of the sounds).
private struct NotificationEventRow: View {
    let title: String
    var description: String? = nil
    @Binding var isOn: Bool
    @Binding var sound: String

    static let toggleWidth: CGFloat = 52
    static let soundWidth: CGFloat = 186

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(SettingsChrome.titleFont)
                if let description {
                    Text(description).font(SettingsChrome.bodyFont).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
                .frame(width: Self.toggleWidth)
            HStack(spacing: 6) {
                Picker("", selection: $sound) {
                    Text(L10n.t("Don't play")).tag("")
                    Divider()
                    // A sound removed since it was chosen still has to appear,
                    // or the picker would silently show a different one.
                    if !sound.isEmpty, !SessionChime.available.contains(sound) {
                        Text(L10n.t("\(sound) (missing)")).tag(sound)
                    }
                    ForEach(SessionChime.available, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                .disabled(!isOn)
                SettingsIconButton(systemName: "play.fill", help: L10n.t("Play \(sound)")) {
                    _ = SessionChime.play(sound)
                }
                .disabled(sound.isEmpty)
                .opacity(sound.isEmpty ? 0.35 : 1)
            }
            .frame(width: Self.soundWidth, alignment: .leading)
        }
        .padding(.horizontal, SettingsChrome.rowPaddingH)
        .padding(.vertical, SettingsChrome.rowPaddingV)
    }
}

private struct AccountRow: View {
    let provider: ProviderSummary
    @ObservedObject var preferences: Preferences
    let signOut: (String) -> Void
    let signIn: (String) -> Bool
    let switchAccount: (String) -> Bool
    let retry: (String) -> Void
    let refresh: (String) -> Void
    /// Whether this row has a place in the notch to argue about. A provider
    /// switched off draws no ring, so there is nothing for a drag to arrange.
    let isOrderable: Bool
    /// The provider in flight, shared with every other row: this one has to
    /// know what is being dragged the moment the pointer arrives, not once it
    /// is released.
    let drag: DragState
    /// Changes on every drop; handed straight to `GrabCursor`, which uses the
    /// change itself rather than the value.
    let cursorRefresh: Int
    /// Tells the list a drop landed, so the cursor rects get re-evaluated while
    /// the pointer is still standing on the grip.
    let onDrop: () -> Void
    /// Move the dragged provider into this row's place. False when the id is
    /// not one of ours.
    let takePlaceOf: (String) -> Bool
    /// Called after this row is switched on, so the list can decide where it
    /// now belongs. The row itself cannot: it can see only itself.
    let didConnect: () -> Void
    /// Takes a switched-off source off the list, back to the Add menu. Nil
    /// while it is on: a ring in the notch is not something to delete.
    var onRemove: (() -> Void)? = nil

    @Environment(\.codenotchReduceTransparency) private var reduceTransparency

    /// The handle only appears under the pointer, so a row at rest stays as
    /// quiet as it was before there was anything to drag.
    @State private var isHovering = false

    private var isConnected: Bool { preferences.isConnected(provider.id) }
    private var isMuted: Bool { preferences.isMutedAlerts(for: provider.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Centred, not baseline-aligned. A glyph is a `Shape` and has no
            // text baseline, so `.firstTextBaseline` lines its *bottom edge* up
            // with the text's baseline and lifts every icon above its own name.
            // Everything on this row is a single line, so centring is what makes
            // the mark, the name, the button and the switch sit on one axis.
            HStack(alignment: .center, spacing: 10) {
                // Grip, mark and name are one grab area: a 12pt square is a
                // blank to hit, and none of the three do anything else. The
                // buttons and the switch stay out — a drag would compete.
                HStack(spacing: 12) {
                    if isOrderable { handle }

                    // The mark on a tile, the way an app lists what it has
                    // installed: one size for every source, whatever its glyph.
                    ProviderGlyphView(glyph: provider.glyph, customIconFilename: provider.customIconFilename, size: 18)
                        .foregroundStyle(isConnected ? .primary : .tertiary)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name)
                            .font(SettingsChrome.titleFont)
                            .foregroundStyle(isConnected ? .primary : .secondary)
                        detail
                            .font(SettingsChrome.bodyFont)
                    }
                }
                // Without this only the drawn pixels are grabbable, and the
                // gaps between the three of them are not.
                .contentShape(Rectangle())
                // `onDrag` rather than `draggable`, for its one advantage: it
                // runs a closure when the drag *starts*. Every other row needs
                // to know what is coming before it can make room for it, and
                // `dropDestination` does not hand over its payload until the
                // drop.
                .onDrag {
                    // A row with no ring has nothing to place. Handing back an
                    // empty provider is how `onDrag` declines a drag.
                    guard isOrderable else { return NSItemProvider() }
                    drag.id = provider.id
                    return NSItemProvider(object: provider.id as NSString)
                } preview: {
                    // The name alone, not the row: dragging the switch, the
                    // buttons and two lines of explanation across the window is
                    // a lot of translucent furniture to move a ring one place
                    // up.
                    HStack(spacing: 6) {
                        ProviderGlyphView(glyph: provider.glyph, size: 12)
                        Text(provider.name)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .help(isOrderable
                      ? L10n.t("Drag to reorder. The notch draws the rings in this order.")
                      : L10n.t("Switch this on to give it a ring in the notch."))
                // Two mechanisms, neither of which covers both halves.
                // `pointerStyle` draws the hand on an ordinary hover but cannot
                // re-evaluate under a pointer that has not moved, which is the
                // state a finished drag leaves behind; the cursor rect exists
                // only so `invalidateCursorRects` can force that.
                //
                // It must sit *over* the content — behind it, SwiftUI's own
                // pointer regions win and the rect is never consulted at all —
                // and it must not take hits, or it swallows the drag.
                .pointerStyle(isOrderable ? .grabIdle : nil)
                .overlay {
                    if isOrderable {
                        GrabCursor(refreshToken: cursorRefresh)
                            .allowsHitTesting(false)
                    }
                }

                Spacer(minLength: 8)

                // Per-provider threshold alerts, muted here rather than in a
                // separate notifications pane — the thing being muted is this
                // row's reading, so the control belongs on the row.
                if isConnected, provider.kind == .usage {
                    SettingsIconButton(systemName: isMuted ? "bell.slash" : "bell",
                                       tint: isMuted ? Color.secondary.opacity(0.6) : .secondary,
                                       help: isMuted
                                           ? L10n.t("Alerts for \(provider.name) are muted. Click to unmute.")
                                           : L10n.t("Alert when \(provider.name) crosses 80% and 100% of a limit.")) {
                        preferences.setAlertsMuted(!isMuted, for: provider.id)
                    }
                }
                if let onRemove {
                    SettingsIconButton(systemName: "trash",
                                       help: L10n.t("Remove \(provider.name) from the list. It goes back to the Add menu."),
                                       action: onRemove)
                }

                // Prefers the app that owns the account, and falls back to the
                // web page only when there is no app to open.
                //
                // The reading is borrowed from an app on this Mac, so that app
                // is where the account actually lives — and the website is a
                // different session entirely, which will bounce you to a login
                // if the browser is not signed in. Sending someone to a login
                // screen from a row that says "connected" is the wrong answer
                // whenever the real thing is one launch away.
                // The way back from a declined keychain prompt, and the only
                // one: declining is easy to do by reflex, and nothing else on
                // screen will ask macOS again.
                //
                // Shown only while macOS is actually refusing. It used to be
                // permanent for any keychain-backed provider, which meant it sat
                // there next to a working account offering to fix nothing — and
                // when it *was* needed there was no way to tell the two apart.
                if isConnected, provider.wasRefusedAccess {
                    Button(L10n.t("Allow access…")) { retry(provider.id) }
                        .controlSize(.small)
                        // Not "it will stop asking": for Claude it will not.
                        // Claude Code recreates its login when the token
                        // rotates, and a recreated item forgets the grant.
                        .help(L10n.t("Asks macOS for \(provider.name)'s saved login again. Always Allow means it is asked less often."))
                }

                if isConnected, let destination {
                    Button(destination.title) { open(destination) }
                        .controlSize(.small)
                        .help(destination.help)
                }

                Toggle(provider.name, isOn: binding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(provider.localModel != nil
                          ? L10n.t("Show or hide this model in the notch. It stays loaded in \(provider.runtimeName ?? "Ollama").")
                          : isConnected
                          ? L10n.t("Switch off to stop reading \(provider.name) and forget its readings. \(provider.signIn.signOutCaveat)")
                          : L10n.t("Switch on to sign in and read \(provider.name) again."))
            }

            // Outside `detail` on purpose. That chain shows the account summary
            // whenever there is an account, and an aged-out token still has
            // one — the credential is there, it is simply too old to use. Put
            // inside, this warning would be swallowed by the very row that
            // makes everything look fine.
            if isConnected, provider.needsSignInRenewal {
                Text(L10n.t("\(provider.name) usage needs its sign-in renewed — run `claude` once in a terminal."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 60)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The whole row is the drop target, handle or not: a 12pt strip is a
        // hard thing to hit, and there is no ambiguity about which row the
        // pointer is over.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .dropDestination(for: String.self) { ids, _ in
            defer { drag.id = nil }
            guard isOrderable else { return false }
            // AppKit resets the cursor when a drag session ends and will not ask
            // what belongs here again until the mouse next moves — so releasing
            // the button and holding still left an arrow on a grip that was
            // perfectly grabbable. Setting a cursor by hand loses that race
            // whatever the timing, because the reset lands last; asking AppKit
            // to re-evaluate the rects does not race it at all.
            onDrop()
            // The list already settled on the way in. This only answers whether
            // what was released was ever ours.
            guard let moved = ids.first else { return false }
            return takePlaceOf(moved)
        } isTargeted: { entered in
            // The rearrangement happens here, not on the drop: the pointer
            // crossing into this row is the whole gesture, and the rows sliding
            // out of the way is what says where the ring will land.
            guard isOrderable, entered, let moved = drag.id, moved != provider.id
            else { return }
            withAnimation(.snappy(duration: 0.22)) { _ = takePlaceOf(moved) }
        }
    }

    /// The affordance only. The drag itself is on the whole group around it,
    /// because this is far too small a thing to have to hit.
    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            // Always drawn, only dimmer at rest. It used to be invisible until
            // hovered, and hover is exactly the state a drag leaves stale: the
            // reorder moves the row out from under a pointer that has not
            // itself moved, so no further hover event arrives and the grip
            // stayed gone until the pointer left the row and came back. Dimming
            // cannot fail that way — the worst a stale `isHovering` costs now
            // is a little emphasis.
            .opacity(isHovering ? 1 : (reduceTransparency ? 0.7 : 0.4))
            // Tall enough to be part of a real target rather than a 13pt strip
            // floating in the middle of the row.
            .frame(width: 12, height: 22)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            accountDetail
            
            // Antigravity limit dropdown
            if isConnected, provider.id == "gemini" {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(L10n.t("Notch reads"))
                            .foregroundStyle(.secondary)
                        Picker(L10n.t("Notch reads"), selection: $preferences.antigravityHeadlineLimit) {
                            ForEach(AntigravityHeadlineLimit.allCases) { limit in
                                Text(limit.title).tag(limit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                    
                    HStack(spacing: 8) {
                        Text(L10n.t("Model data"))
                            .foregroundStyle(.secondary)
                        Picker(L10n.t("Model data"), selection: $preferences.antigravityHeadlineModel) {
                            ForEach(AntigravityHeadlineModel.allCases) { model in
                                Text(model.explanation).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                }
                .padding(.top, 2)
                .help(L10n.t("Choose which limit appears in the main notch for Antigravity."))
                .onChange(of: preferences.antigravityHeadlineLimit) { _ in
                    refresh(provider.id)
                }
                .onChange(of: preferences.antigravityHeadlineModel) { _ in
                    refresh(provider.id)
                }
            }

            // Google publishes no limit for a bare API key, so the ring has
            // nothing to fill against until the user names a ceiling itself.
            if isConnected, provider.id == "gemini-api" {
                // The field's own title would be drawn as a leading label
                // inside a `Form` row, which puts the caption hard against
                // the box and leaves the unit stranded past it. Hidden, so
                // the caption above can own the naming and the row can
                // breathe.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Monthly budget"))
                    HStack(spacing: 8) {
                        TextField(L10n.t("None"), value: $preferences.geminiAPIMonthlyTokenBudget,
                                  format: .number)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 130)
                        Text(L10n.t("tokens"))
                    }
                }
                .padding(.top, 2)
                .foregroundStyle(.secondary)
                .help(L10n.t("Fills the ring against a ceiling you choose; Google publishes none for an API key."))
            }
            // Ollama owns its credential: the user enters an API key here, stored
            // in the keychain. The env var OLLAMA_API_KEY is checked first, so a
            // shell that exports one needs no entry here.
            if provider.id == "ollama" {
                ollamaKeyEntry
            }

            // MiniMax is signed into in Codenotch, or by a Coding Plan key
            // pasted here. The region is which console that key belongs to.
            // Stored in the keychain on Save, the same way Ollama's is.
            if provider.id == "minimax" {
                minimaxEntry
            }
        }
    }

    /// The API key input for Ollama. Stored in the keychain on Save, then a
    /// refresh is triggered so the ring picks up the new credential without a
    /// relaunch.
    @State private var ollamaKey = ""
    @State private var ollamaKeySaved = false

    private var ollamaKeyEntry: some View {
        // Laid out like the Gemini budget above it, and for the same reason:
        // a field's own title becomes a leading label in a `Form` row, which
        // crowds the box and pins it to the caption. The caption goes on its
        // own line instead, and `.small` comes off the controls — it bought
        // nothing but a cramped row.
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("Ollama API key"))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SecureField(L10n.t("Paste your key"), text: $ollamaKey)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                Button(L10n.t("Save")) {
                    guard !ollamaKey.isEmpty else { return }
                    OllamaCredentials.store(ollamaKey)
                    ollamaKey = ""
                    ollamaKeySaved = true
                    _ = signIn(provider.id)
                }
                .disabled(ollamaKey.isEmpty)
                if ollamaKeySaved {
                    Text(L10n.t("Saved"))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.top, 2)
    }

    /// Region and Coding Plan key for MiniMax.
    ///
    /// Laid out like the Ollama key above it, and for the same reason: a
    /// field's own title becomes a leading label in a `Form` row. Captions
    /// sit on their own line. Changing the region only stores the choice —
    /// opening Sign in here would throw a sheet over a preference picker.
    @State private var minimaxKey = ""
    @State private var minimaxKeySaved = false
    @State private var minimaxCookie = ""
    @State private var minimaxCookieSaved = false

    private var minimaxEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Region"))
                    .foregroundStyle(.secondary)
                Picker(selection: $preferences.minimaxRegion) {
                    Text(L10n.t("International")).tag(MiniMaxRegion.international)
                    Text(L10n.t("China mainland")).tag(MiniMaxRegion.china)
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            minimaxKeyEntry
            minimaxCookieEntry

            Text(L10n.t("Sign in to MiniMax in Codenotch, or paste a Coding Plan key. A Cookie header is optional. Codenotch never reads a browser's cookies."))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private var minimaxKeyEntry: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("MiniMax Coding Plan key"))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SecureField(L10n.t("Paste your key"), text: $minimaxKey)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                Button(L10n.t("Save")) {
                    guard !minimaxKey.isEmpty else { return }
                    MiniMaxCredentials.storeAPIKey(minimaxKey)
                    minimaxKey = ""
                    minimaxKeySaved = true
                    _ = signIn(provider.id)
                }
                .disabled(minimaxKey.isEmpty)
                if minimaxKeySaved {
                    Text(L10n.t("Saved"))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var minimaxCookieEntry: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("Cookie header (optional)"))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SecureField(L10n.t("Cookie: …"), text: $minimaxCookie)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                Button(L10n.t("Save")) {
                    guard !minimaxCookie.isEmpty else { return }
                    MiniMaxCredentials.storeCookieHeader(minimaxCookie)
                    minimaxCookie = ""
                    minimaxCookieSaved = true
                    _ = signIn(provider.id)
                }
                .disabled(minimaxCookie.isEmpty)
                if minimaxCookieSaved {
                    Text(L10n.t("Saved"))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder
    private var accountDetail: some View {
        if let model = provider.localModel {
            Text(isConnected ? L10n.t("\(model.memoryText) \(model.memoryLabel) · via \(provider.runtimeName ?? "Ollama")")
                 : L10n.t("Hidden from the notch · Loaded in \(provider.runtimeName ?? "Ollama")"))
                .foregroundStyle(.secondary)
        } else if !isConnected {
            Text(L10n.t("Signed out — nothing is read, and no readings are kept."))
                .foregroundStyle(.tertiary)
        } else if let account = provider.account {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(account.summary)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if canOpenSignIn {
                        Button(L10n.t("Switch…")) { _ = switchAccount(provider.id) }
                            .buttonStyle(.link)
                            .help(provider.signIn.switchHint)
                    }
                }
                // Says where the account actually lives, which is the whole
                // answer to "how do I change it" — not here.
                Text(provider.signIn.switchHint)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if provider.wasRefusedAccess {
            // Not a sign-in problem, so do not send them off to sign in. The
            // credential is right there and macOS is the one saying no — the
            // remedy is the button on this same row.
            Text(L10n.t("macOS is not letting Codenotch read \(provider.name)'s saved login. Choose Allow access… above, then Always Allow."))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                Text(provider.signIn.explanation)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = provider.signIn.actionTitle, canOpenSignIn {
                    Button(title) { _ = signIn(provider.id) }
                        .controlSize(.small)
                }

            }
        }
    }

    /// Where this row's "Open" button goes.
    enum Destination {
        case app(URL, name: String)
        case website(URL, host: String)

        var title: String {
            switch self {
            case .app(_, let name):     return L10n.t("Open \(name)")
            case .website(_, let host): return L10n.t("Open \(host)")
            }
        }

        var help: String {
            switch self {
            case .app(_, let name):
                return L10n.t("Opens \(name), which is where this account is signed in.")
            case .website(_, let host):
                return L10n.t("Opens \(host) in your browser. That site has its own sign-in, separate from the credential read here.")
            }
        }
    }

    /// The owning app when it is installed, the vendor's page otherwise.
    private var destination: Destination? {
        if case .openApp(let bundleID, let name) = provider.signIn,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return .app(app, name: name)
        }
        // Claude Code is a command with no app to open, so its row is always a
        // link — and claude.ai is genuinely where its usage can be checked.
        if let url = provider.account?.manageURL, let host = url.host {
            return .website(url, host: host)
        }
        return nil
    }

    private func open(_ destination: Destination) {
        switch destination {
        case .app(let url, _):
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .website(let url, _):
            NSWorkspace.shared.open(url)
        }
    }

    /// Offering to open an app that isn't installed gives a button that does
    /// nothing — worse than no button.
    private var canOpenSignIn: Bool {
        switch provider.signIn {
        case .modal:
            return true
        case .openApp(let bundleID, _):
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        case .guidance:
            return false
        }
    }

    /// One control for both directions: on signs in, off signs out.
    ///
    /// Switching on does more than set a flag — if there is no credential to
    /// read it opens the sign-in there and then, which is the point of managing
    /// this from one place. Switching off is a real sign-out: it forgets the
    /// readings as well as stopping the next one.
    private var binding: Binding<Bool> {
        Binding(
            get: { preferences.isConnected(provider.id) },
            set: { wantsOn in
                if wantsOn {
                    preferences.setConnected(true, for: provider.id)
                    // After the switch, not before: where it belongs depends on
                    // which providers are connected, and this one has only just
                    // become one of them.
                    didConnect()
                    // Nothing to open for Claude Code — but then there is no
                    // account either, so `detail` is already showing what to do.
                    if provider.localModel == nil { _ = signIn(provider.id) }
                } else {
                    if provider.localModel == nil { signOut(provider.id) }
                    preferences.setConnected(false, for: provider.id)
                }
            }
        )
    }

}

extension SettingsView {
    @ViewBuilder
    private var phonePane: some View {
        if let pairing = phoneLinkPairing, let registry = phoneLinkRegistry, let status = phoneLinkServerStatus {
            PhoneSettingsPane(preferences: preferences, pairing: pairing, registry: registry, serverStatus: status)
        } else {
            Text("Phone linking is not available.")
        }
    }
}

struct PhoneSettingsPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var pairing: PhoneLinkPairing
    @ObservedObject var registry: PhoneLinkRegistry
    @ObservedObject var serverStatus: PhoneLinkServerStatus
    
    @State private var deviceToRemove: PairedDevice?
    
    private func lastSeenText(for device: PairedDevice) -> String {
        let diff = Date().timeIntervalSince(device.lastSeenAt)
        if diff < 60 {
            return "Active now"
        }
        if device.lastSeenAt == device.pairedAt {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return "Paired \(df.string(from: device.pairedAt))"
        }
        let rf = RelativeDateTimeFormatter()
        rf.unitsStyle = .full
        return "Last seen \(rf.localizedString(for: device.lastSeenAt, relativeTo: Date()))"
    }
    
    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.phoneLinkEnabled) {
                    Text(L10n.t("Allow phones on this network"))
                    Text(L10n.t("Your phone reads usage from this Mac over your Wi-Fi. Nothing leaves your network."))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    switch serverStatus.state {
                    case .off:
                        Circle().fill(Color.gray).frame(width: 8, height: 8)
                        Text(L10n.t("Off"))
                    case .starting:
                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                        Text(L10n.t("Starting…"))
                    case .ready(let port):
                        let hosts = PhoneLinkNetwork.getHosts()
                        let hasIP = hosts.first(where: { PhoneLinkNetwork.isPrivateIPv4($0) }) != nil
                        if hasIP {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text(L10n.t("Ready on \(hosts.first ?? ""):\(String(port))"))
                        } else {
                            Circle().fill(Color.orange).frame(width: 8, height: 8)
                            Text(L10n.t("This Mac isn't on a local network"))
                        }
                    case .failed(let err):
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text(err)
                    }
                }
                
                Button(L10n.t("Connect a Phone…")) {
                    if !preferences.phoneLinkEnabled {
                        preferences.phoneLinkEnabled = true
                    }
                    PhoneLinkWindowController.shared.show(pairing: pairing, registry: registry, port: preferences.phoneLinkPort, serverStatus: serverStatus)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            
            Section(L10n.t("Paired phones")) {
                if registry.discardedLegacyDevices {
                    Text(L10n.t("Re-pair your phone after updating"))
                        .foregroundColor(.orange)
                }
                if registry.devices.isEmpty {
                    Text(L10n.t("No phones yet."))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(registry.devices) { device in
                        HStack {
                            Image(systemName: device.platform == "ios" ? "iphone" : "smartphone")
                                .font(.title2)
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(lastSeenText(for: device))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(L10n.t("Remove")) {
                                deviceToRemove = device
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert(item: Binding<PairedDevice?>(
            get: { deviceToRemove },
            set: { deviceToRemove = $0 }
        )) { device in
            Alert(
                title: Text(L10n.t("Remove “\(device.name)”?")),
                message: Text(L10n.t("It will need to scan a new code to connect again.")),
                primaryButton: .destructive(Text(L10n.t("Remove"))) {
                    registry.remove(deviceId: device.deviceId)
                },
                secondaryButton: .cancel()
            )
        }
    }
}
