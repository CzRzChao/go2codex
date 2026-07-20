import Foundation

public struct FourCharacterCode: Equatable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    public init?(_ text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        rawValue = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public var description: String {
        let bytes: [UInt8] = [
            UInt8((rawValue >> 24) & 0xff),
            UInt8((rawValue >> 16) & 0xff),
            UInt8((rawValue >> 8) & 0xff),
            UInt8(rawValue & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

private func code(_ text: String) -> UInt32 {
    FourCharacterCode(text)!.rawValue
}

public enum AppleEventCodes {
    public static let core = code("core")
    public static let getData = code("getd")
    public static let doScript = code("dosc")
    public static let iTerm = code("Itrm")
    public static let iTermNewWindow = code("nwwn")
    public static let iTermNewTab = code("ntwn")
    public static let iTermWrite = code("sntx")

    public static let directObject = code("----")
    public static let errorNumber = code("errn")
    public static let addressAttribute = code("addr")
    public static let applicationBundleIdentifier = code("bund")
    public static let terminalTarget = code("kfil")
    public static let iTermCommand = code("Nwcm")
    public static let iTermText = code("Text")
    public static let iTermNewline = code("Wtnl")

    public static let objectSpecifier = code("obj ")
    public static let desiredClass = code("want")
    public static let container = code("from")
    public static let keyForm = code("form")
    public static let keyData = code("seld")
    public static let propertyClass = code("prop")
    public static let propertyForm = code("prop")
    public static let absolutePositionForm = code("indx")

    public static let finderWindow = code("brow")
    public static let finderTarget = code("fvtg")
    public static let finderURL = code("pURL")
    public static let selection = code("sele")
    public static let window = code("cwin")
    public static let iTermCurrentWindow = code("Crwn")
    public static let iTermCurrentSession = code("Wcsn")
}

public enum TerminalHost: String, CaseIterable {
    case terminal
    case iTerm2 = "iterm2"

    public var bundleIdentifier: String {
        switch self {
        case .terminal:
            return "com.apple.Terminal"
        case .iTerm2:
            return "com.googlecode.iterm2"
        }
    }
}

public enum SessionPlacement: String, CaseIterable {
    case tab
    case window
}

public enum TerminalPlacementAction: Equatable {
    case createWindow
    case createTabInCurrentWindow
    case unsupported
}

public enum TerminalPlacementContract {
    public static func resolve(
        host: TerminalHost,
        placement: SessionPlacement,
        hasWindow: Bool
    ) -> TerminalPlacementAction {
        switch (host, placement, hasWindow) {
        case (.terminal, .tab, true):
            .unsupported
        case (.iTerm2, .tab, true):
            .createTabInCurrentWindow
        case (_, .tab, false), (_, .window, false), (_, .window, true):
            .createWindow
        }
    }
}

public enum ProbeInvocation: Equatable {
    case inspect
    case finder
    case terminalHost(TerminalHost, SessionPlacement)

    public var performsSystemControl: Bool {
        switch self {
        case .inspect:
            return false
        case .finder, .terminalHost:
            return true
        }
    }

    public static func parse(_ arguments: [String]) throws -> ProbeInvocation {
        switch arguments {
        case ["inspect"]:
            return .inspect
        case ["finder"]:
            return .finder
        case let values where values.count == 3 && values[0] == "terminal-host":
            let hostValue = values[1]
            let placementValue = values[2]
            guard let host = TerminalHost(rawValue: hostValue) else {
                throw ProbeArgumentError.invalidHost(hostValue)
            }
            guard let placement = SessionPlacement(rawValue: placementValue) else {
                throw ProbeArgumentError.invalidPlacement(placementValue)
            }
            return .terminalHost(host, placement)
        default:
            throw ProbeArgumentError.usage
        }
    }
}

public enum ProbeArgumentError: Error, Equatable {
    case usage
    case invalidHost(String)
    case invalidPlacement(String)
}

public enum AppleEventFailureCode: String, Error, Equatable {
    case automationPermissionDenied = "automation_permission_denied"
    case automationConsentRequired = "automation_consent_required"
    case replyTimeout = "reply_timeout"
    case applicationUnavailable = "application_unavailable"
    case missingObject = "missing_object"
    case malformedReply = "malformed_reply"
    case unsupportedLocation = "unsupported_location"
    case inaccessibleWorkspace = "inaccessible_workspace"
    case invalidWorkspace = "invalid_workspace"
    case missingHandler = "missing_handler"
    case missingCreatedObject = "missing_created_object"
    case unsupportedPlacement = "unsupported_placement"
    case eventFailure = "apple_event_failure"

    public static func map(status: Int) -> AppleEventFailureCode {
        switch status {
        case -1743:
            return .automationPermissionDenied
        case -1744:
            return .automationConsentRequired
        case -1712:
            return .replyTimeout
        case -600:
            return .applicationUnavailable
        case -1728:
            return .missingObject
        default:
            return .eventFailure
        }
    }
}

public enum WorkspaceReplyContract {
    public static func absoluteFileURL(from text: String?) throws -> URL {
        guard let text, !text.isEmpty, let url = URL(string: text) else {
            throw AppleEventFailureCode.malformedReply
        }
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw AppleEventFailureCode.unsupportedLocation
        }
        return url
    }

    public static func validateReachableDirectory(_ url: URL) throws {
        guard (try? url.checkResourceIsReachable()) == true else {
            throw AppleEventFailureCode.inaccessibleWorkspace
        }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw AppleEventFailureCode.invalidWorkspace
        }
    }
}

public enum MarkerContract {
    public static func identifier() -> String {
        UUID().uuidString.lowercased()
    }

    public static func shellLine(identifier: String) -> String {
        precondition(UUID(uuidString: identifier) != nil)
        return "printf '%s\\n' 'Go2Codex placement probe \(identifier.lowercased())'"
    }
}
