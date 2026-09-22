import SwiftUI

/// The regular Liquid Glass material follows the desktop behind it. A dark
/// system appearance is not a guarantee of a dark result: a light wallpaper
/// can still make the card pale enough to erase secondary copy. Keep that
/// adaptive material, but give reading surfaces a stable dark base in this
/// one case.
enum TooltipGlassContrast {
    static func needsReadableDim(surfaceStyle: NotchSurfaceStyle,
                                 colorScheme: ColorScheme,
                                 reduceTransparency: Bool = false) -> Bool {
        surfaceStyle.effective == .glass && colorScheme == .dark && !reduceTransparency
    }

    static func dim(surfaceStyle: NotchSurfaceStyle, colorScheme: ColorScheme,
                    reduceTransparency: Bool = false) -> Color? {
        if surfaceStyle.effective == .darkGlass {
            return Palette.darkGlassTooltipDim
        }
        return needsReadableDim(surfaceStyle: surfaceStyle, colorScheme: colorScheme,
                                reduceTransparency: reduceTransparency)
            ? Palette.liquidGlassTooltipDim : nil
    }

    static func secondaryInk(surfaceStyle: NotchSurfaceStyle, colorScheme: ColorScheme,
                             reduceTransparency: Bool = false) -> Color {
        needsReadableDim(surfaceStyle: surfaceStyle, colorScheme: colorScheme,
                         reduceTransparency: reduceTransparency)
            ? Palette.readableTooltipTextSecondary : Palette.textSecondary
    }
}

/// The speech-bubble tail, its point aimed at the hovered cell.
///
/// Its shoulders leave the card tangent to the card's edge. That continuous
/// tangent is what makes the two pieces read as one moulded silhouette rather
/// than a triangle pasted onto a rounded rectangle.
struct TooltipTail: Shape {
    /// Which way the card sits relative to the notch — the tip points back the
    /// other way, at the cell.
    let direction: NotchEdge.TooltipDirection

    func path(in rect: CGRect) -> Path {
        // The tip and the two ends of the base opposite it. Each curve starts
        // or finishes parallel to the card edge, rounding both joins while the
        // point stays crisp and continues to land on the hovered ring.
        let (tip, a, b, aShoulder, aTip, bTip, bShoulder):
            (CGPoint, CGPoint, CGPoint, CGPoint, CGPoint, CGPoint, CGPoint)
        switch direction {
        case .leading:   // card on the left, tip to the right
            tip = CGPoint(x: rect.maxX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25)
            aTip = CGPoint(x: rect.maxX - rect.width * 0.42, y: rect.midY - rect.height * 0.12)
            bTip = CGPoint(x: rect.maxX - rect.width * 0.42, y: rect.midY + rect.height * 0.12)
            bShoulder = CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.25)
        case .trailing:  // card on the right, tip to the left
            tip = CGPoint(x: rect.minX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25)
            aTip = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY - rect.height * 0.12)
            bTip = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY + rect.height * 0.12)
            bShoulder = CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.25)
        case .down:      // card below, tip upward
            tip = CGPoint(x: rect.midX, y: rect.minY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY)
            aTip = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.minY + rect.height * 0.42)
            bTip = CGPoint(x: rect.midX + rect.width * 0.12, y: rect.minY + rect.height * 0.42)
            bShoulder = CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.maxY)
        case .up:        // card above, tip downward
            tip = CGPoint(x: rect.midX, y: rect.maxY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
            aShoulder = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY)
            aTip = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.maxY - rect.height * 0.42)
            bTip = CGPoint(x: rect.midX + rect.width * 0.12, y: rect.maxY - rect.height * 0.42)
            bShoulder = CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.minY)
        }

        var path = Path()
        path.move(to: a)
        path.addCurve(to: tip, control1: aShoulder, control2: aTip)
        path.addCurve(to: b, control1: bTip, control2: bShoulder)
        path.closeSubpath()
        return path
    }

    /// Long in the direction it points, wide across it.
    static func size(for direction: NotchEdge.TooltipDirection) -> CGSize {
        switch direction {
        case .leading, .trailing:
            return CGSize(width: NotchLayout.tailLength, height: NotchLayout.tailHeight)
        case .up, .down:
            return CGSize(width: NotchLayout.tailHeight, height: NotchLayout.tailLength)
        }
    }
}

