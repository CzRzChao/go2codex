import AppKit

if CommandLine.arguments.contains("--self-test") {
    print("Go2Codex Settings probe is runnable")
    exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.activate(ignoringOtherApps: true)

let alert = NSAlert()
alert.messageText = "Go2Codex Debug"
alert.informativeText = "Settings entry probe opened successfully."
alert.addButton(withTitle: "OK")
alert.runModal()
