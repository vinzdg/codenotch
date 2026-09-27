import SwiftUI

/// Coding accounts on other machines, each with its own ring.
///
/// A host is a kind plus an SSH destination. Saving probes the server first —
/// reachable, what OS, and whether this kind's token is there — and only a
/// host that answers all three is kept. The token itself is borrowed on every
/// poll and held in memory only; nothing but the connection details is stored.
struct RemoteHostsSettingsView: View {
    @ObservedObject var preferences: Preferences
    /// The row being added or edited. Committed on Save rather than per
    /// keystroke: every committed change rebuilds that host's provider and
    /// refreshes it, which is not something typing should do.
    @State private var isEditing = false
    @State private var isNew = false
    @State private var draft = RemoteHost(name: "", host: "", user: "")
    @State private var probe: ProbeState?
    /// What the last successful probe found, per host — the row's proof the
    /// server answered and the token was there.
    @State private var lastVerified: [String: String] = [:]

    private enum ProbeState: Equatable {
        case testing
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.t("Remote Hosts"))
                                .font(.title3.weight(.semibold))
                            Text(L10n.t("Claude and Codex accounts on servers you reach over SSH."))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            draft = RemoteHost(name: "", host: "", user: "")
                            isNew = true
                            probe = nil
                            isEditing = true
                        } label: {
                            Label(L10n.t("Add Server"), systemImage: "plus")
                        }
                        .buttonStyle(SettingsButtonStyle(kind: .prominent))
                    }

                    Text(L10n.t("SSH key auth must already work — polls run on a timer and never stop at a password prompt."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isEditing {
                        editor
                    }

                    if preferences.remoteHosts.isEmpty, !isEditing {
                        Text(L10n.t("No servers yet. Add one above and its ring appears in the notch."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(preferences.remoteHosts) { host in
                            hostRow(host)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.t("Account"), selection: $draft.kind) {
                ForEach(RemoteHostKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            // The provider id is built from the kind: changing it later would
            // orphan the old ring's archive and nicknames, so a saved row's
            // kind is fixed — a different kind is a different entry.
            .disabled(!isNew)
            .onChange(of: draft.kind) { _ in probe = nil }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L10n.t("Name"))
                    TextField(L10n.t("Work GPU"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(L10n.t("Host"))
                    TextField(L10n.t("gpu.example.com"), text: $draft.host)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(L10n.t("User"))
                    TextField(L10n.t("armin"), text: $draft.user)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(L10n.t("Port"))
                    TextField("22", value: $draft.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                }
                GridRow {
                    Text(L10n.t("Identity file"))
                    TextField(L10n.t("Optional — ~/.ssh/id_ed25519"), text: Binding(
                        get: { draft.identityFile ?? "" },
                        set: { draft.identityFile = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
            .onChange(of: draft.host) { _ in probe = nil }
            .onChange(of: draft.user) { _ in probe = nil }
            .onChange(of: draft.port) { _ in probe = nil }
            .onChange(of: draft.identityFile) { _ in probe = nil }

            switch probe {
            case .testing:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.t("Probing the server…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }

            HStack {
                if !isNew {
                    Button(L10n.t("Remove"), role: .destructive) {
                        preferences.removeRemoteHost(id: draft.id)
                        isEditing = false
                    }
                    .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))
                }
                Spacer()
                Button(L10n.t("Cancel")) {
                    isEditing = false
                }
                .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))
                Button(L10n.t("Save")) { save() }
                    .buttonStyle(SettingsButtonStyle(kind: .prominent, compact: true))
                    .disabled(!draft.isConfigured || probe == .testing)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func hostRow(_ host: RemoteHost) -> some View {
        HStack {
            Text(host.kind.displayName)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.headline)
                if host.isConfigured {
                    Text(host.destination)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.t("Needs a host and user"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let verified = lastVerified[host.id] {
                    Text(verified)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            Toggle(L10n.t("Enabled"), isOn: Binding(
                get: { host.isEnabled },
                set: {
                    var updated = host
                    updated.isEnabled = $0
                    preferences.updateRemoteHost(updated)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            Button(L10n.t("Edit")) {
                draft = host
                isNew = false
                probe = nil
                isEditing = true
            }
            .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Whether the connection changed since the stored row. A rename needs no
    /// re-probe — only the road and the kind do.
    private func connectionChanged(from stored: RemoteHost, to candidate: RemoteHost) -> Bool {
        stored.kind != candidate.kind
            || stored.host.trimmingCharacters(in: .whitespacesAndNewlines)
                != candidate.host.trimmingCharacters(in: .whitespacesAndNewlines)
            || stored.user.trimmingCharacters(in: .whitespacesAndNewlines)
                != candidate.user.trimmingCharacters(in: .whitespacesAndNewlines)
            || stored.port != candidate.port
            || (stored.identityFile ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                != (candidate.identityFile ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let candidate = draft
        let stored = preferences.remoteHosts.first { $0.id == candidate.id }
        if let stored, !connectionChanged(from: stored, to: candidate) {
            preferences.updateRemoteHost(candidate)
            isEditing = false
            return
        }
        probe = .testing
        Task {
            let report: RemoteProbe.Report?
            let message: String?
            do {
                // Off the main thread: the SSH call blocks.
                report = try await Task.detached(priority: .utility) {
                    try RemoteProbe.check(host: candidate)
                }.value
                message = nil
            } catch let failure as RemoteProbe.Failure {
                report = nil
                message = failure.message
            } catch {
                report = nil
                message = error.localizedDescription
            }
            await MainActor.run {
                if let report {
                    if stored == nil {
                        preferences.addRemoteHost(candidate)
                    } else {
                        preferences.updateRemoteHost(candidate)
                    }
                    lastVerified[candidate.id] =
                        L10n.t("Verified · \(report.os.displayName) · token found (\(report.found))")
                    probe = nil
                    isEditing = false
                } else {
                    probe = .failed(message ?? "Unknown error")
                }
            }
        }
    }
}
