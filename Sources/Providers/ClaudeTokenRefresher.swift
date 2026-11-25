import Foundation

/// Keeps the Claude OAuth token in the login keychain from ageing out.
///
/// Codenotch reads that item; only the standalone Claude Code command ever
/// writes it. On a Mac where Claude Code is used through the desktop app the
/// item is therefore written once and then rots — the desktop app renews its
/// own copy elsewhere — and eight hours later every usage reading stops, with
/// nothing the user can do from inside Codenotch. That is the hole this fills.
///
/// **How it renews, and why that is a compatibility mechanism rather than an
/// interface.** Running `claude -p` with an empty stdin makes the command go
/// through its whole start-up — which is where it checks the token's age and
/// renews it — and then exit non-zero with "Input must be provided…", because
/// no prompt ever arrives. Verified on a real machine: the keychain item's
/// modification date moves, the expiry advances by eight hours, no transcript
/// is written, no conversation is created, and the debug log shows no call to
/// the messages endpoint.
///
/// None of that is promised by anyone. A future release could stop renewing at
/// start-up, or stop rejecting an empty prompt. Both are handled by judging the
/// *outcome* instead of trusting the command: unless the expiry actually moved,
/// this reports failure and stops trying. And because it never supplies a
/// prompt, a version that started accepting empty input could not be talked
/// into answering one by accident — the failure mode is a wasted launch, never
/// an invented conversation.
@MainActor
final class ClaudeTokenRefresher: ObservableObject {
    enum Outcome: Equatable {
        case idle
        case refreshed(until: Date)
        /// Ran, or could not be run, and the token is still going to expire.
        /// The string is what the user should be told.
        case failed(String)
    }

    /// A started command: its pid, known synchronously so the session monitor
    /// can be told to ignore it before it can ever be scanned, and a way to
    /// wait for it.
    typealias Launcher = @MainActor (URL, TimeInterval) throws
        -> (pid: Int32, exit: () async -> Int32?)

    @Published private(set) var outcome: Outcome = .idle
    /// Set while the command runs. `ClaudeSessionMonitor.ignoredPIDs` reads
    /// this: the CLI registers a session file of its own for the second it
    /// lives, and it must never show up in the notch as work.
    private(set) var launchedPID: Int32?

    /// How close to expiry is close enough.
    ///
    /// **Must stay under Claude Code's own five minutes.** Its start-up renews
    /// the token only when `Date.now() + 300s >= expiresAt`; launching it any
    /// earlier than that is a no-op, which this would then correctly report as
    /// a failure and stop retrying. Four minutes leaves room for a slow start
    /// without crossing that line.
    private let margin: TimeInterval
    private let cooldown: TimeInterval
    private let timeout: TimeInterval
    private let interval: TimeInterval

    private let cli: URL?
    private let launcher: Launcher
    /// The token's expiry as the usage provider last read it. Cheap: it is the
    /// value already in hand, so asking costs no keychain traffic and no prompt.
    private let expiry: @MainActor () async -> Date?
    /// Drop the held copy and read the keychain again — the after-check.
    private let reload: @MainActor () async -> Date?

    private var timer: Timer?
    private var isRunning = false
    /// Exposed for the test that proves `isRunning` is claimed *before* the
    /// first `await` — not after, which is what would leave a window for two
    /// overlapping calls to both pass the guard.
    var isRunningForTesting: Bool { isRunning }
    private var lastAttempt: Date?
    /// The expiry a launch was already spent on. One attempt per token, which
    /// is what makes a failure stop instead of looping: a token that did not
    /// renew has the same expiry next tick, and is refused.
    private var attemptedFor: Date?

    init(
        expiry: @escaping @MainActor () async -> Date?,
        reload: @escaping @MainActor () async -> Date?,
        cli: URL? = ClaudeCLI.standalone(),
        margin: TimeInterval = 4 * 60,
        cooldown: TimeInterval = 10 * 60,
        timeout: TimeInterval = 30,
        interval: TimeInterval = 60,
        launcher: @escaping Launcher = ClaudeTokenRefresher.run
    ) {
        self.expiry = expiry
        self.reload = reload
        self.cli = cli
        self.margin = margin
        self.cooldown = cooldown
        self.timeout = timeout
        self.interval = interval
        self.launcher = launcher
    }

    func start() {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        Task { await considerRenewing() }
    }

    // MARK: - The gate

