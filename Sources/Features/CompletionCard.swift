import SwiftUI

/// What the notch says when an agent session stops: which one, whether it is
/// done or needs you, and that a click goes there.
///
/// Shown beside the ring the session belongs to until it is clicked or its app
/// comes to the front (`CompletionQueue`); the next one waiting takes its
/// place. The whole card is the target. Built like `UsageResetCard`: same
/// surface, tail and faces.
struct CompletionCard: View {
    let event: SessionCompletionWatcher.Event
    let glyph: ProviderGlyph
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    var hovered = false
    /// How many more stopped sessions wait behind this one.
    var queued = 0

    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @Environment(\.notchSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    static var cardHeight: CGFloat {
        2 * NotchLayout.cardPadding
            + max(NotchLayout.glyphSize, NotchLayout.cardTitleLineHeight + NotchLayout.cardBodyLineHeight)
            + NotchLayout.headerToBlock + NotchLayout.cardBodyLineHeight
    }

    private var glassy: Bool { surfaceStyle.isGlass && !reduceTransparency }
    private var secondaryInk: Color {
        TooltipGlassContrast.secondaryInk(surfaceStyle: surfaceStyle, colorScheme: colorScheme,
                                          reduceTransparency: reduceTransparency)
    }
    private var surfaceFill: Color { glassy ? .clear : Palette.card }

    private var statusText: String {
        let status = event.reason == .blocked ? L10n.t("Needs you — click to jump") : L10n.t("Done — click to jump")
        return queued > 0 ? status + " · " + L10n.t("\(queued) more waiting") : status
    }
    private var statusColor: Color { event.reason == .blocked ? Palette.watch : Palette.ample }

    private var clampedTailOffset: CGFloat {
        let size = TooltipTail.size(for: direction)
        switch direction {
        case .leading, .trailing:
            let maxOffset = max(0, (Self.cardHeight / 2) - NotchLayout.cardCorner - (size.height / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        case .up, .down:
            let maxOffset = max(0, (NotchLayout.cardWidth / 2) - NotchLayout.cardCorner - (size.width / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        }
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
                .frame(width: NotchLayout.cardWidth, height: Self.cardHeight)
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(Palette.textPrimary.opacity(hovered ? 0.06 : 0))
                .frame(width: NotchLayout.cardWidth, height: Self.cardHeight)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: NotchLayout.headerGap) {
                    ProviderGlyphView(glyph: glyph)
                        .foregroundStyle(Palette.textPrimary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(event.session.name)
                            .font(Typography.cardTitle)
                            .foregroundStyle(Palette.textPrimary)
                        Text(event.session.detail)
                            .font(Typography.cardBody)
                            .foregroundStyle(secondaryInk)
                    }
                    .lineLimit(1)
                }
                HStack(spacing: Design.px(12)) {
                    Circle().fill(statusColor).frame(width: Design.px(16), height: Design.px(16))
                    Text(statusText).font(Typography.cardBody).foregroundStyle(statusColor).lineLimit(1)
                }
                .padding(.top, NotchLayout.headerToBlock)
            }
            .padding(NotchLayout.cardPadding)
            .frame(width: NotchLayout.cardWidth, height: Self.cardHeight, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: Self.cardHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular))
        .animation(.easeOut(duration: 0.12), value: hovered)
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .strokeBorder(Palette.ringTrack, lineWidth: 1)
            }
        }
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
