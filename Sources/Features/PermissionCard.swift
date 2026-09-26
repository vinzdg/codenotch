import SwiftUI

/// The card that answers Claude Code from the notch: the terminal's own
/// choices for a tool that wants to run, or the options of an
/// `AskUserQuestion`.
///
/// Built like `UsageResetCard` — same surface, tail, glass handling and title
/// face — so it reads as the same notch saying something new. Wider than the
/// tooltip, with larger text, because it carries a command or a diff that has
/// to be read before it is answered. Its height is computed rather than
/// measured (`height(for:)`), because the panel's hit region is solved from it
/// before anything is drawn.
struct PermissionCard: View {
    let request: PermissionRequest
    /// How many more are queued behind this one.
    let queued: Int
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    /// Which of an `AskUserQuestion`'s questions is showing. Held by the
    /// model, not here, because the controller hit-tests the rows and has to
    /// know which question's rows it is looking at.
    var questionIndex = 0
    /// The choice under the pointer, decided by `NotchWindowController` —
    /// SwiftUI's own hover only sees this panel some of the time.
    var hoveredChoice: Int? = nil
    /// The pointer is on "Answer in <app>", decided by the controller.
    var appLinkHovered = false
    /// The screen's height budget; see `NotchViewModel.permissionCardLimit`.
    var heightLimit: CGFloat = .infinity
    let onDecide: (PermissionDecision) -> Void
    var onNextQuestion: () -> Void = {}

