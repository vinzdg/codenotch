import AppKit

/// What the menu bar item says in place of its icon, once Settings asks it to:
/// for each chosen provider with a five-hour limit, its mark, how much of that
/// window is spent, and how long until it resets — "72% · 2h 18m".
///
/// Built from the same snapshots as the menu under it, never from a reading of
/// its own. Pure, so everything the bar can say, down to "—", can be tested
/// without a status item or a clock.
struct StatusItemSummary: Equatable {
    struct Entry: Equatable {
        let id: String
        let glyph: ProviderGlyph
        /// The profile's slug, only when another entry wears the same mark:
        /// two Claude logins would otherwise be two identical icons.
        let label: String?
        /// "72%", or `unknown` when there is no current five-hour reading.
        let percent: String
        /// "2h 18m", or `unknown` when the reset is unknown or already past.
        let countdown: String
        /// A remembered reading rather than a fresh one, dimmed the way the
        /// notch dims its ring.
        let isStale: Bool
        /// Weekly allowance consumed, for the compact ring. Nil means the
        /// provider did not publish a valid current weekly percentage.
        let weeklyFraction: Double?
        /// What the tooltip and VoiceOver say about this entry, in full.
        let detail: String

        static let unknown = "—"

        /// Nothing to show at all, so it is drawn as the mark and one dash.
        var isBlank: Bool { percent == Self.unknown && countdown == Self.unknown }
    }

    let entries: [Entry]
    /// When the first countdown on show next reads differently. Nil when
    /// nothing is counting down, so nothing needs to wake up for it.
    let nextChange: Date?

    /// Two readings sit side by side comfortably. Past that each keeps its mark
    /// and percentage, and the countdowns stay in the tooltip and the menu.
    static let fullEntryLimit = 2
    /// Past this many the rest are in the menu only. macOS hides a status item
    /// that does not fit rather than squeezing it, and with the app out of the
    /// Dock this item is the only way into it.
    static let entryLimit = 4

    var isCompact: Bool { entries.count > Self.fullEntryLimit }

    /// Whether the bar has anything to say about this provider: it meters a
    /// five-hour window, or it is Claude or Codex, whose headline limit *is*
    /// that window — so a missing figure is worth a dash rather than a silent
    /// gap. Anyone else qualifies once they report one.
    ///
    /// Settings lists exactly these, so it never offers a provider the bar
    /// would not draw.
    static func canSummarise(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.kind == .usage && (snapshot.fiveHourWindow != nil || isFiveHourFamily(snapshot.id))
    }

    /// The chosen providers the bar can summarise, in the order the notch shows
    /// them. None at all while the feature is off — or when nothing chosen has
    /// a limit to show — which gives the item its icon back.
    @MainActor
    static func make(from snapshots: [ProviderSnapshot], showing limits: MenuBarLimits,
                     now: Date, format: ResetTimeFormat = .automatic,
                     showingWeeklyLimit: Bool = false) -> StatusItemSummary {
        guard limits.isOn else { return StatusItemSummary(entries: [], nextChange: nil) }
        let summarised = snapshots.filter { snapshot in
            canSummarise(snapshot) && limits.isChosen(snapshot.id)
        }.prefix(entryLimit)
        var marks: [ProviderGlyph: Int] = [:]
        for snapshot in summarised { marks[snapshot.glyph, default: 0] += 1 }
        let entries = summarised.map { snapshot in
            entry(for: snapshot, sharesMark: marks[snapshot.glyph, default: 0] > 1, now: now,
                  format: format, showingWeeklyLimit: showingWeeklyLimit)
        }
        let nextChange = summarised
            .compactMap { $0.fiveHourWindow?.resetsAt }
            .compactMap { ResetCopy.nextCountdownChange(to: $0, now: now) }
            .min()
        return StatusItemSummary(entries: entries, nextChange: nextChange)
    }

    static func isFiveHourFamily(_ providerID: String) -> Bool {
        ClaudeProfile.isClaude(providerID: providerID) || CodexProfile.isCodex(providerID: providerID)
    }

