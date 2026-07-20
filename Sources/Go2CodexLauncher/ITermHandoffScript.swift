import Foundation

@MainActor
protocol ITermHandoffScriptExecuting {
    func execute(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor
}

@MainActor
struct BundledITermHandoffScriptExecutor: ITermHandoffScriptExecuting {
    private let resourceURL: URL?

    init(bundle: Bundle = .main) {
        resourceURL = bundle.url(
            forResource: ITermHandoffScript.resourceName,
            withExtension: ITermHandoffScript.resourceExtension
        )
    }

    init(resourceURL: URL?) {
        self.resourceURL = resourceURL
    }

    func execute(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        let script = try loadScript()
        var errorInfo: NSDictionary?
        let result: NSAppleEventDescriptor? = script.executeAppleEvent(
            event,
            error: &errorInfo
        )
        if let status = (errorInfo?[NSAppleScript.errorNumber] as? NSNumber)?
            .int32Value,
           status != 0 {
            throw RawAppleEventError.status(status)
        }
        guard let result else {
            throw TerminalAdapterError.iTermScriptExecutionFailed
        }
        return result
    }

    func loadScript() throws -> NSAppleScript {
        guard let resourceURL else {
            throw TerminalAdapterError.iTermScriptResourceMissing
        }

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(
            contentsOf: resourceURL,
            error: &errorInfo
        ), script.isCompiled else {
            throw TerminalAdapterError.iTermScriptLoadFailed
        }
        return script
    }
}

@MainActor
enum ITermHandoffScript {
    static let resourceName = "ITermHandoff"
    static let resourceExtension = "scpt"

    private enum Code {
        static let appleScript: UInt32 = 0x61736372
        static let subroutine: UInt32 = 0x70736272
        static let subroutineName: UInt32 = 0x736e616d
        static let directObject: UInt32 = 0x2d2d2d2d
        static let boolean: UInt32 = 0x626f6f6c
        static let trueValue: UInt32 = 0x74727565
    }

    private static let newWindowHandler = "go2codexNewWindow"
    private static let newTabHandler = "go2codexNewTab"

    static func invocation(
        command: String,
        targetFrontWindow: Bool
    ) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: Code.appleScript,
            eventID: Code.subroutine,
            targetDescriptor: nil,
            returnID: -1,
            transactionID: 0
        )
        event.setParam(
            .init(string: targetFrontWindow
                ? newTabHandler
                : newWindowHandler),
            forKeyword: Code.subroutineName
        )
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(.init(string: command), at: 1)
        event.setParam(arguments, forKeyword: Code.directObject)
        return event
    }

    static func isSuccessfulResult(
        _ result: NSAppleEventDescriptor
    ) -> Bool {
        result.descriptorType == Code.trueValue
            || result.descriptorType == Code.boolean && result.booleanValue
    }

    static var directObjectKeyword: UInt32 {
        Code.directObject
    }

    static var subroutineNameKeyword: UInt32 {
        Code.subroutineName
    }
}
