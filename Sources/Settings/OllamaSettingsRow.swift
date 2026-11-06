import SwiftUI

struct OllamaSettingsRow: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var store: UsageStore
    var relay: OllamaActivityRelay? = nil
    @State private var address = ""
    @State private var addressError: String?

    private var enabled: Bool { preferences.isConnected("ollama-local") }
    private var snapshot: ProviderSnapshot? { store.snapshots.first { $0.id == "ollama-local" } }
    private var checking: Bool { store.refreshing.contains("ollama-local") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProviderGlyphView(glyph: .ollamaLocal, size: 16)
                Text("Ollama")
                Spacer()
                Toggle(L10n.t("Monitor Ollama"), isOn: Binding(
                    get: { enabled },
                    set: { on in
                        preferences.setConnected(on, for: "ollama-local")
                        store.disconnected = preferences.disconnectedIDs(among: store.knownIDs)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .font(.body)

            Button(L10n.t("Open Ollama")) { store.openAccountSource(providerID: "ollama-local") }
                .controlSize(.small)

            HStack {
                TextField(L10n.t("Server address"), text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyAddress() }
                    .accessibilityLabel(L10n.t("Ollama server address"))
                Button(address == preferences.ollamaEndpoint ? L10n.t("Check connection") : L10n.t("Apply")) {
                    applyAddress()
                }
                .disabled(address == preferences.ollamaEndpoint && (!enabled || checking))
                .controlSize(.small)
            }

            if let addressError {
                Text(addressError).foregroundStyle(.orange)
            } else if !enabled {
                Text(L10n.t("Monitoring off."))
                    .foregroundStyle(.secondary)
            } else if checking && snapshot?.hasReading != true {
                Text(L10n.t("Checking Ollama…")).foregroundStyle(.secondary)
            } else {
                Text(snapshot?.localRuntime?.summary ?? snapshot?.statusMessage ?? L10n.t("Connecting to Ollama…"))
                    .foregroundStyle(snapshot?.hasReading == true ? Color.secondary : .orange)
            }

            Text(L10n.t("Detected models appear in Accounts → Connected. Model loading and unloading is checked every second."))
                .foregroundStyle(.secondary)

            Toggle(L10n.t("Measure speed and thinking"), isOn: $preferences.ollamaMetricsEnabled)
                .disabled(!enabled)
            Text(L10n.t("To measure responses, point your chat client to http://127.0.0.1:11435 and keep Codenotch open."))
                .foregroundStyle(.secondary)
            if enabled, preferences.ollamaMetricsEnabled, let relay {
                OllamaRelayStatus(relay: relay)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { address = preferences.ollamaEndpoint }
        .onChange(of: address) { _, _ in addressError = nil }
    }

    private func applyAddress() {
        do {
            let endpoint = try OllamaEndpoint.parse(address)
            address = endpoint.absoluteString
            preferences.ollamaEndpoint = address
            store.updateOllamaEndpoint(endpoint)
            if enabled { store.refresh(providerID: "ollama-local") }
            addressError = nil
        } catch {
            addressError = error.localizedDescription
        }
    }
}

private struct OllamaRelayStatus: View {
    @ObservedObject var relay: OllamaActivityRelay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Speed and thinking")).font(.body.weight(.medium))
            Text(relay.ready ? L10n.t("Listening at \(OllamaActivityRelay.address)") : relay.status)
                .foregroundStyle(relay.ready ? Color.secondary : .orange)
                .textSelection(.enabled)
            if relay.ready {
                Text(relay.performances.isEmpty
                     ? L10n.t("Waiting for a completed response through this address.")
                     : L10n.t("Generation speed received for \(relay.performances.count) model(s)."))
                    .foregroundStyle(.secondary)
                Text(L10n.t("Set your chat client's Ollama address to the one above, or run this in Terminal:"))
                    .foregroundStyle(.secondary)
                Text("OLLAMA_HOST=\(OllamaActivityRelay.address) ollama")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(L10n.t("Keep Codenotch open. Speed appears after each completed native Ollama response. Requests sent directly to the server address only provide model detection here."))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
