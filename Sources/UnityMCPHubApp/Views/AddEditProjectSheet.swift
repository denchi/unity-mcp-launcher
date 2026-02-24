import AppKit
import SwiftUI

struct AddEditProjectSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initial: UnityProject?
    let onSave: (UnityProject) -> Void

    @State private var name: String
    @State private var projectPath: String
    @State private var unityPath: String
    @State private var tags: String

    init(title: String, initial: UnityProject?, onSave: @escaping (UnityProject) -> Void) {
        self.title = title
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial?.name ?? "")
        _projectPath = State(initialValue: initial?.projectPath ?? "")
        _unityPath = State(initialValue: initial?.unityPath ?? "/Applications/Unity/Hub/Editor/6000.0.0f1/Unity.app/Contents/MacOS/Unity")
        _tags = State(initialValue: initial?.tags.joined(separator: ", ") ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))

            LabeledContent("Name") {
                TextField("Project name", text: $name)
            }

            LabeledContent("Project Path") {
                HStack {
                    TextField("/path/to/unity-project", text: $projectPath)
                    Button("Browse") {
                        if let selected = chooseDirectory() {
                            projectPath = selected.path
                            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                name = selected.lastPathComponent
                            }
                        }
                    }
                }
            }

            LabeledContent("Unity Binary") {
                HStack {
                    TextField("/Applications/.../Unity", text: $unityPath)
                    Button("Browse") {
                        if let selected = chooseExecutable() {
                            unityPath = selected.path
                        }
                    }
                }
            }

            LabeledContent("Tags") {
                TextField("shader, tools, prototype", text: $tags)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var project = initial ?? UnityProject(name: "", projectPath: "", unityPath: "")
                    project.name = normalized(name)
                    project.projectPath = normalized(projectPath)
                    project.unityPath = normalized(unityPath)
                    project.tags = tags
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    onSave(project)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!formIsValid)
            }
        }
        .padding(20)
        .frame(width: 760, height: 300)
    }

    private var formIsValid: Bool {
        !normalized(name).isEmpty && !normalized(projectPath).isEmpty && !normalized(unityPath).isEmpty
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseExecutable() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.prompt = "Select"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
