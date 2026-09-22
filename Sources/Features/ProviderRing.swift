import AppKit
import SwiftUI

/// The ring around a provider glyph: a grey track with a coloured arc that
/// starts at 12 o'clock and sweeps clockwise by the fraction used.
///
/// When that provider is doing something right now, a second, much thinner arc
/// appears *inside* the ring, in the gap between the glyph and the track. It is
/// deliberately a different radius, a different weight and a neutral colour, so
/// it reads as a separate fact rather than as the usage number moving.
struct ProviderRing: View {
    /// Nil when the provider reports what is left but never says out of what —
    /// there is no arc to draw, and inventing one would be a lie in a shape.
    let usedFraction: Double?
    let glyph: ProviderGlyph
    var customIconFilename: String? = nil
    var isStale: Bool = false
    /// Blocked right now. Shown as spent whatever the arc says, because that is
    /// what it means for you — a ring reading 16% while the account is paused
    /// is technically true and practically a lie.
    var isBlocked: Bool = false
    var activity: ActivitySummary?
    /// A fetch this cell asked for, in flight.
    var isRefreshing: Bool = false
    var localPerformance: LocalModelPerformance?
    /// A local model's arc: how full its context was on the last request. Nil
    /// draws the whole ring, which is what a runtime that does not say gets.
    var localContextFraction: Double?
    /// The weekly limit, when the provider has one. Nil is the ordinary case
    /// for a provider with a single window, and draws nothing.
    var weeklyFraction: Double?
    /// Where the user asked for it, if at all.
    var weeklyRing: WeeklyRing = .off
    /// A colour of the provider's own for the arc, when the reading is not a
    /// share of a limit: a focus block runs violet whatever its progress.
    var tint: Color? = nil
    var bandOverride: UsageBand? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @Environment(\.usageWatchLimit) private var watchLimit
    @Environment(\.usageCriticalLimit) private var criticalLimit
    @Environment(\.codenotchAccentColor) private var accentColor
    @Environment(\.weeklyRingDashed) private var weeklyRingDashed
    @State private var spin: Double = 0

    private var band: UsageBand {
        guard !isBlocked else { return .exhausted }
        if let bandOverride { return bandOverride }
        return UsageBand.band(for: usedFraction ?? 0, watchLimit: watchLimit, criticalLimit: criticalLimit)
    }
    private var sweep: CGFloat { CGFloat(min(max(usedFraction ?? 0, 0), 1)) }
    private var localSweep: CGFloat { Self.localSweep(for: localContextFraction) }
    /// The floor is a drawing decision only — the number under the ring and in
    /// the card stays true.
    static func localSweep(for contextFraction: Double?) -> CGFloat {
        guard let contextFraction else { return 1 }
        return max(NotchLayout.localArcMinimumSweep, CGFloat(min(max(contextFraction, 0), 1)))
    }
    private var primaryColor: Color {
        if isStale { return Palette.textSecondary }
        if let tint { return tint }
        return band.color(accent: accentColor)
    }

    private var weeklyBand: UsageBand {
        isBlocked ? .exhausted : UsageBand.band(for: weeklyFraction ?? 0, watchLimit: watchLimit, criticalLimit: criticalLimit)
    }
    private var weeklySweep: CGFloat { CGFloat(min(max(weeklyFraction ?? 0, 0), 1)) }

    /// Inside, the weekly ring and the working indicator want the same band —
    /// 1.03pt apart, one of them spinning. Rather than shave both until neither
    /// is legible, the transient one wins: while a provider is working that is
    /// the more urgent fact, and the week is still a hover away. Outside there
    /// is no contest, so nothing is given up there.
    private var isWorking: Bool {
        weeklyRing == .inside && activity != nil && activity?.state != .idle
    }

