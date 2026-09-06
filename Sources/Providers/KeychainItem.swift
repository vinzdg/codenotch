import Foundation
import Security

/// Asking about a keychain item without asking for what is inside it.
///
/// The access control on another app's item guards its **data**, not its
/// attributes: `kSecReturnAttributes` is answered from the item's metadata and
/// never raises the "wants to access your confidential information" dialogue,
/// where `kSecReturnData` always may. `security find-generic-password` versus
/// the same command with `-w` is the same distinction from the shell.
///
/// That is what makes it worth asking often. The expensive read — the one that
/// can interrupt someone — then only has to happen when this says the item has
/// actually changed.
///
/// It is also what makes duplicates safe to resolve without a prompt. Claude
/// Code files a new keychain item on every token rotation rather than
/// updating one in place, so a login that has been used for months
/// accumulates several under the same service name — six, on the machine this
/// was found on. `kSecMatchLimitOne` gives no ordering guarantee across them,
/// so a plain query can return an old, expired duplicate while a valid one
/// sits beside it: the app reads a token that expired days ago, `security
/// find-generic-password` run at the same moment returns a different and
/// current one. `kSecMatchLimitAll` against attributes enumerates every
/// duplicate for free, so the newest is found by comparison rather than luck.
enum KeychainItem {
    /// One matching item, without its secret: when the owning app last wrote
    /// it, and a handle that can fetch its data later without searching again.
    struct Match {
        let modifiedAt: Date?
        /// Opaque to everything but `SecItemCopyMatching`. Reading the item
        /// this points at is the one call that can prompt; enumerating to find
        /// it, like reading `modifiedAt`, never does.
        let persistentRef: Data
    }

    /// The most recently modified item under a service, or nil if there is
    /// none or macOS declined to say. Ties do not arise in practice —
    /// `kSecAttrModificationDate` is a timestamp, not a version counter — and
    /// where they would, either duplicate is an equally good answer.
    static func newest(service: String, account: String? = nil) -> Match? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        if let account { query[kSecAttrAccount] = account }

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        else { return nil }

        // A single match still comes back as one dictionary rather than an
        // array of one — `kSecMatchLimitAll` promises "every match", not "an
        // array", and one is not the many it means.
        let items = (result as? [[CFString: Any]]) ?? (result as? [CFString: Any]).map { [$0] } ?? []
        return winner(among: items)
    }

    /// The selection itself, apart from the query that produces its input.
    /// `SecItemCopyMatching` cannot run in a unit test — there is no keychain
    /// to point it at — so this is the half that can be, and is: given several
    /// duplicates, does the newest one actually win.
    static func winner(among items: [[CFString: Any]]) -> Match? {
        items
            .compactMap { item -> Match? in
                guard let ref = item[kSecValuePersistentRef] as? Data else { return nil }
                return Match(modifiedAt: item[kSecAttrModificationDate] as? Date, persistentRef: ref)
            }
            // A duplicate with no modification date is possible in principle
            // and worth keeping rather than discarding; `.distantPast` only
            // decides its rank against the others, never whether it exists.
            .max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    /// When the owning app last wrote the newest item under this service, or
    /// nil if there is no such item or macOS declined to say.
    static func modifiedAt(service: String, account: String? = nil) -> Date? {
        newest(service: service, account: account)?.modifiedAt
    }
}
