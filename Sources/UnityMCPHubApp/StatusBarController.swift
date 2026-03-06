import AppKit
import SwiftUI

let mainWindowIdentifier = NSUserInterfaceItemIdentifier("UnityMCPHubMainWindow")

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Unity MCP Hub", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        hideInitialWindow()
    }

    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else {
            toggleMainWindow()
            return
        }
        if event.type == .rightMouseUp {
            statusItem?.menu = statusMenu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
            return
        }
        toggleMainWindow()
    }

    @objc private func openMainWindow() {
        showMainWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "Unity MCP Hub")
        item.button?.target = self
        item.button?.action = #selector(handleStatusItemClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func hideInitialWindow(attempt: Int = 0) {
        guard let window = mainWindow() else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.hideInitialWindow(attempt: attempt + 1)
                }
            }
            return
        }
        window.orderOut(nil)
        NSApp.hide(nil)
    }

    private func toggleMainWindow() {
        guard let window = mainWindow() else { return }
        if window.isVisible && NSApp.isActive {
            window.orderOut(nil)
            NSApp.hide(nil)
            return
        }
        showMainWindow()
    }

    private func showMainWindow() {
        guard let window = mainWindow() else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func mainWindow() -> NSWindow? {
        if let identified = NSApp.windows.first(where: { $0.identifier == mainWindowIdentifier }) {
            return identified
        }
        return NSApp.windows.first
    }
}

fileprivate final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.hide(nil)
        return false
    }
}

struct MainWindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else {
                return
            }
            window.identifier = mainWindowIdentifier
            if window.delegate !== context.coordinator.windowDelegate {
                window.delegate = context.coordinator.windowDelegate
            }
        }
    }

    final class Coordinator {
        fileprivate let windowDelegate = MainWindowDelegate()
    }
}
