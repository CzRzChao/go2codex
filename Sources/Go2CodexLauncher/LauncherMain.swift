import AppKit

@main
enum LauncherMain {
    @MainActor
    static func main() {
        let snapshot = InvocationSnapshot.capture()
        let application = NSApplication.shared
        let delegate = LauncherAppDelegate(initialSnapshot: snapshot)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
