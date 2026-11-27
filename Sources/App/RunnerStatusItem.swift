import AppKit

/// How fast the runner moves: the busier the CPU, the quicker the strokes.
enum RunnerPace {
    /// Seconds per frame at rest and at full load.
    static let slowest: TimeInterval = 0.9
    static let fastest: TimeInterval = 0.08

    /// Seconds per frame for a CPU busy share in 0...1, out-of-range values clamped.
    static func interval(busy: Double) -> TimeInterval {
        let share = min(1, max(0, busy))
        return slowest - (slowest - fastest) * share
    }
}

/// A person doing pull-ups, drawn in code as an 18pt template image. Frames
/// follow one repetition: hanging, rising, at the top, lowering.
enum PullUpFrames {
    static let lifts: [CGFloat] = [0, 0.5, 1, 0.5]

    /// Drawn once: the menu bar asks for the same four frames over and over.
    static let images: [NSImage] = lifts.map(image(lift:))

    static func image(lift: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw(lift: lift)
            return true
        }
        // Template: macOS tints it dark or light to match the menu bar.
        image.isTemplate = true
        return image
    }

    /// The pose is laid out top-down, as it reads on the page, and flipped to
    /// AppKit's bottom-up space on the way out.
    private static func draw(lift: CGFloat) {
        NSColor.black.set()

        let centre: CGFloat = 9
        let barY: CGFloat = 2.5
        let shoulderY = lerp(7.5, 5.0, lift)
        let headY = shoulderY - 1.9
        let hipY = shoulderY + 4.0
        let elbowY = (shoulderY + barY) / 2
        let elbowOut = lerp(1.6, 2.9, lift)

        // The bar.
        stroke([(2, barY), (16, barY)], width: 1.4)

        // Head.
        let head = NSBezierPath(ovalIn: NSRect(x: centre - 1.4, y: 18 - headY - 1.4,
                                               width: 2.8, height: 2.8))
        head.fill()

        // Torso.
        stroke([(centre, shoulderY + 0.5), (centre, hipY)], width: 1.7)

        for side: CGFloat in [-1, 1] {
            // Arms: shoulder, elbow, hand on the bar.
            stroke([(centre + side * 1.0, shoulderY),
                    (centre + side * elbowOut, elbowY),
                    (centre + side * 4.0, barY)], width: 1.3)
            // Legs: hip, bent knee, foot.
            stroke([(centre, hipY),
                    (centre + side * 1.4, hipY + lerp(2.8, 2.0, lift)),
                    (centre + side * 0.6, hipY + lerp(5.4, 3.8, lift))], width: 1.3)
        }
    }

    private static func stroke(_ points: [(CGFloat, CGFloat)], width: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (index, point) in points.enumerated() {
            let flipped = NSPoint(x: point.0, y: 18 - point.1)
            if index == 0 { path.move(to: flipped) } else { path.line(to: flipped) }
        }
        path.stroke()
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}

/// A second menu bar item holding the runner. It exists only while the runner
/// is switched on, and never touches the main Codenotch item.
@MainActor
final class RunnerStatusItem {
    private var item: NSStatusItem?
    private var task: Task<Void, Never>?
    private var previousTicks: [UInt32]?

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 18)
        item.button?.toolTip = L10n.t("Runner: faster when the CPU is busier")
        self.item = item
        previousTicks = SystemSampler.cpuTicks()

        task = Task { [weak self] in
            var frame = 0
            while !Task.isCancelled {
                guard let self else { return }
                let images = PullUpFrames.images
                self.item?.button?.image = images[frame % images.count]
                frame += 1
                let interval = RunnerPace.interval(busy: self.busyShare())
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        previousTicks = nil
    }

    /// The CPU share busy since the last frame, from two tick readings.
    private func busyShare() -> Double {
        let now = SystemSampler.cpuTicks()
        defer { previousTicks = now }
        guard let before = previousTicks, let after = now else { return 0 }
        return SystemMetricMath.busyFraction(from: before, to: after) ?? 0
    }
}