    @State private var answers: [String: String] = [:]

    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @Environment(\.notchSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    // MARK: Metrics

    static let width = NotchLayout.permissionCardWidth
    static let previewLimit = 6
    /// `AskUserQuestion` offers at most four; the terminal's "Yes, and…" rows
    /// are one or two in practice.
    static let optionLimit = 4
    static let suggestionLimit = 3
    static let rowHeight = Design.px(84)
    static let rowGap = Design.px(16)
    static let codePadding = Design.px(18)
    /// Between the header, the tool or question line, the preview and the
    /// choices. Looser than the tooltip's `blockSpacing`: this card is read
    /// and answered, not glanced at.
    static let sectionGap = Design.px(28)
    static let padding = Design.px(40)
    static let badgeSize = Design.px(50)
    static let appLinkHeight = Design.px(60)
    static let appLinkGap = Design.px(20)
    static let appLinkPadding = Design.px(26)

    static func appLinkTitle(for request: PermissionRequest) -> String {
        L10n.t("Answer in \(request.appName ?? L10n.t("terminal"))")
    }

    /// The button's width: its label measured in the body face, plus the
    /// arrow, the gap before it and the capsule's padding. Measured so the
    /// title keeps every point the button does not need.
    static func appLinkWidth(for request: PermissionRequest) -> CGFloat {
        let font = NSFontManager.shared.convert(bodyNSFont, toHaveTrait: .boldFontMask)
        let label = (appLinkTitle(for: request) as NSString).size(withAttributes: [.font: font]).width
        return ceil(label) + Design.px(10) + Design.fontSize(capPixels: 17) * 1.2 + 2 * appLinkPadding
    }

    /// Where "Answer in <app>" sits, in card coordinates: centred under the
    /// choices, at the foot of the card. The controller hit-tests this for the
    /// pointing hand.
    static func appLinkRect(for request: PermissionRequest, limit: CGFloat) -> CGRect {
        let linkWidth = appLinkWidth(for: request)
        return CGRect(x: (width - linkWidth) / 2,
                      y: height(for: request, limit: limit) - padding - appLinkHeight,
                      width: linkWidth, height: appLinkHeight)
    }

    static let bodyNSFont = NSFont.systemFont(ofSize: Design.fontSize(capPixels: 23), weight: .regular)
    static let codeNSFont = NSFont.monospacedSystemFont(ofSize: Design.fontSize(capPixels: 17), weight: .regular)
    static let bodyFont = Font(bodyNSFont)
    static let codeFont = Font(codeNSFont)
    static let bodyLine = NotchLayout.lineHeight(bodyNSFont)
    static let codeLine = NotchLayout.lineHeight(codeNSFont) + Design.px(6)

    private static var textWidth: CGFloat { width - 2 * Self.padding }
    private static var header: CGFloat {
        max(NotchLayout.glyphSize, NotchLayout.cardTitleLineHeight + NotchLayout.cardBodyLineHeight)
    }

    private static func rows(_ count: Int) -> CGFloat {
        CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * rowGap
    }

    private static func previewHeight(_ lines: Int) -> CGFloat {
        lines == 0 ? 0 : Self.sectionGap + 2 * codePadding + CGFloat(lines) * codeLine
    }

    /// Question text, wrapped to the card and capped at three lines.
    private static func questionHeight(_ text: String) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: bodyNSFont]
        )
        return CGFloat(min(3, max(1, Int((bounds.height / bodyLine).rounded(.up))))) * bodyLine
    }

    /// How many preview lines to draw: up to `previewLimit`, and fewer when the
    /// screen has no room for them — the choices are never the part cut.
    static func previewLines(for request: PermissionRequest, limit: CGFloat) -> Int {
        guard case .tool(_, _, let preview) = request.kind else { return 0 }
        var lines = min(previewLimit, preview?.lines.count ?? 0)
        while lines > 1, height(for: request, previewLines: lines) > limit { lines -= 1 }
        return lines
    }

    static func height(for request: PermissionRequest, limit: CGFloat = .infinity) -> CGFloat {
        height(for: request, previewLines: previewLines(for: request, limit: limit))
    }

    private static func height(for request: PermissionRequest, previewLines: Int) -> CGFloat {
        let body: CGFloat
        switch request.kind {
        case .tool:
            body = Self.sectionGap + bodyLine + previewHeight(previewLines)
                + Self.sectionGap + rows(toolChoices(request).count)
        case .questions(let questions):
            // The tallest question, so stepping through them never resizes the card.
            body = questions.map { q in
                Self.sectionGap + questionHeight(q.question)
                    + Self.sectionGap + rows(min(optionLimit, q.options.count))
            }.max() ?? 0
        }
        return 2 * Self.padding + header + body + appLinkGap + appLinkHeight
    }

    /// How many choice rows are showing.
    static func choiceCount(for request: PermissionRequest, questionIndex: Int) -> Int {
        switch request.kind {
        case .tool: return toolChoices(request).count
        case .questions(let questions): return min(optionLimit, questions[safe: questionIndex]?.options.count ?? 0)
        }
    }

    /// Where the first choice row starts, measured down from the card's top
    /// edge. The rows follow at `rowHeight + rowGap`.
    static func choicesTop(for request: PermissionRequest, questionIndex: Int, limit: CGFloat) -> CGFloat {
        var top = Self.padding + header + Self.sectionGap
        switch request.kind {
        case .tool:
            top += bodyLine + previewHeight(previewLines(for: request, limit: limit))
        case .questions(let questions):
            top += questionHeight(questions[safe: questionIndex]?.question ?? "")
        }
        return top + Self.sectionGap
    }

    /// Yes, the terminal's "Yes, and…" rows, No — in the terminal's order.
    static func toolChoices(_ request: PermissionRequest) -> [(label: String, decision: PermissionDecision)] {
        // Leaving plan mode has no bare "Yes": every yes names the mode to
        // work in next — see `PermissionRequest.planChoices`.
        if request.isPlan {
            return request.suggestions.map { ($0.label, .allowRemembering($0.value)) }
                + [(L10n.t("No, keep planning"), .deny)]
        }
        return [(L10n.t("Yes"), .allow)]
            + request.suggestions.prefix(suggestionLimit).map { ($0.label, .allowRemembering($0.value)) }
            + [(L10n.t("No"), .deny)]
    }

    // MARK: Look

    private var glassy: Bool { surfaceStyle.isGlass && !reduceTransparency }
    private var secondaryInk: Color {
        TooltipGlassContrast.secondaryInk(surfaceStyle: surfaceStyle, colorScheme: colorScheme,
                                          reduceTransparency: reduceTransparency)
    }
    private var surfaceFill: Color { glassy ? .clear : Palette.card }
    private var height: CGFloat { Self.height(for: request, limit: heightLimit) }

    private var clampedTailOffset: CGFloat {
        let size = TooltipTail.size(for: direction)
        switch direction {
        case .leading, .trailing:
            let maxOffset = max(0, (height / 2) - NotchLayout.cardCorner - (size.height / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        case .up, .down:
            let maxOffset = max(0, (Self.width / 2) - NotchLayout.cardCorner - (size.width / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        }
    }

    private var appLinkTitle: String { Self.appLinkTitle(for: request) }

    private var title: String {
        if case .questions = request.kind { return L10n.t("Claude asks") }
        if request.isPlan { return L10n.t("Plan ready") }
        return L10n.t("Permission Request")
    }

    private var subtitle: String {
        var parts = [request.project]
        if case .questions(let questions) = request.kind, questions.count > 1 {
            parts.append(L10n.t("\(questionIndex + 1) of \(questions.count)"))
        }
        if queued > 0 { parts.append(L10n.t("\(queued) more waiting")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        stack
            .background {
                if glassy {
                    if #available(macOS 26.0, *) {
                        Color.clear
                            .glassEffect(surfaceStyle.glass, in: TooltipSilhouette(direction: direction, tailOffset: clampedTailOffset))
                            .background {
                                if let dim = TooltipGlassContrast.dim(surfaceStyle: surfaceStyle,
                                                                      colorScheme: colorScheme,
                                                                      reduceTransparency: reduceTransparency) {
                                    TooltipSilhouette(direction: direction, tailOffset: clampedTailOffset).fill(dim)
                                }
                            }
                    }
                }
            }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(surfaceFill)
                .frame(width: Self.width, height: height)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: NotchLayout.headerGap) {
                    ProviderGlyphView(glyph: .claude)
                        .foregroundStyle(Palette.textPrimary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(Typography.cardTitle)
                            .foregroundStyle(Palette.textPrimary)
                        Text(subtitle)
                            .font(Typography.cardBody)
                            .foregroundStyle(secondaryInk)
                    }
                    .lineLimit(1)
                }
                .frame(height: Self.header, alignment: .leading)

                switch request.kind {
                case .tool(let name, let target, let preview):
                    toolBody(name: name, target: target, preview: preview)
                case .questions(let questions):
                    if let question = questions[safe: questionIndex] {
                        questionBody(question, isLast: questionIndex == questions.count - 1)
                    }
                }

                // The way out to the full prompt: the notch shows the gist by
                // design, and some answers need the rest.
                Button { onDecide(.passThrough) } label: {
                    HStack(spacing: Design.px(10)) {
                        Text(appLinkTitle)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: Design.fontSize(capPixels: 17), weight: .semibold))
                    }
                    .font(Self.bodyFont.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Self.appLinkPadding)
                    .frame(height: Self.appLinkHeight)
                    .background(Capsule().fill(Palette.textPrimary.opacity(appLinkHovered ? 0.22 : 0.12)))
                    .overlay(Capsule().strokeBorder(Palette.textPrimary.opacity(0.18), lineWidth: 1))
                    .animation(.easeOut(duration: 0.12), value: appLinkHovered)
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, Self.appLinkGap)
            }
            .padding(Self.padding)
            .frame(width: Self.width, height: height, alignment: .topLeading)
        }
        .frame(width: Self.width, height: height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular))
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .strokeBorder(Palette.ringTrack, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func toolBody(name: String, target: String, preview: PermissionRequest.Preview?) -> some View {
        HStack(spacing: Design.px(12)) {
            // A plan is titled by its own heading; the tool name means nothing to read.
            if !request.isPlan {
                Text(name).foregroundStyle(Palette.watch).fontWeight(.semibold)
            }
            Text(target).foregroundStyle(Palette.textPrimary)
                .fontWeight(request.isPlan ? .semibold : .regular)
                .truncationMode(request.isPlan ? .tail : .middle)
        }
        .font(Self.bodyFont)
        .lineLimit(1)
        .frame(height: Self.bodyLine)
        .padding(.top, Self.sectionGap)

        if let preview, !preview.lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(preview.lines.prefix(Self.previewLines(for: request, limit: heightLimit)).enumerated()),
                        id: \.offset) { _, line in
                    Text(Self.marked(line))
                        .font(Self.codeFont)
                        .foregroundStyle(Self.ink(line.mark))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, minHeight: Self.codeLine,
                               maxHeight: Self.codeLine, alignment: .leading)
                }
            }
            .padding(.horizontal, Self.codePadding * 1.2)
            .padding(.vertical, Self.codePadding)
            .background(RoundedRectangle(cornerRadius: Design.px(16)).fill(Palette.barTrack.opacity(0.5)))
            .padding(.top, Self.sectionGap)
        }

        VStack(spacing: Self.rowGap) {
            ForEach(Array(Self.toolChoices(request).enumerated()), id: \.offset) { index, choice in
                ChoiceRow(number: index + 1, label: choice.label, prominent: index == 0,
                          highlighted: hoveredChoice == index) {
                    onDecide(choice.decision)
                }
            }
        }
        .padding(.top, Self.sectionGap)
    }

    private static func marked(_ line: PermissionRequest.Preview.Line) -> String {
        switch line.mark {
        case .removed: return "- \(line.text)"
        case .added: return "+ \(line.text)"
        case .context: return "  \(line.text)"
        case .plain: return line.text
        }
    }

    private static func ink(_ mark: PermissionRequest.Preview.Mark) -> Color {
        switch mark {
        case .removed: return Palette.critical
        case .added: return Palette.ample
        case .context: return Palette.textSecondary
        case .plain: return Palette.textPrimary
        }
    }

    @ViewBuilder
    private func questionBody(_ question: PermissionRequest.Question, isLast: Bool) -> some View {
        Text(question.question)
            .font(Self.bodyFont)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Self.sectionGap)

        // ponytail: a multi-select question takes one choice here; the terminal
        // still has the full picker, and it is answering in parallel.
        VStack(spacing: Self.rowGap) {
            ForEach(Array(question.options.prefix(Self.optionLimit).enumerated()), id: \.offset) { index, option in
                ChoiceRow(number: index + 1, label: option, prominent: false,
                          highlighted: hoveredChoice == index) {
                    answers[question.question] = option
                    if isLast { onDecide(.answer(answers)) } else { onNextQuestion() }
                }
            }
        }
        .padding(.top, Self.sectionGap)
    }

    private var tail: some View {
        let size = TooltipTail.size(for: direction)
        return TooltipTail(direction: direction)
            .fill(surfaceFill)
            .frame(width: size.width, height: size.height)
            .offset(x: direction == .up || direction == .down ? clampedTailOffset : 0,
                    y: direction == .leading || direction == .trailing ? clampedTailOffset : 0)
    }

    @ViewBuilder private var stack: some View {
        switch direction {
        case .leading:  HStack(spacing: 0) { card; tail }
        case .trailing: HStack(spacing: 0) { tail; card }
        case .down:     VStack(spacing: 0) { tail; card }
        case .up:       VStack(spacing: 0) { card; tail }
        }
    }
}

