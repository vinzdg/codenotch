import Foundation

/// One source of usage numbers. Each adapter declares how trustworthy it is,
/// and the UI never dresses a derived number up as an official one.
protocol UsageProvider {
    var id: String { get }
    /// Enough to draw the cell even when a fetch has never succeeded.
    var displayName: String { get }
    var glyph: ProviderGlyph { get }
    func fetchSnapshot() async throws -> ProviderSnapshot
    /// Whose readings these are. Declared here rather than only in an extension:
    /// a method that exists solely in a protocol extension is dispatched
    /// *statically*, so calling it through `any UsageProvider` would always land
    /// on the default and never on the implementation — which is exactly what
    /// happened, and it failed silently by reporting every account as absent.
    func account() -> ProviderAccount?
    /// Where the user goes to sign in, when there is no account to read. A
    /// requirement for the same reason `account()` is.
    var signInRoute: SignInRoute { get }
    /// Discard whatever credential *this app* holds for the provider.
    ///
    /// For a borrowed credential there is nothing here to discard — the session
    /// belongs to Claude Code or Cursor, and ending it is their business, not
    /// ours. For a session Codenotch created itself (`WebSessionProvider`) this
    /// is a real logout. A requirement, not an extension member, for the reason
    /// spelled out above `account()`.
    func signOut() async
    /// Open whatever sign-in this provider can present.
    ///
    /// Only a `WebSessionProvider` has a modal of its own to show — it owns the
    /// session, so it can create one. Everyone else borrows a credential, and
    /// the nearest thing is launching the app that holds it, which is why the
    /// route matters as much as this call. A requirement, not an extension
    /// member, for the reason spelled out above `account()`.
    func presentSignIn()
    /// Drop any credential held in memory, so the next read goes to the
    /// keychain for real.
    ///
    /// Without this, "ask me again" does nothing whenever a valid token is
    /// still cached: the read is served from memory, macOS is never consulted,
    /// and no prompt appears. A requirement, not an extension member, for the
    /// reason spelled out above `account()`.
    func forgetCachedCredential()
}

enum UsageProviderError: Error {
    /// No usable credential — the user has to sign in again.
    case needsAuth
    /// The credential is there, and macOS refused to hand it over — the
    /// keychain prompt was declined. Not the same as being signed out: telling
    /// someone to sign in, when they are signed in and merely pressed Deny,
    /// sends them to fix something that is not broken.
    case accessDenied
    /// The credential is there but has expired, and the app that owns it will
    /// refresh it the next time it runs. Not the same as being signed out: the
    /// last reading is still true, just old.
    case credentialExpired
    /// The owning app emptied its own stored credential — the keychain item is
    /// still there, with an empty token in it.
    ///
    /// Not the same as `needsAuth`, and the difference decides whether the last
    /// reading survives. `needsAuth` means nobody ever signed in here, so there
    /// is nothing to show. This means somebody *was* signed in, worked, and had
    /// the credential taken out from under them. Claude Code does exactly that
    /// to every profile at once after it auto-updates and then wakes from sleep
    /// (anthropics/claude-code#19456, closed as not planned). The numbers taken
    /// before that happened are still the truth about the account.
    case signedOutByOwner
    /// The endpoint answered, but not with anything we understand.
    case badResponse(status: Int)
    /// Asked to slow down. Carries the server's own retry hint when it gave one.
    case rateLimited(retryAfter: TimeInterval)
    /// The account is readable, but there is genuinely no quota being counted —
    /// Cursor's free plan reports an included limit of zero. Not an error, and
    /// it must not be shown as one.
    case nothingMetered(String)
}
