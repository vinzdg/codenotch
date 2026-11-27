import AppKit
import Combine
import SwiftUI

/// The floating pill beside the Dock. macOS lets no app draw inside the Dock
/// itself, so this is a panel of its own, parked just above it.
@MainActor
final class DockChatController: NSObject {
    let model = DockChatModel()
    private let panel: DockChatPanel
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    /// Room above the pill, always there and empty until the pill grows
    /// into it — for the slash list, or a question. The window is never
    /// resized as the pill grows: each resize redrew the pill in the old
    /// place for a frame, and it jumped up off the Dock and slid back.
    /// Clicks in the empty part go through to whatever is underneath.
    private let extraHeight: CGFloat = DockChatController.roomAbove
    static let roomAbove: CGFloat = 330
    private var listSubscription: AnyCancellable?
    private var outsideClick: Any?
    private let host: FirstClickHostingView<DockChatView>

    init(usage: NotchViewModel) {
        let size = DockChatView.size
        panel = DockChatPanel(contentRect: NSRect(origin: .zero, size: size))
        host = FirstClickHostingView(rootView: DockChatView(model: model, usage: usage))
        super.init()
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        // The window's size is this controller's alone. Left to itself, the
        // hosting view resizes its window to fit the pill as it animates —
        // keeping the window's top where it was, so a growing or shrinking
        // pill dragged its bottom off the Dock and back.
        host.sizingOptions = []
        panel.contentView = host
        panel.pasteImage = { [weak model] in model?.pasteImage() ?? false }

        place()
        panel.orderFrontRegardless()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
        // The Dock grows and shrinks as apps open and quit, and the
        // permission to measure it can arrive at any moment. A light poll
        // notices both; once the Dock is moving, `tick` follows it frame by
        // frame until it settles.
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        if !DockFrame.isTrusted { DockFrame.requestTrust() }
        // The list is inside the pill now; a click anywhere outside it
        // puts it away, as a menu would.
        listSubscription = model.$listOpen
            .removeDuplicates()
            .sink { [weak self] open in
                guard let self else { return }
                if let monitor = self.outsideClick { NSEvent.removeMonitor(monitor); self.outsideClick = nil }
                guard open else { return }
                self.outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model.listOpen = false }
                }
            }
    }

    /// Takes the pill away for good: Codedock switched off.
    func close() {
        timer?.invalidate()
        timer = nil
        stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        model.shutDown()
        model.listOpen = false
        listSubscription = nil
        panel.orderOut(nil)
    }

    /// How far below its reported icon list the Dock draws its plate.
    /// Measured on macOS 26 against the plate's own edges on screen.
    static let plateDrop: CGFloat = 3.5

    func watch(_ monitors: [(profile: ClaudeProfile, monitor: ClaudeSessionMonitor)]) {
        model.watch(monitors)
    }

    /// Beside the Dock's icons, level with them, where the Dock is at the
    /// bottom and Accessibility lets it be measured: to the right of it, or
    /// to the left where the right has no room. Otherwise just above the
    /// Dock, centred.
    private func place() {
        let screens = NSScreen.screens
        let base = DockChatView.size
        let gap: CGFloat = 14
        if let row = DockFrame.iconRow(),
           let screen = screens.first(where: { $0.frame.contains(CGPoint(x: row.midX, y: row.midY)) }),
           row.width > row.height {
            // The Dock's plate, not its icon list: the list Accessibility
            // reports sits a little above the plate the Dock draws, so a pill
            // centred on the list stood a few points proud of the Dock.
            let plate = row.offsetBy(dx: 0, dy: -Self.plateDrop)
            let scale = min(1.2, max(0.5, plate.height / base.height))
            let size = CGSize(width: base.width * scale, height: (base.height + extraHeight) * scale)
            let rowHeight = base.height * scale
            // The side chosen in Settings; the other where it has no room.
            let onLeft = UserDefaults.standard.string(forKey: Preferences.codedockSideKey) == "left"
            let right = row.maxX + gap, left = row.minX - gap - size.width
            var x = onLeft ? left : right
            if onLeft, x < screen.frame.minX + 6 { x = right }
            if !onLeft, x + size.width > screen.frame.maxX - 6 { x = left }
            if x >= screen.frame.minX + 6 {
                apply(NSRect(x: x, y: plate.midY - rowHeight / 2, width: size.width, height: size.height),
                      scale: scale)
                return
            }
        }
        let screen = screens.first { $0.visibleFrame.minY > $0.frame.minY } ?? NSScreen.main ?? screens.first
        guard let screen else { return }
        let bottom = screen.visibleFrame.minY > screen.frame.minY
            ? screen.visibleFrame.minY + 8
            : screen.frame.minY + 14
        apply(NSRect(x: screen.frame.midX - base.width / 2, y: bottom,
                     width: base.width, height: base.height + extraHeight), scale: 1)
    }

    // MARK: - Following the Dock

    /// Where the pill is headed: beside the Dock's icons as they are now.
    private var target: NSRect?
    /// Where it is drawn, and how fast it is moving there.
    private var position: CGPoint = .zero
    private var velocity: CGVector = .zero
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var settledFrames = 0

    private func apply(_ frame: NSRect, scale: CGFloat) {
        if model.scale != scale { model.scale = scale }
        guard target != frame else { return }
        let first = target == nil
        target = frame
        settledFrames = 0
        if panel.frame.size != frame.size {
            panel.setFrame(NSRect(origin: first ? frame.origin : position, size: frame.size), display: true)
        }
        if first || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            position = frame.origin
            velocity = .zero
            panel.setFrameOrigin(frame.origin)
            return
        }
        if link == nil {
            lastTick = 0
            let link = host.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// One frame of the follow: measure the Dock again — it is still
    /// animating its own width — and spring toward beside it. Critically
    /// damped, so it arrives without overshooting the Dock's edge.
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick == 0 ? 1.0 / 60 : min(1.0 / 30, max(1.0 / 240, now - lastTick))
        lastTick = now
        place()
        guard let target else { return stop() }
        let omega = 22.0
        func step(_ x: CGFloat, _ v: CGFloat, to goal: CGFloat) -> (CGFloat, CGFloat) {
            let a = omega * omega * (goal - x) - 2 * omega * v
            let v = v + a * dt
            return (x + v * dt, v)
        }
        let (x, vx) = step(position.x, velocity.dx, to: target.minX)
        let (y, vy) = step(position.y, velocity.dy, to: target.minY)
        position = CGPoint(x: x, y: y)
        velocity = CGVector(dx: vx, dy: vy)
        if abs(target.minX - x) < 0.25, abs(target.minY - y) < 0.25,
           abs(vx) < 4, abs(vy) < 4 {
            position = target.origin
            velocity = .zero
            settledFrames += 1
        } else {
            settledFrames = 0
        }
        panel.setFrameOrigin(position)
        // Held a few frames at rest before letting go, so a Dock that pauses
        // mid-resize is still followed when it carries on.
        if settledFrames > 10 { stop() }
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }
}

/// Floats, takes typing without bringing Codenotch's other windows forward,
/// and stays put across Spaces and full-screen apps.
private final class DockChatPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The pill draws its own shadow. The window's is worked out from its
        // shape now and then, and as the pill grew and shrank it went stale:
        // a square box round the window instead of the rounded pill.
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
    }

    /// Takes ⌘V first when the clipboard holds an image, so a screenshot
    /// becomes a frame in the pill rather than nothing, or a path.
    var pasteImage: (() -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v",
           pasteImage?() == true {
            return
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click. The pill never brings Codenotch forward, so it is
/// almost always clicked while another app is in front — and without this,
/// that first click only made the panel key, and the chip did nothing.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
