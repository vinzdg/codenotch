import AppKit
import CoreGraphics

/// Detects whether a full-screen application window is active on a given display.
enum FullScreenDetector {
    /// Pure function checking whether any layer 0 window belonging to `frontmostPID`
    /// matches or spans the `screenBounds`.
    static func isFullScreen(
        screenBounds: CGRect,
        frontmostPID: pid_t,
        windows: [(pid: pid_t, layer: Int, bounds: CGRect)],
        safeAreaTopInset: CGFloat = 0
    ) -> Bool {
        for window in windows {
            guard window.pid == frontmostPID, window.layer == 0 else { continue }
            let b = window.bounds

            // Must match screen width (within small tolerance for window borders/rounding)
            guard abs(b.origin.x - screenBounds.origin.x) <= 4,
                  abs(b.width - screenBounds.width) <= 4 else {
                continue
            }

            // Case 1: Spans full screen height (e.g. video, game, or non-notched screen with hidden menu bar)
            if abs(b.origin.y - screenBounds.origin.y) <= 4 &&
               abs(b.height - screenBounds.height) <= 4 {
                return true
            }

            // Case 2: Full-screen window on a notched MacBook or with menu bar present.
            // Starts right below notch/menu bar, reaches bottom of screen,
            // and occupies the available display area.
            let maxTopInset = max(safeAreaTopInset, 40.0) + 4.0
            let reachesBottom = abs(b.maxY - screenBounds.maxY) <= 4
            let startsNearTop = b.origin.y >= screenBounds.origin.y - 4 &&
                                b.origin.y <= screenBounds.origin.y + maxTopInset
            let occupiesMainArea = b.height >= screenBounds.height - (maxTopInset + 10)

            if reachesBottom && startsNearTop && occupiesMainArea {
                return true
            }
        }
        return false
    }

    /// Queries WindowServer and NSWorkspace to determine if the frontmost app
    /// is occupying the entire `screen`.
    static func isFullScreenAppFrontmost(on screen: NSScreen? = NSScreen.main) -> Bool {
        guard let screen = screen ?? NSScreen.main else { return false }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }

        // Ignore Codenotch itself (settings panel, etc.)
        guard frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }

        // Convert NSScreen (AppKit coordinates: origin bottom-left of primary screen)
        // to CoreGraphics coordinates (origin top-left of primary screen).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgScreenBounds = CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )

        let safeTop: CGFloat
        if #available(macOS 12.0, *) {
            safeTop = screen.safeAreaInsets.top
        } else {
            safeTop = 0
        }

        if let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            var extractedWindows: [(pid: pid_t, layer: Int, bounds: CGRect)] = []
            for info in windowInfoList {
                guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      let layer = info[kCGWindowLayer as String] as? Int,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
                else { continue }
                extractedWindows.append((pid: pid, layer: layer, bounds: bounds))
            }

            if isFullScreen(
                screenBounds: cgScreenBounds,
                frontmostPID: frontApp.processIdentifier,
                windows: extractedWindows,
                safeAreaTopInset: safeTop
            ) {
                return true
            }
        }

        // Supplementary check: on a full-screen Space without camera notch,
        // macOS autohides the menu bar, causing visibleFrame to match the entire screen frame.
        if abs(screen.visibleFrame.width - screen.frame.width) <= 1 &&
           abs(screen.visibleFrame.height - screen.frame.height) <= 1 &&
           frontApp.bundleIdentifier != "com.apple.finder" {
            return true
        }

        return false
    }
}
