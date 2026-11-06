import SwiftUI

struct LMStudioSettingsRow: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var store: UsageStore
    var metrics: LMStudioMetrics? = nil
    @State private var address = ""
    @State private var addressError: String?
    @State private var token = ""
    @State private var tokenSaved = false

    private let providerID = LMStudioMetrics.providerID
    private var enabled: Bool { preferences.isConnected(providerID) }
    private var snapshot: ProviderSnapshot? { store.snapshots.first { $0.id == providerID } }
    private var checking: Bool { store.refreshing.contains(providerID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProviderGlyphView(glyph: .lmstudio, size: 16)
                Text("LM Studio")
                Spacer()
                Toggle(L10n.t("Monitor LM Studio"), isOn: Binding(
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

            Button(L10n.t("Open LM Studio")) { store.openAccountSource(providerID: providerID) }
                .controlSize(.small)

            HStack {
                TextField(L10n.t("Server address"), text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyAddress() }
                    .accessibilityLabel(L10n.t("LM Studio server address"))
                Button(address == preferences.lmstudioEndpoint ? L10n.t("Check connection") : L10n.t("Apply")) {
                    applyAddress()
                }
                .disabled(address == preferences.lmstudioEndpoint && (!enabled || checking))
                .controlSize(.small)
            }

            if let addressError {
                Text(addressError).foregroundStyle(.orange)
            } else if !enabled {
                Text(L10n.t("Monitoring off."))
                    .foregroundStyle(.secondary)
            } else if checking && snapshot?.hasReading != true {
                Text(L10n.t("Checking LM Studio…")).foregroundStyle(.secondary)
            } else {
                Text(snapshot?.localRuntime?.summary ?? snapshot?.statusMessage ?? L10n.t("Connecting to LM Studio…"))
                    .foregroundStyle(snapshot?.hasReading == true ? Color.secondary : .orange)
            }

            Text(L10n.t("Loaded models appear in Accounts → Connected and are checked every second. Embedding models are not shown."))
                .foregroundStyle(.secondary)

            tokenEntry

            if enabled, let metrics {
                LMStudioMetricsStatus(metrics: metrics)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { address = preferences.lmstudioEndpoint }
        .onChange(of: address) { _, _ in addressError = nil }
    }

    /// Only needed when LM Studio's "Require API token" is on. Stored in the
    /// keychain, like the Ollama cloud key; `LM_API_TOKEN` in the environment
    /// wins over it, so a shell that exports one needs no entry here.
    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("API token"))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SecureField("sk-lm-…", text: $token)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                Button(L10n.t("Save")) {
                    guard !token.isEmpty else { return }
                    LMStudioCredentials.store(token)
                    token = ""
                    tokenSaved = true
                    if enabled { store.refresh(providerID: providerID) }
                }
                .disabled(token.isEmpty)
                .controlSize(.small)
                if LMStudioCredentials.isPresent {
                    Button(L10n.t("Remove")) {
                        LMStudioCredentials.delete()
                        tokenSaved = false
                        if enabled { store.refresh(providerID: providerID) }
                    }
                    .controlSize(.small)
                }
                if tokenSaved {
                    Text(L10n.t("Saved")).foregroundStyle(.green)
                }
            }
            Text(LMStudioCredentials.isPresent
                 ? L10n.t("A token is stored and sent with every request.")
                 : L10n.t("Only needed when LM Studio's server requires a token (Developer → Server Settings). Without one, requests are sent with no Authorization header."))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private func applyAddress() {
        do {
            let endpoint = try LMStudioEndpoint.parse(address)
            address = endpoint.absoluteString
            preferences.lmstudioEndpoint = address
            store.updateLMStudioEndpoint(endpoint)
            if enabled { store.refresh(providerID: providerID) }
            addressError = nil
        } catch {
            addressError = error.localizedDescription
        }
    }
}

private struct LMStudioMetricsStatus: View {
    @ObservedObject var metrics: LMStudioMetrics

    private var today: LocalTokenLedger.Totals { metrics.ledger.totalsToday(now: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Activity, speed and tokens")).font(.body.weight(.medium))
            Text(metrics.status)
                .foregroundStyle(metrics.linked ? Color.secondary : .orange)
                .textSelection(.enabled)
            if metrics.historyLoaded {
                Text(metrics.ledger.isEmpty
                     ? L10n.t("No requests found in LM Studio's server log yet.")
                     : L10n.t("Today: \(today.requests) requests · \(LimitWindow.compact(today.inputTokens)) tokens in · \(LimitWindow.compact(today.outputTokens)) out, across \(metrics.ledger.instances.count) model(s) with history."))
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.t("Reading LM Studio's server log…")).foregroundStyle(.secondary)
            }
            Text(L10n.t("What a model is doing comes from LM Studio's own status, polled several times a second. Speed, context use and token counts are read from ~/.lmstudio/server-logs; only the numbers are kept, never a prompt or a reply. Responses through the OpenAI-compatible endpoint carry no clock, so their speed is timed here and marked ~."))
                .foregroundStyle(.secondary)
        }
    }
}
