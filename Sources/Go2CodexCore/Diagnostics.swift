import Foundation

public enum DiagnosticPolicy: String, CaseIterable, Sendable {
    case debug
    case release
}

public enum DiagnosticStage: String, CaseIterable, Sendable {
    case preferencesRead = "preferences.read"
    case preferencesWrite = "preferences.write"
    case settingsOpen = "settings.open"
    case launcherInternal = "launcher.internal"
    case finderWorkspace = "finder.workspace"
    case targetAvailability = "target.availability"
    case desktopURL = "desktop.url"
    case desktopHandoff = "desktop.handoff"
    case terminalCommand = "terminal.command"
    case terminalHandoff = "terminal.handoff"
    case targetPicker = "target.picker"
    case finderToolbarStatus = "finder-toolbar.status"
    case finderToolbarMutation = "finder-toolbar.mutation"
    case transaction = "transaction"
}

public struct DiagnosticCode: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
        if !rawValue.isEmpty,
           rawValue.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            self.rawValue = rawValue
        } else {
            self.rawValue = "invalid-diagnostic-code"
        }
    }
}

public protocol DiagnosticCodeProviding: Error, Sendable {
    var diagnosticCode: DiagnosticCode { get }
}

public struct DiagnosticInput: Sendable {
    public let applicationVersion: String
    public let systemVersion: String
    public let stage: DiagnosticStage
    public let target: AgentTarget?
    public let terminalHost: TerminalHost?
    public let errorCode: DiagnosticCode
    public let errorDetail: String?
    public let workspace: Workspace?
    public let generatedCommand: String?

    public init(
        applicationVersion: String,
        systemVersion: String,
        stage: DiagnosticStage,
        target: AgentTarget? = nil,
        terminalHost: TerminalHost? = nil,
        errorCode: DiagnosticCode,
        errorDetail: String? = nil,
        workspace: Workspace? = nil,
        generatedCommand: String? = nil
    ) {
        self.applicationVersion = applicationVersion
        self.systemVersion = systemVersion
        self.stage = stage
        self.target = target
        self.terminalHost = terminalHost
        self.errorCode = errorCode
        self.errorDetail = errorDetail
        self.workspace = workspace
        self.generatedCommand = generatedCommand
    }
}

public struct DiagnosticRecord: Equatable, Sendable {
    public let policy: DiagnosticPolicy
    public let applicationVersion: String
    public let systemVersion: String
    public let stage: DiagnosticStage
    public let target: AgentTarget?
    public let terminalHost: TerminalHost?
    public let errorCode: DiagnosticCode
    public let detail: String?
    public let workspacePath: String?
    public let generatedCommand: String?

    init(
        policy: DiagnosticPolicy,
        applicationVersion: String,
        systemVersion: String,
        stage: DiagnosticStage,
        target: AgentTarget?,
        terminalHost: TerminalHost?,
        errorCode: DiagnosticCode,
        detail: String?,
        workspacePath: String?,
        generatedCommand: String?
    ) {
        self.policy = policy
        self.applicationVersion = applicationVersion
        self.systemVersion = systemVersion
        self.stage = stage
        self.target = target
        self.terminalHost = terminalHost
        self.errorCode = errorCode
        self.detail = detail
        self.workspacePath = workspacePath
        self.generatedCommand = generatedCommand
    }

    public var rendered: String {
        var lines = [
            "applicationVersion=\(applicationVersion)",
            "systemVersion=\(systemVersion)",
            "stage=\(stage.rawValue)",
            "errorCode=\(errorCode.rawValue)",
        ]
        if let target {
            lines.append("target=\(target.rawValue)")
        }
        if let terminalHost {
            lines.append("terminalHost=\(terminalHost.rawValue)")
        }
        if let detail {
            lines.append("detail=\(detail)")
        }
        if let workspacePath {
            lines.append("workspace=\(workspacePath)")
        }
        if let generatedCommand {
            lines.append("command=\(generatedCommand)")
        }
        return lines.joined(separator: "\n")
    }
}

public enum DiagnosticSanitizer {
    public static func sanitize(
        _ input: DiagnosticInput,
        policy: DiagnosticPolicy
    ) -> DiagnosticRecord {
        switch policy {
        case .debug:
            return DiagnosticRecord(
                policy: policy,
                applicationVersion: input.applicationVersion,
                systemVersion: input.systemVersion,
                stage: input.stage,
                target: input.target,
                terminalHost: input.terminalHost,
                errorCode: input.errorCode,
                detail: input.errorDetail,
                workspacePath: input.workspace?.path,
                generatedCommand: input.generatedCommand
            )
        case .release:
            return DiagnosticRecord(
                policy: policy,
                applicationVersion: input.applicationVersion,
                systemVersion: input.systemVersion,
                stage: input.stage,
                target: input.target,
                terminalHost: input.terminalHost,
                errorCode: input.errorCode,
                detail: releaseDetail(from: input),
                workspacePath: nil,
                generatedCommand: nil
            )
        }
    }

    private static func releaseDetail(from input: DiagnosticInput) -> String? {
        guard var detail = input.errorDetail else {
            return nil
        }

        if input.workspace?.path == "/" {
            return nil
        }

        var sensitiveValues: [String] = []
        if let command = input.generatedCommand, !command.isEmpty {
            sensitiveValues.append(command)
        }
        if let workspace = input.workspace {
            sensitiveValues.append(workspace.fileURL.absoluteString)
            sensitiveValues.append(workspace.path)
            sensitiveValues.append(POSIXShellQuoting.singleQuote(workspace.path))
            if let encodedPath = workspace.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                sensitiveValues.append(encodedPath)
            }
            if let percentEncodedPath = URLComponents(
                url: workspace.fileURL,
                resolvingAgainstBaseURL: false
            )?.percentEncodedPath {
                sensitiveValues.append(percentEncodedPath)
            }
            for target in AgentTargetCatalog.targets where target.kind == .desktop {
                guard let desktopURL = try? DesktopURLBuilder.url(for: target, workspace: workspace),
                      let components = URLComponents(
                        url: desktopURL,
                        resolvingAgainstBaseURL: false
                      ) else {
                    continue
                }
                sensitiveValues.append(desktopURL.absoluteString)
                if let query = components.percentEncodedQuery,
                   let separator = query.firstIndex(of: "=") {
                    sensitiveValues.append(String(query[query.index(after: separator)...]))
                }
            }
        }

        for sensitiveValue in Set(sensitiveValues).sorted(by: { $0.count > $1.count })
        where !sensitiveValue.isEmpty {
            detail = detail.replacingOccurrences(of: sensitiveValue, with: "<redacted>")
        }

        if let workspace = input.workspace, detail.contains(workspace.path) {
            return nil
        }
        if let command = input.generatedCommand,
           !command.isEmpty,
           detail.contains(command) {
            return nil
        }
        return detail
    }
}
