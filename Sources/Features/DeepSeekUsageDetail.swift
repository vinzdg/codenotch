import SwiftUI

/// The account-level section shown below DeepSeek's funded/spent bar.
/// It mirrors the compact Codex activity section, but keeps DeepSeek's CNY
/// cost and API-key/model aggregation explicit.
struct DeepSeekUsageDetail: View {
    let detail: ProviderUsageDetail
    let now: Date
    let schedule: DeepSeekPricing.Schedule
    let showsPricing: Bool
    @Environment(\.codenotchAccentColor) private var accentColor

    private var timeZoneText: String {
        let absolute = abs(detail.timeZoneSeconds)
        let sign = detail.timeZoneSeconds >= 0 ? "+" : "-"
        let hours = absolute / 3_600
        let minutes = (absolute % 3_600) / 60
        return minutes == 0 ? "UTC\(sign)\(hours)" : "UTC\(sign)\(hours):\(String(format: "%02d", minutes))"
    }

    private var points: [Point] {
        var values = [Int: Point]()
        for group in detail.visibleGroups {
            for day in group.days {
                let timestamp = Int(day.date.timeIntervalSince1970)
                var point = values[timestamp] ?? Point(timestamp: timestamp)
                point.tokens += day.totalTokens
                point.cost += day.cost
                values[timestamp] = point
            }
        }
        return values.values.sorted { $0.timestamp < $1.timestamp }
    }

    private var moneyText: String {
        Self.money(detail.totalCost, currency: detail.currency)
    }

    private var pricingText: String {
        switch DeepSeekPricing.phase(at: now, schedule: schedule) {
        case .peak:
            return L10n.t("Peak pricing · 2× off-peak")
        case .offPeak:
            return L10n.t("Off-peak pricing · baseline")
        }
    }

    private var pricingColor: Color {
        switch DeepSeekPricing.phase(at: now, schedule: schedule) {
        case .peak: return Palette.watch
        case .offPeak: return accentColor
        }
    }

    private var nextPricingTransition: DeepSeekPricing.Transition {
        DeepSeekPricing.nextTransition(after: now, schedule: schedule)
    }

    private var nextPricingLabel: String {
        switch nextPricingTransition.phase {
        case .peak: return L10n.t("Next peak")
        case .offPeak: return L10n.t("Next off-peak")
        }
    }

    private var nextPricingTime: String {
        let formatter = ResetCopy.formatter(for: Calendar.current)
        formatter.locale = L10n.locale
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("E j:mm")
        return formatter.string(from: nextPricingTransition.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Palette.ringTrack)
                .frame(height: NotchLayout.hairline)
                .padding(.top, NotchLayout.blockSpacing)

            SplitRow(leading: L10n.t("Usage details"), trailing: timeZoneText)
                .padding(.top, NotchLayout.blockSpacing)

            HStack(spacing: NotchLayout.blockSpacing) {
                DeepSeekMetric(label: L10n.t("Tokens"), value: UsageFormat.tokens(detail.totalTokens))
                DeepSeekMetric(label: L10n.t("Cost"), value: moneyText)
                DeepSeekMetric(label: L10n.t("Requests"), value: "\(detail.totalRequests)")
                DeepSeekMetric(label: L10n.t("API keys"), value: "\(detail.visibleAPIKeyCount)")
            }
            .frame(width: NotchLayout.cardTextWidth)
            .padding(.top, NotchLayout.blockSpacing)

            if showsPricing {
                Rectangle()
                    .fill(Palette.ringTrack)
                    .frame(height: NotchLayout.hairline)
                    .padding(.top, NotchLayout.blockSpacing)

                SplitRow(leading: L10n.t("Pricing"), trailing: pricingText,
                         trailingColor: pricingColor)
                    .padding(.top, NotchLayout.blockSpacing)

                SplitRow(leading: nextPricingLabel, trailing: nextPricingTime)
                    .padding(.top, NotchLayout.usageDetailIdentityGap)
            }

            Rectangle()
                .fill(Palette.ringTrack)
                .frame(height: NotchLayout.hairline)
                .padding(.top, NotchLayout.blockSpacing)

            DeepSeekUsageChart(title: L10n.t("Daily tokens"), values: points.map { Double($0.tokens) }, formatter: {
                UsageFormat.tokens(Int($0))
            })
                .padding(.top, NotchLayout.blockSpacing)
            DeepSeekUsageChart(title: L10n.t("Daily cost"), values: points.map { $0.cost }, formatter: {
                Self.money($0, currency: detail.currency)
            })
            .padding(.top, NotchLayout.usageDetailChartGap)
        }
    }

    private struct Point {
        let timestamp: Int
        var tokens = 0
        var cost = 0.0
    }

    private static func money(_ value: Double, currency: String) -> String {
        let symbol: String
        switch currency.uppercased() {
        case "CNY", "RMB", "JPY": symbol = "¥"
        case "USD": symbol = "$"
        case "EUR": symbol = "€"
        default: symbol = currency + " "
        }
        return "\(symbol)\(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value))"
    }
}

private struct DeepSeekMetric: View {
    let label: String
    let value: String
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    var body: some View {
        VStack(alignment: .leading, spacing: NotchLayout.moneyStatGap) {
            Text(label).foregroundStyle(secondaryInk).lineLimit(1)
            Text(value).foregroundStyle(Palette.textPrimary).monospacedDigit().lineLimit(1)
        }
        .font(Typography.cardBody)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DeepSeekUsageChart: View {
    let title: String
    let values: [Double]
    let formatter: (Double) -> String
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    private var maximum: Double { max(values.max() ?? 0, 1) }
    private var barWidth: CGFloat {
        let count = CGFloat(max(values.count, 1))
        return max(1, (NotchLayout.cardTextWidth - (count - 1) * NotchLayout.usageDetailBarGap) / count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                Text(L10n.t("peak \(formatter(values.max() ?? 0))"))
                    .foregroundStyle(secondaryInk)
                    .lineLimit(1)
            }
            .font(Typography.cardBody)

            ZStack(alignment: .bottom) {
                Rectangle().fill(Palette.ringTrack).frame(height: NotchLayout.hairline)
                HStack(alignment: .bottom, spacing: NotchLayout.usageDetailBarGap) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        RoundedRectangle(cornerRadius: Design.px(4), style: .continuous)
                            .fill(index == values.count - 1 ? Palette.textPrimary : secondaryInk)
                            .frame(width: barWidth,
                                   height: value > 0 ? max(Design.px(4), NotchLayout.usageDetailChartHeight * value / maximum) : 0)
                    }
                }
            }
            .frame(width: NotchLayout.cardTextWidth,
                   height: NotchLayout.usageDetailChartHeight,
                   alignment: .bottom)
            .padding(.top, NotchLayout.usageDetailLabelToBar)
        }
    }
}
