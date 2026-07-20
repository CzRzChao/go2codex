import Foundation

public protocol PreferencesEnvelopeStoring: Sendable {
    func readEnvelopeData() async throws -> Data?
    func replaceEnvelopeData(with data: Data) async throws
}

@MainActor
public protocol LauncherPreferencesLoading {
    func loadPreferences() throws -> PreferencesLoadState
}

@MainActor
public protocol LauncherSettingsOpening {
    func openSettings() async throws
}

@MainActor
public protocol FinderWorkspaceResolving {
    func resolveFrontmostWorkspace() throws -> Workspace
}

@MainActor
public protocol TargetAvailabilityLookingUp {
    func availability(
        for target: AgentTarget,
        workspace: Workspace,
        terminalHost: TerminalHost
    ) throws -> TargetAvailability
}

@MainActor
public protocol TargetPicking {
    func action(
        for plan: TargetPickerPlan,
        at point: ScreenPoint
    ) async throws -> TargetPickerAction
}

public enum HandoffAcceptance: Equatable, Sendable {
    case acceptedByLaunchServices
    case acceptedByTerminalHost
}

@MainActor
public protocol DesktopHandoffPerforming {
    func open(
        _ url: URL,
        for target: AgentTarget
    ) async throws -> HandoffAcceptance
}

@MainActor
public protocol TerminalHandoffPerforming {
    func open(
        _ command: TerminalCommand,
        in host: TerminalHost,
        placement: SessionPlacement
    ) async throws -> HandoffAcceptance
}

public struct AliasResolution: Equatable, Sendable {
    public let fileURL: URL
    public let bookmarkDataWasStale: Bool

    public init(fileURL: URL, bookmarkDataWasStale: Bool) {
        self.fileURL = fileURL
        self.bookmarkDataWasStale = bookmarkDataWasStale
    }
}

public protocol FinderAliasResolving: Sendable {
    func resolve(aliasRecord: Data) throws -> AliasResolution
}

public protocol CoreClock: Sendable {
    func now() -> Date
}

public protocol RetryScheduling: Sendable {
    func sleep(for duration: Duration) async throws
}

public enum PreferencesStoreError: Error, Equatable, Sendable, DiagnosticCodeProviding {
    case readFailed
    case writeFailed

    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .readFailed:
            DiagnosticCode(rawValue: "preferences-read-failed")
        case .writeFailed:
            DiagnosticCode(rawValue: "preferences-write-failed")
        }
    }
}

public enum FinderWorkspaceError: Error, Equatable, Sendable, DiagnosticCodeProviding {
    case automationPermissionDenied
    case consentRequired
    case replyTimeout
    case finderUnavailable
    case objectUnavailable
    case malformedReply
    case unsupportedLocation
    case inaccessibleWorkspace
    case invalidWorkspace
    case appleEventFailure(status: Int32)

    public static func mapAppleEventStatus(_ status: Int32) -> FinderWorkspaceError {
        switch status {
        case -1743:
            .automationPermissionDenied
        case -1744:
            .consentRequired
        case -1712:
            .replyTimeout
        case -600:
            .finderUnavailable
        case -1728, -1719:
            .objectUnavailable
        default:
            .appleEventFailure(status: status)
        }
    }

    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .automationPermissionDenied:
            DiagnosticCode(rawValue: "finder-automation-denied")
        case .consentRequired:
            DiagnosticCode(rawValue: "finder-consent-required")
        case .replyTimeout:
            DiagnosticCode(rawValue: "finder-reply-timeout")
        case .finderUnavailable:
            DiagnosticCode(rawValue: "finder-unavailable")
        case .objectUnavailable:
            DiagnosticCode(rawValue: "finder-object-unavailable")
        case .malformedReply:
            DiagnosticCode(rawValue: "finder-malformed-reply")
        case .unsupportedLocation:
            DiagnosticCode(rawValue: "finder-unsupported-location")
        case .inaccessibleWorkspace:
            DiagnosticCode(rawValue: "workspace-inaccessible")
        case .invalidWorkspace:
            DiagnosticCode(rawValue: "workspace-invalid")
        case .appleEventFailure:
            DiagnosticCode(rawValue: "finder-apple-event-failed")
        }
    }
}

