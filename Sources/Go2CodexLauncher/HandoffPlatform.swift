import AppKit
import ApplicationServices
import Foundation
import Go2CodexCore

typealias WorkspaceOpenCompletion = @Sendable (
    NSRunningApplication?,
    (any Error)?
) -> Void

@MainActor
func awaitWorkspaceOpen<Result: Sendable>(
    mapError: @escaping @Sendable ((any Error)?) -> Result,
    starting operation: (_ completion: @escaping WorkspaceOpenCompletion) -> Void
) async -> Result {
    await withCheckedContinuation { continuation in
        // LaunchServices invokes this completion on its own queue.
        let completion: WorkspaceOpenCompletion = { _, error in
            continuation.resume(returning: mapError(error))
        }
        operation(completion)
    }
}

struct DesktopHandlerRegistration: Equatable {
    let applicationURL: URL
    let bundleIdentifier: String?
}

@MainActor
protocol DesktopHandoffPlatform {
    func handler(toOpen url: URL) -> DesktopHandlerRegistration?
    func open(
        _ url: URL,
        withApplicationAt applicationURL: URL
    ) async -> Int?
}

@MainActor
struct WorkspaceDesktopHandoffPlatform: DesktopHandoffPlatform {
    func handler(toOpen url: URL) -> DesktopHandlerRegistration? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            toOpen: url
        ) else {
            return nil
        }
        return DesktopHandlerRegistration(
            applicationURL: applicationURL,
            bundleIdentifier: Bundle(url: applicationURL)?.bundleIdentifier
        )
    }

    func open(
        _ url: URL,
        withApplicationAt applicationURL: URL
    ) async -> Int? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        return await awaitWorkspaceOpen(
            mapError: { error in
                error.map { ($0 as NSError).code }
            }
        ) { completion in
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration,
                completionHandler: completion
            )
        }
    }
}

@MainActor
struct DesktopOpenAdapter: DesktopHandoffPerforming {
    private let platform: any DesktopHandoffPlatform

    init(
        platform: any DesktopHandoffPlatform = WorkspaceDesktopHandoffPlatform()
    ) {
        self.platform = platform
    }

    func open(
        _ url: URL,
        for target: AgentTarget
    ) async throws -> HandoffAcceptance {
        guard let handler = platform.handler(toOpen: url),
              let verifiedHandler = DesktopTargetHandlerPolicy.verify(
                  target: target,
                  applicationURL: handler.applicationURL,
                  handlerBundleIdentifier: handler.bundleIdentifier
              ) else {
            throw DesktopHandoffError.handlerUnavailable(target)
        }

        if let errorCode = await platform.open(
            url,
            withApplicationAt: verifiedHandler.applicationURL
        ) {
            throw DesktopHandoffError.openFailed(code: errorCode)
        }
        return .acceptedByLaunchServices
    }
}

@MainActor
protocol TerminalApplicationStateLookingUp {
    func applicationURL(bundleIdentifier: String) -> URL?
    func isRunning(bundleIdentifier: String) -> Bool
    func activate(bundleIdentifier: String) -> Bool
}

@MainActor
struct WorkspaceTerminalApplicationState: TerminalApplicationStateLookingUp {
    func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        )
    }

    func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
    }

    func activate(bundleIdentifier: String) -> Bool {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else {
            return false
        }
        return application.activate(options: [.activateAllWindows])
    }
}

struct TerminalApplicationOpenFailure: Equatable, Sendable {
    let code: Int
    let appleEventStatus: Int32?

    init(error: any Error) {
        let outerError = error as NSError
        code = outerError.code

        var status: Int32?
        var current: NSError? = outerError
        for _ in 0..<8 {
            guard let inspected = current else {
                break
            }
            if inspected.domain == NSOSStatusErrorDomain,
               inspected.code == -600
                || (-1799 ... -1700).contains(inspected.code) {
                status = Int32(clamping: inspected.code)
                break
            }
            guard let underlying = inspected.userInfo[NSUnderlyingErrorKey]
                as? NSError,
                  underlying !== inspected else {
                break
            }
            current = underlying
        }
        appleEventStatus = status
    }

