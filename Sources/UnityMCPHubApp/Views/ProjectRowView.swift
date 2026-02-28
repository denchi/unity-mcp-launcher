import SwiftUI

struct ProjectRowView: View {
    let project: UnityProject
    let isSelected: Bool
    let activeSessionStatus: String?
    let isHubConnected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(project.name)
                        .font(.headline)
                        .foregroundStyle(isSelected ? .white : .primary)
                    HStack(spacing: 6) {
                        Image(systemName: projectServerConnected ? "p.circle.fill" : "p.circle")
                            .foregroundStyle(iconColor(connected: projectServerConnected))
                            .help(projectServerConnected ? "Hub connected (P)" : "Hub disconnected (P)")

                        Image(systemName: unityServerConnected ? "u.circle.fill" : "u.circle")
                            .foregroundStyle(iconColor(connected: unityServerConnected))
                            .help(unityServerConnected ? "Unity internal server connected (U)" : "Unity internal server disconnected (U)")

                        if let message = errorMessage {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(isSelected ? Color.white : .orange)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .help(message)
                        }
                    }
                }
                Text(project.projectPath)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? .white.opacity(0.95) : .secondary)
                    .lineLimit(1)
                if let version = project.unityVersion, !version.isEmpty {
                    Text("Unity \(version)")
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                        .lineLimit(1)
                }
                if !project.tags.isEmpty {
                    if isSelected {
                        Text(project.tags.joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.88))
                            .lineLimit(1)
                    } else {
                        Text(project.tags.joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var projectServerConnected: Bool {
        isHubConnected
    }

    private var unityServerConnected: Bool {
        activeSessionStatus?.lowercased() == "ready"
    }

    private var errorMessage: String? {
        switch project.health() {
        case .missingProjectPath:
            return "Project path not found: \(project.projectPath)"
        case .missingUnityPath:
            return "Unity executable is missing or not runnable: \(project.unityPath)"
        case .unknown, .ready:
            break
        }

        if project.hubStatus?.lowercased() == "dead" {
            return "Session is dead. Relaunch this project."
        }
        return nil
    }

    private func iconColor(connected: Bool) -> Color {
        if isSelected {
            return connected ? .white : Color.white.opacity(0.4)
        }
        return connected ? .primary : Color.secondary.opacity(0.55)
    }
}
