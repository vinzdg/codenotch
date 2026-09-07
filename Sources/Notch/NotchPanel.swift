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
    var onClick: (() -> Void)?
    /// ⌥-drag on the chrome, reported as the raw pointer delta since the last
    /// event — not a cumulative offset, so the caller decides what "along the
    /// edge" means for the current one. Chosen over a plain click-and-hold
    /// threshold so an ordinary click never risks being read as a tiny nudge.
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

    override func mouseDown(with event: NSEvent) {
        guard let view = contentView, view.hitTest(event.locationInWindow) != nil else {
            return super.mouseDown(with: event)
        }
        guard event.modifierFlags.contains(.option), onDrag != nil else {
            onClick?()
            return
        }
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
}