    init(code: Int, appleEventStatus: Int32? = nil) {
        self.code = code
        self.appleEventStatus = appleEventStatus
    }
}

@MainActor
protocol TerminalApplicationOpening {
    func openApplication(
        at applicationURL: URL,
        initialAppleEvent: NSAppleEventDescriptor?,
        activates: Bool
    ) async -> TerminalApplicationOpenFailure?
}

@MainActor
struct WorkspaceTerminalApplicationOpener: TerminalApplicationOpening {
    func openApplication(
        at applicationURL: URL,
        initialAppleEvent: NSAppleEventDescriptor?,
        activates: Bool
    ) async -> TerminalApplicationOpenFailure? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        configuration.addsToRecentItems = false
        configuration.appleEvent = initialAppleEvent

        return await awaitWorkspaceOpen(
            mapError: { error in
                error.map(TerminalApplicationOpenFailure.init(error:))
            }
        ) { completion in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration,
                completionHandler: completion
            )
        }
    }
}

struct AutomationPermissionRequest: Equatable, Sendable {
    static let allEvents: UInt32 = 0x2a2a2a2a

    let bundleIdentifier: String
    let eventClass: UInt32
    let eventID: UInt32
}

@MainActor
protocol NativeAppleEventSending {
    func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor

    func requestAutomationPermission(
        _ request: AutomationPermissionRequest
    ) async -> Int32

    func requestAccessibilityPermission() -> Bool
}

@MainActor
struct SystemNativeAppleEventSender: NativeAppleEventSending {
    func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        try NativeAppleEvent.send(event)
    }

    func requestAutomationPermission(
        _ request: AutomationPermissionRequest
    ) async -> Int32 {
        await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(
                bundleIdentifier: request.bundleIdentifier
            )
            guard let address = target.aeDesc else {
                return Int32(paramErr)
            }
            return AEDeterminePermissionToAutomateTarget(
                address,
                request.eventClass,
                request.eventID,
                true
            )
        }.value
    }

    func requestAccessibilityPermission() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

enum TerminalAdapterError: Error, Equatable, DiagnosticCodeProviding {
    case iTermScriptResourceMissing
    case iTermScriptLoadFailed
    case iTermScriptExecutionFailed
    case iTermScriptResultInvalid(UInt32)
    case iTermWindowQueryReplyInvalid(UInt32?)
    case applicationOpenFailed(Int)
    case systemEventsUnavailable
    case systemEventsOpenFailed(Int)
    case systemEventsAutomationPermissionDenied
    case systemEventsConsentRequired
    case systemEventsPermissionCheckFailed(Int32)
    case accessibilityPermissionDenied
    case terminalActivationFailed
    case terminalTabCountReplyInvalid(UInt32?)
    case terminalTabCreationTimedOut
    case terminalTabShortcutFailed(Int32)

    var diagnosticCode: DiagnosticCode {
        switch self {
        case .iTermScriptResourceMissing:
            DiagnosticCode(rawValue: "iterm-script-resource-missing")
        case .iTermScriptLoadFailed:
            DiagnosticCode(rawValue: "iterm-script-load-failed")
        case .iTermScriptExecutionFailed:
            DiagnosticCode(rawValue: "iterm-script-execution-failed")
        case .iTermScriptResultInvalid:
            DiagnosticCode(rawValue: "iterm-script-result-invalid")
        case .iTermWindowQueryReplyInvalid:
            DiagnosticCode(rawValue: "iterm-window-query-malformed")
        case .applicationOpenFailed:
            DiagnosticCode(rawValue: "terminal-open-failed")
        case .systemEventsUnavailable:
            DiagnosticCode(rawValue: "terminal-system-events-unavailable")
        case .systemEventsOpenFailed:
            DiagnosticCode(rawValue: "terminal-system-events-open-failed")
        case .systemEventsAutomationPermissionDenied:
            DiagnosticCode(rawValue: "terminal-system-events-automation-denied")
        case .systemEventsConsentRequired:
            DiagnosticCode(rawValue: "terminal-system-events-consent-required")
        case .systemEventsPermissionCheckFailed:
            DiagnosticCode(rawValue: "terminal-system-events-permission-check-failed")
        case .accessibilityPermissionDenied:
            DiagnosticCode(rawValue: "terminal-accessibility-denied")
        case .terminalActivationFailed:
            DiagnosticCode(rawValue: "terminal-activation-failed")
        case .terminalTabCountReplyInvalid:
            DiagnosticCode(rawValue: "terminal-tab-count-malformed")
        case .terminalTabCreationTimedOut:
            DiagnosticCode(rawValue: "terminal-tab-creation-timeout")
        case .terminalTabShortcutFailed:
            DiagnosticCode(rawValue: "terminal-tab-shortcut-failed")
        }
    }
}

