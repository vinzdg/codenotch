import Darwin
import Foundation

/// Is a pid still running, and is it still the *same* process?
///
/// A session that crashes leaves its file behind saying `busy` forever, so the
/// notch has to check rather than trust the file. Checking the pid alone is not
/// enough on a long-running machine: pids get reused, and a recycled one would
/// resurrect a dead session. Comparing start times settles it.
enum ProcessLiveness {
    /// `startedAt` is when the *session* registered, which is seconds after its
    /// process actually started — near enough, since the only thing this rules
    /// out is a pid that has since been handed to something else entirely.
    static func isAlive(pid: Int32, startedAt: Date?) -> Bool {
        guard exists(pid: pid) else { return false }
        guard let startedAt, let actual = startTime(pid: pid) else {
            // Can't prove it either way — trust the pid rather than hide a
            // session that is probably real.
            return true
        }
        return abs(actual.timeIntervalSince(startedAt)) < reuseTolerance
    }

    /// Wide enough to absorb the gap between process start and registration,
    /// tight enough that a recycled pid never slips through.
    private static let reuseTolerance: TimeInterval = 5 * 60

    private static func exists(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        // EPERM means it exists but belongs to someone else.
        return errno == EPERM
    }

    /// Whether the process is stopped: suspended with ctrl-Z, or by any other
    /// SIGSTOP. It is still alive and comes back with `fg`, but until then it
    /// cannot be doing anything.
    static func isStopped(pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0
        else { return false }
        return Int32(info.kp_proc.p_stat) == SSTOP
    }

    static func startTime(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }
}
