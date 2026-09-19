import SwiftUI

/// The notification modal card displayed beside the notch when a provider's limit resets.
struct UsageResetCard: View {
    let event: UsageResetEvent
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    var onDismiss: (() -> Void)? = nil

    @Environment(\.codenotchAccentColor) private var accentColor
    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @Environment(\.notchSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    static let cardHeight: CGFloat = Design.px(210)

    private var glassy: Bool { surfaceStyle.isGlass && !reduceTransparency }
    private var secondaryInk: Color {
        TooltipGlassContrast.secondaryInk(surfaceStyle: surfaceStyle, colorScheme: colorScheme,
                                          reduceTransparency: reduceTransparency)
    }
    /// Clear on glass: anything of ours under it would override the Clear or
    /// Tinted choice in Appearance settings. `darkGlass` is the one deliberate
    /// exception, and its dim is drawn behind the glass itself, not here.
    private var surfaceFill: Color { glassy ? .clear : Palette.card }

    var body: some View {
        stack
            .background {
                // `isGlass` is only ever true where `glassEffect` exists; the
                // availability check is what tells the compiler so.
                if glassy {
                    if #available(macOS 26.0, *) {
                        Color.clear
                            .glassEffect(surfaceStyle.glass, in: TooltipSilhouette(direction: direction, tailOffset: tailOffset))
                            .background {
                                if let dim = TooltipGlassContrast.dim(surfaceStyle: surfaceStyle,
                                                                       colorScheme: colorScheme,
                                                                       reduceTransparency: reduceTransparency) {
                                    TooltipSilhouette(direction: direction, tailOffset: tailOffset).fill(dim)
                                }
                            }
                    }
                }
            }
    }

    private var titleText: String {
        switch event.kind {
        case .reset:
            return L10n.t("\(event.providerName) Reset")
        case .sessionLimitReached:
            return L10n.t("\(event.providerName) Limit Reached")
        case .weeklyLimitReached:
            return L10n.t("\(event.providerName) Weekly Limit")
        }
    }

    private var subtitleText: String {
        switch event.kind {
        case .reset:
            return L10n.t("\(event.windowLabel) limit refreshed")
        case .sessionLimitReached, .weeklyLimitReached:
            return L10n.t("\(event.windowLabel) limit is spent")
        }
    }

    private var statusColor: Color {
        switch event.kind {
        case .reset:
            return Palette.ample
        case .sessionLimitReached, .weeklyLimitReached:
            return Palette.critical
        }
    }

    private var statusText: String {
        switch event.kind {
        case .reset:
            return L10n.t("Quota is available (0% used)")
        case .sessionLimitReached:
            return L10n.t("Session limit reached (100% used)")
        case .weeklyLimitReached:
            return L10n.t("Weekly limit reached (100% used)")
        }
    }

    private var resetTimePrefix: String {
        switch event.kind {
        case .reset:
            return L10n.t("Next reset")
        case .sessionLimitReached, .weeklyLimitReached:
            return L10n.t("Resets at")
        }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(surfaceFill)
                .frame(width: NotchLayout.cardWidth, height: Self.cardHeight)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: NotchLayout.headerGap) {
                    ProviderGlyphView(glyph: event.glyph)
                        .foregroundStyle(Palette.textPrimary)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Text(titleText)
                                .font(Typography.cardTitle)
                                .foregroundStyle(Palette.textPrimary)
                                .layoutPriority(1)

                            Spacer(minLength: Design.px(12))

                            if let onDismiss {
                                Button(action: onDismiss) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(secondaryInk)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Text(subtitleText)
                            .font(Typography.cardBody)
                            .foregroundStyle(secondaryInk)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: Design.px(12)) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: Design.px(16), height: Design.px(16))

                    Text(statusText)
                        .font(Typography.cardBody)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.top, NotchLayout.headerToBlock)

                if let resetsAt = event.resetsAt {
                    Text("\(resetTimePrefix) \(resetsAt.formatted(date: .omitted, time: .shortened))")
                        .font(Typography.cardBody)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                        .padding(.top, Design.px(8))
                }
            }
            .padding(NotchLayout.cardPadding)
            .frame(width: NotchLayout.cardWidth, height: Self.cardHeight, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: Self.cardHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular))
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
            .offset(x: direction == .up || direction == .down ? tailOffset : 0,
                    y: direction == .leading || direction == .trailing ? tailOffset : 0)
    }

    @ViewBuilder private var stack: some View {
        switch direction {
        case .leading:
            HStack(spacing: 0) { card; tail }
        case .trailing:
            HStack(spacing: 0) { tail; card }
        case .down:
            VStack(spacing: 0) { tail; card }
        case .up:
            VStack(spacing: 0) { card; tail }
        }
    }
}
