import SwiftUI
import AppKit

@main
struct UnityMCPHubApp: App {
    @NSApplicationDelegateAdaptor(StatusBarController.self) private var statusBarController
    @StateObject private var viewModel = ProjectListViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 960, minHeight: 600)
                .background(MainWindowConfigurator())
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    HubProcessManager.killPersistedManagedProcess()
                }
        }
        .windowStyle(.titleBar)
    }
}
