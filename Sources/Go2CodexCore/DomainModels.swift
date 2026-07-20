import Foundation

public enum AgentTarget: String, CaseIterable, Codable, Hashable, Sendable {
    case codexApp = "codex-app"
    case codexCLI = "codex-cli"
    case claudeDesktopCode = "claude-desktop-code"
    case claudeCodeCLI = "claude-code-cli"

    public var kind: AgentTargetKind {
        switch self {
        case .codexApp, .claudeDesktopCode:
            .desktop
        case .codexCLI, .claudeCodeCLI:
            .cli
        }
    }

    public var displayName: String {
        switch self {
        case .codexApp:
            "Codex App"
        case .codexCLI:
            "Codex CLI"
        case .claudeDesktopCode:
            "Claude Desktop Code"
        case .claudeCodeCLI:
            "Claude Code CLI"
        }
    }
}

public enum AgentTargetKind: String, Codable, Hashable, Sendable {
    case desktop
    case cli
}

public enum TerminalHost: String, CaseIterable, Codable, Hashable, Sendable {
    case terminal = "terminal-app"
    case iTerm2 = "iterm2"

    public var bundleIdentifier: String {
        switch self {
        case .terminal:
            "com.apple.Terminal"
        case .iTerm2:
            "com.googlecode.iterm2"
        }
    }

    public var displayName: String {
        switch self {
        case .terminal:
            "Terminal"
        case .iTerm2:
            "iTerm2"
        }
    }
}

public enum SessionPlacement: String, CaseIterable, Codable, Hashable, Sendable {
    case newTab = "new-tab"
    case newWindow = "new-window"
}

public enum AlternateTrigger: String, CaseIterable, Hashable, Sendable {
    case shiftClick = "shift-click"
    case disabled
}

extension AlternateTrigger: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "option-click", Self.shiftClick.rawValue:
            self = .shiftClick
        case Self.disabled.rawValue:
            self = .disabled
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported alternate trigger"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum WorkspaceValidationError: Error, Equatable, Sendable {
    case emptyPath
    case nonFileURL
    case nonAbsolutePath
    case invalidPath
}

public struct Workspace: Codable, Equatable, Hashable, Sendable {
    public let fileURL: URL

    private enum CodingKeys: String, CodingKey {
        case fileURL
    }

    public init(absolutePath: String) throws {
        guard !absolutePath.isEmpty else {
            throw WorkspaceValidationError.emptyPath
        }
        guard absolutePath.hasPrefix("/") else {
            throw WorkspaceValidationError.nonAbsolutePath
        }
        guard !absolutePath.contains("\0") else {
            throw WorkspaceValidationError.invalidPath
        }

        try self.init(fileURL: URL(fileURLWithPath: absolutePath, isDirectory: true))
    }

    public init(fileURL: URL) throws {
        guard fileURL.isFileURL else {
            throw WorkspaceValidationError.nonFileURL
        }

        let path = fileURL.path
        guard !path.isEmpty else {
            throw WorkspaceValidationError.emptyPath
        }
        guard path.hasPrefix("/") else {
            throw WorkspaceValidationError.nonAbsolutePath
        }
        guard !path.contains("\0") else {
            throw WorkspaceValidationError.invalidPath
        }

        self.fileURL = fileURL.standardizedFileURL
    }

    public var path: String {
        fileURL.path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(fileURL: container.decode(URL.self, forKey: .fileURL))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileURL, forKey: .fileURL)
    }
}

public enum TargetUnavailableReason: Equatable, Hashable, Sendable {
    case desktopHandlerMissing(AgentTarget)
    case terminalHostMissing(TerminalHost)
    case notEvaluated
}

public enum TargetAvailability: Equatable, Hashable, Sendable {
    case available
    case unavailable(TargetUnavailableReason)

    public var isAvailable: Bool {
        self == .available
    }
}

public enum TargetAvailabilityEvidence: Equatable, Sendable {
    case desktopURLHandler(isRegistered: Bool)
    case terminalHost(TerminalHost, isRegistered: Bool)
}

public enum AvailabilityClassificationError: Error, Equatable, Sendable {
    case evidenceDoesNotMatchTarget(AgentTarget)
}

public enum TargetAvailabilityClassifier {
    public static func classify(
        target: AgentTarget,
        evidence: TargetAvailabilityEvidence
    ) throws -> TargetAvailability {
        switch (target.kind, evidence) {
        case let (.desktop, .desktopURLHandler(isRegistered)):
            isRegistered ? .available : .unavailable(.desktopHandlerMissing(target))
        case let (.cli, .terminalHost(host, isRegistered)):
            isRegistered ? .available : .unavailable(.terminalHostMissing(host))
        default:
            throw AvailabilityClassificationError.evidenceDoesNotMatchTarget(target)
        }
    }
}

public struct TargetCatalogItem: Equatable, Sendable {
    public let target: AgentTarget
    public let isDefault: Bool
    public let availability: TargetAvailability

    public init(
        target: AgentTarget,
        isDefault: Bool,
        availability: TargetAvailability
    ) {
        self.target = target
        self.isDefault = isDefault
        self.availability = availability
    }

    public var isEnabled: Bool {
        availability.isAvailable
    }
}

public enum AgentTargetCatalog {
    public static let targets: [AgentTarget] = [
        .codexApp,
        .codexCLI,
        .claudeDesktopCode,
        .claudeCodeCLI,
    ]

    public static func items(
        defaultTarget: AgentTarget,
        availability: [AgentTarget: TargetAvailability]
    ) -> [TargetCatalogItem] {
        targets.map { target in
            TargetCatalogItem(
                target: target,
                isDefault: target == defaultTarget,
                availability: availability[target] ?? .unavailable(.notEvaluated)
            )
        }
    }
}

public enum LaunchPlanningError: Error, Equatable, Sendable {
    case targetUnavailable(AgentTarget, TargetUnavailableReason)
}

public struct LaunchRequest: Equatable, Sendable {
    public let workspace: Workspace
    public let target: AgentTarget
    public let terminalHost: TerminalHost
    public let sessionPlacement: SessionPlacement

    public init(
        workspace: Workspace,
        target: AgentTarget,
        terminalHost: TerminalHost,
        sessionPlacement: SessionPlacement,
        availability: TargetAvailability
    ) throws {
        if case let .unavailable(reason) = availability {
            throw LaunchPlanningError.targetUnavailable(target, reason)
        }

        self.workspace = workspace
        self.target = target
        self.terminalHost = terminalHost
        self.sessionPlacement = sessionPlacement
    }
}