/// The card and its tail as a single outline.
///
/// One glass shape, not two: separate ones each grow their own rim highlight
/// and the seam shows where the tail leaves the card. Internal so the tests can
/// measure the outline.
struct TooltipSilhouette: Shape {
    /// Which side of the notch the card is on, so the tail goes on the other one.
    let direction: NotchEdge.TooltipDirection
    /// The same nudge `TooltipShell` applies to the tail view, along the card's
    /// own axis. The glass is masked by this outline, so a tail that has slid
    /// along the card to stay on its cell would otherwise be left unpainted.
    var tailOffset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        // The two pieces are placed out of `rect` exactly the way
        // `TooltipShell.body` stacks them, so the outline keeps following the
        // card while its height animates.
        let tail = TooltipTail.size(for: direction)
        let cardRect: CGRect
        var tailRect: CGRect
        switch direction {
        case .leading:
            cardRect = CGRect(x: rect.minX, y: rect.minY,
                              width: rect.width - tail.width, height: rect.height)
            tailRect = CGRect(x: cardRect.maxX, y: rect.midY - tail.height / 2,
                              width: tail.width, height: tail.height)
        case .trailing:
            tailRect = CGRect(x: rect.minX, y: rect.midY - tail.height / 2,
                              width: tail.width, height: tail.height)
            cardRect = CGRect(x: rect.minX + tail.width, y: rect.minY,
                              width: rect.width - tail.width, height: rect.height)
        case .down:
            tailRect = CGRect(x: rect.midX - tail.width / 2, y: rect.minY,
                              width: tail.width, height: tail.height)
            cardRect = CGRect(x: rect.minX, y: rect.minY + tail.height,
                              width: rect.width, height: rect.height - tail.height)
        case .up:
            cardRect = CGRect(x: rect.minX, y: rect.minY,
                              width: rect.width, height: rect.height - tail.height)
            tailRect = CGRect(x: rect.midX - tail.width / 2, y: cardRect.maxY,
                              width: tail.width, height: tail.height)
        }
        var clampedTailOffset = tailOffset
        switch direction {
        case .leading, .trailing:
            let maxOffset = max(0, (cardRect.height / 2) - NotchLayout.cardCorner - (tail.height / 2))
            clampedTailOffset = min(max(tailOffset, -maxOffset), maxOffset)
            tailRect.origin.y += clampedTailOffset
        case .up, .down:
            let maxOffset = max(0, (cardRect.width / 2) - NotchLayout.cardCorner - (tail.width / 2))
            clampedTailOffset = min(max(tailOffset, -maxOffset), maxOffset)
            tailRect.origin.x += clampedTailOffset
        }

        return RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
            .path(in: cardRect)
            .union(TooltipTail(direction: direction).path(in: tailRect))
    }
}

