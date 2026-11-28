import SwiftUI

struct OpenAIAPICreditSettings: View {
    var onSave: () -> Void
    @State private var key = ""
    @State private var issued = ""
    @State private var expires = ""
    @State private var granted = ""
    @State private var available = ""
    @State private var message = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Link(L10n.t("OpenAI Credit Grants"), destination: OpenAIAPICreditsProvider.grantsURL)
            SecureField(L10n.t("Read-only organization Admin key"), text: $key)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField(L10n.t("Issued (YYYY-MM-DD)"), text: $issued)
                TextField(L10n.t("Expires (YYYY-MM-DD)"), text: $expires)
            }
            HStack {
                TextField(L10n.t("Granted (USD)"), text: $granted)
                TextField(L10n.t("Remaining (USD)"), text: $available)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Button(L10n.t("Verify and save")) { save() }
                    .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))
                    .disabled(saving)
                if !message.isEmpty { Text(message) }
            }
            Text(L10n.t("The Costs API does not expose grant balances or expiry. Enter the current figures from Credit Grants. Future balances are estimates and do not renew automatically."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .onAppear {
            guard let saved = OpenAIAPICreditsProvider.configuredGrant() else { return }
            issued = saved.issued
            expires = saved.expires
            granted = NSDecimalNumber(decimal: saved.granted).stringValue
            available = NSDecimalNumber(decimal: saved.available).stringValue
        }
    }

    private func save() {
        guard let grant = OpenAIAPICreditGrant.validated(issued: issued, expires: expires,
                                                        granted: granted, available: available) else {
            message = L10n.t("Enter valid grant dates and USD amounts.")
            return
        }
        let supplied = key.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        message = ""
        Task {
            defer { saving = false }
            do {
                try await OpenAIAPICreditsProvider.configure(grant, key: supplied)
                key = ""
                message = L10n.t("Saved")
                onSave()
            } catch {
                message = L10n.t("Could not verify organization costs. Check the key and connection.")
            }
        }
    }
}
