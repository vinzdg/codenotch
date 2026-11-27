import AppKit
import ApplicationServices

/// Where the Dock's row of icons actually is, in AppKit screen coordinates.
///
/// The Dock's only window covers the whole screen, so the window list says
/// nothing about its width. Its icon list does, through the Accessibility API,
/// which needs the user's permission. Without it this is nil, and the caller
/// falls back to a place that does not depend on the Dock's width.
enum DockFrame {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's "allow Accessibility" prompt, once per launch at most.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The Dock's icon list, kept between calls: it is read every frame
    /// while the Dock is resizing, and finding it walks the Dock's children.
    nonisolated(unsafe) private static var list: AXUIElement?

    static func iconRow() -> CGRect? {
        if let list, let frame = frame(of: list) { return frame }
        list = nil
        guard isTrusted,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return nil }
        for element in elements {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == (kAXListRole as String),
                  let frame = frame(of: element) else { continue }
            list = element
            return frame
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        // Accessibility measures from the top of the primary screen, AppKit
        // from its bottom.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: position.x, y: primaryHeight - position.y - size.height,
                      width: size.width, height: size.height)
    }
}
