import Foundation

/// Holds a borrowed credential so the keychain is read as rarely as possible.
///
/// Every read of the *data* is a chance for macOS to interrupt someone. The ACL
/// on another app's item does not list Codenotch, so the first read prompts —
/// and if the answer was **Allow** rather than **Always Allow**, so does every
/// one after it.
///
/// The rule is not "hold it while it is valid". That was the rule, and it is
/// what made the app ask over and over: once a token aged out, the cache
/// refused to serve it and *every* caller went back to the keychain — once a
/// minute, all night, for a token that could not change until the owning app
/// next ran. Re-reading an unchanged item cannot produce a different answer; it
/// can only produce another dialogue.
///
/// So the question is whether the item has **changed**, which
/// `KeychainItem.modifiedAt` answers without touching the data and without
/// prompting. Expiry is left to the caller, who is the one that knows what an
/// expired token means.
final class CredentialCache<Credential>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Credential?
    /// The item's modification date the last time we *asked* about it — on a
    /// refusal as much as on a success. Recording it only on success was what
    /// let a refused read be retried on every tick: it had no memory of having
    /// already asked about that version of the item.
    private var attemptedStamp: Date?
    private var attemptedAt: Date?
    /// Why the last attempt failed, kept so a caller can be given the same
    /// answer without macOS being asked again.
    private var lastError: Error?

    private let isExpired: (Credential) -> Bool
    /// How long to sit with what we have when the probe cannot tell us whether
    /// the item moved. Long enough not to nag, short enough that a rotation is
    /// picked up while you are still looking at the notch.
    private let recheckAfter: TimeInterval
    /// How long to leave macOS alone after it has said no, where there is no
    /// probe to be more precise with — and, since the fix below, the same
    /// wait a *transient* failure gets even when the probe says nothing moved.
    private let retryAfterFailure: TimeInterval
    private let now: () -> Date
    /// Whether a failure is a verdict about the credential itself, rather than
    /// about the moment it happened to be asked for.
    ///
    /// The distinction this app actually has is real refusal vs. everything
    /// else: `errSecAuthFailed`/`errSecUserCanceled`/`errSecInteractionNotAllowed`
    /// mean someone was asked and said no, and asking again on a timer would
    /// mean putting the same dialogue back in front of them unprompted. Every
    /// other failure — `errSecInDarkWake` chief among them, from a real
    /// incident: one read landed during it, and every read for the next three
    /// hours replayed that single failure because the item's `mdat` never
    /// moved in between — has nothing to say about the credential at all, and
    /// defaults to being retried after `retryAfterFailure` precisely because
    /// nothing here can prove it wasn't transient.
    private let isPermanentFailure: (Error) -> Bool

    // `isExpired` stays the last parameter, defaultless, so every existing
    // call site's trailing closure — `CredentialCache<Token> { $0.expired }`
    // — keeps binding to it rather than to the new, defaulted parameter.
    init(recheckAfter: TimeInterval = 5 * 60,
         retryAfterFailure: TimeInterval = 5 * 60,
         now: @escaping () -> Date = Date.init,
         isPermanentFailure: @escaping (Error) -> Bool = { _ in false },
         isExpired: @escaping (Credential) -> Bool) {
        self.recheckAfter = recheckAfter
        self.retryAfterFailure = retryAfterFailure
        self.now = now
        self.isPermanentFailure = isPermanentFailure
        self.isExpired = isExpired
    }

    /// The held credential, or a fresh one when the item behind it has moved.
    ///
    /// `itemModifiedAt` must not read the item's data — the whole point is that
    /// it can be called freely.
    ///
    /// `reload` runs outside the lock: it can block on a keychain prompt, and
    /// holding a lock across a modal dialogue would stall every other caller
    /// behind it.
    func value(itemModifiedAt: () -> Date? = { nil },
               reload: () throws -> Credential) throws -> Credential {
        lock.lock()
        let held = stored
        let askedStamp = attemptedStamp
        let askedAt = attemptedAt
        let failure = lastError
        lock.unlock()

        // Still good: nothing to decide.
        if let held, !isExpired(held) { return held }

        // Expired, or nothing held at all. Ask the cheap question first.
        let current = itemModifiedAt()

        // Have we already put this exact version of the item to macOS?
        let alreadyAsked: Bool
        if let current, let askedStamp, current == askedStamp {
            // The probe settles it outright for a success, or for a failure
            // that is a verdict about the credential: the same item can only
            // give the same answer. A *transient* failure is not that — dark
            // wake says nothing about what the item holds — so it falls
            // through to the same backoff a failure with no probe gets below,
            // even though the item has not moved.
            if let failure, !isPermanentFailure(failure) {
                alreadyAsked = askedAt.map { now().timeIntervalSince($0) < retryAfterFailure } ?? false
            } else {
                alreadyAsked = true
            }
        } else if let current, let askedStamp {
            // Different versions: nothing to reuse, whatever the last answer was.
            alreadyAsked = false
        } else if let askedAt {
            // Nothing to compare against, so wait it out instead — and wait
            // longer after a refusal, because a refusal retried on a timer is
            // precisely what this exists to stop.
            let wait = failure == nil ? recheckAfter : retryAfterFailure
            alreadyAsked = now().timeIntervalSince(askedAt) < wait
        } else {
            alreadyAsked = false
        }

        if alreadyAsked {
            if let held { return held }
            // Nothing held and macOS has already refused this item: give back
            // the same answer rather than raising the same dialogue again.
            if let failure { throw failure }
        }

        do {
            let fresh = try reload()
            lock.lock()
            stored = fresh
            attemptedStamp = current
            attemptedAt = now()
            lastError = nil
            lock.unlock()
            return fresh
        } catch {
            lock.lock()
            // The attempt is recorded, the credential is not: a failure must
            // never be handed back as if it were one.
            attemptedStamp = current
            attemptedAt = now()
            lastError = error
            lock.unlock()
            throw error
        }
    }

    /// What is already in hand, and nothing more.
    ///
    /// For a caller that would like the credential's details but must not be
    /// the reason a dialogue appears. The settings row is exactly that: it is
    /// rebuilt every time the window renders, and it has no business asking
    /// macOS for a secret in order to print a plan name.
    var held: Credential? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    /// Stores an externally refreshed credential directly into the cache.
    func updateHeld(_ credential: Credential) {
        lock.lock()
        stored = credential
        attemptedAt = now()
        lastError = nil
        lock.unlock()
    }

    /// Drop what is held, so the next read goes to the keychain for real.
    ///
    /// Called when the server rejects the credential — that is the one signal
    /// the copy in hand is wrong despite not having expired, which is exactly
    /// what happens when someone signs into a different account — and by
    /// "Allow access…", where raising the dialogue again *is* the point.
    func forget() {
        lock.lock()
        stored = nil
        attemptedStamp = nil
        attemptedAt = nil
        lastError = nil
        lock.unlock()
    }
}
