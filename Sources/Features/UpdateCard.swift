import AppKit
import SwiftUI

/// **An update, offered in the notch** — and, taken, installed there.
///
/// Out of the notch like its other cards, its tail on the notch: the app's
/// icon, "Codenotch 1.19.0 is available" and a line of what is in it, with
/// Update, Later and a close. Update turns it into the installing card — the
/// download's progress, then extracting and installing — until Codenotch
/// relaunches as the new version. See `Updater`.
struct UpdateCard: View {
    let prompt: UpdatePrompt
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    var onChoice: ((UpdateChoice) -> Void)?

    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @Environment(\.notchCardSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    static let cardWidth: CGFloat = NotchLayout.updateCardWidth
    static let cardHeight: CGFloat = Design.px(262)
    private static let icon: CGFloat = Design.px(136)
    private static let button: CGFloat = Design.px(66)
    private static let bar: CGFloat = Design.px(16)

    private var glassy: Bool { surfaceStyle.isGlass && !reduceTransparency }
    private var secondaryInk: Color {
        TooltipGlassContrast.secondaryInk(surfaceStyle: surfaceStyle, colorScheme: colorScheme,
                                          reduceTransparency: reduceTransparency)
    }
    private var surfaceFill: Color { glassy ? .clear : Palette.card }

    /// The card's own size, the tail aside, on this edge.
    static func size(for direction: NotchEdge.TooltipDirection) -> CGSize {
        CGSize(width: cardWidth, height: cardHeight)
    }

    private var clampedTailOffset: CGFloat {
        let size = TooltipTail.size(for: direction)
        switch direction {
        case .leading, .trailing:
            let most = max(0, Self.cardHeight / 2 - NotchLayout.cardCorner - size.height / 2)
            return min(max(tailOffset, -most), most)
        case .up, .down:
            let most = max(0, Self.cardWidth / 2 - NotchLayout.cardCorner - size.width / 2)
            return min(max(tailOffset, -most), most)
        }
    }

    var body: some View {
        stack
            .background {
                if glassy {
                    if #available(macOS 26.0, *) {
                        Color.clear
                            .glassEffect(surfaceStyle.glass,
                                         in: TooltipSilhouette(direction: direction, tailOffset: clampedTailOffset))
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

    // MARK: - Contents

    private var installing: Bool { prompt.phase != .available }

    private var title: String {
        installing ? L10n.t("Installing Codenotch \(prompt.version)")
                   : L10n.t("Codenotch \(prompt.version) is available")
    }

    private var status: String {
        switch prompt.phase {
        case .available:
            return prompt.notes.isEmpty ? L10n.t("A new version of Codenotch is ready to install.") : prompt.notes
        case .downloading(let share):
            guard let share else { return L10n.t("Downloading…") }
            return L10n.t("Downloading… \(Int((share * 100).rounded()))%")
        case .extracting:
            return L10n.t("Preparing…")
        case .installing:
            return L10n.t("Installing…")
        }
    }

    /// How far along the bar is: the download, then the unpacking, then full.
    private var progress: Double {
        switch prompt.phase {
        case .available:               return 0
        case .downloading(let share):  return (share ?? 0) * 0.85
        case .extracting(let share):   return 0.85 + min(max(share, 0), 1) * 0.1
        case .installing:              return 1
        }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(surfaceFill)
                .frame(width: Self.cardWidth, height: Self.cardHeight)

            HStack(alignment: .center, spacing: Design.px(30)) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Self.icon, height: Self.icon)

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(Typography.cardTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .contentTransition(.opacity)

                    Text(status)
                        .font(Typography.cardBody)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(installing ? 1 : 2)
                        .monospacedDigit()
                        .padding(.top, Design.px(6))

                    Spacer(minLength: Design.px(14))

                    if installing {
                        progressBar
                            .transition(.opacity)
                    } else {
                        buttons
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(NotchLayout.cardPadding)
            .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .leading)
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular))
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .strokeBorder(Palette.ringTrack, lineWidth: 1)
            }
        }
        .animation(.easeOut(duration: 0.2), value: installing)
    }

    private var buttons: some View {
        HStack(spacing: Design.px(14)) {
            pill(L10n.t("Update"), symbol: "arrow.down.circle") { onChoice?(.install) }
            pill(L10n.t("Later"), symbol: "clock") { onChoice?(.later) }
            Button { onChoice?(.close) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: Self.button, height: Self.button)
                    .background(Circle().fill(Palette.textPrimary.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(UpdateCardButtonStyle())
            .help(L10n.t("Close"))
        }
    }

    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Design.px(10)) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(Typography.cardBody.weight(.semibold))
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, Design.px(28))
            .frame(height: Self.button)
            .background(Capsule().fill(Palette.textPrimary.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(UpdateCardButtonStyle())
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.textPrimary.opacity(0.16))
                Capsule()
                    .fill(Palette.textPrimary.opacity(0.9))
                    .frame(width: max(Self.bar, proxy.size.width * progress))
                    .animation(.easeOut(duration: 0.25), value: progress)
            }
        }
        .frame(height: Self.bar)
        .padding(.bottom, Design.px(20))
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

/// A press that dips, for the card's buttons.
private struct UpdateCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
