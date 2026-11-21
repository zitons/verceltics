import SwiftUI

nonisolated struct VercelEditorSession: Identifiable, CustomStringConvertible {
    let id = UUID()
    let accountID: UUID
    let token: String
    var description: String { "VercelEditorSession(<redacted>)" }
}

@Observable
@MainActor
final class VercelProjectEditorViewModel {
    enum Tab: String, CaseIterable { case settings = "Settings", variables = "Variables", domains = "Domains" }
    let project: Project
    private let api: VercelProjectEditorAPI
    var tab: Tab = .settings
    var isLoading = false
    var isSaving = false
    var hasLoaded = false
    var error: String?
    var notice: String?
    var pending: VercelEditorMutation?
    var isConfirming = false
    var name = ""
    var buildCommand = ""
    var installCommand = ""
    var outputDirectory = ""
    var rootDirectory = ""
    var environments: [VercelEditableEnvironment] = []
    var domains: [VercelEditableDomain] = []
    var environmentID: String?
    var environmentType = "encrypted"
    var variableKey = ""
    var variableValue = ""
    var targets: Set<String> = ["production"]
    var domain = ""
    var isBusy: Bool { isLoading || isSaving }

    init(project: Project, token: String) {
        self.project = project
        self.api = VercelProjectEditorAPI(token: token)
    }