/// One numbered choice, the way the terminal lists them. The first choice of
/// a permission prompt — plain "Yes" — is drawn in the notch's own ink, so it
/// stands out without borrowing a status colour.
private struct ChoiceRow: View {
    let number: Int
    let label: String
    let prominent: Bool
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.px(22)) {
                Text("\(number)")
                    .font(PermissionCard.bodyFont.monospacedDigit())
                    .foregroundStyle(prominent ? Palette.card.opacity(0.6) : Palette.textPrimary.opacity(0.7))
                    .frame(width: PermissionCard.badgeSize, height: PermissionCard.badgeSize)
                    .background(RoundedRectangle(cornerRadius: Design.px(12), style: .continuous)
                        .fill(prominent ? Palette.card.opacity(0.12) : Palette.ringTrack))
                Text(label)
                    .font(PermissionCard.bodyFont.weight(prominent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.px(17))
            .frame(maxWidth: .infinity, minHeight: PermissionCard.rowHeight,
                   maxHeight: PermissionCard.rowHeight)
            .foregroundStyle(prominent ? Palette.card : Palette.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: Design.px(20), style: .continuous)
                    .fill(prominent ? Palette.textPrimary.opacity(highlighted ? 0.85 : 1)
                                    : Palette.textPrimary.opacity(highlighted ? 0.16 : 0.08))
            )
            .animation(.easeOut(duration: 0.12), value: highlighted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
