import AppKit

/// Renders coloured visual quota indicators (markers or bars) over the menu bar status button.
///
/// Drawn as views over the status button rather than into its template image,
/// matching the pattern established by `StatusItemWaitingBadges`: AppKit tints a
/// template image monochrome for the current menu bar appearance, so state colours
/// (normal/ample green, watch yellow/orange, critical red, and stale grey) must be
/// drawn outside the template image to preserve their meaning.
///
/// Each indicator view ignores mouse events (`hitTest` returns nil) so that the
/// entire status item remains a continuous, forgiving click target.
@MainActor
final class StatusItemVisualIndicators {
    private weak var view: NSView?
    private var imageSize: NSSize = .zero
    private var indicators: [String: IndicatorView] = [:]
    private var frames: [String: NSRect] = [:]

    /// The providers showing a visual indicator.
    var showing: Set<String> { Set(indicators.keys) }

    struct Model: Equatable {
        let providerID: String
        let mode: MenuBarVisualMode
        let fraction: Double?
        let band: UsageBand
        let isStale: Bool
        let isBlank: Bool
    }

    func update(view: NSView, imageSize: NSSize, mode: MenuBarVisualMode,
                entries: [StatusItemSummary.Entry], frames: [String: NSRect]) {
        self.view = view
        self.imageSize = imageSize
        self.frames = frames

        guard mode.isVisual else {
            clear()
            return
        }

        let currentIDs = Set(entries.map(\.id))
        for (id, indicator) in indicators where !currentIDs.contains(id) || frames[id] == nil {
            indicator.removeFromSuperview()
            indicators[id] = nil
        }

        for entry in entries {
            guard let frame = frames[entry.id] else { continue }
            let fraction = entry.usedFraction
            let band = fraction.map { UsageBand.band(for: $0) } ?? .ample
            let model = Model(
                providerID: entry.id,
                mode: mode,
                fraction: fraction,
                band: band,
                isStale: entry.isStale,
                isBlank: entry.isBlank
            )

            let indicatorView: IndicatorView
            if let existing = indicators[entry.id] {
                indicatorView = existing
            } else {
                let created = IndicatorView()
                view.addSubview(created)
                indicators[entry.id] = created
                indicatorView = created
            }
            indicatorView.update(model: model)
        }
        layout()
    }

    func relayout() { layout() }

    func clear() {
        for indicator in indicators.values { indicator.removeFromSuperview() }
        indicators.removeAll()
        frames.removeAll()
    }

    func frame(for providerID: String) -> NSRect? { indicators[providerID]?.frame }

    private func layout() {
        guard let view else { return }
        let dx = ((view.bounds.width - imageSize.width) / 2).rounded()
        let dy = ((view.bounds.height - imageSize.height) / 2).rounded()
        for (id, indicator) in indicators {
            guard let rect = frames[id] else { continue }
            let y = view.isFlipped ? view.bounds.height - dy - rect.maxY : dy + rect.minY
            indicator.frame = NSRect(x: dx + rect.minX, y: y, width: rect.width, height: rect.height)
        }
    }

    private final class IndicatorView: NSView {
        private var model: Model?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func update(model: Model) {
            self.model = model
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let model else { return }

            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let stateColor: NSColor
            if model.isBlank || model.isStale {
                stateColor = NSColor.systemGray.withAlphaComponent(model.isStale ? 0.6 : 0.4)
            } else {
                switch model.band {
                case .ample:
                    stateColor = NSColor(hex: isDark ? Palette.amplePair.dark : Palette.amplePair.light)
                case .watch:
                    stateColor = NSColor(hex: isDark ? Palette.watchPair.dark : Palette.watchPair.light)
                case .critical, .exhausted:
                    stateColor = NSColor(hex: isDark ? Palette.criticalPair.dark : Palette.criticalPair.light)
                }
            }

            switch model.mode {
            case .markers:
                stateColor.setFill()
                let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
                NSBezierPath(ovalIn: inset).fill()

            case .bars:
                let corner = bounds.height / 2
                // Subtle track background
                let trackColor = NSColor(white: isDark ? 1.0 : 0.0, alpha: 0.18)
                trackColor.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: corner, yRadius: corner).fill()

                if !model.isBlank, let fraction = model.fraction {
                    let clamped = CGFloat(min(max(fraction, 0), 1))
                    if clamped > 0 {
                        let fillWidth = max(bounds.height, bounds.width * clamped)
                        let fillRect = NSRect(x: bounds.minX, y: bounds.minY, width: fillWidth, height: bounds.height)
                        stateColor.setFill()
                        NSBezierPath(roundedRect: fillRect, xRadius: corner, yRadius: corner).fill()
                    }
                }

            case .text:
                break
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
