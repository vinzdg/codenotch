import SwiftUI

/// The pieces every Settings pane is built from: a page that scrolls on the
/// window's own edge, cards of rows, and a row that says what a setting is
/// and what it does before it offers the control.
///
/// The shape is the one macOS utilities have settled on (System Settings,
/// the ChatGPT app): a measured column of white cards on a plain pane, a
/// title and a sentence per row, the control on the right. Nothing here
/// draws its own control chrome; toggles, pickers and buttons stay native.
enum SettingsChrome {
    static let measure: CGFloat = 820
    static let gutter: CGFloat = 40
    static let cardCorner: CGFloat = 12
    static let rowPaddingH: CGFloat = 16
    static let rowPaddingV: CGFloat = 12
    static let groupSpacing: CGFloat = 28

    static var cardFill: Color { Color(nsColor: .controlBackgroundColor) }
    static var cardStroke: Color { Color.primary.opacity(0.09) }
    static var paneFill: Color { Color(nsColor: .textBackgroundColor) }
    static var sidebarFill: Color { Color(nsColor: .underPageBackgroundColor) }

    static let titleFont = Font.system(size: 13, weight: .medium)
    static let bodyFont = Font.system(size: 12)
    static let groupFont = Font.system(size: 13, weight: .semibold)
}

/// A pane's scrolling body. The scroll view spans the pane, so the scroll
/// bar sits on the window's edge; the column inside it keeps a reading
/// measure and is centred like a page.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SettingsChrome.groupSpacing) {
                content()
            }
            .frame(maxWidth: SettingsChrome.measure, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SettingsChrome.gutter)
            .padding(.top, 6)
            .padding(.bottom, 48)
        }
    }
}

/// A titled card of rows, with an optional line under it.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(SettingsChrome.groupFont)
                    .padding(.leading, 2)
            }
            _VariadicView.Tree(SettingsCardLayout()) { content() }
            if let footer {
                Text(footer)
                    .font(SettingsChrome.bodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Stacks a card's rows with a hairline between each pair, on one surface.
struct SettingsCardLayout: _VariadicView_UnaryViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Divider().padding(.leading, SettingsChrome.rowPaddingH)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                .fill(SettingsChrome.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                .strokeBorder(SettingsChrome.cardStroke, lineWidth: 1)
        )
    }
}

/// One setting: its name and what it does on the left, the control on the
/// right. A row that wraps its control under the text is the exception,
/// for sliders and swatches that need the width.
struct SettingsRow<Control: View>: View {
    let title: String
    var description: String? = nil
    var stacked = false
    @ViewBuilder let control: () -> Control

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 10) {
                    text
                    control()
                }
            } else {
                HStack(alignment: .center, spacing: 24) {
                    text
                    Spacer(minLength: 0)
                    control()
                }
            }
        }
        .padding(.horizontal, SettingsChrome.rowPaddingH)
        .padding(.vertical, SettingsChrome.rowPaddingV)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(SettingsChrome.titleFont)
            if let description {
                Text(description)
                    .font(SettingsChrome.bodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A switch row.
struct SettingsToggleRow: View {
    let title: String
    var description: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, description: description) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// A line of explanation on its own, inside a card.
struct SettingsNote: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(SettingsChrome.bodyFont)
            .foregroundStyle(tint ?? .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsChrome.rowPaddingH)
            .padding(.vertical, SettingsChrome.rowPaddingV)
    }
}

/// Any content as a card row, with the card's padding.
struct SettingsCell<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsChrome.rowPaddingH)
            .padding(.vertical, SettingsChrome.rowPaddingV)
    }
}

/// A small round icon button, visible at rest and plainly a button under
/// the pointer: the bell, the pencil, the play button on a row.
struct SettingsIconButton: View {
    let systemName: String
    var tint: Color = .secondary
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? .primary : tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0.05)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
