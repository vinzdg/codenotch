import SwiftUI

/// The slash commands that fit what is typed, inside the pill above its
/// text, like Claude Code's own list: the highlighted one is what Return runs.
struct DockSlashRows: View {
    @AppStorage(Preferences.codedockLookKey) private var look = "dark"
    private var theme: DockTheme { DockTheme(rawValue: look) ?? .dark }
    @ObservedObject var model: DockChatModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let rowHeight: CGFloat = 25
    static let inset: CGFloat = 8

    /// What the rows add to the pill's height.
    static func height(rows: Int) -> CGFloat {
        rows == 0 ? 0 : CGFloat(rows) * rowHeight + inset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.slashMatches.enumerated()), id: \.element.id) { index, command in
                Button(action: {}) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("/\(command.name)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(index == model.slashIndex ? theme.working : theme.ink.opacity(0.9))
                            .lineLimit(1)
                            .fixedSize()
                        Text(command.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.ink.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        if command.opensInTerminal {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.ink.opacity(0.35))
                                .help(L10n.t("Opens in its terminal"))
                        } else if command.choices != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(theme.ink.opacity(0.35))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Self.rowHeight)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.ink.opacity(index == model.slashIndex ? 0.1 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .highPriorityGesture(TapGesture().onEnded { model.acceptSlash(send: false, at: index) })
                .onHover { if $0 { model.slashIndex = index } }
            }
        }
        .animation(.easeOut(duration: 0.1), value: model.slashIndex)
    }
}

/// What the session is asking, inside the pill above its text: the question,
/// and a row for each answer, with the number its terminal takes for it.
struct DockQuestionRows: View {
    @AppStorage(Preferences.codedockLookKey) private var look = "dark"
    private var theme: DockTheme { DockTheme(rawValue: look) ?? .dark }
    let question: ClaudePendingQuestion
    var highlighted: Int = 0
    var highlight: (Int) -> Void = { _ in }
    let answer: (ClaudePendingQuestion.Choice) -> Void

    static let titleHeight: CGFloat = 22

    static func height(for question: ClaudePendingQuestion) -> CGFloat {
        titleHeight + CGFloat(question.choices.count) * DockSlashRows.rowHeight + DockSlashRows.inset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(question.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.working)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(height: Self.titleHeight, alignment: .leading)
            ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                DockQuestionRow(choice: choice, selected: index == highlighted,
                                hover: { highlight(index) }) { answer(choice) }
            }
        }
        .animation(.easeOut(duration: 0.1), value: highlighted)
    }
}

private struct DockQuestionRow: View {
    @AppStorage(Preferences.codedockLookKey) private var look = "dark"
    private var theme: DockTheme { DockTheme(rawValue: look) ?? .dark }
    let choice: ClaudePendingQuestion.Choice
    var selected = false
    var hover: () -> Void = {}
    let pick: () -> Void

    var body: some View {
        Button(action: {}) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(choice.key)
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(theme.ink.opacity(0.5))
                    .frame(width: 12)
                Text(choice.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? theme.working : theme.ink.opacity(0.92))
                    .lineLimit(1)
                    .fixedSize()
                Text(choice.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.ink.opacity(0.42))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: DockSlashRows.rowHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.ink.opacity(selected ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(TapGesture().onEnded(pick))
        .onHover { if $0 { hover() } }
    }
}
