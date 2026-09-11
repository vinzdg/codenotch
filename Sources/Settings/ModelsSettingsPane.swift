import SwiftUI

/// Visibility is independent of account access: a quieter notch should not
/// require signing in again or discarding a provider's last good reading.
struct ModelsSettingsPane: View {
    @ObservedObject var preferences: Preferences
    let providers: [ProviderSummary]

    private var assistants: [ProviderSummary] {
        providers.filter { $0.kind == .usage }
    }

    private var runtimes: [ProviderSummary] {
        providers.filter { $0.kind == .localRuntime && $0.localModel == nil }
    }

    var body: some View {
        Form {
            Section {
                Text(L10n.t("Choose which assistants and local models appear in the notch. Hidden items keep monitoring, and your choices are saved automatically."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !assistants.isEmpty {
                Section(L10n.t("Assistants")) {
                    ForEach(assistants) { provider in
                        ModelVisibilityRow(preferences: preferences, provider: provider)
                    }
                }
            }

            ForEach(runtimes) { runtime in
                Section(runtime.name) {
                    ModelVisibilityRow(preferences: preferences, provider: runtime)

                    let models = providers.filter { $0.localModel != nil && $0.sourceProviderID == runtime.id }
                    ForEach(models) { model in
                        ModelVisibilityRow(preferences: preferences, provider: model)
                            .padding(.leading, 24)
                            .disabled(!preferences.isConnected(runtime.id) || !preferences.isShownInNotch(runtime.id))
                    }
                    if models.isEmpty {
                        Text(L10n.t("Loaded models appear here automatically when runtime monitoring is enabled."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if providers.isEmpty {
                ContentUnavailableView(L10n.t("No models available"), systemImage: "square.stack.3d.up",
                                       description: Text(L10n.t("Connect an assistant in Accounts or enable a local runtime to get started.")))
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelVisibilityRow: View {
    @ObservedObject var preferences: Preferences
    let provider: ProviderSummary

    var body: some View {
        Toggle(isOn: Binding(
            get: { preferences.isShownInNotch(provider.id) },
            set: { preferences.setShownInNotch($0, for: provider.id) }
        )) {
            HStack(spacing: 10) {
                ProviderGlyphView(glyph: provider.glyph, size: 16)
                    .foregroundStyle(preferences.isShownInNotch(provider.id) ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name)
                        .lineLimit(2)
                    if provider.localModel == nil, !preferences.isConnected(provider.id) {
                        Text(provider.kind == .usage
                             ? L10n.t("Connect in Accounts to show this assistant.")
                             : L10n.t("Enable monitoring in the runtime's settings to show its models."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if provider.localModel == nil, provider.kind == .localRuntime {
                        Text(L10n.t("Show loaded models. Individual choices are kept when this is off."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(L10n.t("Show or hide this item in the notch without changing its connection."))
        .accessibilityIdentifier("model-visibility-\(provider.id)")
    }
}
