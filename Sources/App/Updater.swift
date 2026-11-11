import Foundation
import Sparkle

/// Keeps the app up to date, **asking in the notch**.
///
/// Checks at launch and on Sparkle's schedule, without the first-launch
/// permission prompt Sparkle otherwise shows. What it finds is offered in the
/// notch — "Codenotch 1.19.0 is available", Update, Later — and, taken, is
/// downloaded and installed there with its progress, then relaunched. See
/// `UpdatePrompt` and `NotchUpdateDriver`: Sparkle's own windows are never
/// shown.
///
/// One thing it cannot do, which is macOS rather than Sparkle: the app has to
/// be writable by the user installing the update — true for a normal drag to
/// /Applications, false if it was copied there with `sudo`.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// What the last check came to, in words the settings sheet can show.
    ///
    /// Sparkle's own answer to a failed check is a modal saying "an error
    /// occurred in retrieving update information" — true, and useless: it names
    /// no cause and offers nothing to do. Keeping the outcome here lets the one
    /// place a user goes to think about updates say what actually happened.
    enum Outcome: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case found(String)
        case unreachable
        case failed(String)

        var message: String? {
            switch self {
            case .idle:          return nil
            case .checking:      return L10n.t("Checking…")
            case .upToDate:      return L10n.t("Codenotch is up to date.")
            case .found(let v):  return L10n.t("Version \(v) is available — the notch has it.")
            case .unreachable:
                // The one people actually hit, and the one Sparkle's wording
                // hides: nothing is wrong with the app or the machine.
                return L10n.t("Couldn't reach the update server. Codenotch will try again on its own — nothing is wrong with this copy.")
            case .failed(let why): return why
            }
        }
    }

    @Published private(set) var outcome: Outcome = .idle

    /// What the notch is offering, and how far along taking it up is.
    @Published private(set) var prompt: UpdatePrompt?

    /// **A newer version there to be had**, and not installed — put off with
    /// Later, or closed. What the red dot on the settings button and on the
    /// General tab says; gone once it installs, or a check finds none.
    @Published private(set) var pending: String?
    /// Whether `pending` is only the preview's.
    private var pendingIsPreview = false

    /// The one waiting, offered again: the card back in the notch.
    func reoffer() {
        if pendingIsPreview { preview() } else { checkNow() }
    }

    private lazy var driver = NotchUpdateDriver(updater: self)
    private lazy var sparkle = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                          userDriver: driver, delegate: self)

    /// Mirrors the preference, so switching it off really does stop the checks
    /// rather than only hiding them. Never downloads unasked: what is found is
    /// offered in the notch first.
    var automatic: Bool {
        get { sparkle.automaticallyChecksForUpdates }
        set { sparkle.automaticallyChecksForUpdates = newValue }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var lastChecked: Date? { sparkle.lastUpdateCheckDate }

    /// Starts the scheduled checks, and checks now — so an update out since it
    /// last ran is offered as it launches. Deliberately not in `init`: the
    /// updater is lazy so that `self` exists before it is handed over as the
    /// delegate.
    func start() {
        guard !started else { return }
        started = true
        sparkle.automaticallyDownloadsUpdates = false
        do {
            try sparkle.start()
        } catch {
            outcome = .failed(error.localizedDescription)
            return
        }
        if sparkle.automaticallyChecksForUpdates {
            sparkle.checkForUpdatesInBackground()
        }
    }
    private var started = false

    // MARK: - The prompt in the notch

    /// Sparkle's answer-taker for the update it has offered.
    private var answer: ((SPUUserUpdateChoice) -> Void)?

    func offer(_ item: SUAppcastItem, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        previewing = false
        pending = item.displayVersionString
        pendingIsPreview = false
        answer = reply
        prompt = UpdatePrompt(version: item.displayVersionString,
                              notes: UpdatePrompt.summary(of: item.itemDescription ?? ""),
                              phase: .available)
    }

    /// Release notes that arrived after the offer, for the line under it.
    func offerNotes(_ html: String) {
        guard var shown = prompt, shown.notes.isEmpty else { return }
        shown.notes = UpdatePrompt.summary(of: html)
        prompt = shown
    }

    // MARK: - A preview

    /// The card as a real update would bring it up — offered, and on Update a
    /// download and install played out — for a version that is not there.
    /// Nothing is fetched and nothing installed.
    func preview() {
        previewRun &+= 1
        previewing = true
        answer = nil
        prompt = UpdatePrompt(
            version: Self.nextVersion(after: currentVersion),
            notes: L10n.t("Hold the six dots beside the settings button to carry the notch round the screen."),
            phase: .available)
    }
    private var previewing = false
    private var previewRun = 0

    /// The version after this one, for the preview to name.
    static func nextVersion(after version: String) -> String {
        var parts = version.split(separator: ".").map { Int($0) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        parts[1] += 1
        parts[2] = 0
        return parts.map(String.init).joined(separator: ".")
    }

    private func playPreviewInstall() {
        let run = previewRun
        var steps: [(TimeInterval, UpdatePrompt.Phase?)] = []
        for step in 0...20 {
            let share = Double(step) / 20
            steps.append((0.25 + Double(step) * 0.12, .downloading(share)))
        }
        steps.append((2.9, .extracting(0.5)))
        steps.append((3.4, .installing))
        steps.append((4.6, nil))
        for (delay, phase) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.previewing, self.previewRun == run else { return }
                if let phase {
                    self.prompt?.phase = phase
                } else {
                    self.previewing = false
                    self.prompt = nil
                    if self.pendingIsPreview {
                        self.pending = nil
                        self.pendingIsPreview = false
                    }
                }
            }
        }
    }

    /// The notch's answer.
    func respond(_ choice: UpdateChoice) {
        if previewing, prompt?.phase == .available {
            switch choice {
            case .install:
                prompt?.phase = .downloading(nil)
                playPreviewInstall()
            case .later, .close:
                previewing = false
                if pending == nil || pendingIsPreview {
                    pending = prompt?.version
                    pendingIsPreview = true
                }
                prompt = nil
            }
            return
        }
        guard let reply = answer, prompt?.phase == .available else { return }
        answer = nil
        switch choice {
        case .install:
            prompt?.phase = .downloading(nil)
            reply(.install)
        case .later, .close:
            // Asked again at the next check — the next launch, or tomorrow.
            prompt = nil
            reply(.dismiss)
        }
    }

    func progressed(_ phase: UpdatePrompt.Phase) {
        guard prompt != nil else { return }
        prompt?.phase = phase
    }

    func promptEnded() {
        answer = nil
        prompt = nil
    }

    /// The manual path, for someone who does not want to wait for the schedule.
    /// This one *does* show UI — it was asked for, so silence would read as a
    /// broken button.
    func checkNow() {
        start()
        outcome = .checking
        sparkle.checkForUpdates()
        // Never left on "Checking…". Sparkle reports every ending it knows
        // about below, but a copy whose updater cannot reach its own helper —
        // a damaged install, a helper macOS blocked — reports nothing at all.
        let started = checkGeneration &+ 1
        checkGeneration = started
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkTimeout) { [weak self] in
            guard let self, self.checkGeneration == started else { return }
            self.outcome = Self.outcome(afterTimeoutFrom: self.outcome)
        }
    }

    /// How long a check may stay unanswered before it is called stalled.
    static let checkTimeout: TimeInterval = 45
    private var checkGeneration = 0

    /// Pure, so both endings can be tested without Sparkle.
    static func outcome(afterTimeoutFrom current: Outcome) -> Outcome {
        guard current == .checking else { return current }
        return .failed(L10n.t("The update check didn't finish. Try again, or download the latest Codenotch from hivinz.com."))
    }

    /// A cycle that ended without saying found or not found — the person
    /// closed Sparkle's window, or a download already in progress answered the
    /// request — must not leave the status reading "Checking…".
    static func outcome(afterCycleFrom current: Outcome, errorCode: Int?) -> Outcome {
        guard current == .checking else { return current }
        guard let errorCode else { return .idle }
        return isUnreachable(errorCode) ? .unreachable : .idle
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.outcome = .upToDate(Date())
            if !self.pendingIsPreview { self.pending = nil }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.outcome = .found(version)
            self.pending = version
            self.pendingIsPreview = false
        }
    }

    nonisolated func updater(_ updater: SPUUpdater,
                             didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: Error?) {
        let code = error.map { ($0 as NSError).code }
        Task { @MainActor in
            self.outcome = Self.outcome(afterCycleFrom: self.outcome, errorCode: code)
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        Task { @MainActor in
            // A feed that cannot be fetched is the ordinary failure — offline,
            // or the server is down — and it is not the user's problem to
            // solve. Anything else is reported as itself.
            self.outcome = Self.isUnreachable(code)
                ? .unreachable
                : .failed(error.localizedDescription)
        }
    }

    /// Sparkle folds every "could not load the feed" case into one code.
    static func isUnreachable(_ code: Int) -> Bool {
        code == Int(SUError.appcastError.rawValue)
    }
}

