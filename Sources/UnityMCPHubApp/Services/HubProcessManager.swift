import Foundation
import Darwin

enum HubProcessError: LocalizedError {
    case invalidHubURL
    case missingRunScript(String)
    case missingRequirementsFile(String)
    case dependencyBootstrapFailed(String)
    case unsupportedPythonVersion(String)
    case noCompatiblePythonInterpreter(String)
    case startFailed(String)
    case healthTimeout

    var errorDescription: String? {
        switch self {
        case .invalidHubURL:
            return "Hub URL is invalid."
        case .missingRunScript(let path):
            return "Could not find hub run script at \(path)."
        case .missingRequirementsFile(let path):
            return "Could not find Python requirements file at \(path)."
        case .dependencyBootstrapFailed(let message):
            return "Could not prepare Python dependencies: \(message)"
        case .unsupportedPythonVersion(let message):
            return "Python version is not supported: \(message)"
        case .noCompatiblePythonInterpreter(let message):
            return "No compatible Python interpreter found: \(message)"
        case .startFailed(let message):
            return "Could not start hub service: \(message)"
        case .healthTimeout:
            return "Hub service did not become healthy in time."
        }
    }
}

actor HubProcessManager {
    private var process: Process?
    private let session = URLSession(configuration: .ephemeral)
    private static let managedProcessInfoKey = "hub.managed_process_info"
    private static let legacyManagedPIDKey = "hub.managed_pid"
    private var hubPythonPath: String = "python3"
    private var gatewayPythonPath: String?

    private struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private struct ManagedProcessInfo {
        let pid: Int32
        let startSignature: String
    }

    private struct PythonInterpreter {
        let path: String
        let major: Int
        let minor: Int
        let patch: Int

        var displayVersion: String { "\(major).\(minor).\(patch)" }
    }

    private struct RequirementBundle {
        let requirements: URL
        let imports: [String]
        let minimumPython: (Int, Int)?
        let required: Bool
        let label: String
    }

    func ensureRunning(
        baseURL: String,
        hubAuthToken: String,
        defaultExecuteMethod: String,
        unityAgentPackageName: String,
        unityAgentPackageGitURL: String
    ) async throws {
        cleanupStalePersistedPID()
        try ensurePythonRequirements()

        if await isHealthy(baseURL: baseURL) {
            return
        }

        if process?.isRunning != true {
            try startManagedProcess(
                baseURL: baseURL,
                hubAuthToken: hubAuthToken,
                defaultExecuteMethod: defaultExecuteMethod,
                unityAgentPackageName: unityAgentPackageName,
                unityAgentPackageGitURL: unityAgentPackageGitURL
            )
        }

        try await waitForHealth(baseURL: baseURL)
    }

    func stopManagedProcess() {
        if let process {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            self.process = nil
        }
        Self.killPersistedManagedProcess()
    }

    private func startManagedProcess(
        baseURL: String,
        hubAuthToken: String,
        defaultExecuteMethod: String,
        unityAgentPackageName: String,
        unityAgentPackageGitURL: String
    ) throws {
        guard let parsed = URL(string: normalizedBaseURL(baseURL)),
              let host = parsed.host,
              let port = parsed.port
        else {
            throw HubProcessError.invalidHubURL
        }

        let runScript = defaultRunScriptPath()
        let hubDirectory = runScript.deletingLastPathComponent()

        guard FileManager.default.fileExists(atPath: runScript.path) else {
            throw HubProcessError.missingRunScript(runScript.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [hubPythonPath, "run.py"]
        process.currentDirectoryURL = hubDirectory

        var env = ProcessInfo.processInfo.environment
        env["HUB_HOST"] = host
        env["HUB_PORT"] = String(port)
        let authToken = hubAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !authToken.isEmpty {
            env["HUB_AUTH_TOKEN"] = authToken
        }
        let executeMethod = defaultExecuteMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        if !executeMethod.isEmpty {
            env["HUB_DEFAULT_EXECUTE_METHOD"] = executeMethod
        }
        let packageName = unityAgentPackageName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !packageName.isEmpty {
            env["HUB_UNITY_AGENT_PACKAGE_NAME"] = packageName
        }
        let packageGitURL = unityAgentPackageGitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !packageGitURL.isEmpty {
            env["HUB_UNITY_AGENT_PACKAGE_GIT_URL"] = packageGitURL
        }
        process.environment = env

        do {
            try process.run()
            self.process = process
            persistManagedProcessInfo(Int32(process.processIdentifier))
        } catch {
            throw HubProcessError.startFailed(error.localizedDescription)
        }
    }

    private func persistManagedProcessInfo(_ pid: Int32) {
        guard let startSignature = Self.processStartSignature(pid) else {
            clearPersistedPID()
            return
        }
        UserDefaults.standard.set(
            [
                "pid": Int(pid),
                "start_signature": startSignature,
            ],
            forKey: Self.managedProcessInfoKey
        )
        UserDefaults.standard.removeObject(forKey: Self.legacyManagedPIDKey)
    }

    private func clearPersistedPID() {
        UserDefaults.standard.removeObject(forKey: Self.managedProcessInfoKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyManagedPIDKey)
    }

    private func loadPersistedProcessInfo() -> ManagedProcessInfo? {
        if let raw = UserDefaults.standard.dictionary(forKey: Self.managedProcessInfoKey),
           let pid = raw["pid"] as? Int,
           let start = raw["start_signature"] as? String,
           pid > 0,
           !start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ManagedProcessInfo(pid: Int32(pid), startSignature: start)
        }
        return nil
    }

    private func cleanupStalePersistedPID() {
        guard let info = loadPersistedProcessInfo() else {
            clearPersistedPID()
            return
        }
        if !Self.isExpectedManagedProcess(info) {
            clearPersistedPID()
        }
    }

    nonisolated static func killPersistedManagedProcess() {
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: managedProcessInfoKey)
            defaults.removeObject(forKey: legacyManagedPIDKey)
        }

        guard let raw = defaults.dictionary(forKey: managedProcessInfoKey),
              let pid = raw["pid"] as? Int,
              let startSignature = raw["start_signature"] as? String,
              pid > 0,
              !startSignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        let info = ManagedProcessInfo(pid: Int32(pid), startSignature: startSignature)
        guard isExpectedManagedProcess(info) else {
            return
        }

        _ = kill(info.pid, SIGTERM)
    }

    nonisolated private static func isExpectedManagedProcess(_ info: ManagedProcessInfo) -> Bool {
        if kill(info.pid, 0) != 0 {
            return false
        }
        guard let currentSignature = processStartSignature(info.pid),
              currentSignature == info.startSignature
        else {
            return false
        }
        guard let commandLine = processCommandLine(info.pid)?.lowercased() else {
            return false
        }
        return commandLine.contains("python") && commandLine.contains("run.py")
    }

    nonisolated private static func processStartSignature(_ pid: Int32) -> String? {
        guard let output = runSystemCommand(
            ["/bin/ps", "-p", String(pid), "-o", "lstart="]
        )?.stdout else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func processCommandLine(_ pid: Int32) -> String? {
        guard let output = runSystemCommand(
            ["/bin/ps", "-p", String(pid), "-o", "command="]
        )?.stdout else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func runSystemCommand(_ arguments: [String]) -> CommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func waitForHealth(baseURL: String) async throws {
        for _ in 0..<40 {
            if await isHealthy(baseURL: baseURL) {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw HubProcessError.healthTimeout
    }

    private func isHealthy(baseURL: String) async -> Bool {
        guard let base = URL(string: normalizedBaseURL(baseURL)),
              let url = URL(string: "health", relativeTo: base)
        else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.0

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }

    private func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    private func defaultRunScriptPath() -> URL {
        runtimeRootURL().appendingPathComponent("hub_service/run.py")
    }

    private func runtimeRootURL() -> URL {
        let fileManager = FileManager.default
        let fallback = sourceRepoRootURL()
        var candidates: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL)
        }

        if let executableURL = Bundle.main.executableURL {
            var current = executableURL.deletingLastPathComponent()
            candidates.append(current)
            for _ in 0..<6 {
                current = current.deletingLastPathComponent()
                candidates.append(current)
            }
        }

        candidates.append(fallback)

        for candidate in deduplicatedURLs(candidates) {
            let runScript = candidate.appendingPathComponent("hub_service/run.py")
            if fileManager.fileExists(atPath: runScript.path) {
                return candidate
            }
        }

        return fallback
    }

    private func sourceRepoRootURL() -> URL {
        let serviceFile = URL(fileURLWithPath: #filePath)
        return serviceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            unique.append(url)
        }
        return unique
    }

    private func ensurePythonRequirements() throws {
        let root = runtimeRootURL()
        let interpreters = try discoverPythonInterpreters()
        if interpreters.isEmpty {
            throw HubProcessError.noCompatiblePythonInterpreter("No usable python interpreter was discovered on PATH.")
        }

        let bundles: [RequirementBundle] = [
            RequirementBundle(
                requirements: root.appendingPathComponent("hub_service/requirements.txt"),
                imports: ["fastapi", "uvicorn", "httpx", "pydantic"],
                minimumPython: nil,
                required: true,
                label: "Hub Service"
            ),
            RequirementBundle(
                requirements: root.appendingPathComponent("hub_mcp_gateway/requirements.txt"),
                imports: ["mcp", "httpx"],
                minimumPython: (3, 10),
                required: false,
                label: "Hub MCP Gateway"
            ),
        ]

        for bundle in bundles {
            let prepared = try prepareBundle(bundle, interpreters: interpreters)
            if bundle.label == "Hub Service", let prepared {
                hubPythonPath = prepared.path
            }
            if bundle.label == "Hub MCP Gateway" {
                gatewayPythonPath = prepared?.path
            }
        }

        fputs(
            "[UnityMCPHub] Hub Python interpreter: \(hubPythonPath)\n",
            stderr
        )
        if let gatewayPythonPath {
            fputs(
                "[UnityMCPHub] MCP gateway Python interpreter: \(gatewayPythonPath)\n",
                stderr
            )
        }
    }

    private func prepareBundle(_ bundle: RequirementBundle, interpreters: [PythonInterpreter]) throws -> PythonInterpreter? {
        let minimum = bundle.minimumPython
        let compatible = interpreters.filter { interpreter in
            guard let minimum else { return true }
            return isVersion(interpreter, atLeast: minimum)
        }

        if compatible.isEmpty {
            if bundle.required {
                if let minimum {
                    throw HubProcessError.noCompatiblePythonInterpreter(
                        "\(bundle.label) requires Python \(minimum.0).\(minimum.1)+"
                    )
                }
                throw HubProcessError.noCompatiblePythonInterpreter("\(bundle.label) has no compatible interpreter.")
            }
            if let minimum {
                fputs(
                    "[UnityMCPHub] Optional dependency setup skipped for \(bundle.label): no Python \(minimum.0).\(minimum.1)+ found.\n",
                    stderr
                )
            }
            return nil
        }

        var failures: [String] = []
        for interpreter in compatible {
            do {
                try ensureRequirementBundleInstalled(bundle, interpreter: interpreter)
                return interpreter
            } catch {
                failures.append("\(interpreter.path): \(error.localizedDescription)")
            }
        }

        let joinedFailures = failures.joined(separator: "\n")
        if bundle.required {
            throw HubProcessError.dependencyBootstrapFailed(joinedFailures)
        }
        fputs(
            "[UnityMCPHub] Optional dependency setup skipped for \(bundle.label):\n\(joinedFailures)\n",
            stderr
        )
        return nil
    }

    private func ensureRequirementBundleInstalled(_ bundle: RequirementBundle, interpreter: PythonInterpreter) throws {
        let requirements = bundle.requirements
        let requiredImports = bundle.imports
        guard FileManager.default.fileExists(atPath: requirements.path) else {
            throw HubProcessError.missingRequirementsFile(requirements.path)
        }

        if let minimum = bundle.minimumPython, !isVersion(interpreter, atLeast: minimum) {
            throw HubProcessError.unsupportedPythonVersion(
                "\(bundle.label) needs Python \(minimum.0).\(minimum.1)+, current is \(interpreter.major).\(interpreter.minor)"
            )
        }

        if try pythonImportsAvailable(requiredImports, interpreterPath: interpreter.path) {
            return
        }

        let install = try runCommand(
            [
                interpreter.path,
                "-m",
                "pip",
                "install",
                "--user",
                "-r",
                requirements.path,
            ],
            currentDirectory: requirements.deletingLastPathComponent()
        )
        guard install.exitCode == 0 else {
            let message = install.stderr.isEmpty ? install.stdout : install.stderr
            throw HubProcessError.dependencyBootstrapFailed(message)
        }

        if try !pythonImportsAvailable(requiredImports, interpreterPath: interpreter.path) {
            throw HubProcessError.dependencyBootstrapFailed(
                "Installed dependencies but Python still cannot import: \(requiredImports.joined(separator: ", "))"
            )
        }
    }

    private func pythonImportsAvailable(_ modules: [String], interpreterPath: String) throws -> Bool {
        let importCode = "import " + modules.joined(separator: ",")
        let check = try runCommand([interpreterPath, "-c", importCode], currentDirectory: nil)
        return check.exitCode == 0
    }

    private func pythonVersion(interpreterPath: String) throws -> (major: Int, minor: Int, patch: Int) {
        let check = try runCommand(
            [interpreterPath, "-c", "import sys; print(f\"{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}\")"],
            currentDirectory: nil
        )
        guard check.exitCode == 0 else {
            let message = check.stderr.isEmpty ? check.stdout : check.stderr
            throw HubProcessError.dependencyBootstrapFailed(message)
        }
        let trimmed = check.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".").map(String.init)
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1])
        else {
            throw HubProcessError.dependencyBootstrapFailed("Could not detect Python version.")
        }
        let patch = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
        return (major, minor, patch)
    }

    private func discoverPythonInterpreters() throws -> [PythonInterpreter] {
        var candidates: [String] = []

        let commandNames = ["python3", "python3.13", "python3.12", "python3.11", "python3.10", "python"]
        for name in commandNames {
            if let resolved = try resolveCommandPath(name) {
                candidates.append(resolved)
            }
        }

        let searchDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.pyenv/shims",
            "/usr/bin",
        ]
        let fm = FileManager.default
        for directory in searchDirectories {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where isPythonExecutableName(entry) {
                let path = "\(directory)/\(entry)"
                if fm.isExecutableFile(atPath: path) {
                    candidates.append(path)
                }
            }
        }

        var seen: Set<String> = []
        let deduped = candidates.filter { path in
            if seen.contains(path) { return false }
            seen.insert(path)
            return true
        }

        var interpreters: [PythonInterpreter] = []
        for path in deduped {
            if let interpreter = try detectInterpreter(path: path) {
                interpreters.append(interpreter)
            }
        }
        return interpreters
    }

    private func resolveCommandPath(_ name: String) throws -> String? {
        let check = try runCommand(["which", name], currentDirectory: nil)
        guard check.exitCode == 0 else { return nil }
        let resolved = check.stdout
            .split(separator: "\n")
            .map(String.init)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved, !resolved.isEmpty else { return nil }
        return resolved
    }

    private func detectInterpreter(path: String) throws -> PythonInterpreter? {
        let version = try pythonVersion(interpreterPath: path)
        return PythonInterpreter(path: path, major: version.major, minor: version.minor, patch: version.patch)
    }

    private func isPythonExecutableName(_ name: String) -> Bool {
        if name.contains("config") {
            return false
        }
        if name == "python" || name == "python3" {
            return true
        }
        if name.hasPrefix("python3.") {
            let suffix = String(name.dropFirst("python3.".count))
            return suffix.allSatisfy { $0.isNumber || $0 == "." }
        }
        return false
    }

    private func isVersion(_ interpreter: PythonInterpreter, atLeast minimum: (Int, Int)) -> Bool {
        if interpreter.major > minimum.0 {
            return true
        }
        if interpreter.major < minimum.0 {
            return false
        }
        return interpreter.minor >= minimum.1
    }

    private func runCommand(_ arguments: [String], currentDirectory: URL?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw HubProcessError.dependencyBootstrapFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