    var body: some View {
        ZStack {
            // Dimming applies to the usage reading only. Whether Claude is
            // working right now is known first-hand and stays at full strength
            // even when the percentage behind it has gone stale.
            ZStack {
                Circle()
                    .strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.trackStroke)

                if localPerformance != nil || localContextFraction != nil {
                    // Two facts on one ring: the arc is the context filling up,
                    // the colour is the last response's speed. Inset by half the
                    // stroke so a full arc lands exactly where the solid
                    // `strokeBorder` ring used to, and a runtime with no context
                    // reading looks as it always did. Grey until a speed exists:
                    // the quota colours would say something a local model has
                    // no quota to mean.
                    Circle()
                        .inset(by: NotchLayout.progressStroke / 2)
                        .trim(from: 0, to: localSweep)
                        .stroke(
                            localPerformance?.band.color ?? Palette.textSecondary,
                            style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(NotchMotion.reading, value: localSweep)
                        .animation(NotchMotion.reading, value: localPerformance?.band)
                } else if usedFraction != nil {
                    Circle()
                        .inset(by: NotchLayout.trackStroke / 2)
                        .trim(from: 0, to: sweep)
                        .stroke(
                            tint ?? band.color(accent: accentColor),
                            style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round)
                        )
                        // Refreshing spins the reading itself rather than
                        // overlaying a separate spinner: the thing being
                        // refetched is the thing that should move, and a second
                        // arc on the same track only competes with it.
                        .rotationEffect(.degrees(-90 + spin))
                        // A ring that snaps to a new value reads as a glitch; one
                        // that sweeps reads as a measurement being taken.
                        .animation(NotchMotion.reading, value: sweep)
                        .animation(NotchMotion.reading, value: band)
                }

                // The weekly limit, when there is one and it has been asked
                // for. Same start and direction as the headline arc, so the
                // two are read the same way round; thinner and at its own
                // radius, so which is which never has to be worked out.
                //
                // It carries its own band colour rather than borrowing the
                // headline's: a session at 12% beside a week at 91% is exactly
                // the case this exists for, and painting them the same colour
                // would hide it. Held slightly back in opacity so the headline
                // stays the one the eye lands on first.
                if let radius = weeklyRing.radius, weeklyFraction != nil, !isWorking {
                    let inset = NotchLayout.ringDiameter / 2 - radius

                    // A track of its own, for the same reason the headline has
                    // one: a week nobody has spent yet draws an arc of zero
                    // length, and without something behind it that is
                    // indistinguishable from the feature being broken. Codex
                    // opened its week at 0% and read as missing.
                    Circle()
                        .inset(by: inset)
                        .stroke(Palette.ringTrack,
                                style: StrokeStyle(lineWidth: NotchLayout.weeklyRingStroke,
                                                   dash: weeklyRingDashed ? [4, 2] : []))
                        .opacity(reduceTransparency ? 1 : 0.7)

                    Circle()
                        .inset(by: inset)
                        .trim(from: 0, to: weeklySweep)
                        .stroke(
                            weeklyBand.color(accent: accentColor),
                            style: StrokeStyle(lineWidth: NotchLayout.weeklyRingStroke,
                                               lineCap: weeklyRingDashed ? .butt : .round,
                                               dash: weeklyRingDashed ? [4, 2] : [])
                        )
                        .opacity(reduceTransparency ? 1 : 0.8)
                        .rotationEffect(.degrees(-90))
                        .animation(NotchMotion.reading, value: weeklySweep)
                        .animation(NotchMotion.reading, value: weeklyBand)
                }

                ProviderGlyphView(glyph: glyph, customIconFilename: customIconFilename)
                    .foregroundStyle(Palette.textPrimary)
                    // A spent limit dims its glyph so the ring reads as "waiting".
                    // Under reduce-transparency, boost opacity so it stays legible without low alpha.
                    .opacity(band == .exhausted ? (reduceTransparency ? 0.7 : 0.35) : 1)
            }
            .opacity(isStale ? (reduceTransparency ? 0.75 : 0.45) : 1)

            if let activity, activity.state != .idle {
                ActivityArc(summary: activity)
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
        // Pressed in while it works, and released when the answer lands. The
        // ring is the button, so the ring is what should feel pressed.
        .scaleEffect(isRefreshing ? 0.93 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isRefreshing)
        .onChange(of: isRefreshing) { _, refreshing in
            guard refreshing, !reduceMotion else { return }
            // Exactly one turn, and it stops by itself.
            //
            // The obvious spelling is a `repeatForever` linear spin started on
            // the way in and cancelled on the way out — but `repeatForever` does
            // not stop when you set the value back, and if the value you set is
            // the one it is already animating toward, nothing changes and it
            // simply keeps going. The ring then spins for ever after a refresh
            // that finished half a second in.
            //
            // A single finite turn has no cancellation problem at all: 360° is
            // the same angle as 0°, so it lands exactly where the reading
            // belongs. It eases out, so it settles rather than stopping dead.
            withAnimation(.timingCurve(0.32, 0, 0.14, 1, duration: 0.95)) {
                spin += 360
            }
        }
    }
}

/// The inner indicator: a short arc that spins while work is happening, and a
/// full pulsing ring when something is blocked waiting on you.
private struct ActivityArc: View {
    let summary: ActivitySummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @State private var pulsing = false