typealias TerminalTabPollDelay = @MainActor () async -> Void

private enum TerminalFrontWindowState {
    case notRunning
    case noWindow
    case hasWindow
}

@MainActor
struct TerminalOpenAdapter: TerminalHandoffPerforming {
    private let applicationState: any TerminalApplicationStateLookingUp
    private let applicationOpener: any TerminalApplicationOpening
    private let eventSender: any NativeAppleEventSending
    private let iTermScriptExecutor: any ITermHandoffScriptExecuting
    private let terminalTabPollAttempts: Int
    private let terminalTabPollDelay: TerminalTabPollDelay

    init(
        applicationState: any TerminalApplicationStateLookingUp =
            WorkspaceTerminalApplicationState(),
        applicationOpener: any TerminalApplicationOpening =
            WorkspaceTerminalApplicationOpener(),
        eventSender: any NativeAppleEventSending = SystemNativeAppleEventSender(),
        iTermScriptExecutor: any ITermHandoffScriptExecuting =
            BundledITermHandoffScriptExecutor(),
        terminalTabPollAttempts: Int = 50,
        terminalTabPollDelay: @escaping TerminalTabPollDelay = {
            try? await Task.sleep(for: .milliseconds(100))
        }
    ) {
        self.applicationState = applicationState
        self.applicationOpener = applicationOpener
        self.eventSender = eventSender
        self.iTermScriptExecutor = iTermScriptExecutor
        self.terminalTabPollAttempts = max(1, terminalTabPollAttempts)
        self.terminalTabPollDelay = terminalTabPollDelay
    }

    func open(
        _ command: TerminalCommand,
        in host: TerminalHost,
        placement: SessionPlacement
    ) async throws -> HandoffAcceptance {
        guard let applicationURL = applicationState.applicationURL(
            bundleIdentifier: host.bundleIdentifier
        ), applicationURL.isFileURL, applicationURL.path.hasPrefix("/") else {
            throw TerminalHandoffError.hostUnavailable(host)
        }

        switch host {
        case .terminal:
            try await openTerminal(
                command: command.line,
                placement: placement,
                applicationURL: applicationURL
            )
        case .iTerm2:
            try await openITerm(
                command: command.line,
                placement: placement,
                applicationURL: applicationURL,
                host: host
            )
        }
        return .acceptedByTerminalHost
    }

    private func openTerminal(
        command: String,
        placement: SessionPlacement,
        applicationURL: URL
    ) async throws {
        let host = TerminalHost.terminal
        let wasRunning = applicationState.isRunning(
            bundleIdentifier: host.bundleIdentifier
        )
        if !wasRunning {
            try await openHost(
                applicationURL: applicationURL,
                event: nil,
                host: host,
                activates: true
            )
        }
        try await requestHostAutomationPermission(host)

        let frontWindowID = placement == .newTab
            ? try terminalFrontWindowID()
            : nil
        let placementPlan = TerminalPlacementPlanner.plan(
            for: .terminal,
            placement: placement,
            hasWindow: frontWindowID != nil
        )
        switch placementPlan {
        case .createTabInFrontWindow:
            guard let frontWindowID else {
                throw TerminalAdapterError.terminalTabCountReplyInvalid(nil)
            }
            try await sendTerminalNewTab(
                command: command,
                windowID: frontWindowID
            )
        case .createWindow:
            try await sendTerminal(
                command: command,
                host: host,
                applicationURL: applicationURL,
                isRunning: true
            )
        case .unsupported:
            throw TerminalHandoffError.unsupportedPlacement(.terminal, placement)
        }
    }

