import AppKit

if CommandLine.arguments.contains("--self-test") {
    print("Go2Codex Toolbar Launcher probe is runnable")
    exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.activate(ignoringOtherApps: true)

let alert = NSAlert()
alert.messageText = "Go2Codex Debug"
alert.informativeText = "Finder toolbar launcher test succeeded."
alert.addButton(withTitle: "OK")
alert.runModal()
