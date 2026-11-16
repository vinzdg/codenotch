import SwiftUI

/// Settings › Tasks: where the day's tasks come from, which list the card's
/// third tab shows, how long a focus block is, and the Focus window.
struct TaskSettingsPane: View {
    @ObservedObject var todos: TodoStore = .shared
    @ObservedObject var focus: FocusStore = .shared
    @State private var todoistToken = TodoistBridge.token
    @AppStorage(FocusNotify.enabledKey) private var focusNotifies = true

    private func saveTodoistToken() {
        let trimmed = todoistToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != TodoistBridge.token else { return }
        TodoistBridge.token = trimmed
        if todos.source == .todoist { todos.source = .todoist }   // re-reads with the new token
    }

    var body: some View {
        Form {
            Section(L10n.t("Tasks")) {
                Picker(L10n.t("Source"), selection: Binding(get: { todos.source }, set: { todos.source = $0 })) {
                    ForEach(TaskSource.allCases) { Text($0.menuTitle).tag($0) }
                }
                .pickerStyle(.menu)

                if todos.source == .todoist {
                    LabeledContent(L10n.t("Todoist API token")) {
                        HStack(spacing: 8) {
                            SecureField("", text: $todoistToken, prompt: Text(L10n.t("Paste your token")))
                                .textFieldStyle(.roundedBorder).frame(width: 220)
                                .onSubmit { saveTodoistToken() }
                                .onChange(of: todoistToken) { _, _ in saveTodoistToken() }
                            Link(L10n.t("Get one"), destination: URL(string: "https://app.todoist.com/app/settings/integrations/developer")!)
                                .buttonStyle(.bordered)
                        }
                    }
                    Text(L10n.t("From Todoist → Settings → Integrations → Developer. Kept in your login keychain; the list refreshes as soon as it is pasted."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker(L10n.t("Third tab"), selection: Binding(get: { todos.customList }, set: { todos.customList = $0 })) {
                    ForEach(todos.source.builtinLists + todos.lists, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)

                Text(L10n.t("Switch the Tasks ring on in Accounts. Things 3 needs the Automation permission; Reminders asks for access to your reminders; Todoist needs an API token."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.t("Focus")) {
                Picker(L10n.t("Focus block"), selection: Binding(get: { focus.targetMinutes }, set: { focus.targetMinutes = $0 })) {
                    ForEach([15, 25, 30, 45, 50, 60, 90], id: \.self) { Text(L10n.t("\($0) min")).tag($0) }
                }
                .pickerStyle(.menu)

                Toggle(L10n.t("Notify when a focus block ends"), isOn: $focusNotifies)

                Button(L10n.t("Open Focus…")) { Tasks.showFocus() }
                Text(L10n.t("Focus time by day, week or month, per project, with the blocks editable."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