/// The card chrome every tooltip shares: fixed width, the frame's padding and
/// corner, and the tail welded on so there is no seam between them.
private struct TooltipShell<Content: View>: View {
    /// Given explicitly rather than left to the contents.
    ///
    /// Sized by its contents, the card's height changes the instant they do —
    /// and the tail, centred on that height, jumps with it while the card's
    /// position is still gliding. The two halves then visibly come apart.
    let height: CGFloat
    /// Which side of the notch the card is on, so the tail goes on the other one.
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    @ViewBuilder let content: Content

    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @Environment(\.notchSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    /// Reduce transparency means "no see-through chrome", which for this card
    /// is the solid style — the same precedence the Settings window applies to
    /// its own translucent chrome.
    private var glassy: Bool { surfaceStyle.isGlass && !reduceTransparency }

    /// Clear on glass: anything of ours under it would override the Clear or
    /// Tinted choice in Appearance settings. `darkGlass` is the one deliberate
    /// exception, and its dim is drawn behind the glass itself, not here.
    private var surfaceFill: Color { glassy ? .clear : Palette.card }

    private var card: some View {
        // The same arrangement that makes the notch fold work: the contents
        // are laid out once at their natural size and never move, and it is
        // the *mask* that changes size over them.
        //
        // The obvious alternative — putting the contents inside a frame of
        // the animating height — makes SwiftUI re-align them on every frame
        // of the animation, so the rows drift vertically inside the card and
        // the top ones slide out under the clip. Nothing should move here
        // except the boundary.
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(surfaceFill)
                .frame(width: NotchLayout.cardWidth, height: height)

            content
                .padding(NotchLayout.cardPadding)
                .frame(width: NotchLayout.cardWidth, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: height, alignment: .top)
        .clipShape(
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
        )
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .strokeBorder(Palette.ringTrack, lineWidth: 1)
            }
        }
    }

    private var clampedTailOffset: CGFloat {
        let size = TooltipTail.size(for: direction)
        switch direction {
        case .leading, .trailing:
            let maxOffset = max(0, (height / 2) - NotchLayout.cardCorner - (size.height / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        case .up, .down:
            let maxOffset = max(0, (NotchLayout.cardWidth / 2) - NotchLayout.cardCorner - (size.width / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        }
    }

    private var tail: some View {
        let size = TooltipTail.size(for: direction)
        // The tail is deliberately outside the clip: it is part of the card's
        // silhouette, not of its contents.
        return TooltipTail(direction: direction)
            .fill(surfaceFill)
            .frame(width: size.width, height: size.height)
            .offset(x: direction == .up || direction == .down ? clampedTailOffset : 0,
                    y: direction == .leading || direction == .trailing ? clampedTailOffset : 0)
    }

    var body: some View {
        stack
            // The background takes the stack's bounds — card plus tail — and is
            // re-solved as `height` animates, so one piece of glass covers both
            // pieces however tall the card is.
            .background {
                // `isGlass` is only ever true where `glassEffect` exists;
                // the availability check is what tells the compiler so. Below
                // that, `surfaceFill` has already painted the card opaque.
                if glassy {
                    if #available(macOS 26.0, *) {
                        Color.clear
                            .glassEffect(surfaceStyle.glass, in: TooltipSilhouette(direction: direction,
                                                                                   tailOffset: clampedTailOffset))
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

    @ViewBuilder private var stack: some View {
        // Card first or tail first, laid out along whichever axis the tail
        // points. The pair is one silhouette either way.
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

private struct TooltipHeader<Mark: View>: View {
    let title: String
    /// The account's named tier, when the provider publishes one.
    var subtitle: String?
    /// Sits on the header's own line, so saying when a reading was taken costs
    /// the card no extra height.
    var note: String?
    @ViewBuilder let mark: Mark
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        HStack(alignment: .center, spacing: NotchLayout.headerGap) {
            mark
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(title)
                        .font(Typography.cardTitle)
                        .foregroundStyle(Palette.textPrimary)
                        // The title names the model; a long note yields before it does.
                        .layoutPriority(1)
                    if let note {
                        Spacer(minLength: Design.px(20))
                        Text(note)
                            .font(Typography.cardBody)
                            .foregroundStyle(secondaryInk)
                            .lineLimit(1)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.cardBody)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// A label on the left and a quieter value on the right — the row shape the
/// design frame uses throughout.
struct SplitRow<Accessory: View>: View {
    let leading: String
    let trailing: String
    var leadingColor: Color = Palette.textPrimary
    var trailingColor: Color? = nil
    /// Sits immediately before the trailing text, inside the same group, so it
    /// travels with the word instead of drifting to the middle of the row.
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        HStack(spacing: Design.px(20)) {
            Text(leading).foregroundStyle(leadingColor)
            Spacer(minLength: 0)
            HStack(spacing: NotchLayout.statusDotGap) {
                accessory()
                Text(trailing).foregroundStyle(trailingColor ?? secondaryInk)
            }
        }
        .font(Typography.cardBody)
        .lineLimit(1)
    }
}

extension SplitRow where Accessory == EmptyView {
    init(leading: String,
         trailing: String,
         leadingColor: Color = Palette.textPrimary,
         trailingColor: Color? = nil) {
        self.init(leading: leading, trailing: trailing,
                  leadingColor: leadingColor, trailingColor: trailingColor,
                  accessory: { EmptyView() })
    }
}

/// The ring beside a session's status.
///
/// Turning while the agent is working, still when it is not — so the row says
/// what is happening before the word is read.
private struct StatusRing: View {
    let state: AgentSession.State
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One turn, in seconds. Slow enough to read as deliberate rather than as
    /// something struggling.
    private static let period: Double = 1.4

    var body: some View {
        Group {
            switch state {
            case .busy:
                if reduceMotion {
                    // Still, but still three-quarters: the gap alone says
                    // "in progress" without anything moving.
                    ring(trim: 0.75)
                } else {
                    // A timeline rather than `repeatForever`. An endless
                    // animation has to be cancelled to stop, and setting the
                    // value it is already heading towards does not cancel it —
                    // which is exactly how the refresh ring here once span for
                    // ever. Derived from the clock, it simply stops being drawn.
                    TimelineView(.animation) { context in
                        ring(trim: 0.75)
                            .rotationEffect(.degrees(angle(at: context.date)))
                    }
                }
            case .waiting, .success:
                // Half a ring, held still: blocked, not progressing. (Or a full ring for success).
                // Wait, if we want success to be a full ring, we can use 1.0 trim for success.
                ring(trim: state == .success ? 1.0 : 0.5)
            case .idle:
                ring(trim: 1)
            }
        }
        .frame(width: NotchLayout.statusDot, height: NotchLayout.statusDot)
    }

    private func ring(trim: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: trim)
            .stroke(color,
                    style: StrokeStyle(lineWidth: NotchLayout.statusDotStroke, lineCap: .round))
            // Start the gap at the top, where the eye lands first.
            .rotationEffect(.degrees(-90))
    }

    private func angle(at date: Date) -> Double {
        let turns = date.timeIntervalSinceReferenceDate / Self.period
        return turns.truncatingRemainder(dividingBy: 1) * 360
    }
}

// MARK: - Providers

/// One metered window: label and reset copy on a line, a track bar, then the
/// percentage burned.
private struct LimitWindowRow: View {
    let window: LimitWindow
    var inset: CGFloat = 0
    let fidelity: Fidelity
    let now: Date
    let resetTimeFormat: ResetTimeFormat
    let showsUsagePace: Bool
    @Environment(\.codenotchAccentColor) private var accentColor
    @Environment(\.usageWatchLimit) private var watchLimit
    @Environment(\.usageCriticalLimit) private var criticalLimit
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    private var band: UsageBand {
        if let override = window.bandOverride { return override }
        return UsageBand.band(for: window.usedFraction ?? 0, watchLimit: watchLimit, criticalLimit: criticalLimit)
    }
    private var trackWidth: CGFloat { NotchLayout.cardWidth - 2 * NotchLayout.cardPadding - inset }
    private var fillWidth: CGFloat {
        let fraction = CGFloat(min(max(window.usedFraction ?? 0, 0), 1))
        return max(NotchLayout.barHeight, trackWidth * fraction)
    }

    private var paceText: Text {
        guard showsUsagePace, let pace = window.usagePace(now: now) else {
            return Text("")
        }
        return Text(" · \(pace.summary)")
            .foregroundColor(pace.isDeficit ? .orange : secondaryInk)
    }

    /// Blank rather than invented: some providers never say when the window rolls.
    private var resetText: String {
        window.resetsAt.map { ResetCopy.text(for: $0, now: now, format: resetTimeFormat) } ?? ""
    }

    /// A count-only row (no fraction, no reset) — like Ollama's per-model request
    /// counts — renders as a single table line: name left, count right.
    private var isCountRow: Bool {
        window.usedFraction == nil && (window.used != nil || window.detail != nil)
    }

    var body: some View {
        if let money = window.money {
            MoneyBreakdownView(title: window.label, money: money, fidelity: fidelity)
        } else if isCountRow {
            SplitRow(leading: window.label, trailing: window.detail ?? window.usedText ?? "\(window.used ?? 0)")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SplitRow(leading: window.label, trailing: resetText)

                // No bar without a denominator — an empty track would read as "none
                // used", which is not what "we do not know the limit" means.
                if window.usedFraction != nil {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.barTrack)
                        Capsule().fill(band.color(accent: accentColor)).frame(width: fillWidth)
                    }
                    .frame(width: trackWidth, height: NotchLayout.barHeight)
                    .padding(.top, NotchLayout.labelToBar)
                }

                Text("\(window.usedFraction == nil ? "" : fidelity.qualifier)\(window.detail ?? window.summary)\(paceText)")
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.top, NotchLayout.barToUsed)
            }
        }
    }
}

private struct MoneyBreakdownView: View {
    let title: String
    let money: UsageMoneyBreakdown
    let fidelity: Fidelity
    @Environment(\.codenotchAccentColor) private var accentColor
    @Environment(\.usageWatchLimit) private var watchLimit
    @Environment(\.usageCriticalLimit) private var criticalLimit

    private var symbol: String {
        switch money.currency.uppercased() {
        case "CNY", "RMB", "JPY": return "¥"
        case "USD": return "$"
        case "EUR": return "€"
        default: return "\(money.currency) "
        }
    }

    private func amount(_ value: Double) -> String {
        "\(symbol)\(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SplitRow(leading: title,
                     trailing: "\(fidelity.qualifier)\(Percent.text(for: money.spentFraction))% used")
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(UsageBand.band(for: money.spentFraction, watchLimit: watchLimit, criticalLimit: criticalLimit).color(accent: accentColor))
                        .frame(width: proxy.size.width * CGFloat(money.spentFraction))
                    Rectangle().fill(Palette.barTrack)
                }
            }
            .frame(width: NotchLayout.cardTextWidth, height: NotchLayout.moneyBarHeight)
            .clipShape(Capsule())
            .padding(.top, NotchLayout.labelToBar)

            HStack(spacing: NotchLayout.blockSpacing) {
                MoneyStat(label: L10n.t("Spent"), value: amount(money.spent), color: accentColor)
                MoneyStat(label: L10n.t("Remaining"), value: amount(money.remaining))
                MoneyStat(label: L10n.t("Funded"), value: amount(money.funded), color: Palette.textPrimary)
            }
            .frame(width: NotchLayout.cardTextWidth)
            .padding(.top, NotchLayout.moneyBarToStats)
        }
    }
}

