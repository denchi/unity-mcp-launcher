import AppKit
import SwiftUI

struct UnityInstallationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ProjectListViewModel

    var body: some View {
        VStack(spacing: 16) {
            header

            ScrollView {
                if viewModel.unityInstallations.isEmpty {
                    Text("No Unity installations detected.")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        ForEach(viewModel.unityInstallations, id: \.self) { installation in
                            installationRow(for: installation)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            Divider()

            installSection

            footer
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
        .task {
            await viewModel.refreshUnityInstallations()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Unity Installations")
                    .font(.title3.weight(.semibold))
                Text("Install, remove, or add local versions for the hub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") {
                Task {
                    await viewModel.refreshUnityInstallations()
                }
            }
            .disabled(viewModel.isBusy)
        }
    }

    private func installationRow(for installation: HubUnityInstallation) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(installation.version)
                    .font(.headline)
                Text(installation.installPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Remove") {
                viewModel.removeUnityInstallation(installation)
            }
            .disabled(viewModel.isBusy)
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add Unity Versions")
                .font(.headline)
            HStack {
                TextField("Unity version (e.g. 2023.3.0f1)", text: $viewModel.unityVersionInstallInput)
                    .textFieldStyle(.roundedBorder)
                Button("Install") {
                    viewModel.installUnityVersion()
                }
                .disabled(
                    viewModel.isBusy
                        || viewModel.unityVersionInstallInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            HStack {
                Text("Use a version already installed on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select Installed from Disk") {
                    if let selected = chooseUnityInstallation() {
                        viewModel.registerLocalUnityInstallation(selected.path)
                    }
                }
                .disabled(viewModel.isBusy)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private func chooseUnityInstallation() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
