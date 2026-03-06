import AppKit
import Foundation

@MainActor
final class ProjectListViewModel: ObservableObject {
    struct AlertData: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published private(set) var projects: [UnityProject] = []
    @Published var selectedProjectID: UUID? {
        didSet {
            if selectedProjectID != oldValue {
                selectedUnityLaunchVersion = ""
                Task {
                    await refreshSelectedProjectUnityVersion()
                }
            }
        }
    }
    @Published var searchText = ""
    @Published var showingAddSheet = false
    @Published var editingProject: UnityProject?
    @Published var alertData: AlertData?
    @Published var isBusy = false
    @Published private(set) var activeSessionsByProjectID: [String: HubSessionRecord] = [:]
    @Published var lastSyncAt: Date?
    @Published var hubRuntimeStatus: String = "Idle"
    @Published var forwardTestResult: String = ""
    @Published var listToolsResult: String = ""
    @Published var callToolResult: String = ""
    @Published var availableToolNames: [String] = []
    @Published var selectedToolName: String = ""
    @Published var toolArgumentsJSON: String = "{}"
    private var toolDefaultArgumentsByName: [String: String] = [:]
    @Published var unityInstallations: [HubUnityInstallation] = []
    @Published var selectedUnityLaunchVersion: String = ""
    @Published var unityVersionInstallInput: String = ""

    @Published var hubBaseURL: String
    @Published var hubToken: String
    @Published var clientID: String
    @Published var defaultExecuteMethod: String
    @Published var unityAgentPackageName: String
    @Published var unityAgentPackageGitURL: String

    private let hubClient: HubClient
    private let processManager: HubProcessManager
    private let defaults: UserDefaults
    private var sessionPollTasksBySessionID: [String: Task<Void, Never>] = [:]

    private enum Keys {
        static let hubBaseURL = "hub.base_url"
        static let hubToken = "hub.auth_token"
        static let clientID = "hub.client_id"
        static let defaultExecuteMethod = "hub.default_execute_method"
        static let unityAgentPackageName = "hub.unity_agent_package_name"
        static let unityAgentPackageGitURL = "hub.unity_agent_package_git_url"
    }

    init(
        hubClient: HubClient = HubClient(),
        processManager: HubProcessManager = HubProcessManager(),
        defaults: UserDefaults = .standard
    ) {
        self.hubClient = hubClient
        self.processManager = processManager
        self.defaults = defaults

        hubBaseURL = defaults.string(forKey: Keys.hubBaseURL) ?? "http://127.0.0.1:8787"
        hubToken = defaults.string(forKey: Keys.hubToken) ?? "dev-shared-secret"
        clientID = defaults.string(forKey: Keys.clientID) ?? Host.current().localizedName?.replacingOccurrences(of: " ", with: "-").lowercased() ?? "mac-client"
        defaultExecuteMethod = defaults.string(forKey: Keys.defaultExecuteMethod) ?? "Mcp.HubBootstrap.Start"
        unityAgentPackageName = defaults.string(forKey: Keys.unityAgentPackageName) ?? ""
        unityAgentPackageGitURL = defaults.string(forKey: Keys.unityAgentPackageGitURL) ?? ""

        Task {
            await refreshFromHub()
        }
    }

    var filteredProjects: [UnityProject] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = projects.sorted {
            let lhs = $0.lastOpenedAt ?? $0.lastSeenAt ?? $0.createdAt
            let rhs = $1.lastOpenedAt ?? $1.lastSeenAt ?? $1.createdAt
            return lhs > rhs
        }

        guard !trimmed.isEmpty else {
            return base
        }