private struct MoneyStat: View {
    let label: String
    let value: String
    var color: Color? = nil
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        VStack(alignment: .leading, spacing: NotchLayout.moneyStatGap) {
            Text(label).foregroundStyle(secondaryInk).lineLimit(1)
            Text(value).foregroundStyle(color ?? secondaryInk).monospacedDigit().lineLimit(1)
        }
        .font(Typography.cardBody)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderTooltip: View {
    /// What a local model is doing right now, for the header's note.
    var activityNote: String?
    let snapshot: ProviderSnapshot
    let now: Date
    let resetTimeFormat: ResetTimeFormat
    let showUsagePace: Bool
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    /// Only worth saying when the numbers are not current. A remembered reading
    /// has to be dated, or it quietly passes itself off as live.
    private var readingAge: String? {
        guard snapshot.hasReading, let since = snapshot.status.staleSince,
              since != .distantPast
        else { return nil }
        return ElapsedCopy.ago(since: since, now: now)
    }

    private struct WindowGroup: Identifiable {
        let id: String
        let title: String?
        var windows: [LimitWindow]
    }

    private var groupedWindows: [WindowGroup] {
        var result: [WindowGroup] = []
        for window in snapshot.windows {
            if let last = result.last, last.title == window.group {
                result[result.count - 1].windows.append(window)
            } else {
                result.append(WindowGroup(id: window.group ?? window.id, title: window.group, windows: [window]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TooltipHeader(title: snapshot.kind == .localRuntime
                          ? L10n.t("\(snapshot.localModel?.brand?.displayName ?? snapshot.displayName) · Local")
                          : L10n.t("\(snapshot.displayName) Usage"),
                          subtitle: snapshot.plan,
                          note: activityNote ?? (snapshot.localModel?.brand != nil ? snapshot.displayName : readingAge)) {
                ProviderGlyphView(glyph: snapshot.glyph, customIconFilename: snapshot.customIconFilename)
                    .foregroundStyle(Palette.textPrimary)
            }

            if let block = snapshot.block {
                BlockedRow(text: block.summary(now: now))
                    .padding(.top, NotchLayout.headerToBlock)
            }

            if let message = snapshot.statusMessage {
                Text(message)
                    .font(Typography.cardBody)
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, NotchLayout.headerToBlock)
            } else if let localModel = snapshot.localModel {
                RuntimeModelDetails(model: localModel, performance: snapshot.localPerformance,
                                    showsPerformance: snapshot.showsLocalPerformance,
                                    ledger: snapshot.localLedger, now: now)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(groupedWindows.enumerated()), id: \.element.id) { groupIndex, group in
                        if let title = group.title {
                            VStack(alignment: .leading, spacing: Design.px(12)) {
                                Text(title)
                                    .font(Typography.cardBody)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Palette.textPrimary)
                                    .padding(.leading, Design.px(4))

                                VStack(alignment: .leading, spacing: NotchLayout.blockSpacing) {
                                    ForEach(Array(group.windows.enumerated()), id: \.element.id) { windowIndex, window in
                                        LimitWindowRow(window: window, inset: 2 * Design.px(16), fidelity: snapshot.fidelity, now: now, resetTimeFormat: resetTimeFormat, showsUsagePace: showUsagePace)
                                            .padding(.top, windowIndex == 0 ? 0 : NotchLayout.blockSpacing)
                                    }
                                }
                                .padding(Design.px(16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Design.px(20))
                                        .stroke(Color.white.opacity(0.25), lineWidth: Design.px(1.5))
                                )
                            }
                            .padding(.top, groupIndex == 0 ? NotchLayout.headerToBlock : Design.px(28))
                        } else {
                            ForEach(Array(group.windows.enumerated()), id: \.element.id) { windowIndex, window in
                                LimitWindowRow(window: window, fidelity: snapshot.fidelity, now: now, resetTimeFormat: resetTimeFormat, showsUsagePace: showUsagePace)
                                    .padding(.top, (groupIndex == 0 && windowIndex == 0) ? NotchLayout.headerToBlock : NotchLayout.blockSpacing)
                            }
                        }
                    }
                }
                .padding(.bottom, groupedWindows.contains(where: { $0.title != nil }) ? Design.px(8) : 0)
            }
        }
    }
}