    @MainActor
    private static func entry(for snapshot: ProviderSnapshot, sharesMark: Bool,
                              now: Date, format: ResetTimeFormat,
                              showingWeeklyLimit: Bool) -> Entry {
        let window = snapshot.fiveHourWindow
        // Past its reset a reading describes a window that is over. The store
        // re-reads on its first tick after a reset; until that lands the honest
        // figure is none, not the old one.
        let isOver = window?.resetsAt.map { $0 <= now } ?? false
        var percent = Entry.unknown
        if !isOver, let fraction = window?.usedFraction, fraction.isFinite {
            percent = Percent.whole(for: fraction) + "%"
        }
        let countdown = window?.resetsAt.flatMap { ResetCopy.countdown(to: $0, now: now) }
        let label = sharesMark
            ? ClaudeProfile.slug(fromProviderID: snapshot.id) ?? CodexProfile.slug(fromProviderID: snapshot.id)
            : nil
        let weeklyWindow = showingWeeklyLimit ? snapshot.weeklyLimitWindow : nil
        let weeklyIsOver = weeklyWindow?.resetsAt.map { $0 <= now } ?? false
        let weeklyFraction = weeklyIsOver ? nil : weeklyWindow?.usedFraction.flatMap { fraction in
            fraction.isFinite && fraction >= 0 ? fraction : nil
        }
        var detail = detail(for: snapshot, window: window, isOver: isOver,
                            countdown: countdown, now: now, format: format)
        if weeklyFraction != nil, let weeklyWindow {
            // The window's own label, the way the line above already names the
            // headline window. "Weekly" was baked in here when every provider
            // that had a second window called it that; QianwenAI's is a monthly
            // allowance, Claude's is "All models", and a bar that relabels
            // either one is reporting a window the provider never declared.
            detail += " · \(weeklyWindow.label): \(weeklyWindow.summary)"
        }
        return Entry(
            id: snapshot.id,
            glyph: snapshot.glyph,
            label: label,
            percent: percent,
            countdown: countdown ?? Entry.unknown,
            isStale: snapshot.status.isStale
                && (percent != Entry.unknown || weeklyFraction != nil),
            weeklyFraction: weeklyFraction,
            detail: detail
        )
    }

    /// The bar's figures with the words it has no room for: whose they are,
    /// which window, and what is left. The countdown is the bar's own, so the
    /// two never disagree by the minute that rounding would put between them.
    @MainActor
    private static func detail(for snapshot: ProviderSnapshot, window: LimitWindow?,
                               isOver: Bool, countdown: String?, now: Date,
                               format: ResetTimeFormat) -> String {
        let reading: String
        if let window {
            let figures = isOver
                ? [L10n.t("Resetting…")]
                : [window.summary] + [countdown].compactMap { $0 }
            reading = "\(window.label): \(figures.joined(separator: " · "))"
        } else if let headline = snapshot.headline {
            // What the account does meter, so a dash in the bar is explained
            // rather than merely shown.
            reading = StatusItemController.windowLine(for: headline, now: now, format: format)
        } else {
            reading = snapshot.statusMessage ?? L10n.t("No reading")
        }
        var line = "\(snapshot.displayName) — \(reading)"
        if snapshot.hasReading, let since = snapshot.status.staleSince, since != .distantPast {
            line += " · \(ElapsedCopy.ago(since: since, now: now))"
        }
        return line
    }
}

/// The summary as the menu bar draws it: one template image, so AppKit tints it
/// for whatever bar it is on — dark on light, light on dark, right against a
/// wallpaper-tinted bar — exactly as it does the icon it stands in for.
///
/// Measured here and drawn by the image's handler whenever AppKit wants pixels,
/// so it is sharp at whatever scale the display has.
struct StatusItemArtwork {
    let summary: StatusItemSummary
    /// Provider ids whose glyphs are currently pulsing. Activity never changes
    /// the figures beside them; only the matching mark's alpha is varied.
    let activeProviderIDs: Set<String>
    let activeGlyphOpacity: CGFloat
    let font: NSFont
    let height: CGFloat

