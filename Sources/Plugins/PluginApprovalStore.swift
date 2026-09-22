import Foundation

/// Where the pinned plugin approvals live.
///
/// Not in UserDefaults. The preferences plist is writable by any process
/// running as the user — the same adversary that can drop a manifest into the
/// plugins folder — so an approval kept there is forgeable with one
/// `defaults write`, and the consent step it exists to enforce could be
/// skipped end to end.
///
/// Not in the login keychain either. The same adversary can delete our item
/// there without a prompt and file its own under our name with an ACL any
/// application may read, and every attribute of that item — the partition
/// entry that names its creator included — is written by the client that
/// creates it. Only the **data-protection keychain** answers this: its items
/// sit in an access group that securityd ties to the caller's entitlements,
/// which no process outside this team can carry. A build without that
/// entitlement (ad-hoc, unsigned, or signed without a profile that grants
/// it) keeps no approvals at all: every plugin asks again at each launch,
/// which is the safe answer and a visible one.
protocol PluginApprovalStore: AnyObject {
    /// Plugin id → the approved content hash. Empty when nothing is approved,
    /// and empty — fail closed — whenever the store cannot vouch for what it
    /// finds.
    func load() -> [String: String]
    func save(_ approvals: [String: String])
}

/// Approvals that live and die with the process: tests, and the demo mode.
final class EphemeralPluginApprovalStore: PluginApprovalStore {
    private var approvals: [String: String]

    init(_ approvals: [String: String] = [:]) {
        self.approvals = approvals
    }

    func load() -> [String: String] { approvals }
    func save(_ approvals: [String: String]) { self.approvals = approvals }
}

/// The real store: one generic-password item holding the approvals as JSON.
final class KeychainPluginApprovalStore: PluginApprovalStore {
    static let service = "codenotch-plugin-approvals"
    static let account = "approvals"

    func load() -> [String: String] {
        guard DataProtectionKeychain.isAvailable else {
            Log.usage.error("plugin approvals: this build has no data-protection keychain entitlement; approvals are not kept between launches")
            return [:]
        }
        guard let text = DataProtectionKeychain.read(service: Self.service, account: Self.account) else { return [:] }
        return Self.decode(text)
    }

    func save(_ approvals: [String: String]) {
        guard DataProtectionKeychain.isAvailable else { return }
        if approvals.isEmpty {
            DataProtectionKeychain.delete(service: Self.service, account: Self.account)
            return
        }
        guard let text = Self.encode(approvals),
              DataProtectionKeychain.store(service: Self.service, account: Self.account, value: text)
        else {
            Log.usage.error("plugin approvals: keychain write failed")
            return
        }
    }

    /// The wire form, split out so the codec is testable without a keychain.
    static func encode(_ approvals: [String: String]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(approvals)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Anything that is not a flat `{id: hash}` object is treated as no
    /// approvals at all.
    static func decode(_ text: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))) ?? [:]
    }
}