private struct RuntimeModelDetails: View {
    let model: LocalRuntimeReading.Model
    let performance: LocalModelPerformance?
    let showsPerformance: Bool
    /// Present for a runtime that logs its requests; five more rows, counted
    /// in `ProviderSnapshot.localLedgerRowCount`.
    let ledger: LocalTokenLedger.Summary?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.name)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(height: NotchLayout.modelNameHeight(model.name), alignment: .topLeading)
                .padding(.top, NotchLayout.headerToBlock)
                .accessibilityLabel(model.name)
            VStack(spacing: NotchLayout.sessionRowGap) {
                if showsPerformance {
                    SplitRow(leading: "Last speed (derived)", trailing: performance?.speedText ?? "Not measured",
                             trailingColor: performance?.band.color)
                    SplitRow(leading: "Speed band", trailing: performance?.band.label ?? "—")
                }
                SplitRow(leading: model.memoryLabel, trailing: model.displayedMemoryBytes == nil ? "Unavailable" : model.memoryText)
                SplitRow(leading: "Context limit", trailing: model.contextText)
                SplitRow(leading: "Quantization", trailing: model.quantizationText)
                SplitRow(leading: "Unloads", trailing: model.unloadText(now: now))
                if showsPerformance {
                    SplitRow(leading: "Measured", trailing: performance.map { ElapsedCopy.ago(since: $0.measuredAt, now: now) } ?? "—")
                }
                if let ledger {
                    SplitRow(leading: "Context used", trailing: ledger.contextText(contextLength: model.contextLength))
                    SplitRow(leading: "Tokens today", trailing: ledger.tokensTodayText)
                    SplitRow(leading: "Requests today", trailing: ledger.requestsTodayText)
                    SplitRow(leading: "Reasoning share", trailing: ledger.reasoningShareText)
                    SplitRow(leading: "Draft accepted", trailing: ledger.draftAcceptanceText)
                }
            }
            .padding(.top, NotchLayout.blockSpacing)
        }
        .font(Typography.cardBody)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum UsageFormat {
    static func tokens(_ value: Int?) -> String {
        guard let value else { return "—" }
        switch value {
        case 1_000_000_000...:
            return String(format: "%.2fB", locale: Locale(identifier: "en_US_POSIX"),
                          Double(value) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", locale: Locale(identifier: "en_US_POSIX"),
                          Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.0fK", locale: Locale(identifier: "en_US_POSIX"),
                          Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    static func duration(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 {
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        return "\(minutes)m"
    }

    static func days(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value)d"
    }
}

private struct CodexMetric: Identifiable {
    let id: String
    let value: String
    let label: String
}

private struct CodexMetricList: View {
    let metrics: [CodexMetric]
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        VStack(alignment: .leading, spacing: NotchLayout.codexMetricRowGap) {
            ForEach(metrics) { metric in
                HStack(alignment: .firstTextBaseline, spacing: Design.px(20)) {
                    Text(metric.label)
                        .font(Typography.cardBody)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(metric.value)
                        .font(Typography.cardBody)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                .frame(height: NotchLayout.codexMetricRowHeight)
            }
        }
        .frame(height: NotchLayout.codexMetricHeight)
    }
}

private struct CodexDailyUsageChart: View {
    let buckets: [CodexTokenUsage.DailyBucket]
    let maximum: Int
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(Palette.ringTrack)
                    .frame(height: NotchLayout.hairline)

                HStack(alignment: .bottom, spacing: Design.px(4)) {
                    ForEach(buckets) { bucket in
                        RoundedRectangle(cornerRadius: Design.px(3), style: .continuous)
                            .fill(secondaryInk)
                            .frame(maxWidth: .infinity)
                            .frame(height: proxy.size.height
                                   * CGFloat(bucket.tokens) / CGFloat(maximum))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: NotchLayout.codexChartHeight)
        .clipped()
    }
}

/// Unused rate-limit resets on the Codex account.
private struct CodexResetCreditsSection: View {
    let credits: CodexResetCredits
    let now: Date
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    private var countText: String {
        switch credits.availableCount {
        case 0: return L10n.t("No unused resets")
        case 1: return L10n.t("1 unused reset")
        case let n: return L10n.t("\(n) unused resets")
        }
    }

    private var expiryText: String? {
        guard credits.availableCount > 0, let date = credits.nextExpiry, date > now else {
            return nil
        }
        let stamp = Self.stamp(for: date, now: now)
        return credits.availableCount > 1
            ? L10n.t("Next expires \(stamp)")
            : L10n.t("Expires \(stamp)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Palette.ringTrack)
                .frame(height: NotchLayout.hairline)
                .padding(.top, NotchLayout.codexUsageTop)

            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t("Unused resets"))
                    .font(Typography.cardBody)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.top, NotchLayout.blockSpacing)

                Text(countText)
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .padding(.top, NotchLayout.codexUsageRowGap)

                if let expiryText {
                    Text(expiryText)
                        .font(Typography.cardBody)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                        .padding(.top, NotchLayout.codexUsageRowGap)
                }
            }
            .frame(height: NotchLayout.codexResetCreditsHeight, alignment: .top)
        }
    }

    /// Same date templates `ResetCopy` uses past the hour, so this line and
    /// the quota rows agree on what "soon" looks like.
    private static func stamp(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = ResetCopy.formatter(for: calendar)
        formatter.locale = L10n.locale
        if ResetCopy.daysApart(from: now, to: date, calendar: calendar) >= 7 {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("E j:mm")
        }
        return formatter.string(from: date)
    }
}

