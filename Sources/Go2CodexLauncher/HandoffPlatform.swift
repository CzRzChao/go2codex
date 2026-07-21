import AppKit
import Foundation
import Go2CodexCore

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
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { _, error in
                continuation.resume(returning: error.map {
                    ($0 as NSError).code
                })
            }
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
        initialAppleEvent: NSAppleEventDescriptor
    ) async -> TerminalApplicationOpenFailure?
}

@MainActor
struct WorkspaceTerminalApplicationOpener: TerminalApplicationOpening {
    func openApplication(
        at applicationURL: URL,
        initialAppleEvent: NSAppleEventDescriptor
    ) async -> TerminalApplicationOpenFailure? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.appleEvent = initialAppleEvent

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { _, error in
                continuation.resume(returning: error.map {
                    TerminalApplicationOpenFailure(error: $0)
                })
            }
        }
    }
}

@MainActor
protocol NativeAppleEventSending {
    func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor
}

@MainActor
struct SystemNativeAppleEventSender: NativeAppleEventSending {
    func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        try NativeAppleEvent.send(event)
    }
}

enum TerminalAdapterError: Error, Equatable, DiagnosticCodeProviding {
    case iTermScriptResourceMissing
    case iTermScriptLoadFailed
    case iTermScriptExecutionFailed
    case iTermScriptResultInvalid(UInt32)
    case iTermWindowQueryReplyInvalid(UInt32?)
    case applicationOpenFailed(Int)

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
        }
    }
}

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

    init(
        applicationState: any TerminalApplicationStateLookingUp =
            WorkspaceTerminalApplicationState(),
        applicationOpener: any TerminalApplicationOpening =
            WorkspaceTerminalApplicationOpener(),
        eventSender: any NativeAppleEventSending = SystemNativeAppleEventSender(),
        iTermScriptExecutor: any ITermHandoffScriptExecuting =
            BundledITermHandoffScriptExecutor()
    ) {
        self.applicationState = applicationState
        self.applicationOpener = applicationOpener
        self.eventSender = eventSender
        self.iTermScriptExecutor = iTermScriptExecutor
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

        let windowState: TerminalFrontWindowState
        switch host {
        case .terminal:
            windowState = placement == .newTab
                ? try frontWindowState(for: host)
                : applicationState.isRunning(
                    bundleIdentifier: host.bundleIdentifier
                ) ? .noWindow : .notRunning
        case .iTerm2:
            windowState = placement == .newTab
                ? try frontWindowState(for: host)
                : .noWindow
        }
        let placementPlan = TerminalPlacementPlanner.plan(
            for: host,
            placement: placement,
            hasWindow: windowState == .hasWindow
        )

        let targetFrontWindow: Bool
        switch placementPlan {
        case .createTabInFrontWindow:
            targetFrontWindow = true
        case .createWindow:
            targetFrontWindow = false
        case .unsupported:
            throw TerminalHandoffError.unsupportedPlacement(host, placement)
        }

        switch host {
        case .terminal:
            try await sendTerminal(
                command: command.line,
                host: host,
                applicationURL: applicationURL,
                isRunning: windowState != .notRunning
            )
        case .iTerm2:
            try sendITerm(
                command: command.line,
                targetFrontWindow: targetFrontWindow,
                host: host
            )
        }
        return .acceptedByTerminalHost
    }

    private func frontWindowState(
        for host: TerminalHost
    ) throws -> TerminalFrontWindowState {
        guard applicationState.isRunning(
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
        isRunning: Bool
    ) async throws {
        let event = NativeAppleEvent.terminalNewWindow(command: command)
        guard isRunning else {
            try await openTerminal(
                applicationURL: applicationURL,
                event: event,
                host: host
            )
            return
        }

        do {
            _ = try eventSender.send(event)
        } catch RawAppleEventError.status(-600) {
            try await openTerminal(
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

    private func openTerminal(
        applicationURL: URL,
        event: NSAppleEventDescriptor,
        host: TerminalHost
    ) async throws {
        guard let failure = await applicationOpener.openApplication(
            at: applicationURL,
            initialAppleEvent: event
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
