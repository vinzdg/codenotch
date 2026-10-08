import AppKit
import XCTest
@testable import Codenotch

/// The breathing disc runs in Core Animation rather than SwiftUI, so what a
/// SwiftUI version would say in its modifiers is pinned here on the layer.
@MainActor
final class BusyWaveViewTests: XCTestCase {
    private let outerRadius = NotchLayout.activityDiameter / 2 + NotchLayout.activityStroke / 2

    private func hosted(_ view: BusyWaveView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: true)
        // Closed by the test while ARC still holds it.
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return window
    }

    private func discView(queued: Bool = false, animates: Bool = true) -> BusyWaveView {
        let side = NotchLayout.ringDiameter
        let view = BusyWaveView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.configure(color: .white, outerRadius: outerRadius, animates: animates, queued: queued)
        view.layout()
        return view
    }

    func testItBreathesOnceEveryOnePointOneSecondsOnScreen() throws {
        let view = discView()
        let window = hosted(view)
        defer { window.close() }

        let breath = try XCTUnwrap(view.disc.animation(forKey: BusyWaveView.animationKey) as? CAAnimationGroup)
        XCTAssertEqual(breath.duration, 1.1)
        XCTAssertTrue(breath.autoreverses)
        XCTAssertEqual(breath.repeatCount, .infinity)
    }

    func testAQueuedModelBreathesTwiceAsFast() throws {
        let view = discView(queued: true)
        let window = hosted(view)
        defer { window.close() }

        let breath = try XCTUnwrap(view.disc.animation(forKey: BusyWaveView.animationKey) as? CAAnimationGroup)
        XCTAssertEqual(breath.duration, 0.55)
        XCTAssertEqual(BusyWaveView.breathDuration(queued: true),
                       BusyWaveView.breathDuration(queued: false) / 2)
    }

    func testReduceMotionHoldsItStill() {
        let view = discView(animates: false)
        let window = hosted(view)
        defer { window.close() }
        XCTAssertNil(view.disc.animation(forKey: BusyWaveView.animationKey))
    }

    func testTheDiscStopsAtTheActivityGap() throws {
        let view = discView()
        let box = try XCTUnwrap(view.disc.path).boundingBox
        XCTAssertEqual(box.width, 2 * outerRadius, accuracy: 0.5)
    }

    func testItNeverTakesAClick() {
        let view = discView()
        XCTAssertNil(view.hitTest(NSPoint(x: view.bounds.midX, y: view.bounds.midY)))
    }
}
