import AppKit
import SwiftUI

/// Every session, grouped by repository and branch, in a card that springs up
/// above the pill — the arrow's list. Codedock's own rather than a system
/// menu, so it can move: the card grows out of the arrow, and its rows come
/// in one after another.
struct DockSessionList: View {
    @ObservedObject var model: DockChatModel
    /// Set once the window is on screen, so the card animates in rather than
    /// appearing already open; cleared to animate it out before it closes.
    var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 280

    var body: some View {
        let rows = rowsInOrder
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Group {
                    switch row {
                    case .header(let title):
                        Text(title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.top, index == 0 ? 2 : 8)
                            .padding(.bottom, 2)
                    case .session(let target):
                        DockSessionRow(target: target,
                                       selected: target.id == model.selected?.id,
                                       subtitle: model.subtitle(for: target)) {
                            model.pick(target.id)
                        }
                    }
                }
                // One after another, from the top.
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 6)
                .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82)
                    .delay(shown ? Double(index) * 0.025 : 0), value: shown)
            }
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .background {
                    if #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(12)
        // Grows out of the arrow, at its bottom right.
        .scaleEffect(shown ? 1 : 0.9, anchor: .bottomTrailing)
        .opacity(shown ? 1 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: shown)
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum Row {
        case header(String)
        case session(DockChatModel.Target)
    }

    private var rowsInOrder: [Row] {
        model.groups.flatMap { group in
            [Row.header(group.title)] + group.targets.map { Row.session($0) }
        }
    }
}

private struct DockSessionRow: View {
    let target: DockChatModel.Target
    let selected: Bool
    let subtitle: String
    let pick: () -> Void
    @State private var hovered = false
    @AppStorage(Preferences.codedockLookKey) private var look = "dark"
    private var theme: DockTheme { DockTheme(rawValue: look) ?? .dark }

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.ink)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.ink.opacity(0.92))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.ink.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if target.state == .busy {
                    ClaudeSpinnerGlyph(active: true, size: 11)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: DockSessionRows.rowHeight)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.ink.opacity(hovered ? 0.1 : selected ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(TapGesture().onEnded(pick))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

/// A card's window above the pill — the session list, the slash commands:
/// floats there, takes the first click, and is put away by a click anywhere
/// else or Escape. The card animates in and out; the window only holds it.
@MainActor
final class DockPopover {
    private let panel: NSPanel
    private let host: FirstClickHostingView<AnyView>
    private let content: (Bool) -> AnyView
    private let dismiss: () -> Void
    private var monitors: [Any] = []
    private var closing: DispatchWorkItem?
    private var anchor: NSRect = .zero

    init(content: @escaping (_ shown: Bool) -> AnyView, dismiss: @escaping () -> Void) {
        self.content = content
        self.dismiss = dismiss
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Its card draws its own shadow; see DockChatPanel.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        host = FirstClickHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        panel.contentView = host
    }

    var isOpen: Bool { panel.isVisible && closing == nil }

    /// Opens above `anchor` — the pill's frame — its right edge on the
    /// pill's right edge.
    func open(above anchor: NSRect) {
        closing?.cancel()
        closing = nil
        self.anchor = anchor
        host.rootView = content(false)
        fit()
        panel.orderFrontRegardless()
        // Next turn, so the card is laid out closed before it animates open.
        DispatchQueue.main.async { self.host.rootView = self.content(true) }
        watchForDismissal()
    }

    /// Its content has grown or shrunk: the window follows, bottom fixed.
    func fit() {
        let size = host.fittingSize
        var origin = NSPoint(x: anchor.maxX - size.width, y: anchor.maxY + 8)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            origin.x = min(max(origin.x, screen.frame.minX + 6), screen.frame.maxX - size.width - 6)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func close() {
        guard panel.isVisible, closing == nil else { return }
        stopWatching()
        host.rootView = content(false)
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.closing = nil
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func watchForDismissal() {
        stopWatching()
        // A click in another app, or on the desktop.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(global) }
        // Escape, or a click in Codenotch outside the card — except on the
        // pill, whose own controls open and close it.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            if event.type == .leftMouseDown, event.window !== self.panel,
               event.window?.contentView is FirstClickHostingView<DockChatView> == false {
                self.dismiss()
            }
            return event
        }) { monitors.append(local) }
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

/// Every session, grouped by repository and branch, inside the pill above
/// its row — the arrow's list, grown upward like the slash commands.
struct DockSessionRows: View {
    @ObservedObject var model: DockChatModel
    @AppStorage(Preferences.codedockLookKey) private var look = "dark"
    private var theme: DockTheme { DockTheme(rawValue: look) ?? .dark }

    static let rowHeight: CGFloat = 36
    static let headerHeight: CGFloat = 20

    /// What the list adds to the pill's height, up to the room there is;
    /// past that it scrolls.
    static func height(groups: [(title: String, targets: [DockChatModel.Target])]) -> CGFloat {
        let rows = groups.reduce(0) { $0 + $1.targets.count }
        let natural = CGFloat(groups.count) * headerHeight + CGFloat(rows) * rowHeight + DockSlashRows.inset + 4
        return min(natural, DockChatController.roomAbove - 6)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.groups, id: \.title) { group in
                    Text(group.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.ink.opacity(0.4))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: Self.headerHeight, alignment: .bottomLeading)
                    ForEach(group.targets) { target in
                        DockSessionRow(target: target, selected: target.id == model.selected?.id,
                                       subtitle: model.subtitle(for: target)) {
                            model.pick(target.id)
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }
}