    private func openITerm(
        command: String,
        placement: SessionPlacement,
        applicationURL: URL,
        host: TerminalHost
    ) async throws {
        let wasRunning = applicationState.isRunning(
            bundleIdentifier: host.bundleIdentifier
        )
        if wasRunning {
            try await requestHostAutomationPermission(host)
        }
        // AEDeterminePermission requires a running target. This bootstrap event
        // suppresses iTerm window restoration before cold-start preflight.
        try await openHost(
            applicationURL: applicationURL,
            event: NativeAppleEvent.iTermQuietLaunch(),
            host: host,
            activates: true
        )
        if !wasRunning {
            try await requestHostAutomationPermission(host)
        }
        let windowState = placement == .newTab
            ? try frontWindowState(for: host, assumesRunning: true)
            : .noWindow
        let placementPlan = TerminalPlacementPlanner.plan(
            for: host,
            placement: placement,
            hasWindow: windowState == .hasWindow
        )
        switch placementPlan {
        case .createTabInFrontWindow:
            try sendITerm(
                command: command,
                targetFrontWindow: true,
                host: host
            )
        case .createWindow:
            try sendITerm(
                command: command,
                targetFrontWindow: false,
                host: host
            )
        case .unsupported:
            throw TerminalHandoffError.unsupportedPlacement(host, placement)
        }
    }

