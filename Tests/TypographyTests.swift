import XCTest
import SwiftUI
@testable import Codenotch

final class TypographyTests: XCTestCase {
    func testFontSizesScaleLinearly() {
        let baseBody = Typography.fontSize(capPixels: 18, scale: 1.0)
        let scaledBody = Typography.fontSize(capPixels: 18, scale: 1.5)
        XCTAssertGreaterThan(scaledBody, baseBody)

        let baseTitle = Typography.fontSize(capPixels: 26, scale: 1.0)
        let scaledTitle = Typography.fontSize(capPixels: 26, scale: 1.3)
        XCTAssertGreaterThan(scaledTitle, baseTitle)

        let smallPercent = Typography.fontSize(capPixels: 27, scale: 0.85)
        let standardPercent = Typography.fontSize(capPixels: 27, scale: 1.0)
        XCTAssertLessThan(smallPercent, standardPercent)
    }

    func testNotchLayoutCardHeightExpandsWithTypographyScale() {
        let standardHeight = NotchLayout.cardHeight(
            windowCount: 2,
            sessionCount: 1,
            hasPlan: true,
            typographyScale: 1.0
        )
        let largeHeight = NotchLayout.cardHeight(
            windowCount: 2,
            sessionCount: 1,
            hasPlan: true,
            typographyScale: 1.3
        )
        let extraLargeHeight = NotchLayout.cardHeight(
            windowCount: 2,
            sessionCount: 1,
            hasPlan: true,
            typographyScale: 1.5
        )

        XCTAssertGreaterThan(largeHeight, standardHeight, "Larger font scale must budget a taller card")
        XCTAssertGreaterThan(extraLargeHeight, largeHeight, "Extra large font scale must budget even taller card")
    }

    func testBodyTextHeightScalesWithScaleParameter() {
        let text = "This is a longer status description that will wrap across lines on a high DPI display."
        let standardHeight = NotchLayout.bodyTextHeight(text, scale: 1.0)
        let scaledHeight = NotchLayout.bodyTextHeight(text, scale: 1.5)
        XCTAssertGreaterThanOrEqual(scaledHeight, standardHeight)
    }
}
