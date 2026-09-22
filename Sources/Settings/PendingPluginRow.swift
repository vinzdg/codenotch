import AppKit
import SwiftUI

/// A plugin that asked to run but has not been approved. Shows exactly what
/// would execute — path, arguments, and the SHA-256 the approval will pin —
/// and offers to open the manifest and the plugin folder, because "Enable" is
/// a trust decision, not a toggle: the user should be able to read what they
/// are trusting before they trust it.
struct PendingPluginRow: View {
    let plugin: PluginCoordinator.PendingPlugin
    let approve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                ProviderGlyphView(glyph: .external, size: 16, providerID: plugin.id)
                    .foregroundStyle(.tertiary)
                Text(plugin.displayName)
                    .foregroundStyle(.secondary)
                PluginBadge()
                Spacer(minLength: 8)
                // Read-only looks before the decision: the manifest in the
                // default editor, the folder in Finder. Neither runs anything.
                Button {
                    NSWorkspace.shared.open(plugin.manifestURL)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 11))
                }
                .buttonStyle(SettingsIconButtonStyle())
                .accessibilityLabel(L10n.t("View manifest"))
                .help(L10n.t("Open plugin.json, the manifest this approval pins."))
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([plugin.manifestURL])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(SettingsIconButtonStyle())
                .accessibilityLabel(L10n.t("Reveal in Finder"))
                .help(L10n.t("Show the plugin folder in Finder."))
                Button(L10n.t("Enable…"), action: approve)
                    .controlSize(.small)
                    .help(L10n.t("Trust this exact build of the plugin and connect it. Any change to its manifest or executable asks again."))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.commandLine)
                    .textSelection(.enabled)
                if let signIn = plugin.signInCommandLine {
                    Text(L10n.t("Sign in: \(signIn)"))
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Text("SHA-256 \(plugin.shortHash)…")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plugin.contentHash, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(SettingsIconButtonStyle())
                    .accessibilityLabel(L10n.t("Copy full SHA-256"))
                    .help(L10n.t("Copy the full hash."))
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            // 48 = the handle, the glyph and the two gaps before the name —
            // the same metric AccountRow uses, so the detail starts under the
            // first letter of the name in both rows.
            .padding(.leading, 48)
        }
    }
}