    private func frontWindowState(
        for host: TerminalHost,
        assumesRunning: Bool = false
    ) throws -> TerminalFrontWindowState {
        guard assumesRunning || applicationState.isRunning(
            bundleIdentifier: host.bundleIdentifier
        ) else {
            return .notRunning
        }

        do {
            let reply = try eventSender.send(
                host == .iTerm2
                    ? try NativeAppleEvent.iTermCurrentWindowQuery()
                    : try NativeAppleEvent.frontWindowQuery(
                        bundleIdentifier: host.bundleIdentifier
                    )
            )
            if host == .iTerm2 {
                return try iTermWindowState(from: reply)
            }
            return .hasWindow
        } catch RawAppleEventError.status(-1728),
                RawAppleEventError.status(-1719) {
            return .noWindow
        } catch RawAppleEventError.status(-600) where host == .terminal {
            return .notRunning
        } catch let RawAppleEventError.status(status) {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: host
            )
        }
    }

    private func terminalFrontWindowID() throws -> Int32? {
        do {
            let reply = try eventSender.send(
                try NativeAppleEvent.terminalFrontWindowIDQuery()
            )
            guard let windowID = NativeAppleEvent.terminalWindowID(
                from: reply
            ) else {
                throw TerminalAdapterError.terminalTabCountReplyInvalid(
                    reply.paramDescriptor(
                        forKeyword: NativeAppleEvent.directObjectKeyword
                    )?.descriptorType
                )
            }
            return windowID
        } catch RawAppleEventError.status(-1728),
                RawAppleEventError.status(-1719),
                RawAppleEventError.status(-600) {
            return nil
        } catch let RawAppleEventError.status(status) {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: .terminal
            )
        }
    }

    private func iTermWindowState(
        from reply: NSAppleEventDescriptor
    ) throws -> TerminalFrontWindowState {
        switch NativeAppleEvent.classifyITermCurrentWindowReply(reply) {
        case .window:
            return .hasWindow
        case .noWindow:
            return .noWindow
        case .invalid(let descriptorType):
            throw TerminalAdapterError.iTermWindowQueryReplyInvalid(
                descriptorType
            )
        }
    }

    private func sendTerminal(
        command: String,
        host: TerminalHost,
        applicationURL: URL,
        isRunning: Bool,
        targetFrontWindow: Bool = false,
        fallbackToNewWindowIfTargetMissing: Bool = false
    ) async throws {
        let event = try NativeAppleEvent.terminalCommand(
            command: command,
            targetFrontWindow: targetFrontWindow
        )
        guard isRunning else {
            try await openHost(
                applicationURL: applicationURL,
                event: event,
                host: host
            )
            return
        }

        do {
            _ = try eventSender.send(event)
        } catch RawAppleEventError.status(-1728)
            where targetFrontWindow && fallbackToNewWindowIfTargetMissing {
            _ = try sendTerminalEvent(
                NativeAppleEvent.terminalNewWindow(command: command),
                host: host
            )
        } catch RawAppleEventError.status(-1719)
            where targetFrontWindow && fallbackToNewWindowIfTargetMissing {
            _ = try sendTerminalEvent(
                NativeAppleEvent.terminalNewWindow(command: command),
                host: host
            )
        } catch RawAppleEventError.status(-600) {
            try await openHost(
                applicationURL: applicationURL,
                event: event,
                host: host
            )
        } catch let RawAppleEventError.status(status) {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: host
            )
        }
    }

    private func sendTerminalNewTab(
        command: String,
        windowID: Int32
    ) async throws {
        try await ensureSystemEventsRunning()
        try await requestSystemEventsAutomationPermission()
        guard eventSender.requestAccessibilityPermission() else {
            throw TerminalAdapterError.accessibilityPermissionDenied
        }
        let initialTTYs = try terminalTabTTYs(windowID: windowID)
        guard Set(initialTTYs).count == initialTTYs.count else {
            throw TerminalAdapterError.terminalTabCountReplyInvalid(nil)
        }
        guard applicationState.activate(
            bundleIdentifier: TerminalHost.terminal.bundleIdentifier
        ) else {
            throw TerminalAdapterError.terminalActivationFailed
        }

        let shortcut = try NativeAppleEvent.systemEventsTerminalNewTabShortcut()
        do {
            _ = try eventSender.send(shortcut)
        } catch let RawAppleEventError.status(status) {
            throw mapSystemEventsStatus(
                status,
                fallback: .terminalTabShortcutFailed(status)
            )
        }

        let initialTTYSet = Set(initialTTYs)
        var targetTTY: String?
        for _ in 0..<terminalTabPollAttempts {
            await terminalTabPollDelay()
            let currentTTYs = try terminalTabTTYs(windowID: windowID)
            let currentTTYSet = Set(currentTTYs)
            guard currentTTYSet.count == currentTTYs.count else {
                throw TerminalAdapterError.terminalTabCountReplyInvalid(nil)
            }
            let addedTTYs = currentTTYSet.subtracting(initialTTYSet)
            if currentTTYs.count == initialTTYs.count + 1,
               initialTTYSet.isSubset(of: currentTTYSet),
               addedTTYs.count == 1 {
                targetTTY = addedTTYs.first
                break
            }
        }
        guard let targetTTY else {
            throw TerminalAdapterError.terminalTabCreationTimedOut
        }

        _ = try sendTerminalEvent(
            try NativeAppleEvent.terminalCommand(
                command: command,
                targetTabTTY: targetTTY,
                inWindowID: windowID
            ),
            host: .terminal
        )
    }

    private func terminalTabTTYs(windowID: Int32) throws -> [String] {
        do {
            let reply = try eventSender.send(
                try NativeAppleEvent.terminalTabTTYsQuery(windowID: windowID)
            )
            guard let ttys = NativeAppleEvent.terminalTabTTYs(from: reply) else {
                throw TerminalAdapterError.terminalTabCountReplyInvalid(
                    reply.paramDescriptor(
                        forKeyword: NativeAppleEvent.directObjectKeyword
                    )?.descriptorType
                )
            }
            return ttys
        } catch let RawAppleEventError.status(status) {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: .terminal
            )
        }
    }

    private func sendTerminalEvent(
        _ event: NSAppleEventDescriptor,
        host: TerminalHost
    ) throws -> NSAppleEventDescriptor {
        do {
            return try eventSender.send(event)
        } catch let RawAppleEventError.status(status) {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: host
            )
        }
    }

    private func requestHostAutomationPermission(
        _ host: TerminalHost
    ) async throws {
        let eventClass: UInt32
        let eventID: UInt32
        switch host {
        case .terminal:
            eventClass = TerminalAppleEventContract.terminalDoScriptClass.rawValue
            eventID = TerminalAppleEventContract.terminalDoScriptID.rawValue
        case .iTerm2:
            eventClass = AutomationPermissionRequest.allEvents
            eventID = AutomationPermissionRequest.allEvents
        }
        let status = await eventSender.requestAutomationPermission(
            AutomationPermissionRequest(
                bundleIdentifier: host.bundleIdentifier,
                eventClass: eventClass,
                eventID: eventID
            )
        )
        guard status == noErr else {
            throw TerminalHandoffError.mapAppleEventStatus(status, host: host)
        }
    }

    private func ensureSystemEventsRunning() async throws {
        let bundleIdentifier = NativeAppleEvent.systemEventsBundleIdentifier
        guard let applicationURL = applicationState.applicationURL(
            bundleIdentifier: bundleIdentifier
        ), applicationURL.isFileURL, applicationURL.path.hasPrefix("/") else {
            throw TerminalAdapterError.systemEventsUnavailable
        }
        guard !applicationState.isRunning(bundleIdentifier: bundleIdentifier) else {
            return
        }
        if let failure = await applicationOpener.openApplication(
            at: applicationURL,
            initialAppleEvent: nil,
            activates: false
        ) {
            throw TerminalAdapterError.systemEventsOpenFailed(failure.code)
        }
    }

    private func requestSystemEventsAutomationPermission() async throws {
        let shortcut = try NativeAppleEvent.systemEventsTerminalNewTabShortcut()
        let status = await eventSender.requestAutomationPermission(
            AutomationPermissionRequest(
                bundleIdentifier: NativeAppleEvent.systemEventsBundleIdentifier,
                eventClass: shortcut.eventClass,
                eventID: shortcut.eventID
            )
        )
        guard status == noErr else {
            throw mapSystemEventsStatus(
                status,
                fallback: .systemEventsPermissionCheckFailed(status)
            )
        }
    }

    private func mapSystemEventsStatus(
        _ status: Int32,
        fallback: TerminalAdapterError
    ) -> TerminalAdapterError {
        switch status {
        case -1743:
            .systemEventsAutomationPermissionDenied
        case -1744:
            .systemEventsConsentRequired
        case -600:
            .systemEventsUnavailable
        default:
            fallback
        }
    }

    private func openHost(
        applicationURL: URL,
        event: NSAppleEventDescriptor?,
        host: TerminalHost,
        activates: Bool = true
    ) async throws {
        guard let failure = await applicationOpener.openApplication(
            at: applicationURL,
            initialAppleEvent: event,
            activates: activates
        ) else {
            return
        }
        if let status = failure.appleEventStatus {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: host
            )
        }
        throw TerminalAdapterError.applicationOpenFailed(failure.code)
    }

    private func sendITerm(
        command: String,
        targetFrontWindow: Bool,
        host: TerminalHost
    ) throws {
        do {
            let result = try iTermScriptExecutor.execute(
                ITermHandoffScript.invocation(
                    command: command,
                    targetFrontWindow: targetFrontWindow
                )
            )
            guard ITermHandoffScript.isSuccessfulResult(result) else {
                throw TerminalAdapterError.iTermScriptResultInvalid(
                    result.descriptorType
                )
            }
        } catch let RawAppleEventError.status(status) {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: host
            )
        }
    }
}
