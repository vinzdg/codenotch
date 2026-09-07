import AppKit
import Darwin
import Foundation

/// Brings the window an agent is running in to the front.
///
/// A session knows its own pid and nothing else — Claude Code publishes no
/// window, tab or tty. What it does have is a parent: the shell that launched
/// it, whose parent is the terminal application. So the app is found by walking
/// up the process tree until something turns up that macOS considers an
/// application, and that is what gets raised.
///
/// This stops at the application. Selecting the *tab* inside it needs the
/// terminal's own scripting interface and there is no general one: Terminal.app
/// and iTerm2 can match a tab by tty over AppleScript, Warp and Ghostty publish
/// no scripting dictionary at all. Rather than work for two terminals and
/// silently do nothing in a third, the app is raised for everybody and the
/// tooltip names the session so the last hop is one keystroke.
enum SessionFocus {
    /// Raise whichever application owns this process.
    ///
    /// Returns false when the chain runs out before an application appears,
    /// which is the honest answer for an agent started by launchd, over ssh, or
    /// from a process that has since been reparented to init.
    @discardableResult
    static func activateApp(owning pid: pid_t) -> Bool {
        guard let app = owningApp(of: pid) else {
            Log.usage.debug("no owning app for pid \(pid, privacy: .public)")
            return false
        }
        // `activate()` rather than the deprecated options form: the notch's own
        // panel is non-activating, so there is no focus of ours to hand over
        // and nothing to co-ordinate.
        return app.activate()
    }

    /// The nearest ancestor process that macOS knows as a running application.
    static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        for candidate in ancestry(of: pid) {
            if let app = NSRunningApplication(processIdentifier: candidate),
               app.bundleIdentifier != nil {
                return app
            }
        }
        return nil
    }

    /// The process and its parents, nearest first.
    ///
    /// Bounded rather than looped until pid 1: a corrupted `kinfo_proc` that
    /// reports itself as its own parent would otherwise spin forever, and no
    /// real chain from an agent to its terminal is more than a handful deep.
    static func ancestry(of pid: pid_t, limit: Int = 8) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        while chain.count < limit, current > 1 {
            chain.append(current)
            guard let parent = parent(of: current), parent != current else { break }
            current = parent
        }
        return chain
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0
        else { return nil }
        return info.kp_eproc.e_ppid
    }
}
