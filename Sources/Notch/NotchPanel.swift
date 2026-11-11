import AppKit

/// Borderless, non-activating panel that floats over everything, including the
/// menu bar and full-screen apps. Non-activating matters: glancing at your
/// usage must never take focus off what you were actually doing.
final class NotchPanel: NSPanel {
    /// Supplies the right-click menu. Handled here rather than on the content
    /// view because `NSWindow.sendEvent` sees every event first — the hosting
    /// view's hit test resolves to a SwiftUI-owned subview, which has no menu
    /// of its own and may consume the click before it reaches us.
    var contextMenuProvider: (() -> NSMenu?)?
    /// A left click on the visible chrome. Handled here for the same reason the
    /// menu is: the hit test lands on a SwiftUI subview that may consume it.
    var onClick: ((CGPoint) -> Void)?
    /// ⌥-drag on the chrome, reported as the raw pointer delta since the last
    /// event — not a cumulative offset, so the caller decides what "along the
    /// edge" means for the current one. Chosen over a plain click-and-hold
    /// threshold so an ordinary click never risks being read as a tiny nudge.
    var onDragStart: (() -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    /// The ⌥-drag ended. Where to persist the offset the drags above moved to.
    var onDragEnd: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .rightMouseDown,
              let menu = contextMenuProvider?(),
              let view = contentView,
              // Only over the visible chrome; elsewhere the panel is a hole.
              view.hitTest(event.locationInWindow) != nil
        else { return super.sendEvent(event) }

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// Whether a press at this point, in the window's own coordinates, is on
    /// something that carries the notch without ⌥ — the grip beside the
    /// settings button.
    var startsDrag: ((CGPoint) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        guard let view = contentView, view.hitTest(event.locationInWindow) != nil else {
            return super.mouseDown(with: event)
        }
        let carries = event.modifierFlags.contains(.option)
            || startsDrag?(event.locationInWindow) == true
        guard carries, onDrag != nil else {
            onClick?(event.locationInWindow)
            return
        }
        onDragStart?()
        trackOptionDrag()
    }

    /// Blocks on this window's own event stream until the button lifts, the
    /// standard AppKit pattern for a custom drag started from `mouseDown`.
    /// Never falls through to `onClick` on release: an ⌥-drag is a distinct
    /// gesture from the start, not a click that grew into one, so there is
    /// nothing to reinterpret once the button comes up.
    private func trackOptionDrag() {
        while let event = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch event.type {
            case .leftMouseDragged:
                onDrag?(event.deltaX, event.deltaY)
            case .leftMouseUp:
                onDragEnd?()
                return
            default:
                return
            }
        }
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Whether the panel tells AppKit it has active appearance — set only while
    /// the dock style floats the notch (`NotchViewModel.floats`). A flag on the
    /// one panel rather than a subclass picked at creation, because the panel
    /// is built once and only ever re-framed, while the style and the edge
    /// that decide this change under it.
    var claimsActiveAppearance = false

    /// **Private AppKit API.** The system gives clear glass only to a window
    /// with active appearance and frosts it otherwise, and a notch never takes
    /// focus, so the dock style's slab came out frosted. Claiming
    /// `isKeyWindow`/`isMainWindow`, `controlActiveState` and `appearsActive`
    /// all left it frosted; answering this private selector, `_hasActiveAppearance`,
    /// is the one thing that did not. Claimed only while the dock style floats,
    /// so every other style looks exactly as it always did: otherwise this
    /// answers whatever `NSPanel`'s own implementation does. If a later macOS
    /// drops the selector, AppKit never calls this and the slab falls back to
    /// frosted glass.
    @objc(_hasActiveAppearance) private func hasActiveAppearance() -> Bool {
        if claimsActiveAppearance { return true }
        let selector = NSSelectorFromString("_hasActiveAppearance")
        guard let method = class_getInstanceMethod(NSPanel.self, selector) else { return false }
        typealias Implementation = @convention(c) (AnyObject, Selector) -> ObjCBool
        let inherited = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
        return inherited(self, selector).boolValue
    }
}
