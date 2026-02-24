import SwiftUI
import AppKit

@main
struct UnityMCPHubApp: App {
    @StateObject private var viewModel = ProjectListViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 960, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    HubProcessManager.killPersistedManagedProcess()
                }
        }
        .windowStyle(.titleBar)
    }
}
