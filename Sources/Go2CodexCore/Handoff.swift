import Foundation

public struct DesktopURLContract: Equatable, Sendable {
    public let scheme: String
    public let host: String
    public let path: String
    public let workspaceQueryName: String

    public init(
        scheme: String,
        host: String,
        path: String,
        workspaceQueryName: String
    ) {
        self.scheme = scheme
        self.host = host
        self.path = path
        self.workspaceQueryName = workspaceQueryName
    }
}

public enum DesktopURLBuildError: Error, Equatable, Sendable,
    DiagnosticCodeProviding {
    case unsupportedTarget(AgentTarget)
    case malformedComponents(AgentTarget)

    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .unsupportedTarget:
            DiagnosticCode(rawValue: "desktop-target-unsupported")
        case .malformedComponents:
            DiagnosticCode(rawValue: "desktop-url-malformed")
        }
    }
}

public struct VerifiedDesktopTargetHandler: Equatable, Sendable {
    public let applicationURL: URL

    fileprivate init(applicationURL: URL) {
        self.applicationURL = applicationURL
    }
}

public enum DesktopURLBuilder {
    public static func contract(for target: AgentTarget) throws -> DesktopURLContract {
        switch target {
        case .codexApp:
            DesktopURLContract(
                scheme: "codex",
                host: "new",
                path: "",
                workspaceQueryName: "path"
            )
        case .claudeDesktopCode:
            DesktopURLContract(
                scheme: "claude",
                host: "code",
                path: "/new",
                workspaceQueryName: "folder"
            )
        case .codexCLI, .claudeCodeCLI:
            throw DesktopURLBuildError.unsupportedTarget(target)
        }
    }

    public static func url(for target: AgentTarget, workspace: Workspace) throws -> URL {
        let contract = try contract(for: target)
        var components = URLComponents()
        components.scheme = contract.scheme
        components.host = contract.host
        components.path = contract.path
        components.queryItems = [
            URLQueryItem(name: contract.workspaceQueryName, value: workspace.path),
        ]

        guard let url = components.url else {
            throw DesktopURLBuildError.malformedComponents(target)
        }
        return url
    }
}

public enum DesktopTargetHandlerPolicy {
    public static func expectedBundleIdentifier(for target: AgentTarget) throws -> String {
        switch target {
        case .codexApp:
            "com.openai.codex"
        case .claudeDesktopCode:
            "com.anthropic.claudefordesktop"
        case .codexCLI, .claudeCodeCLI:
            throw DesktopURLBuildError.unsupportedTarget(target)
        }
    }

    public static func accepts(
        target: AgentTarget,
        handlerBundleIdentifier: String?
    ) -> Bool {
        guard let expected = try? expectedBundleIdentifier(for: target) else {
            return false
        }
        return handlerBundleIdentifier == expected
    }

    public static func verify(
        target: AgentTarget,
        applicationURL: URL?,
        handlerBundleIdentifier: String?
    ) -> VerifiedDesktopTargetHandler? {
        guard accepts(
            target: target,
            handlerBundleIdentifier: handlerBundleIdentifier
        ),
              let applicationURL,
              applicationURL.isFileURL,
              applicationURL.path.hasPrefix("/") else {
            return nil
        }
        return VerifiedDesktopTargetHandler(applicationURL: applicationURL)
    }
}

public enum CLIExecutable: String, CaseIterable, Codable, Sendable {
    case codex
    case claude

    public init(target: AgentTarget) throws {
        switch target {
        case .codexCLI:
            self = .codex
        case .claudeCodeCLI:
            self = .claude
        case .codexApp, .claudeDesktopCode:
            throw TerminalCommandBuildError.unsupportedTarget(target)
        }
    }
}

public enum POSIXShellQuoting {
    public static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum TerminalCommandBuildError: Error, Equatable, Sendable,
    DiagnosticCodeProviding {
    case unsupportedTarget(AgentTarget)

    public var diagnosticCode: DiagnosticCode {
        DiagnosticCode(rawValue: "terminal-target-unsupported")
    }
}

public struct TerminalCommand: Equatable, Sendable {
    public let executable: CLIExecutable
    public let line: String

    public init(executable: CLIExecutable, line: String) {
        self.executable = executable
        self.line = line
    }
}

public enum TerminalCommandBuilder {
    public static func command(
        for target: AgentTarget,
        workspace: Workspace
    ) throws -> TerminalCommand {
        let executable = try CLIExecutable(target: target)
        let line = "cd \(POSIXShellQuoting.singleQuote(workspace.path)) && \(executable.rawValue)"
        return TerminalCommand(executable: executable, line: line)
    }
}

public struct FourCharacterCode: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init?(ascii: String) {
        let bytes = Array(ascii.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 128 }) else {
            return nil
        }
        rawValue = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public var ascii: String {
        let bytes = [
            UInt8((rawValue >> 24) & 0xff),
            UInt8((rawValue >> 16) & 0xff),
            UInt8((rawValue >> 8) & 0xff),
            UInt8(rawValue & 0xff),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum FinderAppleEventContract {
    public static let targetBundleIdentifier = "com.apple.finder"
    public static let eventClass = FourCharacterCode(rawValue: 0x636f7265)
    public static let eventID = FourCharacterCode(rawValue: 0x67657464)
    public static let directObjectKeyword = FourCharacterCode(rawValue: 0x2d2d2d2d)
    public static let urlProperty = FourCharacterCode(rawValue: 0x7055524c)
    public static let targetProperty = FourCharacterCode(rawValue: 0x66767467)
    public static let browserWindowClass = FourCharacterCode(rawValue: 0x62726f77)
    public static let absoluteIndex = 1
}

public enum TerminalAppleEventContract {
    public static let terminalDoScriptClass = FourCharacterCode(rawValue: 0x636f7265)
    public static let terminalDoScriptID = FourCharacterCode(rawValue: 0x646f7363)
    public static let directParameterKeyword = FourCharacterCode(rawValue: 0x2d2d2d2d)
    public static let terminalTargetKeyword = FourCharacterCode(rawValue: 0x6b66696c)
    public static let iTermClass = FourCharacterCode(rawValue: 0x4974726d)
    public static let iTermCreateWindowID = FourCharacterCode(rawValue: 0x6e77776e)
    public static let iTermCreateTabID = FourCharacterCode(rawValue: 0x6e74776e)
    public static let iTermWriteTextID = FourCharacterCode(rawValue: 0x736e7478)
    public static let iTermCurrentWindowProperty = FourCharacterCode(rawValue: 0x4372776e)
    public static let subjectAttribute = FourCharacterCode(rawValue: 0x7375626a)
    public static let iTermTextKeyword = FourCharacterCode(rawValue: 0x54657874)
    public static let iTermNewlineKeyword = FourCharacterCode(rawValue: 0x57746e6c)
}
