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
    @Published var selectedProjectID: UUID?
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
            let mapped = records.map(mapRecord)
            projects = mapped
            if selectedProjectID == nil || !projects.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = projects.first?.id
            }
            applyActiveSessions(sessions)
            lastSyncAt = Date()
            hubRuntimeStatus = "Connected"
        } catch {
            showError(title: "Sync Failed", error: error)
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
                        executeMethod: executeMethod ?? normalizedDefaultExecuteMethod()
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
                    sessionID: session.sessionID
                )
                activeSessionsByProjectID.removeValue(forKey: selected.hubProjectID)
                stopPollingSession(sessionID: session.sessionID)
                if let index = projects.firstIndex(where: { $0.hubProjectID == selected.hubProjectID }) {
                    projects[index].hubStatus = dead.status
                }
            } catch {
                showError(title: "Kill Session Failed", error: error)
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

    private func mapRecord(_ record: HubProjectRecord) -> UnityProject {
        UnityProject(
            id: UUID(uuidString: record.projectID) ?? UUID(),
            name: record.name,
            projectPath: record.projectPath,
            unityPath: record.unityPath,
            tags: record.tags,
            hubStatus: record.status,
            lastSeenAt: record.lastSeenAt,
            createdAt: Date(),
            lastOpenedAt: record.lastSeenAt
        )
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
