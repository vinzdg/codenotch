import SwiftUI

struct OMLXSettingsRow: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var store: UsageStore
    var metrics: OMLXMetrics? = nil
    @State private var address = ""
    @State private var addressError: String?

    private let providerID = OMLXMetrics.providerID
    private var enabled: Bool { preferences.isConnected(providerID) }
    private var snapshot: ProviderSnapshot? { store.snapshots.first { $0.id == providerID } }
    private var checking: Bool { store.refreshing.contains(providerID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProviderGlyphView(glyph: .omlx, size: 16)
                Text("oMLX")
                Spacer()
                Toggle("Monitor oMLX", isOn: Binding(
                    get: { enabled },
                    set: { on in
                        preferences.setConnected(on, for: providerID)
                        store.disconnected = preferences.disconnectedIDs(among: store.knownIDs)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .font(.body)

            Button(L10n.t("Open oMLX")) { store.openAccountSource(providerID: providerID) }
                .controlSize(.small)

            HStack {
                TextField(L10n.t("Server address"), text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyAddress() }
                    .accessibilityLabel("oMLX server address")
                Button(address == preferences.omlxEndpoint ? L10n.t("Check connection") : L10n.t("Apply")) {
                    applyAddress()
                }
                .disabled(address == preferences.omlxEndpoint && (!enabled || checking))
                .controlSize(.small)
            }

            if let addressError {
                Text(addressError).foregroundStyle(.orange)
            } else if !enabled {
                Text(L10n.t("Monitoring off."))
                    .foregroundStyle(.secondary)
            } else if checking && snapshot?.hasReading != true {
                Text(L10n.t("Checking oMLX…")).foregroundStyle(.secondary)
            } else {
                Text(snapshot?.localRuntime?.summary ?? snapshot?.statusMessage ?? L10n.t("Connecting to oMLX…"))
                    .foregroundStyle(snapshot?.hasReading == true ? Color.secondary : .orange)
            }

            Text(L10n.t("Loaded models appear in Accounts → Connected and are checked every second. Embedding, reranker and audio models are not shown. The API key is read from ~/.omlx/settings.json (or OMLX_API_KEY); speed and tokens come from ~/.omlx/logs."))
                .foregroundStyle(.secondary)

            if enabled, let metrics {
                OMLXMetricsStatus(metrics: metrics)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { address = preferences.omlxEndpoint }
        .onChange(of: address) { _, _ in addressError = nil }
    }

    private func applyAddress() {
        do {
            let endpoint = try OMLXEndpoint.parse(address)
            address = endpoint.absoluteString
            preferences.omlxEndpoint = address
            store.updateOMLXEndpoint(endpoint)
            if enabled { store.refresh(providerID: providerID) }
            addressError = nil
        } catch {
            addressError = error.localizedDescription
        }
    }
}

private struct OMLXMetricsStatus: View {
    @ObservedObject var metrics: OMLXMetrics

    private var today: LocalTokenLedger.Totals { metrics.ledger.totalsToday(now: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity, speed and tokens").font(.body.weight(.medium))
            Text(metrics.status)
                .foregroundStyle(metrics.linked ? Color.secondary : .orange)
                .textSelection(.enabled)
            if metrics.historyLoaded {
                Text(metrics.ledger.isEmpty
                     ? "No requests found in oMLX's server log yet."
                     : "Today: \(today.requests) requests · \(LimitWindow.compact(today.inputTokens)) tokens in · \(LimitWindow.compact(today.outputTokens)) out, across \(metrics.ledger.instances.count) model(s) with history.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Reading oMLX's server log…").foregroundStyle(.secondary)
            }
            Text("What a model is doing comes from oMLX's admin activity endpoint, polled several times a second. Speed and token counts are read from ~/.omlx/logs; only the numbers are kept, never a prompt or a reply.")
                .foregroundStyle(.secondary)
        }
    }
}
