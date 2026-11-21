import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

@MainActor
final class SettingsSidebarTests: XCTestCase {
    func testSettingsSidebarConstants() {
        XCTAssertEqual(SettingsView.sidebarWidth, 220)
        XCTAssertEqual(SettingsView.miniSidebarWidth, 68)
        XCTAssertLessThan(SettingsView.miniSidebarWidth, SettingsView.sidebarWidth)

        // Collapsed traffic lights must fit cleanly inside miniSidebarWidth
        let lastLightRightEdge = SettingsWindowController.collapsedFirstLightCentreX
            + 2 * SettingsWindowController.collapsedLightSpacing
            + 7 // standard button radius
        XCTAssertLessThan(lastLightRightEdge, SettingsView.miniSidebarWidth)
    }

    func testSettingsSidebarRendersExpanded() throws {
        let name = "SettingsSidebarTests.expanded.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(false, forKey: "settingsSidebarCollapsed")

        let settings = SettingsView(
            preferences: Preferences(defaults: defaults),
            providers: { [] },
            signOut: { _ in },
            signIn: { _ in false },
            switchAccount: { _ in false },
            retry: { _ in },
            resetPosition: {},
            quit: {},
            updater: Updater()
        )
        let view = settings
            .defaultAppStorage(defaults)
            .frame(width: SettingsView.width, height: SettingsView.height)

        let image = try XCTUnwrap(ImageRenderer(content: view).nsImage)
        XCTAssertEqual(image.size, CGSize(width: SettingsView.width, height: SettingsView.height))
    }

    func testSettingsSidebarRendersMiniCollapsed() throws {
        let name = "SettingsSidebarTests.collapsed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(true, forKey: "settingsSidebarCollapsed")

        let settings = SettingsView(
            preferences: Preferences(defaults: defaults),
            providers: { [] },
            signOut: { _ in },
            signIn: { _ in false },
            switchAccount: { _ in false },
            retry: { _ in },
            resetPosition: {},
            quit: {},
            updater: Updater()
        )
        let view = settings
            .defaultAppStorage(defaults)
            .frame(width: SettingsView.width, height: SettingsView.height)

        let image = try XCTUnwrap(ImageRenderer(content: view).nsImage)
        XCTAssertEqual(image.size, CGSize(width: SettingsView.width, height: SettingsView.height))
    }
}