    /// Whether a launch is worth making. Pure, so every branch is testable
    /// without a clock, a keychain or a subprocess.
    static func shouldRenew(
        expiry: Date?,
        now: Date,
        margin: TimeInterval,
        attemptedFor: Date?,
        lastAttempt: Date?,
        cooldown: TimeInterval
    ) -> Bool {
        // Nothing read yet: never launch on a guess.
        guard let expiry else { return false }
        // Plenty of time left. Also the case where launching would do nothing,
        // because the command's own gate has not opened either.
        guard expiry.timeIntervalSince(now) < margin else { return false }
        // Already spent an attempt on this exact token. This is the whole
        // no-retry-loop guarantee: a launch that failed to move the expiry
        // leaves the same value here next tick, and never runs again.
        guard expiry != attemptedFor else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < cooldown { return false }
        return true
    }

    func considerRenewing(now: Date = Date()) async {
        // Claimed here, synchronously, before anything is awaited — not after
        // deciding there is something to do. `shouldRenew` also happens to
        // block a second overlapping call in the common case (it shares
        // `attemptedFor` and the cooldown, both written moments from now), but
        // both of those depend on the two calls agreeing on roughly the same
        // token and the same `now`. `isRunning` does not: it is what makes "at
        // most one launch" true unconditionally, and it can only do that by
        // being set before the first `await` — set any later and a second
        // overlapping call reaches this same guard while `isRunning` is still
        // false, exactly as `expiry()` below is what it would be waiting on.
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; launchedPID = nil }

        let current = await expiry()
        guard Self.shouldRenew(expiry: current, now: now, margin: margin,
                               attemptedFor: attemptedFor, lastAttempt: lastAttempt,
                               cooldown: cooldown),
              let current
        else { return }

        lastAttempt = now
        attemptedFor = current

        let remaining = current.timeIntervalSince(now)
        guard let cli else {
            fail("Claude's saved login is about to expire and the `claude` command "
               + "isn't installed to renew it. Run Claude Code once to sign in again.")
            return
        }
        Log.usage.notice("claude token expires in \(remaining, format: .fixed(precision: 0))s; renewing via \(cli.path, privacy: .public)")

        let status: Int32?
        do {
            let (pid, exit) = try launcher(cli, timeout)
            launchedPID = pid          // synchronously, before it can be scanned
            status = await exit()
        } catch {
            fail("Couldn't run `claude` to renew Claude's saved login.")
            Log.usage.error("token renewal could not start: \(String(describing: error), privacy: .public)")
            return
        }

        // Judged on the outcome, never on the exit status: refusing an empty
        // prompt is a *non-zero* exit and a successful renewal at the same time.
        let after = await reload()
        guard let after, after > current else {
            fail("Claude usage needs its sign-in renewed — run `claude` once in a terminal.")
            Log.usage.error("token renewal ran (exit \(status ?? -1)) but the expiry did not move; still \(String(describing: after), privacy: .public)")
            return
        }
        outcome = .refreshed(until: after)
        Log.usage.notice("claude token renewed, now expires \(after, privacy: .public)")
    }

    private func fail(_ message: String) {
        outcome = .failed(message)
    }

    // MARK: - Running it

    /// Starts the command and hands back its pid plus a way to wait for it.
    ///
    /// `nullDevice` on stdin is the whole trick: the command gets an immediate
    /// end-of-input, so it starts up, renews, and refuses for want of a prompt.
    /// Output goes nowhere — there is nothing in it worth keeping, and a token
    /// could in principle be echoed into it.
    /// Contained the way `ClaudeUsageCLI` is (#227). Without these the run
    /// started every MCP server and hook the user had configured, from
    /// whatever directory the app was launched in — `/` from Finder — and
    /// macOS put their reads of Desktop, Documents, Downloads and network
    /// volumes to the user as Codenotch asking for access.
    static let arguments = ["-p", "--no-session-persistence", "--strict-mcp-config"]

    nonisolated static func run(_ cli: URL, timeout: TimeInterval) throws
        -> (pid: Int32, exit: () async -> Int32?) {
        let process = Process()
        process.executableURL = cli
        process.arguments = Self.arguments
        // The same fixed directory `/usage` runs from, never the app's own.
        if let scratch = try? ClaudeUsageCLI.scratchDirectory() {
            process.currentDirectoryURL = scratch
            var environment = ProcessInfo.processInfo.environment
            environment["PWD"] = scratch.path
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let wait: () async -> Int32? = {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !process.isRunning else {
                // Never left to linger: a renewal that hangs is exactly the
                // shape of the bug this app just had to fix elsewhere.
                process.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    // Confirmed rather than assumed: every other process this
                    // app spawns is waited on after asking it to stop
                    // (`CodexBridge`, `AntigravityBridge`, both via the
                    // synchronous `waitUntilExit()`). That call would block
                    // this function's caller — MainActor, since `run` is
                    // isolated to it — so the same guarantee is reached by
                    // polling instead, at the cost of a few more lines for the
                    // one path that needs it.
                    while process.isRunning {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                return nil
            }
            return process.terminationStatus
        }
        return (process.processIdentifier, wait)
    }
}