/// Account-wide Codex activity. Unlike the quota rows above, this is sourced
/// from the Codex profile usage endpoint and is not a local estimate.
private struct CodexUsageSection: View {
    let usage: CodexTokenUsage
    let now: Date

    private var buckets: [CodexTokenUsage.DailyBucket] {
        usage.last30Days(now: now)
    }

    private var maximum: Int {
        max(1, buckets.map(\.tokens).max() ?? 0)
    }

    private var todayText: String {
        usage.usageToday(now: now).map { UsageFormat.tokens($0) } ?? L10n.t("Pending")
    }

    private var metrics: [CodexMetric] {
        let summary = usage.summary
        return [
            CodexMetric(id: "lifetime", value: UsageFormat.tokens(summary?.lifetimeTokens),
                        label: L10n.t("Lifetime tokens")),
            CodexMetric(id: "peak", value: UsageFormat.tokens(summary?.peakDailyTokens),
                        label: L10n.t("Peak tokens")),
            CodexMetric(id: "longest", value: UsageFormat.duration(
                seconds: summary?.longestRunningTurnSeconds), label: L10n.t("Longest chat")),
            CodexMetric(id: "current-streak", value: UsageFormat.days(
                summary?.currentStreakDays), label: L10n.t("Current streak")),
            CodexMetric(id: "longest-streak", value: UsageFormat.days(
                summary?.longestStreakDays), label: L10n.t("Longest streak"))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Palette.ringTrack)
                .frame(height: NotchLayout.hairline)
                .padding(.top, NotchLayout.codexUsageTop)

            CodexMetricList(metrics: metrics)
                .padding(.top, NotchLayout.codexMetricTop)
                .padding(.bottom, NotchLayout.codexMetricBottom)

            Rectangle()
                .fill(Palette.ringTrack)
                .frame(height: NotchLayout.hairline)

            SplitRow(leading: L10n.t("Today"), trailing: todayText)
                .padding(.top, NotchLayout.blockSpacing)
            SplitRow(leading: L10n.t("30-day tokens"),
                     trailing: UsageFormat.tokens(usage.usageInLast30Days(now: now)))
                .padding(.top, NotchLayout.codexUsageRowGap)
            CodexDailyUsageChart(buckets: buckets, maximum: maximum)
                .padding(.top, NotchLayout.codexChartTop)
        }
    }
}

