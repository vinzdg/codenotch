import AppKit
import Darwin
import Foundation

/// Activates the host application or terminal window that owns an agent session.
enum SessionFocus {
    // Overridable hooks for testing
    static var parentPidLookup: (pid_t) -> pid_t? = parentPid(of:)
    static var appLookup: (pid_t) -> NSRunningApplication? = { NSRunningApplication(processIdentifier: $0) }
    static var runningApplicationsLookup: () -> [NSRunningApplication] = { NSWorkspace.shared.runningApplications }
    static var appActivator: (NSRunningApplication) -> Bool = activate(app:)

    /// Attempt to bring the target session's host application to the front.
    /// Returns `true` if an application was found and activated.
    @discardableResult
    static func activate(target: AgentSession.FocusTarget) -> Bool {
        switch target {
        case .process(let pid):
            return activateProcess(pid: pid)
        case .application(let bundleID):
            return activateApplication(bundleID: bundleID)
        }
    }

    /// Walk up the process tree from `pid` to find the nearest ancestor with an
    /// active GUI application (e.g., Terminal, iTerm2, Warp, Ghostty, VS Code, Cursor),
    /// then activate that application.
    @discardableResult
    static func activateProcess(pid: pid_t) -> Bool {
        var current: pid_t = pid
        for _ in 0..<30 {
            if let app = appLookup(current), isActivatable(app) {
                return appActivator(app)
            }
            guard let ppid = parentPidLookup(current), ppid > 1 else { break }
            current = ppid
        }
        return false
    }

    /// Find a running application matching `bundleID` and activate it.
    @discardableResult
    static func activateApplication(bundleID: String) -> Bool {
        let running = runningApplicationsLookup()
        if let app = running.first(where: { $0.bundleIdentifier == bundleID }) {
            return appActivator(app)
        }
        if let app = running.first(where: {
            $0.bundleURL?.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(bundleID) == .orderedSame
        }) {
            return appActivator(app)
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
            return true
        }
        return false
    }

    static func isActivatable(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular || app.bundleIdentifier != nil
    }

    @discardableResult
    static func activate(app: NSRunningApplication) -> Bool {
        if #available(macOS 14.0, *) {
            return app.activate()
        } else {
            return app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Reads the parent process ID via `sysctl` `KERN_PROC_PID`.
    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        guard ppid > 1 else { return nil }
        return ppid
    }

    #if DEBUG
    static func resetTestHooks() {
        parentPidLookup = parentPid(of:)
        appLookup = { NSRunningApplication(processIdentifier: $0) }
        runningApplicationsLookup = { NSWorkspace.shared.runningApplications }
        appActivator = activate(app:)
    }
    #endif
}
