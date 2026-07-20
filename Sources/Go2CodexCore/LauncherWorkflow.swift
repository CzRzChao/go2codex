import Foundation

public enum LauncherAutomationPermissionContext: Equatable, Sendable {
    case finder
    case terminal(TerminalHost)
}

public struct LauncherWorkflowFailure: Error, Equatable, Sendable, DiagnosticCodeProviding {
    public let stage: DiagnosticStage
    public let code: DiagnosticCode
    public let detail: String
    public let target: AgentTarget?
    public let terminalHost: TerminalHost?
    public let workspace: Workspace?
    public let generatedCommand: String?
    public let permissionContext: LauncherAutomationPermissionContext?

    public var diagnosticCode: DiagnosticCode {
        code
    }

    public init(
        error: any Error,
        stage: DiagnosticStage,
        target: AgentTarget? = nil,
        terminalHost: TerminalHost? = nil,
        workspace: Workspace? = nil,
        generatedCommand: String? = nil
    ) {
        self.stage = stage
        code = (error as? any DiagnosticCodeProviding)?.diagnosticCode
            ?? DiagnosticCode(rawValue: "launcher-unexpected-error")
        detail = String(reflecting: error)
        self.target = target
        self.terminalHost = terminalHost
        self.workspace = workspace
        self.generatedCommand = generatedCommand
        permissionContext = Self.permissionContext(
            for: error,
            terminalHost: terminalHost
        )
    }

    private static func permissionContext(
        for error: any Error,
        terminalHost: TerminalHost?
    ) -> LauncherAutomationPermissionContext? {
        if let finderError = error as? FinderWorkspaceError {
            switch finderError {
            case .automationPermissionDenied, .consentRequired:
                return .finder
            default:
                break
            }
        }
        if let terminalError = error as? TerminalHandoffError {
            switch terminalError {
            case let .automationPermissionDenied(host),
                 let .consentRequired(host):
                return .terminal(host)
            default:
                break
            }
        }
        if let terminalHost,
           codeIndicatesAutomationPermission(error) {
            return .terminal(terminalHost)
        }
        return nil
    }

    private static func codeIndicatesAutomationPermission(
        _ error: any Error
    ) -> Bool {
        guard let provider = error as? any DiagnosticCodeProviding else {
            return false
        }
        return provider.diagnosticCode.rawValue.contains("automation-denied")
            || provider.diagnosticCode.rawValue.contains("consent-required")
    }
}

public enum LauncherWorkflowOutcome: Equatable, Sendable {
    case settingsOpened
    case cancelled
    case handoffAccepted(
        target: AgentTarget,
        terminalHost: TerminalHost?,
        acceptance: HandoffAcceptance
    )
}

public enum LauncherWorkflowAvailabilityError: Error, Equatable, Sendable,
    DiagnosticCodeProviding {
    case targetUnavailable(AgentTarget, TargetUnavailableReason)

    public var diagnosticCode: DiagnosticCode {
        switch self {
        case let .targetUnavailable(target, reason):
            switch reason {
            case .desktopHandlerMissing:
                DiagnosticCode(rawValue: "\(target.rawValue)-handler-unavailable")
            case let .terminalHostMissing(host):
                DiagnosticCode(rawValue: "\(host.rawValue)-unavailable")
            case .notEvaluated:
                DiagnosticCode(rawValue: "target-availability-not-evaluated")
            }
        }
    }
}

public enum LauncherWorkflowUnexpectedError: Error, Equatable, Sendable,
    DiagnosticCodeProviding {
    case unexpected

    public var diagnosticCode: DiagnosticCode {
        DiagnosticCode(rawValue: "launcher-unexpected-error")
    }
}

public enum LauncherWorkflowInvocationError: Error, Equatable, Sendable,
    DiagnosticCodeProviding {
    case optionModifierUnsupported

    public var diagnosticCode: DiagnosticCode {
        DiagnosticCode(rawValue: "finder-option-modifier-unsupported")
    }
}

public typealias DesktopURLBuildingOperation = @MainActor (
    AgentTarget,
    Workspace
) throws -> URL

