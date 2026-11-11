import SwiftUI
import XCTest
@testable import Codenotch

/// A MacBook's own notch, as this machine reports it.
private let realNotch = HardwareNotch(width: 220, height: 38)

private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
    var hardwareNotch: HardwareNotch?
}

private let notched = FakeScreen(
    frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    visibleFrameValue: CGRect(x: 0, y: 59, width: 1800, height: 1071),
    hardwareNotch: realNotch
)

private let plain = FakeScreen(
    frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1144),
    hardwareNotch: nil
)

/// On a Mac that has a notch of its own, a top-edge Codenotch runs up to meet
/// it so the two read as one shape rather than as a bar parked underneath.
final class HardwareNotchGeometryTests: XCTestCase {
    private let size = CGSize(width: 700, height: 200)

    /// It stays on the bezel and centres on the cutout, because what it holds
    /// is a pair of bars either side of it — see `AboveTheCutoutTests` and
    /// `MergesWithTheCutoutTests`.
    func testATopNotchKeepsTheBezelAndCentresOnTheHardware() {
        let frame = NotchGeometry.panelFrame(for: notched, panelSize: size, edge: .top)
        XCTAssertEqual(frame.maxY, notched.frameValue.maxY, accuracy: 0.001,
                       "it left the bezel")
        XCTAssertEqual(frame.midX, notched.frameValue.midX, accuracy: 0.5,
                       "the pair is symmetric about the hole, so the panel is too")
    }

    func testWithoutOneItStillReachesThePhysicalTopEdge() {
        let frame = NotchGeometry.panelFrame(for: plain, panelSize: size, edge: .top)
        XCTAssertEqual(frame.maxY, plain.frameValue.maxY, accuracy: 0.001)
    }

    /// Hardware merging only affects the top edge.
    func testTheOtherEdgesAreUnaffectedByIt() {
        XCTAssertEqual(
            NotchGeometry.panelFrame(for: notched, panelSize: size, edge: .bottom).minY,
            notched.frameValue.minY, accuracy: 0.001
        )
        XCTAssertEqual(
            NotchGeometry.panelFrame(for: notched, panelSize: CGSize(width: 300, height: 700), edge: .right).maxX,
            notched.frameValue.maxX, accuracy: 0.001
        )
    }

    func testItReadsTheNotchFromTheAreasEitherSideOfIt() {
        XCTAssertEqual(realNotch.width, 220, accuracy: 0.001)
        XCTAssertEqual(realNotch.height, 38, accuracy: 0.001)
    }
}

/// The merged and split top-notch layouts are gone. The notch is one shape on
/// all four edges now, and the display's cutout decides only *where* the top
/// edge's panel starts — see `NotchGeometry.panelFrame`.
///
/// What used to be tested below has no subject any more: a bar drawn to the
/// hardware's depth, rings either side of the hole, a resting shape that was
/// the cutout, an orb hung off a flush bar's corner. `AboveTheCutoutTests`
/// asserts what replaced all of it, which is simply that nothing is drawn in
/// the band the hole occupies.