/// **An update, as the notch offers it**: which version, a line of what is in
/// it, and how far along taking it up is.
struct UpdatePrompt: Equatable {
    enum Phase: Equatable {
        case available
        /// Downloading, with how much of it has come, once its size is known.
        case downloading(Double?)
        case extracting(Double)
        case installing
    }

    var version: String
    var notes: String
    var phase: Phase

    /// A line of release notes from the appcast's HTML: the tags and entities
    /// out, the whitespace run together.
    static func summary(of html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the notch said to the update it offered.
enum UpdateChoice: Equatable {
    case install, later, close
}

/// **Sparkle's windows, replaced by the notch.** Sparkle calls this for every
/// moment of an update it would otherwise show a window for; each is passed
/// to `Updater`, which the notch draws. Called on the main thread.
final class NotchUpdateDriver: NSObject, SPUUserDriver {
    private weak var updater: Updater?
    private var expected: UInt64 = 0
    private var received: UInt64 = 0

    init(updater: Updater) {
        self.updater = updater
    }

    private func onMain(_ work: @escaping @MainActor (Updater) -> Void) {
        let updater = self.updater
        MainActor.assumeIsolated {
            if let updater { work(updater) }
        }
    }

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onMain { $0.offer(appcastItem, reply: reply) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let html = String(data: downloadData.data, encoding: .utf8) ?? ""
        onMain { $0.offerNotes(html) }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        onMain { $0.promptEnded() }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expected = 0
        received = 0
        onMain { $0.progressed(.downloading(nil)) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
        received = 0
        onMain { $0.progressed(.downloading(0)) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        guard expected > 0 else { return }
        let share = min(1, Double(received) / Double(expected))
        onMain { $0.progressed(.downloading(share)) }
    }

    func showDownloadDidStartExtractingUpdate() {
        onMain { $0.progressed(.extracting(0)) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        onMain { $0.progressed(.extracting(progress)) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Already asked for, in the notch: straight on to installing.
        onMain { $0.progressed(.installing) }
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        onMain { $0.progressed(.installing) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        onMain { $0.promptEnded() }
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        onMain { $0.promptEnded() }
    }
}
