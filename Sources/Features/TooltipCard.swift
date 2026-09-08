import SwiftUI

/// The speech-bubble tail, its point aimed at the hovered cell.
private struct TooltipTail: Shape {
    /// Which way the card sits relative to the notch — the tip points back the
    /// other way, at the cell.
    let direction: NotchEdge.TooltipDirection

    func path(in rect: CGRect) -> Path {
        // The tip, and the two corners of the base opposite it.
        let (tip, a, b): (CGPoint, CGPoint, CGPoint)
        switch direction {
        case .leading:   // card on the left, tip to the right
            tip = CGPoint(x: rect.maxX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
        case .trailing:  // card on the right, tip to the left
            tip = CGPoint(x: rect.minX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
        case .down:      // card below, tip upward
            tip = CGPoint(x: rect.midX, y: rect.minY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY))
        case .up:        // card above, tip downward
            tip = CGPoint(x: rect.midX, y: rect.maxY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
        }

        var path = Path()
        path.move(to: a)
        path.addLine(to: tip)
        path.addLine(to: b)
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
    @ViewBuilder let content: Content

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
                .fill(Palette.card)
                .frame(width: NotchLayout.cardWidth, height: height)

            content
                .padding(NotchLayout.cardPadding)
                .frame(width: NotchLayout.cardWidth, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: height, alignment: .top)
        .clipShape(
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
        )
    }

    private var tail: some View {
        let size = TooltipTail.size(for: direction)
        // The tail is deliberately outside the clip: it is part of the card's
        // silhouette, not of its contents.
        return TooltipTail(direction: direction)
            .fill(Palette.card)
            .frame(width: size.width, height: size.height)
    }

    var body: some View {
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
    /// Sits on the header's own line, so saying when a reading was taken costs
    /// the card no extra height.
    var note: String?
    @ViewBuilder let mark: Mark

    var body: some View {
        HStack(spacing: NotchLayout.headerGap) {
            mark
            Text(title)
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.textPrimary)
            if let note {
                Spacer(minLength: Design.px(20))
                Text(note)
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A label on the left and a quieter value on the right — the row shape the
/// design frame uses throughout.
private struct SplitRow<Accessory: View>: View {
    let leading: String
    let trailing: String
    var leadingColor: Color = Palette.textPrimary
    var trailingColor: Color = Palette.textSecondary
    /// Sits immediately before the trailing text, inside the same group, so it
    /// travels with the word instead of drifting to the middle of the row.
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Design.px(20)) {
            Text(leading).foregroundStyle(leadingColor)
            Spacer(minLength: 0)
            HStack(spacing: NotchLayout.statusDotGap) {
                accessory()
                Text(trailing).foregroundStyle(trailingColor)
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
         trailingColor: Color = Palette.textSecondary) {
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
            case .waiting:
                // Half a ring, held still: blocked, not progressing.
                ring(trim: 0.5)
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
    let fidelity: Fidelity
    let now: Date

    private var band: UsageBand { UsageBand.band(for: window.usedFraction ?? 0) }
    private var trackWidth: CGFloat { NotchLayout.cardWidth - 2 * NotchLayout.cardPadding }
    private var fillWidth: CGFloat {
        let fraction = CGFloat(min(max(window.usedFraction ?? 0, 0), 1))
        return max(NotchLayout.barHeight, trackWidth * fraction)
    }

    /// Blank rather than invented: some providers never say when the window rolls.
    private var resetText: String {
        window.resetsAt.map { ResetCopy.text(for: $0, now: now) } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SplitRow(leading: window.label, trailing: resetText)

            // No bar without a denominator — an empty track would read as "none
            // used", which is not what "we do not know the limit" means.
            if window.usedFraction != nil {
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.barTrack)
                    Capsule().fill(band.color).frame(width: fillWidth)
                }
                .frame(width: trackWidth, height: NotchLayout.barHeight)
                .padding(.top, NotchLayout.labelToBar)
            }

            Text("\(window.usedFraction == nil ? "" : fidelity.qualifier)\(window.summary)")
                .font(Typography.cardBody)
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, NotchLayout.barToUsed)
        }
    }
}

private struct ProviderTooltip: View {
    let snapshot: ProviderSnapshot
    let now: Date

    /// Only worth saying when the numbers are not current. A remembered reading
    /// has to be dated, or it quietly passes itself off as live.
    private var readingAge: String? {
        guard snapshot.hasReading, let since = snapshot.status.staleSince,
              since != .distantPast
        else { return nil }
        return ElapsedCopy.ago(since: since, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TooltipHeader(title: "\(snapshot.displayName) Usage", note: readingAge) {
                ProviderGlyphView(glyph: snapshot.glyph)
                    .foregroundStyle(Palette.textPrimary)
            }

            if let block = snapshot.block {
                BlockedRow(text: block.summary(now: now))
                    .padding(.top, NotchLayout.headerToBlock)
            }

            if let message = snapshot.statusMessage {
                Text(message)
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, NotchLayout.headerToBlock)
            } else {
                ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { index, window in
                    LimitWindowRow(window: window, fidelity: snapshot.fidelity, now: now)
                        .padding(.top, index == 0 ? NotchLayout.headerToBlock : NotchLayout.blockSpacing)
                }
            }
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
    @State private var isHovered = false

    private var stateColor: Color {
        switch session.state {
        case .busy:    return Palette.ample
        case .waiting: return Palette.watch
        case .idle:    return Palette.textSecondary
        }
    }

    private var stateWord: String {
        switch session.state {
        case .busy:    return "working"
        case .waiting: return "waiting"
        case .idle:    return "idle"
        }
    }

    /// While blocked, what it is blocked on matters more than where it lives.
    private var detail: String {
        if session.state == .waiting, let waitingFor = session.waitingFor, !waitingFor.isEmpty {
            return waitingFor
        }
        return session.detail
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SplitRow(leading: session.name, trailing: stateWord,
                     trailingColor: stateColor) {
                StatusRing(state: session.state, color: stateColor)
            }
            SplitRow(
                leading: detail,
                trailing: ElapsedCopy.text(since: session.since, now: now),
                leadingColor: (session.focusTarget != nil && isHovered) ? Palette.textPrimary : Palette.textSecondary,
                trailingColor: (session.focusTarget != nil && isHovered) ? Palette.textPrimary : Palette.textSecondary
            )
            .padding(.top, NotchLayout.sessionRowGap)
        }
        .contentShape(Rectangle())
    }

    var body: some View {
        if let target = session.focusTarget {
            Button {
                SessionFocus.activate(target: target)
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .onHover { inside in
                isHovered = inside
                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovered {
                    isHovered = false
                    NSCursor.pop()
                }
            }
        } else {
            rowContent
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

    /// Busy sessions first, so what is hidden is what matters least.
    private var ordered: [AgentSession] {
        summary.sessions.sorted { a, b in
            let rank: (AgentSession) -> Int = {
                switch $0.state { case .waiting: 0; case .busy: 1; case .idle: 2 }
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
                SessionRow(session: session, now: now)
                    .padding(.top, NotchLayout.blockSpacing)
            }

            if hidden > 0 {
                Text("and \(hidden) more")
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textSecondary)
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

    /// The same figure the hover region uses, so what is drawn and what is
    /// reachable can never drift apart.
    private var height: CGFloat {
        NotchLayout.cardHeight(
            windowCount: snapshot.windows.count,
            sessionCount: activity?.sessions.count ?? 0,
            sessionCap: sessionCap,
            statusMessage: snapshot.statusMessage,
            blockMessage: snapshot.block?.summary(now: now)
        )
    }

    var body: some View {
        TooltipShell(height: height, direction: direction) {
            // Stacked, not replaced in place: during a swap both sets of rows
            // exist for a moment, and in a ZStack they overlap and dissolve
            // instead of shoving each other around. Top-aligned so neither
            // drifts while the card resizes around them.
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    ProviderTooltip(snapshot: snapshot, now: now)
                    if let activity {
                        SessionList(summary: activity, now: now, cap: sessionCap)
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