/// The line that says you are stopped.
///
/// Deliberately loud where the rest of the card is quiet: it is the one thing
/// here that changes what you can do next, and it can be true while the
/// percentage beside it still reads comfortable.
private struct BlockedRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NotchLayout.statusDotGap) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: NotchLayout.statusDot))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(Typography.cardBody)
        .foregroundStyle(Palette.critical)
    }
}

// MARK: - Activity

private struct SessionRow: View {
    let session: AgentSession
    let now: Date
    /// Set when rows can be clicked to jump to the session's terminal.
    var onFocus: ((pid_t) -> Void)? = nil
    @Environment(\.codenotchAccentColor) private var accentColor
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    private var stateColor: Color {
        switch session.state {
        case .busy:    return Palette.textPrimary
        case .waiting: return Palette.watch
        case .success: return Palette.ample
        case .idle:    return secondaryInk
        }
    }

    private var stateWord: String {
        switch session.state {
        case .busy:    return L10n.t("working")
        case .waiting: return L10n.t("waiting")
        case .success: return L10n.t("complete")
        case .idle:    return L10n.t("idle")
        }
    }

    /// While blocked, what it is blocked on matters more than where it lives.
    private var detail: String {
        if session.state == .waiting, let waitingFor = session.waitingFor, !waitingFor.isEmpty {
            return waitingFor
        }
        return session.detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SplitRow(leading: session.name, trailing: stateWord,
                     trailingColor: stateColor) {
                StatusRing(state: session.state, color: stateColor)
            }
            SplitRow(
                leading: detail,
                trailing: ElapsedCopy.text(since: session.since, now: now),
                leadingColor: secondaryInk
            )
            .padding(.top, NotchLayout.sessionRowGap)
        }
        // Sessions that publish a pid can be jumped to; the rest are text,
        // and a gesture on them would promise something it cannot do.
        .contentShape(Rectangle())
        .onTapGesture {
            guard let pid = session.processID else { return }
            onFocus?(pid)
        }
    }
}

/// The live sessions for this provider, under a rule that separates them from
/// the limit windows above — they answer a different question.
private struct SessionList: View {
    let summary: ActivitySummary
    let now: Date
    /// How many rows this screen has room for; the rest are counted.
    let cap: Int
    var onFocus: ((pid_t) -> Void)? = nil
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    /// Busy sessions first, so what is hidden is what matters least.
    private var ordered: [AgentSession] {
        summary.sessions.sorted { a, b in
            let rank: (AgentSession) -> Int = {
                switch $0.state { case .waiting: 0; case .busy: 1; case .success: 2; case .idle: 3 }
            }
            return rank(a) == rank(b) ? a.since > b.since : rank(a) < rank(b)
        }
    }

    private var shown: [AgentSession] { Array(ordered.prefix(max(0, cap))) }
    private var hidden: Int { max(0, summary.sessions.count - shown.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Palette.ringTrack)
                .frame(height: NotchLayout.hairline)
                .padding(.top, NotchLayout.blockSpacing)

            // Only as many as the card's budgeted height can hold. The rest
            // are counted rather than drawn: the card is clipped, not scrolled,
            // so anything past the budget silently pushes the title off the top.
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                SessionRow(session: session, now: now, onFocus: onFocus)
                    .padding(.top, NotchLayout.blockSpacing)
            }

