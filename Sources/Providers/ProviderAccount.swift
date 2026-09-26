import Foundation

/// Whose readings these are.
///
/// Worth showing plainly, because Codenotch never signs in — it borrows a
/// credential the owning tool already holds, and there is nothing stopping that
/// credential belonging to a different account than the one you are sitting in
/// front of. It happened during development: a browser sign-in created a second,
/// empty Cursor account, and the notch spent an afternoon faithfully reporting
/// somebody else's zero. A visible email would have caught it in seconds.
struct ProviderAccount: Equatable {
    /// Email or display name, where the credential carries one.
    let label: String?
    /// The plan, named the way the provider names it.
    let plan: String?
    /// Which app's credential this borrows.
    let source: String
    /// The provider's own usage page, for checking this against the source.
    let manageURL: URL?

    /// One line for the settings row.
    var summary: String {
        [label, plan.map { $0.capitalized }, L10n.t("via \(source)")]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// Where to go when a provider has no usable credential.
///
/// Codenotch cannot sign anyone in — it reads a credential the owning tool
/// holds — so the most it can honestly do is open that tool, or say what to do
/// when there is nothing to open.
enum SignInRoute: Equatable {
    /// The provider owns the session and can present its own sign-in window.
    /// The only case where Codenotch genuinely signs anyone in or out.
    case modal(name: String)
    /// Launch the app that owns the credential.
    case openApp(bundleID: String, name: String)
    /// Nothing to launch; Claude Code is a command, not an application.
    case guidance(String)
    /// A command-line tool signs in from the terminal: the button runs its
    /// login command in a new terminal window, which opens the browser.
    case command(String, name: String, install: URL? = nil)

    var actionTitle: String? {
        switch self {
        case .modal(let name):     return L10n.t("Sign in to \(name)")
        case .openApp(_, let name): return L10n.t("Open \(name)")
        case .guidance:            return nil
        case .command(_, let name, _): return L10n.t("Sign in to \(name)")
        }
    }

    var explanation: String {
        switch self {
        case .modal(let name):      return L10n.t("Sign in to \(name) to read this account.")
        case .openApp(_, let name): 
            if name == "Antigravity" {
                return L10n.t("Ensure Antigravity IDE is running to read this account.")
            }
            return L10n.t("Sign in with \(name) to read this account.")
        case .guidance(let text):   return text
        case .command(let command, let name, _):
            guard TerminalCommand.isInstalled(command: command) else {
                return L10n.t("Install the \(name) CLI first; Sign in opens its install page.")
            }
            return command.hasSuffix("login")
                ? L10n.t("Runs \(command) in your terminal; it opens the browser to sign in and saves the session this reads.")
                : L10n.t("Runs \(command) in your terminal; sign in there with /login and the notch reads the session.")
        }
    }

    /// How to change which account is being read.
    ///
    /// Always somewhere else: the credential belongs to the tool that issued
    /// it, so switching accounts is that tool's business and this can only say
    /// where to go.
    var switchHint: String {
        switch self {
        case .modal(let name):      return L10n.t("Sign out in the \(name) window to use another account.")
        case .openApp(_, let name): return L10n.t("Switch accounts in \(name); the notch follows.")
        case .guidance, .command:   return L10n.t("Switch accounts in the tool that owns it; the notch follows.")
        }
    }

    /// What switching a provider off does and does not reach, said plainly, so
    /// nobody switches off here expecting to be signed out of the tool as well.
    var signOutCaveat: String {
        switch self {
        case .modal(let name):
            return L10n.t("Signs out of \(name) — the session belongs to Codenotch.")
        case .openApp(_, let name):
            return L10n.t("You stay signed in to \(name) — end that session in \(name) itself.")
        case .guidance, .command:
            return L10n.t("You stay signed in to the tool that owns the account.")
        }
    }
}

extension UsageProvider {
    /// Providers that borrow no credential have no account to show.
    ///
    /// A default for a requirement *declared in the protocol* is fine — the
    /// requirement keeps dispatch dynamic, so an implementation still wins. It
    /// is declaring a method only in an extension that quietly breaks.
    func account() -> ProviderAccount? { nil }

    var signInRoute: SignInRoute {
        .guidance(L10n.t("Sign in with the tool that owns this account."))
    }

    /// Nothing of our own to discard, by default.
    func signOut() async {}

    /// No modal of our own to show, by default — `UsageStore.signIn` falls back
    /// to the route.
    func presentSignIn() {}

    /// Providers that hold nothing in memory have nothing to drop.
    func forgetCachedCredential() {}
}

/// A provider as the settings sheet needs it.
struct ProviderSummary: Identifiable, Equatable {
    var kind: ProviderKind = .usage
    var localModel: LocalRuntimeReading.Model? = nil
    var sourceProviderID: String? = nil
    /// The runtime a local model is loaded in, for the row's own words.
    var runtimeName: String? = nil
    /// Whether this provider's credential lives in the keychain, and so can be
    /// refused. Codex still reads an ordinary file and never prompts. Cursor
    /// does too when the editor is signed in, but `cursor-agent` files its
    /// JWT in the login keychain — without this flag a declined prompt would
    /// have no "Allow access…" to put the dialogue back.
    ///
    /// Only Antigravity's default profile reads the keychain. The extra ones
    /// are read from their own directory's `oauth_creds.json` or `agent.db`
    /// and never raise the dialogue, so offering to restore access there would
    /// point at a prompt that cannot appear.
    ///
    /// Apify's CLI files its token in the login keychain too, so a Deny is
    /// possible there — and "Allow access…" is the only way back from one.
    ///
    /// Remote logins borrow their token over SSH and touch no local
    /// keychain item at all — same exclusion, for the same reason.
    var usesKeychain: Bool {
        (ClaudeProfile.isClaude(providerID: id) && !RemoteHost.isRemoteClaude(providerID: id))
            || id == AntigravityProfile.defaultID || id == "cursor" || id == "muse"
            || id == "apify"
    }
    }

    let id: String
    let name: String
    let glyph: ProviderGlyph
    var customIconFilename: String? = nil
    let account: ProviderAccount?
    let signIn: SignInRoute
    /// Whether macOS refused this credential on the last fetch — the one state
    /// "Allow access…" can actually repair.
    ///
    /// Deliberately *not* read off the snapshot's status. A refusal leaves the
    /// last reading standing and its status untouched, because the number is
    /// still true; the refusal itself is remembered separately by the store.
    /// Offering to re-ask macOS for a credential it is already handing over is a
    /// cure for an illness the provider does not have, and a button that does
    /// nothing is indistinguishable from a broken one.
    var wasRefusedAccess: Bool = false
    /// Whether this provider's saved login has aged out and Codenotch could not
    /// renew it, so someone has to run the tool that owns it.
    ///
    /// Deliberately *not* read off the snapshot's status, for the same reason
    /// `wasRefusedAccess` is not: an expired token leaves the last reading in
    /// place and looking fine. Tying the warning to "is there a reading" would
    /// hide it behind exactly the stale number it is warning about.
    var needsSignInRenewal: Bool = false
}