    /// How much of the circle the moving arc covers.
    private let arcFraction: CGFloat = 0.25

    private var inset: CGFloat {
        (NotchLayout.ringDiameter - NotchLayout.activityDiameter) / 2
    }

    var body: some View {
        Group {
            switch summary.state {
            case .working: spinner
            case .waiting, .success: pulse
            case .idle:    EmptyView()
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
    }

    /// Dots are a line of things: with requests queued behind the running one
    /// the arc becomes a ring of them, still turning, so a backed-up model is
    /// told apart from a busy one at a glance.
    private var queued: Bool { summary.queued > 0 }

    /// Turned by Core Animation, not by SwiftUI.
    ///
    /// A `repeatForever` rotation re-runs the hosting view's layout on every
    /// frame, and the notch is one hosting view: while any session was working
    /// that alone kept the app near 4% of a core, which is most of the time
    /// for anyone who leaves Claude Code running. A layer animation is carried
    /// out by the render server and costs the app nothing between frames.
    private var spinner: some View {
        SpinningArc(
            color: summary.color,
            arcFraction: queued ? 1 : arcFraction,
            dashed: queued,
            inset: inset,
            turns: !reduceMotion
        )
    }

    private var pulse: some View {
        Circle()
            .inset(by: inset)
            .stroke(summary.color, lineWidth: NotchLayout.activityStroke)
            .opacity(pulsing ? (reduceTransparency ? 0.65 : 0.3) : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .onDisappear { pulsing = false }
    }
}

struct ProviderCell: View {
    let snapshot: ProviderSnapshot
    var activity: ActivitySummary?
    var isRefreshing: Bool = false
    var weeklyRing: WeeklyRing = .off

    /// A running focus ticks every second, straight from its store, rather
    /// than waiting for the next provider poll.
    @ObservedObject private var focus = FocusStore.shared

    private var isFocusClock: Bool { snapshot.headlineID == "focus" && focus.isActive }

    /// A dash, not "0%": nothing read is not the same as nothing used.
    private var readingText: String {
        if isFocusClock { return FocusStore.clock(focus.elapsed) }
        return snapshot.hasReading ? snapshot.headlineText : "—"
    }

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ProviderRing(
                usedFraction: snapshot.localModel == nil && snapshot.hasReading ? snapshot.ringFraction : nil,
                glyph: snapshot.glyph,
                customIconFilename: snapshot.customIconFilename,
                isStale: snapshot.status.isStale || !snapshot.hasReading,
                isBlocked: snapshot.block != nil,
                activity: activity,
                isRefreshing: isRefreshing,
                localPerformance: snapshot.localPerformance,
                localContextFraction: snapshot.localContextFraction,
                weeklyFraction: snapshot.hasReading ? snapshot.weeklyFraction : nil,
                weeklyRing: weeklyRing,
                tint: snapshot.headlineID == "focus" ? TaskColors.violet : nil,
                bandOverride: snapshot.bandOverride
            )
            Text(readingText)
                .font(Typography.percent)
                .foregroundStyle(snapshot.showsLocalPerformance && snapshot.localPerformance == nil
                                 ? Palette.textSecondary : Palette.textPrimary)
                // Keep local speeds inside the ring's column so longer units
                // cannot consume the notch's existing side margins.
                .lineLimit(1)
                .minimumScaleFactor(snapshot.localModel == nil ? 1 : 0.5)
                .fixedSize(horizontal: snapshot.localModel == nil, vertical: false)
                .frame(width: snapshot.localModel == nil ? nil : NotchLayout.ringDiameter,
                       height: NotchLayout.percentLineHeight)
                // A clock ticking every second is swapped, not animated: the
                // rolling digits cost a burst of frames each tick, and the
                // whole panel composites again for every one of them.
                .contentTransition(isFocusClock ? .identity : .numericText())
                .animation(isFocusClock ? nil : NotchMotion.reading, value: readingText)
        }
        .frame(height: NotchLayout.cellExtent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Everything the cell says, as one sentence for VoiceOver and the tests.
    var accessibilityText: String {
        snapshot.localModel.map {
            "\($0.brand.map { "\($0.displayName), " } ?? "")\($0.name), \(snapshot.displayName) local, \(snapshot.showsLocalPerformance ? (snapshot.localPerformance.map { "Last generation speed \($0.speedText), \($0.band.label)" } ?? "Speed not measured") : "Loaded"), \($0.detail)\(localActivityText)\(localLedgerText)"
        } ?? "\(snapshot.displayName), \(readingText)"
    }

    /// What the model is doing, the way the tooltip's header says it.
    private var localActivityText: String {
        guard let activity, activity.state == .working else { return "" }
        let phase = activity.sessions.first?.name ?? "Working"
        return activity.queued > 0 ? ", \(phase), \(activity.queued) queued" : ", \(phase)"
    }

    private var localLedgerText: String {
        guard let ledger = snapshot.localLedger else { return "" }
        let context = snapshot.localContextFraction.map { ", Context \(Percent.text(for: $0))% full" } ?? ""
        return "\(context), Tokens today \(ledger.tokensTodayText), \(ledger.requestsTodayText) requests"
    }
}

private struct WeeklyRingDashedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var weeklyRingDashed: Bool {
        get { self[WeeklyRingDashedKey.self] }
        set { self[WeeklyRingDashedKey.self] = newValue }
    }
}

/// The working arc as a shape layer: a quarter of the activity circle from
/// 3 o'clock clockwise, or the whole circle as dots while requests are queued,
/// turning clockwise once every 1.1 seconds.
private struct SpinningArc: NSViewRepresentable {
    let color: Color
    let arcFraction: CGFloat
    let dashed: Bool
    let inset: CGFloat
    let turns: Bool

    func makeNSView(context: Context) -> SpinningArcView { SpinningArcView() }

    func updateNSView(_ view: SpinningArcView, context: Context) {
        view.configure(color: NSColor(color), arcFraction: arcFraction,
                       dashed: dashed, inset: inset, turns: turns)
    }
}

final class SpinningArcView: NSView {
    static let turnDuration: CFTimeInterval = 1.1
    static let animationKey = "turn"

    let arc = CAShapeLayer()
    private var color: NSColor = .white
    private var inset: CGFloat = 0
    private var turns = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        arc.lineWidth = NotchLayout.activityStroke
        arc.strokeStart = 0
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Decoration only: clicks belong to the ring and the notch beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: NSColor, arcFraction: CGFloat, dashed: Bool, inset: CGFloat, turns: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.color = color
        self.inset = inset
        self.turns = turns
        arc.strokeEnd = arcFraction
        arc.lineDashPattern = dashed
            ? [0.01, NSNumber(value: Double(NotchLayout.activityStroke * 2.2))]
            : nil
        applyColor()
        rebuildPath()
        CATransaction.commit()
        updateAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuildPath()
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arc.strokeColor = color.cgColor
        }
    }

    /// The layer's own coordinates run y-up, so a visually clockwise circle
    /// starting at 3 o'clock is drawn with decreasing angles — the same start
    /// and direction as SwiftUI's `Circle().trim(from: 0, …)`.
    private func rebuildPath() {
        arc.frame = bounds
        let radius = max(0, min(bounds.width, bounds.height) / 2 - inset)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                    startAngle: 0, endAngle: -2 * .pi, clockwise: true)
        arc.path = path
    }

    /// Re-added whenever it has gone missing: AppKit drops layer animations
    /// when a window leaves the screen, and the notch's panel does.
    private func updateAnimation() {
        guard turns, window != nil else {
            arc.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard arc.animation(forKey: Self.animationKey) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = Self.turnDuration
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: Self.animationKey)
    }
}