            if hidden > 0 {
                Text(L10n.t("and \(hidden) more"))
                    .font(Typography.cardBody)
                    .foregroundStyle(secondaryInk)
                    .padding(.top, NotchLayout.blockSpacing)
            }
        }
    }
}

// MARK: - Entry point

struct TooltipCard: View {
    let snapshot: ProviderSnapshot
    var activity: ActivitySummary?
    let now: Date
    /// Which way the card sits from the notch, which follows from the edge.
    var direction: NotchEdge.TooltipDirection = .leading
    /// How many sessions this screen has room to list. Solved from the display
    /// rather than fixed, so a big screen hides nothing.
    var sessionCap: Int = NotchLayout.defaultSessionCap
    /// Task rows the tasks card may list.
    var taskRows: Int = TasksCard.maxRows
    var resetTimeFormat: ResetTimeFormat = .automatic
    var deepSeekPricingEnabled: Bool = true
    var deepSeekPricingSchedule: DeepSeekPricing.Schedule = .current
    var tailOffset: CGFloat = 0
    /// A tap on a session row jumps to that session's terminal — nil leaves
    /// the rows as plain text.
    var onFocusSession: ((pid_t) -> Void)? = nil
    @AppStorage(Preferences.showUsagePaceKey) private var showUsagePace = false

    /// The phase a local model is in, and the queue behind it, for the header.
    /// Ollama's relay only knows thinking; LM Studio's poll names the phase.
    private var localActivityNote: String? {
        guard snapshot.localModel != nil, let activity, activity.state == .working else { return nil }
        return activity.note ?? activity.sessions.first?.name ?? L10n.t("Thinking")
    }

    /// The same figure the hover region uses, so what is drawn and what is
    /// reachable can never drift apart.
    private var height: CGFloat {
        if snapshot.id == TasksProvider.providerID { return TasksCard.height(rows: taskRows) }
        return NotchLayout.cardHeight(
            windowCount: snapshot.windows.count,
            groupCount: snapshot.windowGroupCount,
            moneyWindowCount: snapshot.windows.filter { $0.money != nil }.count,
            usageDetailGroupCount: snapshot.usageDetail?.visibleGroups.count ?? 0,
            sessionCount: snapshot.localModel == nil ? (activity?.sessions.count ?? 0) : 0,
            sessionCap: sessionCap,
            statusMessage: snapshot.statusMessage,
            blockMessage: snapshot.block?.summary(now: now),
            hasTokenUsage: snapshot.tokenUsage != nil,
            hasPlan: snapshot.plan != nil,
            hasResetCredits: snapshot.hasAvailableResetCredits,
            localModelName: snapshot.localModel?.name,
            showsLocalPerformance: snapshot.showsLocalPerformance,
                localLedgerRows: snapshot.localLedgerRowCount,
            compactRowCount: snapshot.compactRowCount,
            showsDeepSeekPricing: deepSeekPricingEnabled
        )
    }

    var body: some View {
        TooltipShell(height: height, direction: direction, tailOffset: tailOffset) {
            // Stacked, not replaced in place: during a swap both sets of rows
            // exist for a moment, and in a ZStack they overlap and dissolve
            // instead of shoving each other around. Top-aligned so neither
            // drifts while the card resizes around them.
            ZStack(alignment: .topLeading) {
                if snapshot.id == TasksProvider.providerID {
                    TasksCard(now: now, rows: taskRows)
                        .id(snapshot.id)
                        .transition(.opacity.animation(NotchMotion.crossfade))
                } else {
                VStack(alignment: .leading, spacing: 0) {
                    ProviderTooltip(activityNote: localActivityNote, snapshot: snapshot, now: now, resetTimeFormat: resetTimeFormat,
                                    showUsagePace: showUsagePace)
                    if let resetCredits = snapshot.resetCredits,
                       snapshot.hasAvailableResetCredits {
                        CodexResetCreditsSection(credits: resetCredits, now: now)
                    }
                    if let tokenUsage = snapshot.tokenUsage {
                        CodexUsageSection(usage: tokenUsage, now: now)
                    }
                    if let usageDetail = snapshot.usageDetail, usageDetail.hasUsage {
                        DeepSeekUsageDetail(detail: usageDetail, now: now,
                                            schedule: deepSeekPricingSchedule,
                                            showsPricing: deepSeekPricingEnabled)
                    }
                    if let activity, snapshot.localModel == nil {
                        SessionList(summary: activity, now: now, cap: sessionCap,
                                    onFocus: onFocusSession)
                    }
                }
                // An identity, so one provider's rows are never interpolated
                // into another's — that is what slid text through positions
                // belonging to neither layout. A crossfade rather than an
                // instant swap, so the change is part of the movement instead
                // of a cut in the middle of it.
                .id(snapshot.id)
                .transition(.opacity.animation(NotchMotion.crossfade))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
