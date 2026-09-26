import SwiftUI

/// Settings › Costs: how each login is paid, the plan detected for it, and
/// the market data the money is worked out from.
struct CostSettingsPane: View {
    @ObservedObject var accounts: CostAccountStore = .shared
    @ObservedObject var prices: PriceTable = .shared
    @ObservedObject var catalog: PlanCatalog = .shared

    private var currencyName: String { Locale.current.localizedString(forCurrencyCode: prices.currency) ?? prices.currency }

    var body: some View {
        Form {
            ForEach(accounts.accounts) { account in
                Section(account.name) {
                    CostAccountRows(account: account)
                }
            }

            Section(L10n.t("How the money is worked out")) {
                Text(L10n.t("Detected from each login once a day. A week of the plan costs the price ÷ 4.35; a project that used 4% of the weekly allowance spent 4% of that. Amounts in \(currencyName), your Mac's currency. Type the amount you actually pay to override the list price."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.t("Market data")) {
                LabeledContent(L10n.t("Exchange rate")) {
                    Text(prices.rateKnown ? L10n.t("1 USD = \(MoneyFormat.string(prices.rate, currency: prices.currency))") : L10n.t("Not fetched yet"))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(L10n.t("Per-token prices")) {
                    Text(L10n.t("\(prices.prices.count) models")).foregroundStyle(.secondary)
                }
                LabeledContent(L10n.t("Plan catalog")) {
                    HStack(spacing: 8) {
                        Text(L10n.t("\(catalog.plans.count) plans")).foregroundStyle(.secondary)
                        Button(L10n.t("Open catalog")) { NSWorkspace.shared.activateFileViewerSelecting([PlanCatalog.fileURL]) }
                    }
                }
                Button(L10n.t("Refresh now")) { prices.refreshIfDue(force: true); catalog.refreshIfDue(force: true) }
                Text(L10n.t("Refreshed once a day, no account needed: exchange rate from open.er-api.com, per-token prices from OpenRouter. Plans live in plans.json, editable."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button(L10n.t("Open Activity…")) { Costs.showActivity() }
                Text(L10n.t("Day, week and month per login: sessions per project with what each cost."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// One login's billing: how it is paid, what it costs, and the plan detected.
private struct CostAccountRows: View {
    let account: CostAccount
    @ObservedObject private var accounts = CostAccountStore.shared
    @ObservedObject private var prices = PriceTable.shared
    @ObservedObject private var catalog = PlanCatalog.shared

    var body: some View {
        let auto = account.monthlyLocal(rate: prices.rate)
        Picker(L10n.t("Billing"), selection: Binding(get: { account.billing }, set: { accounts.setBilling(account.id, $0) })) {
            ForEach(CostAccount.Billing.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)

        if account.billing == .subscription {
            LabeledContent(L10n.t("Monthly price")) {
                TextField("", value: Binding(get: { account.monthlyPrice == 0 ? nil : account.monthlyPrice },
                                             set: { accounts.setMonthlyPrice(account.id, $0 ?? 0) }),
                          format: .number,
                          prompt: Text(auto > 0 ? MoneyFormat.string(auto, currency: prices.currency) : "—"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
            }
            LabeledContent(L10n.t("Plan")) {
                Text(planDetail).foregroundStyle(.secondary)
            }
        }
    }

    private var planDetail: String {
        guard let tier = account.planTier else { return L10n.t("Plan not detected yet") }
        let name = catalog.name(for: tier)
        if let local = catalog.monthly(for: tier, currency: prices.currency, rate: prices.rate) {
            return L10n.t("\(name) · \(MoneyFormat.string(local, currency: prices.currency))/month (catalog)")
        }
        return L10n.t("\(name) · price unknown, set it here")
    }
}
