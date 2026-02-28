import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: ProjectListViewModel
    @State private var showingSettings = false
    @State private var showingDebugTools = false
    @State private var showingToolResponse = false
    @State private var showingUnityInstallationsSheet = false
    @State private var toolResponseText = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(viewModel.filteredProjects, selection: $viewModel.selectedProjectID) { project in
                    let projectSession = viewModel.activeSessionsByProjectID[project.hubProjectID]
                    ProjectRowView(
                        project: project,
                        isSelected: viewModel.selectedProjectID == project.id,
                        activeSessionStatus: projectSession?.status,
                        isHubConnected: viewModel.hubRuntimeStatus == "Connected"
                    )
                        .tag(project.id)
                        .contextMenu {
                            Button("Edit") { viewModel.editingProject = project }
                            Button("Remove", role: .destructive) {
                                if viewModel.selectedProjectID != project.id {
                                    viewModel.selectedProjectID = project.id
                                }
                                viewModel.removeSelectedProject()
                            }
                        }
                }
                .searchable(text: $viewModel.searchText, placement: .sidebar)
            }
            .navigationTitle("Unity MCP Hub")
        } detail: {
            detailPanel
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    viewModel.showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Project")

                Button {
                    viewModel.editingProject = viewModel.selectedProject
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit Project")
                .disabled(viewModel.selectedProject == nil || viewModel.isBusy)

                Button(role: .destructive) {
                    viewModel.removeSelectedProject()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove Project")
                    .disabled(viewModel.selectedProject == nil || viewModel.isBusy)

                Divider()

                Button {
                    Task { await viewModel.refreshFromHub() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Sync Projects")
                .disabled(viewModel.isBusy)

                Button {
                    showingUnityInstallationsSheet = true
                } label: {
                    Image(systemName: "square.stack.3d.up")
                }
                .help("Manage installed Unity versions")
                .disabled(viewModel.isBusy)

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $viewModel.showingAddSheet) {
            AddEditProjectSheet(title: "Add Project", initial: nil) { project in
                viewModel.addProject(project)
            }
        }
        .sheet(item: $viewModel.editingProject) { project in
            AddEditProjectSheet(title: "Edit Project", initial: project) { updated in
                viewModel.updateProject(updated)
            }
        }
        .sheet(isPresented: $showingSettings) {
            settingsSheet
        }
        .sheet(isPresented: $showingUnityInstallationsSheet) {
            UnityInstallationsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingToolResponse) {
            toolResponseSheet
        }
        .alert(item: $viewModel.alertData) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onChange(of: viewModel.callToolResult) { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            toolResponseText = newValue
            showingToolResponse = true
        }
    }

    private var detailPanel: some View {
        Group {
            if let project = viewModel.selectedProject {
                VStack(alignment: .leading, spacing: 16) {
                    Text(project.name)
                        .font(.largeTitle.weight(.semibold))

                    LabeledContent("Project Path") {
                        Text(project.projectPath)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Unity Version") {
                        let selectedVersionLabel = launchVersionSelectionLabel(project)
                        let selectedWarning = unityVersionWarningMessage(for: selectedVersionLabel)
                        Menu {
                            if let projectVersion = normalizedProjectVersion(project.unityVersion) {
                                Button {
                                    viewModel.selectedUnityLaunchVersion = projectVersion
                                } label: {
                                    HStack {
                                        Text(projectVersionRowTitle(projectVersion))
                                        if isSelectedLaunchVersion(projectVersion) {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                Divider()
                            }
                            ForEach(viewModel.unityInstallations, id: \.version) { installation in
                                Button {
                                    viewModel.selectedUnityLaunchVersion = installation.version
                                } label: {
                                    HStack {
                                        Text(installation.version)
                                        if isSelectedLaunchVersion(installation.version) {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(selectedVersionLabel)
                                if let selectedWarning {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .help(selectedWarning)
                                }
                            }
                        }
                        .disabled(viewModel.isBusy)
                    }
                    LabeledContent("Status") {
                        Text(project.hubStatus?.capitalized ?? "Unknown")
                    }

                    if let session = viewModel.activeSessionsByProjectID[project.hubProjectID] {
                        LabeledContent("Session") {
                            Text(session.sessionID)
                                .font(.caption)
                                .textSelection(.enabled)
                        }

                        Button("Kill Session", role: .destructive) {
                            viewModel.killSelectedProjectSession()
                        }
                        .disabled(viewModel.isBusy)

                        if session.status.lowercased() == "ready" {
                            DisclosureGroup("Debug Tools", isExpanded: $showingDebugTools) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Button("Test Agent Health (/mcp/health)") {
                                        viewModel.runForwardHealthTest()
                                    }
                                    .disabled(viewModel.isBusy)

                                    if !viewModel.forwardTestResult.isEmpty {
                                        Text(viewModel.forwardTestResult)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }

                                    Divider()

                                    Button("List Bridge Tools (/tools)") {
                                        viewModel.runForwardListToolsTest()
                                    }
                                    .disabled(viewModel.isBusy)

                                    if !viewModel.listToolsResult.isEmpty {
                                        Text(viewModel.listToolsResult)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }

                                    Picker("Tool", selection: $viewModel.selectedToolName) {
                                        Text("Select tool").tag("")
                                        ForEach(viewModel.availableToolNames, id: \.self) { tool in
                                            Text(tool).tag(tool)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .disabled(viewModel.availableToolNames.isEmpty || viewModel.isBusy)
                                    .onChange(of: viewModel.selectedToolName) { newValue in
                                        viewModel.selectTool(newValue)
                                    }

                                    if !viewModel.availableToolNames.isEmpty {
                                        Text("Discovered: \(viewModel.availableToolNames.prefix(8).joined(separator: ", "))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }

                                    TextField("Tool arguments JSON", text: $viewModel.toolArgumentsJSON, axis: .vertical)
                                        .textFieldStyle(.roundedBorder)
                                        .lineLimit(2...6)
                                        .disabled(viewModel.isBusy)

                                    Button("Call Tool (/tools/call)") {
                                        viewModel.runForwardCallToolTest()
                                    }
                                    .disabled(
                                        viewModel.isBusy
                                            || viewModel.selectedToolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    )
                                }
                                .padding(.top, 6)
                            }
                        }
                    }

                    Button(viewModel.canLaunchSelectedProject ? "Launch Project" : "Project Running") {
                        viewModel.launchSelectedProject()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canLaunchSelectedProject)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            } else {
                VStack(spacing: 16) {
                    Text("No Project Selected")
                        .font(.title2.weight(.medium))
                    Text("Add a Unity project or select one from the list.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            }
        }
        .overlay(alignment: .topTrailing) {
            if viewModel.isBusy {
                ProgressView()
                    .padding(12)
            }
        }
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close") {
                    showingSettings = false
                }
                .keyboardShortcut(.cancelAction)
            }

            Text("Hub Connection")
                .font(.headline)

            TextField("Hub URL", text: $viewModel.hubBaseURL)
                .textFieldStyle(.roundedBorder)

            SecureField("Hub Token", text: $viewModel.hubToken)
                .textFieldStyle(.roundedBorder)

            Text("Launch Preflight (Optional)")
                .font(.headline)

            TextField("UPM Package Name (com.example.unitymcp)", text: $viewModel.unityAgentPackageName)
                .textFieldStyle(.roundedBorder)

            TextField("UPM Git URL (https://...#tag)", text: $viewModel.unityAgentPackageGitURL)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save") {
                    viewModel.saveHubSettings()
                }
                .disabled(viewModel.isBusy)

                Button("Save + Sync") {
                    viewModel.saveHubSettings()
                    Task { await viewModel.refreshFromHub() }
                }
                .disabled(viewModel.isBusy)

                Spacer()
            }

            HStack {
                Text("Hub: \(viewModel.hubRuntimeStatus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastSync = viewModel.lastSyncAt {
                    Text("Last sync: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 340)
    }

    private var toolResponseSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tool Response")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(toolResponseText, forType: .string)
                }
                Button("Close") {
                    showingToolResponse = false
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(toolResponseText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 420)
    }

    private func unityVersionWarningMessage(for version: String?) -> String? {
        guard let version else { return nil }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let required = canonicalUnityVersion(trimmed) else {
            return "Could not parse project Unity version: \(trimmed)"
        }

        let installedNormalized = viewModel.unityInstallations.compactMap {
            canonicalUnityVersion($0.version)
        }
        if installedNormalized.contains(required) {
            return nil
        }

        if installedNormalized.isEmpty {
            return "Project requires \(trimmed) (normalized: \(required)), but no installed Unity versions are currently listed."
        }

        let uniqueInstalled = Array(Set(installedNormalized)).sorted()
        return "Project requires \(trimmed) (normalized: \(required)); installed normalized versions: \(uniqueInstalled.joined(separator: ", "))"
    }

    private func launchVersionSelectionLabel(_ project: UnityProject) -> String {
        let selected = viewModel.selectedUnityLaunchVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty {
            return selected
        }
        return project.unityVersion ?? "Unknown"
    }

    private func normalizedProjectVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func projectVersionRowTitle(_ version: String) -> String {
        if unityVersionWarningMessage(for: version) == nil {
            return "Project version: \(version)"
        }
        return "Project version: \(version) (Not installed)"
    }

    private func isSelectedLaunchVersion(_ version: String) -> Bool {
        let selected = viewModel.selectedUnityLaunchVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return false }
        guard let normalizedSelected = canonicalUnityVersion(selected),
              let normalizedVersion = canonicalUnityVersion(version)
        else {
            return selected.caseInsensitiveCompare(version) == .orderedSame
        }
        return normalizedSelected == normalizedVersion
    }

    private func canonicalUnityVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let token = String(trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first ?? "")
        let lowered = token.lowercased()
        guard !lowered.isEmpty else { return nil }
        if let range = lowered.range(
            of: #"^\d+\.\d+\.\d+[abcfp]\d+"#,
            options: .regularExpression
        ) {
            return String(lowered[range])
        }
        return lowered
    }
}
