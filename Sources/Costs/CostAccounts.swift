import Foundation
import Combine

/// One CLI login as the cost layer sees it: a Codenotch profile (Claude or
/// Codex, default or `~/.claude-<slug>`) plus how it is paid. Billing choices,
/// the detected plan and the credit cap persist in accounts.json.
struct CostAccount: Identifiable, Equatable {
    enum Billing: String, Codable, CaseIterable, Identifiable {
        case subscription, api
        var id: String { rawValue }
        var title: String { self == .subscription ? L10n.t("Monthly plan") : L10n.t("API key (per token)") }
    }

    let id: String                 // the provider id Codenotch uses ("claude", "claude-braspine", "codex", …)
    let provider: String           // "claude" | "codex"
    let name: String               // "Claude (work)": the profile's own name
    let configDirectory: URL
    var billing: Billing = .subscription
    var monthlyPrice: Double = 0   // manual override in the Mac's currency (0 = detected plan)
    var planTier: String?
    var planDetectedAt: Date?
    var creditLimit: Double?

    var isDefault: Bool { !id.contains("-") }

    @MainActor var planName: String? { planTier.map { PlanCatalog.shared.name(for: $0) } }

    /// Monthly price in the Mac's currency: the override, else the catalog.
    @MainActor func monthlyLocal(rate: Double) -> Double {
        if monthlyPrice > 0 { return monthlyPrice }
        guard let tier = planTier else { return 0 }
        return PlanCatalog.shared.monthly(for: tier, currency: PriceTable.shared.currency, rate: rate) ?? 0
    }

    @MainActor func creditLocal(rate: Double) -> Double? {
        let usd = planTier.flatMap { PlanCatalog.shared.creditUSD(for: $0) } ?? 1
        return rate > 0 ? usd * rate : nil
    }

    var transcriptsRoot: URL {
        configDirectory.appendingPathComponent(provider == "codex" ? "sessions" : "projects")
    }
}

@MainActor
final class CostAccountStore: ObservableObject {
    static let shared = CostAccountStore()

    @Published private(set) var accounts: [CostAccount] = []

    private struct Stored: Codable {
        var billing: CostAccount.Billing?
        var monthlyPrice: Double?
        var planTier: String?
        var planDetectedAt: Date?
        var creditLimit: Double?
    }
    private var stored: [String: Stored] = [:]

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Codenotch/costs/accounts.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let map = try? JSONDecoder().decode([String: Stored].self, from: data) { stored = map }
        rediscover()
    }

    /// Profiles come from Codenotch's own discovery, so an account added there
    /// (a new `~/.claude-<slug>`) shows up here without a second list.
    func rediscover() {
        var list: [CostAccount] = []
        for p in ClaudeProfile.discover() {
            list.append(apply(CostAccount(id: p.id, provider: "claude", name: p.displayName, configDirectory: p.configDirectory)))
        }
        for p in CodexProfile.discover() {
            list.append(apply(CostAccount(id: p.id, provider: "codex", name: p.displayName, configDirectory: p.configDirectory)))
        }
        if list != accounts { accounts = list }
    }

    private func apply(_ a: CostAccount) -> CostAccount {
        var a = a
        if let s = stored[a.id] {
            a.billing = s.billing ?? .subscription
            a.monthlyPrice = s.monthlyPrice ?? 0
            a.planTier = s.planTier
            a.planDetectedAt = s.planDetectedAt
            a.creditLimit = s.creditLimit
        }
        return a
    }

    func account(_ id: String) -> CostAccount? { accounts.first { $0.id == id } }
    func accounts(for provider: String) -> [CostAccount] { accounts.filter { $0.provider == provider } }

    private func mutate(_ id: String, _ change: (inout CostAccount) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[i])
        let a = accounts[i]
        stored[id] = Stored(billing: a.billing, monthlyPrice: a.monthlyPrice, planTier: a.planTier,
                            planDetectedAt: a.planDetectedAt, creditLimit: a.creditLimit)
        save()
    }

    func setBilling(_ id: String, _ b: CostAccount.Billing) { mutate(id) { $0.billing = b } }
    func setMonthlyPrice(_ id: String, _ p: Double) { mutate(id) { $0.monthlyPrice = p } }
    func setCreditLimit(_ id: String, _ l: Double) { mutate(id) { if $0.creditLimit != l { $0.creditLimit = l } } }
    func setPlan(_ id: String, tier: String) {
        mutate(id) { a in
            if a.planTier == tier, let at = a.planDetectedAt, Date().timeIntervalSince(at) < 3600 { return }
            a.planTier = tier; a.planDetectedAt = Date()
        }
    }
    func planIsFresh(_ id: String) -> Bool {
        guard let a = account(id), let at = a.planDetectedAt else { return false }
        return Date().timeIntervalSince(at) < 24 * 3600
    }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(stored) {
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: Plan detection (once a day, from the login the CLI already holds)

    func detectPlanIfDue(_ id: String) {
        guard let a = account(id), !planIsFresh(id) else { return }
        if a.provider == "codex" {
            if let plan = CodexCredentials.account(from: a.configDirectory.appendingPathComponent("auth.json"))?.plan {
                setPlan(id, tier: plan)
            }
            return
        }
        guard let profile = ClaudeProfile.discover().first(where: { $0.id == id }) else { return }
        Task.detached(priority: .utility) {
            guard let creds = try? ClaudeCredentials.read(services: profile.keychainServices, interactive: false) else { return }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
            request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.timeoutInterval = 15
            guard let (data, resp) = try? await URLSession.shared.data(for: request),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            let org = root["organization"] as? [String: Any]
            guard let tier = (org?["rate_limit_tier"] as? String)
                ?? ((org?["organization_type"] as? String).map { "default_" + $0 }) else { return }
            await MainActor.run { CostAccountStore.shared.setPlan(id, tier: tier) }
        }
    }
}