public typealias TerminalCommandBuildingOperation = @MainActor (
    AgentTarget,
    Workspace
) throws -> TerminalCommand

@MainActor
public struct LauncherWorkflow {
    private let preferencesLoader: any LauncherPreferencesLoading
    private let settingsOpener: any LauncherSettingsOpening
    private let workspaceResolver: any FinderWorkspaceResolving
    private let availabilityLookup: any TargetAvailabilityLookingUp
    private let targetPicker: any TargetPicking
    private let desktopHandoff: any DesktopHandoffPerforming
    private let terminalHandoff: any TerminalHandoffPerforming
    private let desktopURLBuilder: DesktopURLBuildingOperation
    private let terminalCommandBuilder: TerminalCommandBuildingOperation

    public init(
        preferencesLoader: any LauncherPreferencesLoading,
        settingsOpener: any LauncherSettingsOpening,
        workspaceResolver: any FinderWorkspaceResolving,
        availabilityLookup: any TargetAvailabilityLookingUp,
        targetPicker: any TargetPicking,
        desktopHandoff: any DesktopHandoffPerforming,
        terminalHandoff: any TerminalHandoffPerforming,
        desktopURLBuilder: @escaping DesktopURLBuildingOperation = {
            try DesktopURLBuilder.url(for: $0, workspace: $1)
        },
        terminalCommandBuilder: @escaping TerminalCommandBuildingOperation = {
            try TerminalCommandBuilder.command(for: $0, workspace: $1)
        }
    ) {
        self.preferencesLoader = preferencesLoader
        self.settingsOpener = settingsOpener
        self.workspaceResolver = workspaceResolver
        self.availabilityLookup = availabilityLookup
        self.targetPicker = targetPicker
        self.desktopHandoff = desktopHandoff
        self.terminalHandoff = terminalHandoff
        self.desktopURLBuilder = desktopURLBuilder
        self.terminalCommandBuilder = terminalCommandBuilder
    }

    public func run(
        modifiers: InvocationModifierFlags,
        pointerLocation: ScreenPoint
    ) async throws -> LauncherWorkflowOutcome {
        let loadState: PreferencesLoadState
        do {
            loadState = try preferencesLoader.loadPreferences()
        } catch {
            return try await openSettings()
        }

        let envelope: PreferencesEnvelope
        switch loadState {
        case let .configured(configured):
            envelope = configured
        case .firstRun, .recoveryRequired:
            return try await openSettings()
        }

        if modifiers.contains(.option) {
            throw LauncherWorkflowFailure(
                error: LauncherWorkflowInvocationError.optionModifierUnsupported,
                stage: .finderWorkspace
            )
        }

        let workspace: Workspace
        do {
            workspace = try workspaceResolver.resolveFrontmostWorkspace()
        } catch {
            throw LauncherWorkflowFailure(
                error: error,
                stage: .finderWorkspace
            )
        }

        let target: AgentTarget
        if AlternateTriggerMatcher.matches(
            envelope.alternateTrigger,
            modifiers: modifiers
        ) {
            var availability: [AgentTarget: TargetAvailability] = [:]
            for candidate in AgentTargetCatalog.targets {
                do {
                    availability[candidate] = try availabilityLookup.availability(
                        for: candidate,
                        workspace: workspace,
                        terminalHost: envelope.defaultTerminalHost
                    )
                } catch {
                    throw LauncherWorkflowFailure(
                        error: error,
                        stage: .targetAvailability,
                        target: candidate,
                        terminalHost: envelope.defaultTerminalHost,
                        workspace: workspace
                    )
                }
            }
            let plan = TargetPickerPlan(
                defaultTarget: envelope.defaultTarget,
                availability: availability
            )

            let action: TargetPickerAction
            do {
                action = try await targetPicker.action(
                    for: plan,
                    at: pointerLocation
                )
            } catch {
                throw LauncherWorkflowFailure(
                    error: error,
                    stage: .targetPicker,
                    terminalHost: envelope.defaultTerminalHost,
                    workspace: workspace
                )
            }

            var selection = TargetPickerSelectionStateMachine(plan: plan)
            do {
                switch try selection.resolve(action) {
                case let .selected(selected):
                    target = selected
                case .cancelled:
                    return .cancelled
                }
            } catch {
                throw LauncherWorkflowFailure(
                    error: error,
                    stage: .targetPicker,
                    target: selectedTarget(for: action, in: plan),
                    terminalHost: envelope.defaultTerminalHost,
                    workspace: workspace
                )
            }
        } else {
            target = envelope.defaultTarget
        }

        let availability: TargetAvailability
        do {
            availability = try availabilityLookup.availability(
                for: target,
                workspace: workspace,
                terminalHost: envelope.defaultTerminalHost
            )
            if case let .unavailable(reason) = availability {
                throw LauncherWorkflowAvailabilityError.targetUnavailable(
                    target,
                    reason
                )
            }
        } catch {
            throw LauncherWorkflowFailure(
                error: error,
                stage: .targetAvailability,
                target: target,
                terminalHost: envelope.defaultTerminalHost,
                workspace: workspace
            )
        }

        let request: LaunchRequest
        do {
            request = try LaunchRequest(
                workspace: workspace,
                target: target,
                terminalHost: envelope.defaultTerminalHost,
                sessionPlacement: envelope.sessionPlacement,
                availability: availability
            )
        } catch {
            throw LauncherWorkflowFailure(
                error: LauncherWorkflowUnexpectedError.unexpected,
                stage: .targetAvailability,
                target: target,
                terminalHost: envelope.defaultTerminalHost,
                workspace: workspace
            )
        }

        switch request.target.kind {
        case .desktop:
            return try await performDesktopHandoff(request)
        case .cli:
            return try await performTerminalHandoff(request)
        }
    }