    /// The menu bar's own type size, with figures of one width: "72%" and
    /// "18%" take the same room, so nothing jitters as the numbers move.
    init(summary: StatusItemSummary,
         activeProviderIDs: Set<String> = [],
         activeGlyphOpacity: CGFloat = 1,
         font: NSFont = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
                                                   weight: .regular),
         height: CGFloat = NSStatusBar.system.thickness) {
        self.summary = summary
        self.activeProviderIDs = activeProviderIDs
        self.activeGlyphOpacity = min(max(activeGlyphOpacity, 0), 1)
        self.font = font
        self.height = height
    }

    private enum Mark {
        case glyph(ProviderGlyph, NSRect, weeklyFraction: Double?)
        case text(String, NSPoint)
        /// The upright rule between two providers' readings.
        case rule(NSRect)
    }

    private var separator: String { " · " }
    private var glyphSize: CGFloat { (font.pointSize * 1.1).rounded() }
    private var glyphGap: CGFloat { (font.pointSize * 0.3).rounded() }
    /// Either side of the rule between two readings.
    private var entryGap: CGFloat { (font.pointSize * 0.55).rounded() }
    /// Lighter than the figures on either side of it: it divides, it does not
    /// say anything.
    private var ruleAlpha: CGFloat { 0.35 }

    /// The widest either figure gets in the ordinary run of a window, measured
    /// in the current language. Each is given at least this much room, so the
    /// item keeps one width from the start of a window to its reset — the
    /// items to its left would otherwise shuffle every time "10%" became "9%"
    /// or "1h 00m" became "59m".
    private var percentRoom: CGFloat { width("00%") }
    private var countdownRoom: CGFloat {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        return width(ResetCopy.countdown(to: now.addingTimeInterval(5 * 3600 - 30), now: now) ?? "")
    }

    var size: NSSize { NSSize(width: layout().width, height: height) }

    func image() -> NSImage {
        let (width, marks, _) = layout()
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for (mark, alpha) in marks { draw(mark, alpha: alpha) }
            return true
        }
        image.cacheMode = .always
        image.isTemplate = true
        return image
    }

    func glyphFrame(for providerID: String) -> NSRect? {
        layout().glyphFrames[providerID]
    }

    /// A provider mark cropped out of the existing artwork, retaining its
    /// weekly ring, optical scaling and stale alpha without a second renderer.
    func glyphImage(for providerID: String) -> NSImage? {
        guard let frame = glyphFrame(for: providerID) else { return nil }
        let whole = image()
        let image = NSImage(size: frame.size, flipped: false) { target in
            whole.draw(in: target, from: frame, operation: .sourceOver, fraction: 1)
            return true
        }
        image.cacheMode = .always
        image.isTemplate = true
        return image
    }

    private func layout() -> (width: CGFloat, marks: [(Mark, CGFloat)], glyphFrames: [String: NSRect]) {
        // Figures centred on the bar by their cap height, which is what the eye
        // measures digits by; the marks are centred on the same line.
        let baseline = ((height - font.capHeight) / 2 * 2).rounded() / 2
        let middle = baseline + font.capHeight / 2
        var marks: [(Mark, CGFloat)] = []
        var glyphFrames: [String: NSRect] = [:]
        var x: CGFloat = 0
        func text(_ string: String, alpha: CGFloat) {
            marks.append((.text(string, NSPoint(x: x, y: baseline)), alpha))
            x += width(string)
        }
        for (index, entry) in summary.entries.enumerated() {
            if index > 0 {
                // "72% · 2h 18m | 41% · 4h 05m": without the rule, two readings
                // run together into one line of figures. As tall as the marks,
                // and on whole points so it stays one crisp line.
                x = (x + entryGap).rounded()
                marks.append((.rule(NSRect(x: x, y: middle - glyphSize / 2, width: 1, height: glyphSize)),
                              ruleAlpha))
                x += 1 + entryGap
            }
            let alpha: CGFloat = entry.isStale ? 0.5 : 1
            let box = NSRect(x: x, y: middle - glyphSize / 2, width: glyphSize, height: glyphSize)
            glyphFrames[entry.id] = box
            marks.append((.glyph(entry.glyph, box, weeklyFraction: entry.weeklyFraction),
                          glyphAlpha(for: entry)))
            x += glyphSize + glyphGap
            if let label = entry.label {
                text(label, alpha: alpha)
                x += glyphGap
            }
            if entry.isBlank {
                text(StatusItemSummary.Entry.unknown, alpha: alpha)
                continue
            }
            // Right-aligned, so the "%" stays put and the figure grows leftward.
            let percentWidth = width(entry.percent)
            x += max(0, percentRoom - percentWidth)
            text(entry.percent, alpha: alpha)
            if !summary.isCompact {
                text(separator, alpha: alpha)
                let start = x
                text(entry.countdown, alpha: alpha)
                x = max(x, start + countdownRoom)
            }
        }
        return (x.rounded(.up), marks, glyphFrames)
    }

    /// Kept pure so the provider-specific activity contract is testable
    /// without installing a real status item. Text continues to use the base
    /// alpha in `layout`; only this glyph value follows the pulse.
    func glyphAlpha(for entry: StatusItemSummary.Entry) -> CGFloat {
        let base: CGFloat = entry.isStale ? 0.5 : 1
        return activeProviderIDs.contains(entry.id) ? base * activeGlyphOpacity : base
    }

    private func width(_ string: String) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    private func draw(_ mark: Mark, alpha: CGFloat) {
        // Black at some opacity: a template image is read only for its alpha,
        // and AppKit supplies the colour.
        let ink = NSColor.black.withAlphaComponent(alpha)
        switch mark {
        case .text(let string, let origin):
            // Without `.usesLineFragmentOrigin` the rect's origin is the baseline.
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: ink])
                .draw(with: NSRect(origin: origin, size: .zero), options: [], context: nil)
        case .rule(let rect):
            ink.setFill()
            // Composited like everything else here; plain `fill()` copies.
            rect.fill(using: .sourceOver)
        case .glyph(let glyph, let box, let weeklyFraction):
            var glyphBox = box
            if let weeklyFraction {
                // Weekly usage borrows the app's established ring language and
                // occupies the glyph's existing box, so enabling it adds no
                // width even with several providers. The faint complete track
                // makes 0% visible; the clockwise arc grows to a full circle.
                let circle = box.insetBy(dx: 0.75, dy: 0.75)
                let radius = min(circle.width, circle.height) / 2
                let track = NSBezierPath()
                track.appendArc(withCenter: NSPoint(x: circle.midX, y: circle.midY),
                                radius: radius, startAngle: 90, endAngle: -270,
                                clockwise: true)
                track.lineWidth = 1
                ink.withAlphaComponent(alpha * 0.32).setStroke()
                track.stroke()

                let clamped = CGFloat(min(max(weeklyFraction, 0), 1))
                if clamped > 0 {
                    let progress = NSBezierPath()
                    progress.appendArc(withCenter: NSPoint(x: circle.midX, y: circle.midY),
                                       radius: radius, startAngle: 90,
                                       endAngle: 90 - 360 * clamped, clockwise: true)
                    progress.lineWidth = 1.25
                    progress.lineCapStyle = .round
                    ink.setStroke()
                    progress.stroke()
                }
                glyphBox = box.insetBy(dx: 2.25, dy: 2.25)
            }
            let inset = glyphBox.width * (1 - glyph.opticalScale) / 2
            let rect = glyphBox.insetBy(dx: inset, dy: inset)
            // The same preference as the notch: a bundled asset over the trace,
            // fitted rather than stretched, since not every mark is square.
            if let asset = NSImage(named: glyph.assetName), asset.size.width > 0, asset.size.height > 0 {
                let scale = min(rect.width / asset.size.width, rect.height / asset.size.height)
                let fitted = NSSize(width: asset.size.width * scale, height: asset.size.height * scale)
                asset.draw(in: NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                                      width: fitted.width, height: fitted.height),
                           from: .zero, operation: .sourceOver, fraction: alpha)
                return
            }
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            // Outlines are traced top-down in a unit box; the image is not flipped.
            func point(_ p: CGPoint) -> NSPoint {
                NSPoint(x: rect.minX + p.x * rect.width, y: rect.maxY - p.y * rect.height)
            }
            for loop in glyph.outline {
                guard let first = loop.first else { continue }
                path.move(to: point(first))
                for p in loop.dropFirst() { path.line(to: point(p)) }
                path.close()
            }
            ink.setFill()
            path.fill()
        }
    }
}