        return base.filter { project in
            project.name.localizedCaseInsensitiveContains(trimmed)
                || project.projectPath.localizedCaseInsensitiveContains(trimmed)
                || project.tags.joined(separator: ",").localizedCaseInsensitiveContains(trimmed)
        }
    }

    var selectedProject: UnityProject? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    var selectedProjectSession: HubSessionRecord? {
        guard let selected = selectedProject else { return nil }
        return activeSessionsByProjectID[selected.hubProjectID]
    }

    var canLaunchSelectedProject: Bool {
        guard let selected = selectedProject, !isBusy else {
            return false
        }
        guard let session = activeSessionsByProjectID[selected.hubProjectID] else {
            let projectStatus = selected.hubStatus?.lowercased()
            return projectStatus != "starting" && projectStatus != "ready"
        }
        let status = session.status.lowercased()
        return status != "starting" && status != "ready"
    }

    func saveHubSettings() {
        defaults.set(hubBaseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.hubBaseURL)
        defaults.set(hubToken.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.hubToken)
        defaults.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.clientID)
        defaults.set(defaultExecuteMethod.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.defaultExecuteMethod)
        defaults.set(unityAgentPackageName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.unityAgentPackageName)
        defaults.set(unityAgentPackageGitURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.unityAgentPackageGitURL)
    }

    func refreshFromHub() async {
        saveHubSettings()
        setBusy(true)
        defer { setBusy(false) }

        do {
            try await ensureHubRunning()
            let records = try await hubClient.listProjects(baseURL: hubBaseURL, token: hubToken)
            let sessions = try await hubClient.listSessions(
                baseURL: hubBaseURL,
                token: hubToken,
                clientID: clientID,
                includeDead: false
            )
            let mapped = mapRecords(records)
            projects = mapped
            if selectedProjectID == nil || !projects.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = projects.first?.id
            }
            applyActiveSessions(sessions)
            lastSyncAt = Date()
            hubRuntimeStatus = "Connected"
            await refreshUnityInstallations()
            await refreshAllProjectUnityVersions()
            updatePreferredUnityLaunchVersion(force: true)
        } catch {
            showError(title: "Sync Failed", error: error)
        }
    }

    func refreshUnityInstallations() async {
        do {
            let installations = try await hubClient.listUnityInstallations(
                baseURL: hubBaseURL,
                token: hubToken
            )
            unityInstallations = installations
            updatePreferredUnityLaunchVersion()
        } catch {
            showError(title: "Unity Installations Failed", error: error)
        }
    }

    func installUnityVersion() {
        let version = unityVersionInstallInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            return
        }

        Task {
            setBusy(true)
            defer { setBusy(false) }
            do {
                try await hubClient.installUnityVersion(
                    baseURL: hubBaseURL,
                    token: hubToken,
                    version: version
                )
                unityVersionInstallInput = ""
                await refreshUnityInstallations()
            } catch {
                showError(title: "Install Failed", error: error)
            }
        }
    }

    func uninstallUnityVersion(_ version: String, source: String? = nil) {
        Task {
            setBusy(true)
            defer { setBusy(false) }
            do {
                try await hubClient.uninstallUnityVersion(
                    baseURL: hubBaseURL,
                    token: hubToken,
                    version: version,
                    source: source
                )
                await refreshUnityInstallations()
            } catch {
                showError(title: "Remove Installation Failed", error: error)
            }
        }
    }

    func removeUnityInstallation(_ installation: HubUnityInstallation) {
        if installation.source == "custom" {
            forgetLocalUnityInstallation(installation.installPath)
            return
        }
        uninstallUnityVersion(installation.version, source: installation.source)
    }

    func registerLocalUnityInstallation(_ installPath: String) {
        let normalizedPath = installPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            return
        }
        Task {
            setBusy(true)
            defer { setBusy(false) }
            do {
                _ = try await hubClient.registerUnityInstallation(
                    baseURL: hubBaseURL,
                    token: hubToken,
                    installPath: normalizedPath
                )
                await refreshUnityInstallations()
            } catch {
                showError(title: "Add Installation Failed", error: error)
            }
        }
    }

    func forgetLocalUnityInstallation(_ installPath: String) {
        let normalizedPath = installPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            return
        }
        Task {
            setBusy(true)
            defer { setBusy(false) }
            do {
                try await hubClient.forgetUnityInstallation(
                    baseURL: hubBaseURL,
                    token: hubToken,
                    installPath: normalizedPath
                )
                await refreshUnityInstallations()
            } catch {
                showError(title: "Forget Installation Failed", error: error)
            }
        }
    }

    func addProject(_ project: UnityProject) {
        Task {
            await upsertProject(project.withNormalizedTags())
        }
    }

    func updateProject(_ project: UnityProject) {
        Task {
            await upsertProject(project.withNormalizedTags())
        }
    }

    func removeSelectedProject() {
        guard let selected = selectedProject else { return }
        Task {
            setBusy(true)
            defer { setBusy(false) }
            do {
                try await hubClient.deleteProject(
                    baseURL: hubBaseURL,
                    token: hubToken,
                    projectID: selected.hubProjectID
                )
                projects.removeAll { $0.id == selected.id }
                selectedProjectID = projects.first?.id
                if let removed = activeSessionsByProjectID.removeValue(forKey: selected.hubProjectID) {
                    stopPollingSession(sessionID: removed.sessionID)
                }
            } catch {
                showError(title: "Delete Failed", error: error)
            }
        }
    }

    func revealSelectedInFinder() {
        guard let selected = selectedProject else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selected.projectPath)])
    }

    func launchSelectedProject(headless: Bool = false, executeMethod: String? = nil) {
        guard let selected = selectedProject, canLaunchSelectedProject else { return }

        Task {
            setBusy(true)
            defer { setBusy(false) }

            do {
                try await ensureHubRunning()
                let response = try await hubClient.selectProject(
                    baseURL: hubBaseURL,
                    token: hubToken,
                    payload: HubSelectProjectRequest(
                        clientID: clientID,
                        projectID: selected.hubProjectID,
                        name: nil,
                        tags: [],
                        mostRecent: false,
                        autoLaunch: true,
                        launchHeadless: headless,
                        executeMethod: executeMethod ?? normalizedDefaultExecuteMethod(),
                        unityVersion: normalizedUnityVersion(selectedUnityLaunchVersion)
                    )
                )
                activeSessionsByProjectID[selected.hubProjectID] = response.session
                if let index = projects.firstIndex(where: { $0.id == selected.id }) {
                    projects[index].lastOpenedAt = Date()
                    projects[index].hubStatus = response.session.status
                }
                listToolsResult = ""
                callToolResult = ""
                availableToolNames = []
                selectedToolName = ""
                startSessionPolling(sessionID: response.session.sessionID, projectID: response.session.projectID)
                hubRuntimeStatus = "Connected"
            } catch {
                showError(title: "Launch Failed", error: error)
            }
        }
    }

    func killSelectedProjectSession() {
        guard let selected = selectedProject,
              let session = activeSessionsByProjectID[selected.hubProjectID]
        else {
            return
        }

        Task {
            setBusy(true)
            defer { setBusy(false) }
            do {
                let dead = try await hubClient.killSession(
                    baseURL: hubBaseURL,
                    token: hubToken,
                    sessionID: session.sessionID,
                    force: true,
                    terminateProcess: true
                )
                activeSessionsByProjectID.removeValue(forKey: selected.hubProjectID)
                stopPollingSession(sessionID: session.sessionID)
                if let index = projects.firstIndex(where: { $0.hubProjectID == selected.hubProjectID }) {
                    projects[index].hubStatus = dead.status
                }
            } catch {
                showError(title: "Force Quit Failed", error: error)
            }
        }
    }

    func startManagedHub() {
        Task {
            setBusy(true)
            defer { setBusy(false) }
            do {
                try await ensureHubRunning()
                hubRuntimeStatus = "Connected"
            } catch {
                showError(title: "Hub Start Failed", error: error)
            }
        }
    }

    func stopManagedHub() {
        Task {
            for (_, task) in sessionPollTasksBySessionID {
                task.cancel()
            }
            sessionPollTasksBySessionID.removeAll()
            activeSessionsByProjectID.removeAll()
            await processManager.stopManagedProcess()
            hubRuntimeStatus = "Stopped"
        }
    }

    func runForwardHealthTest() {
        guard let session = selectedProjectSession else { return }

        Task {
            setBusy(true)
            defer { setBusy(false) }
            do {
                let result = try await hubClient.forwardHealthCheck(
                    baseURL: hubBaseURL,
                    token: hubToken,
                    sessionID: session.sessionID
                )
                forwardTestResult = result
            } catch {
                forwardTestResult = "error: \(error.localizedDescription)"
                showError(title: "Forward Test Failed", error: error)
            }
        }
    }

    func runForwardListToolsTest() {
        guard let session = selectedProjectSession else { return }

        Task {
            setBusy(true)
            defer { setBusy(false) }
            do {
                let result = try await hubClient.forwardBridgeListTools(
                    baseURL: hubBaseURL,
                    token: hubToken,
                    sessionID: session.sessionID
                )
                listToolsResult = "status=\(result.statusCode)"
                let descriptors = extractToolDescriptors(from: result.body)
                let names = descriptors.map(\.name)
                toolDefaultArgumentsByName = Dictionary(
                    uniqueKeysWithValues: descriptors.map { ($0.name, $0.defaultArgumentsJSON) }
                )
                availableToolNames = Array(names.prefix(64))
                if names.isEmpty {
                    selectedToolName = ""
                    toolArgumentsJSON = "{}"
                } else if !names.contains(selectedToolName), let first = names.first {
                    selectedToolName = first
                    selectTool(first)
                } else {
                    selectTool(selectedToolName)
                }
            } catch {
                listToolsResult = "error: \(error.localizedDescription)"
                availableToolNames = []
                selectedToolName = ""
                toolDefaultArgumentsByName = [:]
                toolArgumentsJSON = "{}"
                showError(title: "List Tools Failed", error: error)
            }
        }
    }

    func selectTool(_ toolName: String) {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toolArgumentsJSON = "{}"
            return
        }
        guard let defaults = toolDefaultArgumentsByName[trimmed] else {
            return
        }
        toolArgumentsJSON = defaults
    }

    func runForwardCallToolTest() {
        guard let session = selectedProjectSession else { return }
        let toolName = selectedToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else {
            callToolResult = "error: select a tool name first"
            return
        }

        Task {
            setBusy(true)
            defer { setBusy(false) }
            do {
                let args = try parseToolArguments(toolArgumentsJSON)
                let result = try await hubClient.forwardBridgeCallTool(
                    baseURL: hubBaseURL,
                    token: hubToken,
                    sessionID: session.sessionID,
                    toolName: toolName,
                    arguments: args
                )
                callToolResult = result
            } catch {
                callToolResult = "error: \(error.localizedDescription)"
                showError(title: "Call Tool Failed", error: error)
            }
        }
    }

    private func upsertProject(_ project: UnityProject) async {
        setBusy(true)
        defer { setBusy(false) }

        do {
            try await hubClient.upsertProject(
                baseURL: hubBaseURL,
                token: hubToken,
                payload: HubProjectUpsertRequest(
                    projectID: project.hubProjectID,
                    name: project.name,
                    projectPath: project.projectPath,
                    unityPath: project.unityPath,
                    tags: project.tags
                )
            )
            await refreshFromHub()
            selectedProjectID = project.id
        } catch {
            showError(title: "Save Failed", error: error)
        }
    }

    private func mapRecords(_ records: [HubProjectRecord]) -> [UnityProject] {
        var mapped: [UnityProject] = []
        var seenIDs: Set<UUID> = []

        for record in records {
            let project = mapRecord(record)
            if seenIDs.insert(project.id).inserted {
                mapped.append(project)
            }
        }

        return mapped
    }

    private func mapRecord(_ record: HubProjectRecord) -> UnityProject {
        let stableID = stableProjectID(for: record)
        return UnityProject(
            id: stableID,
            name: record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled Project"
                : record.name,
            projectPath: record.projectPath.trimmingCharacters(in: .whitespacesAndNewlines),
            unityPath: record.unityPath.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: record.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            hubStatus: record.status,
            lastSeenAt: record.lastSeenAt,
            createdAt: Date(),
            lastOpenedAt: record.lastSeenAt
        )
    }

    private func stableProjectID(for record: HubProjectRecord) -> UUID {
        let trimmedID = record.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = UUID(uuidString: trimmedID) {
            return parsed
        }

        let fallbackSeed: String
        if trimmedID.isEmpty {
            fallbackSeed = "\(record.name)|\(record.projectPath)|\(record.unityPath)"
        } else {
            fallbackSeed = trimmedID
        }
        return deterministicUUID(seed: fallbackSeed)
    }

    private func deterministicUUID(seed: String) -> UUID {
        var forwardHash: UInt64 = 1_469_598_103_934_665_603
        var reverseHash: UInt64 = 1_099_511_628_211

        for byte in seed.utf8 {
            forwardHash ^= UInt64(byte)
            forwardHash &*= 1_099_511_628_211
        }

        for byte in seed.utf8.reversed() {
            reverseHash ^= UInt64(byte)
            reverseHash &*= 1_469_598_103_934_665_603
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        bytes.append(contentsOf: withUnsafeBytes(of: forwardHash.bigEndian, Array.init))
        bytes.append(contentsOf: withUnsafeBytes(of: reverseHash.bigEndian, Array.init))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func updatePreferredUnityLaunchVersion(force: Bool = false) {
        guard let selected = selectedProject else {
            selectedUnityLaunchVersion = ""
            return
        }

        let projectVersion = selected.unityVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProjectVersion = canonicalUnityVersion(projectVersion)

        if force {
            selectedUnityLaunchVersion = projectVersion ?? ""
            return
        }

        let normalizedSelected = canonicalUnityVersion(selectedUnityLaunchVersion)
        if normalizedSelected == normalizedProjectVersion {
            selectedUnityLaunchVersion = projectVersion ?? selectedUnityLaunchVersion
            return
        }

        if selectedUnityLaunchVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedUnityLaunchVersion = projectVersion ?? ""
        }
    }

    private func refreshAllProjectUnityVersions() async {
        let projectIDs = projects.map(\.id)
        for projectID in projectIDs {
            await refreshProjectUnityVersion(projectID: projectID, reportFailure: false)
        }
    }

    private func refreshSelectedProjectUnityVersion() async {
        guard let projectID = selectedProjectID else {
            return
        }
        await refreshProjectUnityVersion(projectID: projectID, reportFailure: true)
    }

    private func refreshProjectUnityVersion(projectID: UUID, reportFailure: Bool) async {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            return
        }

        do {
            let version = try await hubClient.detectProjectUnityVersion(
                baseURL: hubBaseURL,
                token: hubToken,
                projectID: project.hubProjectID
            )
            if let index = projects.firstIndex(where: { $0.id == projectID }) {
                projects[index].unityVersion = version
            }
            if selectedProjectID == projectID {
                updatePreferredUnityLaunchVersion(force: true)
            }
        } catch {
            if let index = projects.firstIndex(where: { $0.id == projectID }) {
                projects[index].unityVersion = nil
            }
            if selectedProjectID == projectID {
                updatePreferredUnityLaunchVersion(force: true)
            }
            if reportFailure {
                showError(title: "Unity Version Detection Failed", error: error)
            }
        }
    }

    private func isUnityVersionInstalled(_ version: String) -> Bool {
        guard let normalizedTarget = canonicalUnityVersion(version) else {
            return false
        }
        return unityInstallations.contains {
            guard let normalizedCandidate = canonicalUnityVersion($0.version) else {
                return false
            }
            return normalizedTarget == normalizedCandidate
        }
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

    private func setBusy(_ value: Bool) {
        isBusy = value
    }

    private func showError(title: String, error: Error) {
        alertData = AlertData(title: title, message: error.localizedDescription)
    }

    private func ensureHubRunning() async throws {
        hubRuntimeStatus = "Starting..."
        try await processManager.ensureRunning(
            baseURL: hubBaseURL,
            defaultExecuteMethod: normalizedDefaultExecuteMethod(),
            unityAgentPackageName: normalizedUnityAgentPackageName(),
            unityAgentPackageGitURL: normalizedUnityAgentPackageGitURL()
        )
    }

    private func normalizedDefaultExecuteMethod() -> String {
        defaultExecuteMethod.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedUnityAgentPackageName() -> String {
        unityAgentPackageName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedUnityAgentPackageGitURL() -> String {
        unityAgentPackageGitURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedUnityVersion(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyActiveSessions(_ sessions: [HubSessionRecord]) {
        var nextByProject: [String: HubSessionRecord] = [:]
        var expectedSessionIDs: Set<String> = []
        for session in sessions {
            expectedSessionIDs.insert(session.sessionID)
            if nextByProject[session.projectID] == nil {
                nextByProject[session.projectID] = session
            }
            startSessionPolling(sessionID: session.sessionID, projectID: session.projectID)
        }

        for (sessionID, _) in sessionPollTasksBySessionID where !expectedSessionIDs.contains(sessionID) {
            stopPollingSession(sessionID: sessionID)
        }

        activeSessionsByProjectID = nextByProject
    }

    private func stopPollingSession(sessionID: String) {
        sessionPollTasksBySessionID[sessionID]?.cancel()
        sessionPollTasksBySessionID.removeValue(forKey: sessionID)
    }

    private func startSessionPolling(sessionID: String, projectID: String) {
        if sessionPollTasksBySessionID[sessionID] != nil {
            return
        }

        let task = Task {
            while !Task.isCancelled {
                if Task.isCancelled {
                    return
                }

                do {
                    let session = try await hubClient.getSession(
                        baseURL: hubBaseURL,
                        token: hubToken,
                        sessionID: sessionID
                    )
                    activeSessionsByProjectID[projectID] = session
                    if let index = projects.firstIndex(where: { $0.hubProjectID == session.projectID }) {
                        projects[index].hubStatus = session.status
                    }
                    if session.status == "dead" {
                        activeSessionsByProjectID.removeValue(forKey: projectID)
                        stopPollingSession(sessionID: sessionID)
                        return
                    }
                } catch {
                    if let index = projects.firstIndex(where: { $0.hubProjectID == projectID }) {
                        projects[index].hubStatus = "dead"
                    }
                    activeSessionsByProjectID.removeValue(forKey: projectID)
                    stopPollingSession(sessionID: sessionID)
                    return
                }

                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        sessionPollTasksBySessionID[sessionID] = task
    }

    private func parseToolArguments(_ jsonText: String) throws -> [String: Any] {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [:]
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw HubClientError.requestFailed("Arguments are not valid UTF-8 JSON.")
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw HubClientError.requestFailed("Arguments JSON must be an object.")
        }
        return dictionary
    }

    private struct ToolDescriptor {
        let name: String
        let defaultArgumentsJSON: String
    }

    private func extractToolDescriptors(from value: JSONValue) -> [ToolDescriptor] {
        let items = extractToolItems(from: value)
        var descriptors: [ToolDescriptor] = []
        var seen: Set<String> = []

        for item in items {
            guard case .object(let object) = item,
                  let entry = object["name"],
                  case .string(let name) = entry
            else {
                continue
            }
            if seen.insert(name).inserted {
                descriptors.append(
                    ToolDescriptor(
                        name: name,
                        defaultArgumentsJSON: defaultArgumentsJSON(for: object)
                    )
                )
            }
        }
        return descriptors
    }

    private func extractToolItems(from value: JSONValue) -> [JSONValue] {
        switch value {
        case .array(let array):
            return array
        case .object(let object):
            if let nested = object["tools"], case .array(let tools) = nested {
                return tools
            }
            if let nested = object["result"] {
                return extractToolItems(from: nested)
            }
            if let nested = object["data"] {
                return extractToolItems(from: nested)
            }
            return []
        default:
            return []
        }
    }

    private func defaultArgumentsJSON(for toolObject: [String: JSONValue]) -> String {
        let schemaKeys = ["inputSchema", "input_schema", "parameters", "schema"]
        var schemaValue: JSONValue?
        for key in schemaKeys {
            if let value = toolObject[key] {
                schemaValue = value
                break
            }
        }

        guard let schema = schemaValue else {
            return "{}"
        }

        let args = buildDefaultObject(fromSchema: schema)
        return prettyJSONString(from: args)
    }

    private func buildDefaultObject(fromSchema schema: JSONValue) -> [String: Any] {
        guard case .object(let schemaObject) = schema else {
            return [:]
        }

        let propertiesValue: JSONValue?
        if let properties = schemaObject["properties"] {
            propertiesValue = properties
        } else if case .string(let type)? = schemaObject["type"], type == "object" {
            propertiesValue = schemaObject["properties"]
        } else {
            propertiesValue = nil
        }

        guard let propertiesRaw = propertiesValue,
              case .object(let properties) = propertiesRaw
        else {
            return [:]
        }

        var result: [String: Any] = [:]
        for key in properties.keys.sorted() {
            if let value = defaultValue(fromSchema: properties[key] ?? .null) {
                result[key] = value
            }
        }
        return result
    }

    private func defaultValue(fromSchema schema: JSONValue) -> Any? {
        guard case .object(let object) = schema else {
            return nil
        }

        if let explicitDefault = object["default"] {
            return foundationValue(from: explicitDefault)
        }

        if let enumValue = object["enum"],
           case .array(let entries) = enumValue,
           let first = entries.first {
            return foundationValue(from: first)
        }

        if let oneOf = object["oneOf"],
           case .array(let options) = oneOf,
           let first = options.first {
            return defaultValue(fromSchema: first)
        }
        if let anyOf = object["anyOf"],
           case .array(let options) = anyOf,
           let first = options.first {
            return defaultValue(fromSchema: first)
        }

        if let typeValue = object["type"], case .string(let type) = typeValue {
            switch type {
            case "string":
                return ""
            case "integer", "number":
                return 0
            case "boolean":
                return false
            case "array":
                return []
            case "object":
                return buildDefaultObject(fromSchema: schema)
            default:
                return nil
            }
        }

        return nil
    }

    private func foundationValue(from value: JSONValue) -> Any {
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return number
        case .bool(let bool):
            return bool
        case .null:
            return NSNull()
        case .array(let array):
            return array.map { foundationValue(from: $0) }
        case .object(let object):
            var mapped: [String: Any] = [:]
            for (key, child) in object {
                mapped[key] = foundationValue(from: child)
            }
            return mapped
        }
    }

    private func prettyJSONString(from object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
