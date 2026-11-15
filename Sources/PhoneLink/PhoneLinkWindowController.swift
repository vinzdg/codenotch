import AppKit
import SwiftUI

final class PhoneLinkWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PhoneLinkWindowController()
    private weak var pairing: PhoneLinkPairing?
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.t("Connect your phone")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @MainActor
    func show(pairing: PhoneLinkPairing, registry: PhoneLinkRegistry, port: Int, serverStatus: PhoneLinkServerStatus) {
        self.pairing = pairing
        pairing.openWindow()
        pairing.lastPaired = nil
        let view = PhoneLinkPairingView(pairing: pairing, registry: registry, port: port, serverStatus: serverStatus)
        window?.contentView = NSHostingView(rootView: view)
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        pairing?.closeWindow()
    }
}
