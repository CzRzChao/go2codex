import AppKit
import SwiftUI

private let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("io.github.czrzchao.go2codex.settings")

@main
struct Go2CodexApp: App {
    @NSApplicationDelegateAdaptor(SettingsAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Go2Codex", id: "settings") {
            SettingsRootView()
                .background(SettingsWindowTaggingView())
        }
        .defaultSize(width: 600, height: 650)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        activateAndRaiseSettings()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        raiseSettingsWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        activateAndRaiseSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func activateAndRaiseSettings() {
        NSApp.activate(ignoringOtherApps: true)
        raiseSettingsWindow()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.raiseSettingsWindow()
        }
    }

    private func raiseSettingsWindow() {
        let window = NSApp.windows.first { $0.identifier == settingsWindowIdentifier }
            ?? NSApp.windows.first { $0.canBecomeKey && !$0.isMiniaturized }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class SettingsWindowTaggingNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = settingsWindowIdentifier
    }
}

private struct SettingsWindowTaggingView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowTaggingNSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
