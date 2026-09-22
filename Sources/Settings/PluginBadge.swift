import SwiftUI

/// The small "Plugin" tag on any settings row backed by an external
/// executable, so a plugin never presents itself as a built-in provider.
struct PluginBadge: View {
    var body: some View {
        Text(L10n.t("Plugin"))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.secondary.opacity(0.5), lineWidth: 0.5)
            }
    }
}
