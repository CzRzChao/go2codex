import AppKit
import Foundation
import PlatformContractProbeCore

private let help = """
Usage:
  platform-contract-probe inspect
  platform-contract-probe finder
  platform-contract-probe terminal-host <terminal|iterm2> <tab|window>

inspect is read-only. finder and terminal-host explicitly send Apple Events and may
show a macOS Automation consent prompt. This probe never opens Codex or Claude.
"""

private struct RuntimeFailure: Error {
    let code: AppleEventFailureCode
}

private func handlerIsRegistered(bundleIdentifier: String) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
}

private func schemeHandlerMatches(
    _ scheme: String,
    expectedBundleIdentifier: String
) -> Bool {
    guard let url = URL(string: "\(scheme)://") else {
        return false
    }
    return NSWorkspace.shared.urlForApplication(toOpen: url)
        .flatMap { Bundle(url: $0)?.bundleIdentifier }
        == expectedBundleIdentifier
}

private func printInspection() {
    let finderRegistered = handlerIsRegistered(bundleIdentifier: "com.apple.finder")
    let codexRegistered = schemeHandlerMatches(
        "codex",
        expectedBundleIdentifier: "com.openai.codex"
    )
    let claudeRegistered = schemeHandlerMatches(
        "claude",
        expectedBundleIdentifier: "com.anthropic.claudefordesktop"
    )
    print("mode=inspect")
    print("system_control=false")
    print("handler.finder=\(finderRegistered)")
    print("handler.terminal=\(handlerIsRegistered(bundleIdentifier: TerminalHost.terminal.bundleIdentifier))")
    print("handler.iterm2=\(handlerIsRegistered(bundleIdentifier: TerminalHost.iTerm2.bundleIdentifier))")
    print("handler.codex_scheme_exact_identity=\(codexRegistered)")
    print("handler.claude_scheme_exact_identity=\(claudeRegistered)")
    print("event.finder=core/getd direct=pURL(fvtg(brow[1]))")
    print("event.terminal.window=core/dosc direct=text")
    print("event.terminal.tab_existing=unsupported_before_submission")
    print("event.iterm2.window=Itrm/nwwn then Itrm/sntx")
    print("event.iterm2.current_window=core/getd direct=Crwn")
    print("event.iterm2.tab=Itrm/ntwn direct=Crwn then Itrm/sntx")
    print("event.iterm2.create_command_keyword=omitted")
    print("iterm2.create_write_race=requires_manual_observation")
    print("modifier_picker.real_finder_validation=pending_production_debug_probe")
}

private func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
    do {
        let reply = try event.sendEvent(
            options: [.waitForReply, .canInteract],
            timeout: 60
        )
        if let error = reply.paramDescriptor(forKeyword: AppleEventCodes.errorNumber) {
            let status = Int(error.int32Value)
            if status != 0 {
                throw RuntimeFailure(code: .map(status: status))
            }
        }
        return reply
    } catch let failure as RuntimeFailure {
        throw failure
    } catch {
        throw RuntimeFailure(code: .map(status: (error as NSError).code))
    }
}

private func runFinderProbe() throws {
    let reply = try send(AppleEventDescriptors.finderWorkspace())
    let text = reply.paramDescriptor(forKeyword: AppleEventCodes.directObject)?.stringValue
    let workspace = try WorkspaceReplyContract.absoluteFileURL(from: text)
    try WorkspaceReplyContract.validateReachableDirectory(workspace)
    print("mode=finder")
    print("status=accepted")
    print("workspace=redacted_absolute_reachable_directory")
}

private func hasFrontWindow(_ host: TerminalHost) throws -> Bool {
    let running = !NSRunningApplication.runningApplications(
        withBundleIdentifier: host.bundleIdentifier
    ).isEmpty
    guard running else {
        return false
    }
    do {
        _ = try send(
            host == .iTerm2
                ? AppleEventDescriptors.iTermCurrentWindowQuery()
                : AppleEventDescriptors.frontWindowQuery(bundleIdentifier: host.bundleIdentifier)
        )
        return true
    } catch let failure as RuntimeFailure where failure.code == .missingObject {
        return false
    }
}

private func runTerminalProbe(host: TerminalHost, placement: SessionPlacement) throws {
    guard handlerIsRegistered(bundleIdentifier: host.bundleIdentifier) else {
        throw RuntimeFailure(code: .missingHandler)
    }
    let marker = MarkerContract.identifier()
    let shellLine = MarkerContract.shellLine(identifier: marker)
    let hadFrontWindow = placement == .tab ? try hasFrontWindow(host) : false
    let placementAction = TerminalPlacementContract.resolve(
        host: host,
        placement: placement,
        hasWindow: hadFrontWindow
    )

    switch host {
    case .terminal:
        guard placementAction == .createWindow else {
            throw RuntimeFailure(code: .unsupportedPlacement)
        }
        _ = try send(AppleEventDescriptors.terminal(command: shellLine))
    case .iTerm2:
        guard placementAction != .unsupported else {
            throw RuntimeFailure(code: .unsupportedPlacement)
        }
        let create = AppleEventDescriptors.iTermCreate(
            createsTab: placementAction == .createTabInCurrentWindow
        )
        let createReply = try send(create)
        guard let createdObject = createReply.paramDescriptor(
            forKeyword: AppleEventCodes.directObject
        ), createdObject.isRecordDescriptor else {
            throw RuntimeFailure(code: .missingCreatedObject)
        }
        let write = AppleEventDescriptors.iTermWrite(
            createdObject: createdObject,
            text: shellLine
        )
        _ = try send(write)
    }

    let actualPlacement = placementAction == .createTabInCurrentWindow
        ? "tab_candidate"
        : "window_candidate"
    print("mode=terminal-host")
    print("status=apple_events_accepted")
    print("host=\(host.rawValue)")
    print("requested_placement=\(placement.rawValue)")
    print("resolved_placement=\(actualPlacement)")
    print("marker=\(marker)")
    print("verification=manual")
    if host == .iTerm2 {
        print("create_command_keyword=omitted")
        print("create_write_race=observe_marker_in_created_session")
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
        print(help)
        exit(0)
    }
    let invocation = try ProbeInvocation.parse(arguments)
    switch invocation {
    case .inspect:
        printInspection()
    case .finder:
        try runFinderProbe()
    case .terminalHost(let host, let placement):
        try runTerminalProbe(host: host, placement: placement)
    }
} catch let failure as RuntimeFailure {
    fputs("status=failed code=\(failure.code.rawValue)\n", stderr)
    exit(1)
} catch let failure as AppleEventFailureCode {
    fputs("status=failed code=\(failure.rawValue)\n", stderr)
    exit(1)
} catch {
    fputs("\(help)\n", stderr)
    exit(64)
}