public enum AvailabilityLookupError: Error, Equatable, Sendable, DiagnosticCodeProviding {
    case lookupFailed(AgentTarget)
    case inconsistentEvidence(AgentTarget)

    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .lookupFailed:
            DiagnosticCode(rawValue: "availability-lookup-failed")
        case .inconsistentEvidence:
            DiagnosticCode(rawValue: "availability-evidence-mismatch")
        }
    }
}

public enum DesktopHandoffError: Error, Equatable, Sendable, DiagnosticCodeProviding {
    case unsupportedTarget(AgentTarget)
    case handlerUnavailable(AgentTarget)
    case malformedURL(AgentTarget)
    case openFailed(code: Int)

    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .unsupportedTarget:
            DiagnosticCode(rawValue: "desktop-target-unsupported")
        case .handlerUnavailable:
            DiagnosticCode(rawValue: "desktop-handler-unavailable")
        case .malformedURL:
            DiagnosticCode(rawValue: "desktop-url-malformed")
        case .openFailed:
            DiagnosticCode(rawValue: "desktop-open-failed")
        }
    }
}

public enum TerminalHandoffError: Error, Equatable, Sendable, DiagnosticCodeProviding {
    case unsupportedTarget(AgentTarget)
    case hostUnavailable(TerminalHost)
    case unsupportedPlacement(TerminalHost, SessionPlacement)
    case automationPermissionDenied(TerminalHost)
    case consentRequired(TerminalHost)
    case replyTimeout(TerminalHost)
    case terminalUnavailable(TerminalHost)
    case appleEventFailure(TerminalHost, status: Int32)

    public static func mapAppleEventStatus(
        _ status: Int32,
        host: TerminalHost
    ) -> TerminalHandoffError {
        switch status {
        case -1743:
            .automationPermissionDenied(host)
        case -1744:
            .consentRequired(host)
        case -1712:
            .replyTimeout(host)
        case -600, -1719:
            .terminalUnavailable(host)
        default:
            .appleEventFailure(host, status: status)
        }
    }

    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .unsupportedTarget:
            DiagnosticCode(rawValue: "terminal-target-unsupported")
        case .hostUnavailable:
            DiagnosticCode(rawValue: "terminal-host-unavailable")
        case .unsupportedPlacement:
            DiagnosticCode(rawValue: "terminal-placement-unsupported")
        case .automationPermissionDenied:
            DiagnosticCode(rawValue: "terminal-automation-denied")
        case .consentRequired:
            DiagnosticCode(rawValue: "terminal-consent-required")
        case .replyTimeout:
            DiagnosticCode(rawValue: "terminal-reply-timeout")
        case .terminalUnavailable:
            DiagnosticCode(rawValue: "terminal-unavailable")
        case .appleEventFailure:
            DiagnosticCode(rawValue: "terminal-apple-event-failed")
        }
    }
}

public enum AliasResolutionError: Error, Equatable, Sendable, DiagnosticCodeProviding {
    case emptyAliasRecord
    case conversionFailed
    case bookmarkResolutionFailed
    case nonFileURL
    case targetMissing
    case storedURLConflict
    case expectedLauncherConflict

    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .emptyAliasRecord:
            DiagnosticCode(rawValue: "alias-empty")
        case .conversionFailed:
            DiagnosticCode(rawValue: "alias-conversion-failed")
        case .bookmarkResolutionFailed:
            DiagnosticCode(rawValue: "alias-bookmark-resolution-failed")
        case .nonFileURL:
            DiagnosticCode(rawValue: "alias-non-file-url")
        case .targetMissing:
            DiagnosticCode(rawValue: "alias-target-missing")
        case .storedURLConflict:
            DiagnosticCode(rawValue: "alias-stored-url-conflict")
        case .expectedLauncherConflict:
            DiagnosticCode(rawValue: "alias-expected-launcher-conflict")
        }
    }
}

public enum FinderAliasAgreement {
    public static func validate(
        resolution: AliasResolution,
        storedURL: URL,
        expectedLauncherURL: URL
    ) throws -> URL {
        guard resolution.fileURL.isFileURL else {
            throw AliasResolutionError.nonFileURL
        }

        let resolved = resolution.fileURL.standardizedFileURL
        guard storedURL.isFileURL,
              storedURL.standardizedFileURL == resolved else {
            throw AliasResolutionError.storedURLConflict
        }
        guard expectedLauncherURL.isFileURL,
              expectedLauncherURL.standardizedFileURL == resolved else {
            throw AliasResolutionError.expectedLauncherConflict
        }
        return resolved
    }
}
