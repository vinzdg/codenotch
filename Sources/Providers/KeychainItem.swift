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
        /// The service name it was filed under — needed to reach the same item
        /// by name when a direct read of it is refused.
        let service: String
    }

    /// The most recently modified item under a service, or nil if there is
    /// none or macOS declined to say. Ties do not arise in practice —
    /// `kSecAttrModificationDate` is a timestamp, not a version counter — and
    /// where they would, either duplicate is an equally good answer.
    static func newest(service: String, account: String? = nil) -> Match? {
        newest(among: matches(service: service, account: account))
    }

    /// Every item under a service, without its secret. Enumerating attributes
    /// never prompts, so a caller that must know whether it is looking at
    /// *one* item — its own — or at a name something else has also filed
    /// under can find out for free.
    static func matches(service: String, account: String? = nil) -> [Match] {
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
        else { return [] }

        // A single match still comes back as one dictionary rather than an
        // array of one — `kSecMatchLimitAll` promises "every match", not "an
        // array", and one is not the many it means.
        let items = (result as? [[CFString: Any]]) ?? (result as? [CFString: Any]).map { [$0] } ?? []
        return items.compactMap { item -> Match? in
            guard let ref = item[kSecValuePersistentRef] as? Data else { return nil }
            return Match(modifiedAt: item[kSecAttrModificationDate] as? Date, persistentRef: ref,
                         service: item[kSecAttrService] as? String ?? "")
        }
    }

    /// The selection itself, apart from the query that produces its input.
    /// `SecItemCopyMatching` cannot run in a unit test — there is no keychain
    /// to point it at — so this is the half that can be, and is: given several
    /// duplicates, does the newest one actually win.
    static func winner(among items: [[CFString: Any]]) -> Match? {
        newest(among: items.compactMap { item -> Match? in
            guard let ref = item[kSecValuePersistentRef] as? Data else { return nil }
            return Match(modifiedAt: item[kSecAttrModificationDate] as? Date, persistentRef: ref,
                         service: item[kSecAttrService] as? String ?? "")
        })
    }

    /// The same choice over already-decoded matches.
    static func newest(among matches: [Match]) -> Match? {
        // A duplicate with no modification date is possible in principle
        // and worth keeping rather than discarding; `.distantPast` only
        // decides its rank against the others, never whether it exists.
        matches.max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    /// When the owning app last wrote the newest item under this service, or
    /// nil if there is no such item or macOS declined to say.
    static func modifiedAt(service: String, account: String? = nil) -> Date? {
        newest(service: service, account: account)?.modifiedAt
    }

    /// The newest item across several services — the same "newest wins" choice
    /// as `newest(service:)`, widened to a profile whose token may be filed
    /// under more than one service name (see `ClaudeProfile.keychainServices`).
    /// Enumerating each service's attributes never raises a prompt, so trying
    /// two costs no extra dialogue over trying one.
    static func newest(services: [String], account: String? = nil) -> Match? {
        services
            .compactMap { newest(service: $0, account: account) }
            .max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    /// When the owning app last wrote the newest item across these services.
    static func modifiedAt(services: [String], account: String? = nil) -> Date? {
        newest(services: services, account: account)?.modifiedAt
    }

    /// Reads the data from the newest item under a service. The one call that
    /// can trigger a keychain prompt. Items this app created itself (`store`)
    /// do not prompt either — but only as long as the binary keeps the same
    /// signing identity that stored them; an ad-hoc rebuild is a new identity,
    /// which is why even own-item readers go through `CredentialCache`.
    static func read(service: String, account: String? = nil) -> String? {
        guard let match = newest(service: service, account: account) else { return nil }
        return read(match)
    }

    /// Reads exactly the item a match points at — not whichever item is
    /// under that name by the time the read happens. A caller that has
    /// inspected an item and decided to trust it must read *that* item.
    static func read(_ match: Match) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: match.persistentRef,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores a string under a service+account, creating or updating the item.
    /// For items this app owns, no prompt is involved on either write or read.
    static func store(service: String, account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Deletes the item under a service+account, if one exists.
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

/// The data-protection keychain: items live in an access group that only
/// code signed with this app's team can name, enforced by securityd from
/// the caller's entitlements. No other process can file, read, replace or
/// delete an item there, whatever it says about itself. It is available to
/// a build that carries the `keychain-access-groups` entitlement (and, for
/// Developer ID, the provisioning profile that grants it); anything else —
/// an ad-hoc or unsigned development build — gets `errSecMissingEntitlement`
/// and has to fall back.
enum DataProtectionKeychain {
    /// Whether this build is entitled to the data-protection keychain. A
    /// read from an unentitled process answers "not found", the same as an
    /// entitled build with nothing stored; only a write answers
    /// `errSecMissingEntitlement`. So the answer comes from writing a probe
    /// item once and deleting it — decided once per process, since the
    /// entitlement cannot change while it runs.
    static let isAvailable: Bool = {
        let probe: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "codenotch-keychain-probe",
            kSecAttrAccount: "probe",
            kSecValueData: Data("probe".utf8),
            kSecUseDataProtectionKeychain: true
        ]
        switch SecItemAdd(probe as CFDictionary, nil) {
        case errSecSuccess, errSecDuplicateItem:
            delete(service: "codenotch-keychain-probe", account: "probe")
            return true
        default:
            return false
        }
    }()

    /// The stored text, or nil when there is none. Only meaningful where
    /// `isAvailable`; an unentitled process is answered "not found".
    static func read(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func store(service: String, account: String, value: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
