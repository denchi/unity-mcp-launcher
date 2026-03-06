import Foundation

struct UnityProject: Identifiable, Codable, Hashable {
    enum Health: String, Codable {
        case unknown
        case ready
        case missingProjectPath
        case missingUnityPath
    }

    let id: UUID
    var name: String
    var projectPath: String
    var unityPath: String
    var tags: [String]
    var hubStatus: String?
    var lastSeenAt: Date?
    var createdAt: Date
    var lastOpenedAt: Date?
    var unityVersion: String?

    init(
        id: UUID = UUID(),
        name: String,
        projectPath: String,
        unityPath: String,
        tags: [String] = [],
        hubStatus: String? = nil,
        lastSeenAt: Date? = nil,
        createdAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        unityVersion: String? = nil
    ) {
        self.unityVersion = unityVersion
        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.unityPath = unityPath
        self.tags = tags
        self.hubStatus = hubStatus
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }

    var hubProjectID: String {
        id.uuidString.lowercased()
    }

    var normalizedTags: [String] {
        tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func withNormalizedTags() -> UnityProject {
        var copy = self
        copy.tags = normalizedTags
        return copy
    }

    func health(fileManager: FileManager = .default) -> Health {
        let normalizedProjectPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectPath.isEmpty, !normalizedProjectPath.contains("\u{0000}") else {
            return .missingProjectPath
        }
        guard fileManager.fileExists(atPath: normalizedProjectPath) else {
            return .missingProjectPath
        }

        let normalizedUnityPath = unityPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUnityPath.isEmpty, !normalizedUnityPath.contains("\u{0000}") else {
            return .missingUnityPath
        }
        guard fileManager.isExecutableFile(atPath: normalizedUnityPath) else {
            return .missingUnityPath
        }
        return .ready
    }
}