    private func openSettings() async throws -> LauncherWorkflowOutcome {
        do {
            try await settingsOpener.openSettings()
            return .settingsOpened
        } catch {
            throw LauncherWorkflowFailure(
                error: error,
                stage: .settingsOpen
            )
        }
    }

    private func performDesktopHandoff(
        _ request: LaunchRequest
    ) async throws -> LauncherWorkflowOutcome {
        let url: URL
        do {
            url = try desktopURLBuilder(request.target, request.workspace)
        } catch {
            throw LauncherWorkflowFailure(
                error: error,
                stage: .desktopURL,
                target: request.target,
                workspace: request.workspace
            )
        }

        do {
            let acceptance = try await desktopHandoff.open(
                url,
                for: request.target
            )
            return .handoffAccepted(
                target: request.target,
                terminalHost: nil,
                acceptance: acceptance
            )
        } catch {
            throw LauncherWorkflowFailure(
                error: error,
                stage: .desktopHandoff,
                target: request.target,
                workspace: request.workspace
            )
        }
    }

    private func performTerminalHandoff(
        _ request: LaunchRequest
    ) async throws -> LauncherWorkflowOutcome {
        let command: TerminalCommand
        do {
            command = try terminalCommandBuilder(
                request.target,
                request.workspace
            )
        } catch {
            throw LauncherWorkflowFailure(
                error: error,
                stage: .terminalCommand,
                target: request.target,
                terminalHost: request.terminalHost,
                workspace: request.workspace
            )
        }

        do {
            let acceptance = try await terminalHandoff.open(
                command,
                in: request.terminalHost,
                placement: request.sessionPlacement
            )
            return .handoffAccepted(
                target: request.target,
                terminalHost: request.terminalHost,
                acceptance: acceptance
            )
        } catch {
            throw LauncherWorkflowFailure(
                error: error,
                stage: .terminalHandoff,
                target: request.target,
                terminalHost: request.terminalHost,
                workspace: request.workspace,
                generatedCommand: command.line
            )
        }
    }

    private func selectedTarget(
        for action: TargetPickerAction,
        in plan: TargetPickerPlan
    ) -> AgentTarget? {
        guard case let .select(index) = action,
              plan.items.indices.contains(index) else {
            return nil
        }
        return plan.items[index].target
    }
}
