import AppKit
import ApplicationServices
import Foundation

/// Types a line into the terminal tab an agent session is running in, as if
/// it had been typed there.
///
/// Like `TerminalTabFocus`, every terminal is its own answer. Terminal.app and
/// iTerm2 can be written to by tty over AppleScript. The rest publish no way
/// to write into a tab, so the text goes on the clipboard and the tab is
/// brought forward for a paste.
enum TerminalInput {
    enum Outcome: Equatable {
        /// Written into the session's tab and submitted.
        case sent
        /// On the clipboard, with the session's tab brought forward.
        case onClipboard
        /// The editor's helper was just installed and its windows have not
        /// loaded it yet.
        case editorNeedsReload
        case failed
    }

    /// Off the main actor: osascript is a subprocess.
    static func send(_ text: String, toSessionPID pid: pid_t) -> Outcome {
        // One line: a newline in the middle would submit half of it.
        let line = text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return .failed }
        let app = SessionFocus.owningApp(of: pid)
        let tty = SessionFocus.tty(of: pid)
        let escaped = TerminalTabFocus.appleScriptEscaped(line)

        switch (app?.bundleIdentifier, tty) {
        case ("com.apple.Terminal", let tty?):
            // `do script` into a busy tab is input to what runs there. The
            // return goes separately: written in one burst with the text, a
            // TUI can take the whole thing for a paste and keep the newline
            // as part of the prompt instead of submitting it.
            return osascript("""
                tell application "Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "/dev/\(TerminalTabFocus.appleScriptEscaped(tty))" then
                        do script "\(escaped)" in t
                        delay 0.06
                        do script "" in t
                        return "found"
                      end if
                    end repeat
                  end repeat
                end tell
                """) ? .sent : .failed
        case ("com.googlecode.iterm2", let tty?):
            return osascript("""
                tell application "iTerm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "/dev/\(TerminalTabFocus.appleScriptEscaped(tty))" then
                          tell s to write text "\(escaped)" newline no
                          delay 0.06
                          tell s to write text ""
                          return "found"
                        end if
                      end repeat
                    end repeat
                  end repeat
                end tell
                """) ? .sent : .failed
        case (let bundle?, _) where EditorBridge.editors[bundle] != nil:
            return throughEditor(line, app: app!, pid: pid)
        default:
            return paste(line, into: app, pid: pid, tty: tty)
        }
    }

    // MARK: - Choosing

    /// A key into the session's terminal with no Return — a number picking
    /// from the list it is showing.
    static func press(_ keys: String, sessionPID pid: pid_t) -> Outcome {
        let app = SessionFocus.owningApp(of: pid)
        let tty = SessionFocus.tty(of: pid)
        let escaped = TerminalTabFocus.appleScriptEscaped(keys)
        switch (app?.bundleIdentifier, tty) {
        case ("com.googlecode.iterm2", let tty?):
            if osascript("""
                tell application "iTerm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "/dev/\(TerminalTabFocus.appleScriptEscaped(tty))" then
                          tell s to write text "\(escaped)" newline no
                          return "found"
                        end if
                      end repeat
                    end repeat
                  end repeat
                end tell
                """) { return .sent }
        case (let bundle?, _) where EditorBridge.editors[bundle] != nil:
            if EditorBridge.keys(keys, ancestry: SessionFocus.ancestry(of: pid)) == .sent { return .sent }
        default:
            break
        }
        guard let app else { return .failed }
        _ = TerminalTabFocus.selectTab(bundleID: app.bundleIdentifier, pid: pid,
                                       tty: tty, cwd: SessionFocus.currentDirectory(of: pid))
        DispatchQueue.main.sync { _ = app.activate() }
        guard AXIsProcessTrusted(), waitUntilFrontmost(app) else { return .failed }
        if let bundle = app.bundleIdentifier, editors.contains(bundle), !focusIsTerminal(in: app) {
            return .failed
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        for unit in keys.utf16 {
            var character = unit
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                event.post(tap: .cghidEventTap)
            }
        }
        return .sent
    }

    // MARK: - Stopping

    /// Escape into the session's terminal — what stops Claude Code mid-turn.
    /// Written straight in where the terminal allows it; otherwise the tab
    /// is brought forward and Escape pressed there.
    static func interrupt(sessionPID pid: pid_t) -> Outcome {
        var editorOutdated = false
        let app = SessionFocus.owningApp(of: pid)
        let tty = SessionFocus.tty(of: pid)
        switch (app?.bundleIdentifier, tty) {
        case ("com.googlecode.iterm2", let tty?):
            if osascript("""
                tell application "iTerm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "/dev/\(TerminalTabFocus.appleScriptEscaped(tty))" then
                          tell s to write text (character id 27) newline no
                          return "found"
                        end if
                      end repeat
                    end repeat
                  end repeat
                end tell
                """) { return .sent }
        case (let bundle?, _) where EditorBridge.editors[bundle] != nil:
            switch EditorBridge.interrupt(ancestry: SessionFocus.ancestry(of: pid)) {
            case .sent: return .sent
            case .outdated: editorOutdated = true
            default: break
            }
        default:
            break
        }
        // Terminal.app's `do script` always adds a Return, which after an
        // Escape could be read as something else; a real key press is safer.
        guard let app else { return .failed }
        _ = TerminalTabFocus.selectTab(bundleID: app.bundleIdentifier, pid: pid,
                                       tty: tty, cwd: SessionFocus.currentDirectory(of: pid))
        DispatchQueue.main.sync { _ = app.activate() }
        guard AXIsProcessTrusted(), waitUntilFrontmost(app) else {
            return editorOutdated ? .editorNeedsReload : .failed
        }
        // Escape is harmless wherever it lands, so it is pressed even when
        // the editor will not say its terminal has focus; reported as done
        // only when it has said so.
        // Pressed first, checked after: a stop should not wait on the
        // editor describing its focus.
        key(53, flags: [], source: CGEventSource(stateID: .combinedSessionState))
        let confirmed = !(app.bundleIdentifier.map(editors.contains) ?? false) || focusIsTerminal(in: app)
        if confirmed { return .sent }
        return editorOutdated ? .editorNeedsReload : .failed
    }

    // MARK: - Editors, through their own extension

    /// Typed by the editor's own extension, with the editor left where it is.
    /// The first time, the extension is installed, and the line goes once a
    /// window has loaded it.
    private static func throughEditor(_ line: String, app: NSRunningApplication, pid: pid_t) -> Outcome {
        let ancestry = SessionFocus.ancestry(of: pid)
        switch EditorBridge.send(line, ancestry: ancestry) {
        case .sent: return .sent
        case .noTerminal: return .failed
        case .unreachable, .outdated: break
        }
        guard EditorBridge.install(into: app) else { return .failed }
        for _ in 0..<16 {
            usleep(500_000)
            switch EditorBridge.send(line, ancestry: ancestry) {
            case .sent: return .sent
            case .noTerminal: return .failed
            case .unreachable, .outdated: continue
            }
        }
        return .editorNeedsReload
    }

    // MARK: - Pasting, for terminals with no way in

    /// Apps that are nothing but terminals: whatever has focus in them is a
    /// terminal, so a paste there cannot land anywhere else.
    private static let terminals: Set<String> = [
        "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "dev.warp.Warp", "com.cmuxterm.app",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
    ]

    /// Editors with a terminal panel. Their focus can as easily be on a file,
    /// so the paste waits until what has focus says it is a terminal.
    private static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "com.vscodium",
    ]

    /// Brings the session's tab forward and pastes the line into it with a
    /// Return, as a person would. Needs Accessibility to post the keys; with
    /// anything uncertain — no permission, the app not in front, focus not on
    /// a terminal — it stops at the clipboard and says so.
    private static func paste(_ line: String, into app: NSRunningApplication?,
                              pid: pid_t, tty: String?) -> Outcome {
        let previous = DispatchQueue.main.sync { () -> String? in
            let board = NSPasteboard.general
            let old = board.string(forType: .string)
            board.clearContents()
            board.setString(line, forType: .string)
            return old
        }
        guard let app else { return .onClipboard }
        _ = TerminalTabFocus.selectTab(bundleID: app.bundleIdentifier, pid: pid,
                                       tty: tty, cwd: SessionFocus.currentDirectory(of: pid))
        DispatchQueue.main.sync { _ = app.activate() }
        guard AXIsProcessTrusted(), waitUntilFrontmost(app),
              focusIsTerminal(in: app) else { return .onClipboard }

        let source = CGEventSource(stateID: .combinedSessionState)
        key(9, flags: .maskCommand, source: source)   // ⌘V
        usleep(180_000)
        key(36, flags: [], source: source)            // Return
        // Put back what was on the clipboard, once the paste has read it.
        usleep(400_000)
        if let previous {
            DispatchQueue.main.sync {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(previous, forType: .string)
            }
        }
        return .sent
    }

    private static func waitUntilFrontmost(_ app: NSRunningApplication) -> Bool {
        for _ in 0..<20 {
            let front = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            if front == app.processIdentifier { return true }
            usleep(50_000)
        }
        return false
    }

    private static func focusIsTerminal(in app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleIdentifier else { return false }
        if terminals.contains(bundle) { return true }
        guard editors.contains(bundle) else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Electron keeps its accessibility tree switched off until asked.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        for _ in 0..<6 {
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString,
                                              &focused) == .success,
               let focused {
                let target = focused as! AXUIElement
                let words = [kAXDescriptionAttribute, kAXTitleAttribute, kAXRoleDescriptionAttribute,
                             kAXHelpAttribute]
                    .compactMap { attribute -> String? in
                        var value: CFTypeRef?
                        AXUIElementCopyAttributeValue(target, attribute as CFString, &value)
                        return value as? String
                    }
                    .joined(separator: " ")
                    .lowercased()
                Log.usage.debug("dock chat focus: \(words, privacy: .public)")
                return words.contains("terminal")
            }
            usleep(80_000)
        }
        return false
    }

    private static func key(_ code: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private static func osascript(_ script: String) -> Bool {
        TerminalTabFocus.run("/usr/bin/osascript", ["-e", script], timeout: 5)
            .map { $0.contains("found") } ?? false
    }
}
