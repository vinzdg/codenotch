import SwiftUI

/// "What used it" on the hover card: the projects that consumed this
/// account's allowance in the current week (or credit cycle), each with its
/// share and the money that share is worth. The full picker lives in the
/// Activity window; the card keeps to one range so it never grows past what
/// `NotchLayout.cardHeight` reserved for it.
struct CostSection: View {
    @ObservedObject var model: CostModel
    /// Rows the screen has room for (solved by the view model); never more than `maxRows`.
    var rows: Int = CostSection.maxRows

    static let maxRows = 5

    /// How many lines the card must reserve — read by the height math, so it
    /// has to agree with what `body` draws.
    @MainActor static func rowCount(for snapshot: ProviderSnapshot) -> Int {
        guard let m = CostModels.model(for: snapshot.id), m.state == .ready else { return 0 }
        return min(m.rows.count, maxRows)
    }

    private var shown: [ProjectCost] { Array(model.rows.prefix(min(rows, Self.maxRows))) }

    /// The ranges the card offers: the day, the allowance window (a week, or
    /// a credit cycle) and the month.
    static let tabs: [CostRange] = [.today, .weekly, .month]

    private func title(_ range: CostRange) -> String {
        if range == .weekly, model.creditBacked { return L10n.t("Cycle") }
        return range.shortTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchLayout.sessionRowGap) {
            HStack(spacing: Design.px(18)) {
                ForEach(Self.tabs) { range in
                    let selected = model.range == range
                    Button { model.range = range } label: {
                        Text(title(range))
                            .font(selected ? Typography.cardBody.weight(.semibold) : Typography.cardBody)
                            .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(height: NotchLayout.cardBodyLineHeight)
            .padding(.top, NotchLayout.blockSpacing)
            ForEach(shown) { row in
                HStack(spacing: Design.px(12)) {
                    Text(row.displayName)
                        .font(Typography.cardBody)
                        .foregroundStyle(row.isUnexplained ? Palette.textSecondary : Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Design.px(8))
                    Text(Percent.text(for: row.pct / 100) + "%")
                        .font(Typography.cardBody)
                        .foregroundStyle(Palette.textSecondary)
                        .monospacedDigit()
                    if let cost = row.cost {
                        Text(MoneyFormat.string(cost, currency: PriceTable.shared.currency))
                            .font(Typography.cardBody)
                            .foregroundStyle(Palette.textSecondary)
                            .monospacedDigit()
                            .frame(minWidth: Design.px(70), alignment: .trailing)
                    }
                }
            }
        }
        .onAppear {
            // Opens on the allowance window when the account has one, else the
            // month; the tabs take it from there.
            guard !Self.tabs.contains(model.range) else { return }
            model.range = model.quotaBacked ? .weekly : .month
        }
    }
}