    func load() async {
        isLoading = true
        hasLoaded = false
        error = nil
        defer { isLoading = false }
        do {
            switch tab {
            case .settings:
                let settings = try await api.settings(projectID: project.id, teamID: project.teamId)
                try Task.checkCancellation()
                name = settings.name
                buildCommand = settings.buildCommand ?? ""
                installCommand = settings.installCommand ?? ""
                outputDirectory = settings.outputDirectory ?? ""
                rootDirectory = settings.rootDirectory ?? ""
            case .variables:
                let entries = try await api.environments(projectID: project.id, teamID: project.teamId)
                try Task.checkCancellation()
                environments = entries
            case .domains:
                let entries = try await api.domains(projectID: project.id, teamID: project.teamId)
                try Task.checkCancellation()
                domains = entries
            }
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
    }

    func confirm(_ change: VercelEditorMutation) {
        pending = change
        isConfirming = true
        error = nil
    }

    func save(_ change: VercelEditorMutation) async -> Bool {
        guard !isBusy else { return false }
        isSaving = true
        pending = nil
        error = nil
        notice = nil
        defer { isSaving = false }
        do {
            try await api.mutate(projectID: project.id, teamID: project.teamId, change: change)
            try Task.checkCancellation()
            switch change {
            case .saveEnvironment, .deleteEnvironment: clearVariable()
            case .addDomain, .removeDomain: domain = ""
            case .settings: break
            }
            notice = change.successMessage
            await load()
            return true
        } catch is CancellationError {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func edit(_ entry: VercelEditableEnvironment) {
        environmentID = entry.id
        environmentType = entry.type
        variableKey = entry.key
        variableValue = ""
        targets = Set(entry.target)
    }

    func clearVariable() {
        environmentID = nil
        environmentType = "encrypted"
        variableKey = ""
        variableValue = ""
        targets = ["production"]
    }

    func confirmSettings() {
        confirm(.settings(VercelEditableProject(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            buildCommand: optional(buildCommand), installCommand: optional(installCommand),
            outputDirectory: optional(outputDirectory), rootDirectory: optional(rootDirectory)
        )))
    }

    func confirmVariable() {
        confirm(.saveEnvironment(id: environmentID, update: VercelEnvironmentUpdate(
            key: variableKey.trimmingCharacters(in: .whitespacesAndNewlines), value: variableValue,
            target: targets.sorted(), type: environmentType
        )))
    }

    private func optional(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}

struct VercelProjectEditorView: View {
    let session: VercelEditorSession
    let onChanged: () -> Void
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss
    @State private var vm: VercelProjectEditorViewModel
    @State private var saveTask: Task<Void, Never>?
    @State private var showVariableValue = false
    @State private var reloadID = 0

    init(project: Project, session: VercelEditorSession, onChanged: @escaping () -> Void) {
        self.session = session
        self.onChanged = onChanged
        _vm = State(initialValue: VercelProjectEditorViewModel(project: project, token: session.token))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Section", selection: $vm.tab) {
                        ForEach(VercelProjectEditorViewModel.Tab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(vm.isBusy)
                    Text(vm.project.sourceScope?.name ?? vm.project.teamId ?? "Personal account")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if vm.isBusy { Section { ProgressView(vm.isSaving ? "Saving..." : "Loading...") } }
                if let error = vm.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Refresh") { reloadID += 1 }.disabled(vm.isBusy)
                    }
                }
                if let notice = vm.notice { Section { Text(notice) } }
                if vm.hasLoaded {
                    switch vm.tab {
                    case .settings: settingsForm
                    case .variables: variablesForm
                    case .domains: domainsForm
                    }
                }
            }
            .navigationTitle("Edit \(vm.name.isEmpty ? vm.project.name : vm.name)")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.canvas)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(vm.isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") { reloadID += 1 }.disabled(vm.isBusy)
                }
            }
            .task(id: "\(vm.tab.rawValue)-\(reloadID)") {
                guard authManager.activeAccountId == session.accountID else { dismiss(); return }
                await vm.load()
            }
            .alert("Confirm Vercel change", isPresented: $vm.isConfirming, presenting: vm.pending) { change in
                Button("Confirm", role: change.isDeletion ? .destructive : nil) {
                    guard authManager.activeAccountId == session.accountID, authManager.token == session.token else {
                        dismiss()
                        return
                    }
                    saveTask = Task { @MainActor in
                        if await vm.save(change), !Task.isCancelled,
                           authManager.activeAccountId == session.accountID { onChanged() }
                    }
                }
                Button("Cancel", role: .cancel) { vm.pending = nil }
            } message: { change in
                Text("Project: \(vm.project.name)\n\(change.confirmation)")
            }
            .onChange(of: authManager.activeAccountId) { _, accountID in
                if accountID != session.accountID { dismiss() }
            }
            .onDisappear { saveTask?.cancel(); vm.variableValue = ""; vm.pending = nil }
            .interactiveDismissDisabled(vm.isSaving)
        }
    }

    private var settingsForm: some View {
        Section {
            TextField("Project name", text: $vm.name)
            TextField("Build command", text: $vm.buildCommand)
            TextField("Install command", text: $vm.installCommand)
            TextField("Output directory", text: $vm.outputDirectory)
            TextField("Root directory", text: $vm.rootDirectory)
            Button("Save settings") { vm.confirmSettings() }
                .disabled(vm.isBusy || vm.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Project settings")
        } footer: {
            Text("Clear an optional field to restore its default. Build changes apply to future deployments.")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .disabled(vm.isBusy)
    }

    @ViewBuilder private var variablesForm: some View {
        Section("Environment variables") {
            Text("Values are hidden. Editing replaces the value. Redeploy to apply changes.").font(.footnote)
            if vm.environments.isEmpty { Text("No variables") }
            ForEach(vm.environments) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.key).font(.headline)
                    Text("\(entry.scopeDescription) | \(entry.type)").font(.caption).foregroundStyle(.secondary)
                    if !entry.canEdit { Text("Edit branch-specific, custom-environment and system variables in Vercel.").font(.caption) }
                    HStack {
                        Button("Edit") { vm.edit(entry); showVariableValue = false }.disabled(!entry.canEdit)
                        Spacer()
                        Button("Delete", role: .destructive) { vm.confirm(.deleteEnvironment(entry)) }
                    }.buttonStyle(.borderless)
                }
            }
        }.disabled(vm.isBusy)
        Section(vm.environmentID == nil ? "Add variable" : "Replace variable") {
            TextField("Variable name", text: $vm.variableKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if showVariableValue {
                TextEditor(text: $vm.variableValue).frame(minHeight: 100)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } else {
                SecureField("New value (may be empty)", text: $vm.variableValue)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Toggle("Show value / edit multiline", isOn: $showVariableValue)
            ForEach(["production", "preview", "development"], id: \.self) { target in
                Toggle(target, isOn: Binding(
                    get: { vm.targets.contains(target) },
                    set: { selected in
                        if selected { vm.targets.insert(target) } else { vm.targets.remove(target) }
                    }
                )).disabled(vm.environmentType == "sensitive" && target == "development")
            }
            Button("Save variable") { vm.confirmVariable() }
                .disabled(vm.variableKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.targets.isEmpty)
            if vm.environmentID != nil { Button("Cancel editing") { vm.clearVariable(); showVariableValue = false } }
        }.disabled(vm.isBusy)
    }

    @ViewBuilder private var domainsForm: some View {
        Section("Project domains") {
            Text("Binding a domain may require DNS configuration or ownership verification in Vercel.").font(.footnote)
            if vm.domains.isEmpty { Text("No domains") }
            ForEach(vm.domains) { domain in
                VStack(alignment: .leading, spacing: 8) {
                    Text(domain.name)
                    Text(domain.verified ? "Verified" : "Verification required").font(.caption).foregroundStyle(.secondary)
                    Button("Remove", role: .destructive) { vm.confirm(.removeDomain(domain.name)) }
                }
            }
        }.disabled(vm.isBusy)
        Section("Add domain") {
            TextField("example.com", text: $vm.domain)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Add domain") { vm.confirm(.addDomain(vm.domain)) }
                .disabled(vm.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.disabled(vm.isBusy)
    }
}
