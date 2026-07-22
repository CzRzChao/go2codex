import AppKit
import Foundation
import Go2CodexCore

enum AppleEventConstructionError: Error, DiagnosticCodeProviding {
    case objectSpecifier

    var diagnosticCode: DiagnosticCode {
        DiagnosticCode(rawValue: "apple-event-construction-failed")
    }
}

enum RawAppleEventError: Error, Equatable {
    case status(Int32)
}

enum ITermCurrentWindowReply: Equatable {
    case noWindow
    case window
    case invalid(UInt32?)
}

@MainActor
enum NativeAppleEvent {
    private enum Code {
        static let appleEvent: UInt32 = 0x61657674
        static let openDocuments: UInt32 = 0x6f646f63
        static let core: UInt32 = 0x636f7265
        static let getData: UInt32 = 0x67657464
        static let doScript: UInt32 = 0x646f7363
        static let directObject: UInt32 = 0x2d2d2d2d
        static let errorNumber: UInt32 = 0x6572726e
        static let subject: UInt32 = 0x7375626a
        static let terminalTarget: UInt32 = 0x6b66696c

        static let objectSpecifier: UInt32 = 0x6f626a20
        static let absoluteOrdinal: UInt32 = 0x6162736f
        static let typeCode: UInt32 = 0x74797065
        static let enumerated: UInt32 = 0x656e756d
        static let null: UInt32 = 0x6e756c6c
        static let desiredClass: UInt32 = 0x77616e74
        static let container: UInt32 = 0x66726f6d
        static let keyForm: UInt32 = 0x666f726d
        static let keyData: UInt32 = 0x73656c64
        static let comparisonOperator: UInt32 = 0x72656c6f
        static let comparisonObject1: UInt32 = 0x6f626a31
        static let comparisonObject2: UInt32 = 0x6f626a32
        static let propertyClass: UInt32 = 0x70726f70
        static let propertyForm: UInt32 = 0x70726f70
        static let absolutePositionForm: UInt32 = 0x696e6478
        static let nameForm: UInt32 = 0x6e616d65
        static let uniqueIDForm: UInt32 = 0x49442020
        static let testForm: UInt32 = 0x74657374
        static let allElements: UInt32 = 0x616c6c20
        static let equals: UInt32 = 0x3d202020
        static let comparisonDescriptor: UInt32 = 0x636d7064
        static let objectBeingExamined: UInt32 = 0x65786d6e
        static let list: UInt32 = 0x6c697374

        static let finderWindow: UInt32 = 0x62726f77
        static let finderTarget: UInt32 = 0x66767467
        static let finderURL: UInt32 = 0x7055524c
        static let window: UInt32 = 0x6377696e
        static let terminalTab: UInt32 = 0x74746162
        static let terminalWindowID: UInt32 = 0x49442020
        static let terminalTTY: UInt32 = 0x74747479
        static let iTermCurrentWindow: UInt32 = 0x4372776e

        static let systemEventsProcessSuite: UInt32 = 0x70726373
        static let systemEventsKeystroke: UInt32 = 0x6b707273
        static let systemEventsUsing: UInt32 = 0x6661616c
        static let commandDown: UInt32 = 0x4b636d64
    }

    static func finderWorkspace() throws -> NSAppleEventDescriptor {
        let finderWindow = try elementSpecifier(
            desiredClass: Code.finderWindow,
            index: 1,
            container: .null()
        )
        let finderTarget = try propertySpecifier(
            Code.finderTarget,
            container: finderWindow
        )
        let finderURL = try propertySpecifier(
            Code.finderURL,
            container: finderTarget
        )
        let event = event(
            eventClass: Code.core,
            eventID: Code.getData,
            bundleIdentifier: FinderAppleEventContract.targetBundleIdentifier
        )
        event.setParam(finderURL, forKeyword: Code.directObject)
        return event
    }

    static func frontWindowQuery(
        bundleIdentifier: String
    ) throws -> NSAppleEventDescriptor {
        let event = event(
            eventClass: Code.core,
            eventID: Code.getData,
            bundleIdentifier: bundleIdentifier
        )
        event.setParam(try frontWindowSpecifier(), forKeyword: Code.directObject)
        return event
    }

    static func iTermCurrentWindowQuery() throws -> NSAppleEventDescriptor {
        let event = event(
            eventClass: Code.core,
            eventID: Code.getData,
            bundleIdentifier: TerminalHost.iTerm2.bundleIdentifier
        )
        event.setParam(
            try propertySpecifier(Code.iTermCurrentWindow, container: .null()),
            forKeyword: Code.directObject
        )
        return event
    }

    static var iTermQuietLaunchSentinelURL: URL {
        let applicationSupportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return applicationSupportURL
            .appendingPathComponent("iTerm2/version.txt", isDirectory: false)
    }

    static func iTermQuietLaunch(
        sentinelURL: URL? = nil
    ) -> NSAppleEventDescriptor {
        let directObject = NSAppleEventDescriptor.list()
        directObject.insert(
            .init(fileURL: sentinelURL ?? iTermQuietLaunchSentinelURL),
            at: 1
        )
        let event = NSAppleEventDescriptor(
            eventClass: Code.appleEvent,
            eventID: Code.openDocuments,
            targetDescriptor: nil,
            returnID: -1,
            transactionID: 0
        )
        event.setParam(directObject, forKeyword: Code.directObject)
        return event
    }

    static func terminalNewWindow(
        command: String
    ) -> NSAppleEventDescriptor {
        let event = event(
            eventClass: Code.core,
            eventID: Code.doScript,
            bundleIdentifier: TerminalHost.terminal.bundleIdentifier
        )
        event.setParam(.init(string: command), forKeyword: Code.directObject)
        return event
    }

    static func terminalCommand(
        command: String,
        targetFrontWindow: Bool
    ) throws -> NSAppleEventDescriptor {
        let event = terminalNewWindow(command: command)
        if targetFrontWindow {
            event.setParam(
                try frontWindowSpecifier(),
                forKeyword: Code.terminalTarget
            )
        }
        return event
    }

    static func terminalCommand(
        command: String,
        targetTabTTY: String,
        inWindowID windowID: Int32
    ) throws -> NSAppleEventDescriptor {
        let event = terminalNewWindow(command: command)
        event.setParam(
            try terminalTabSpecifier(
                tty: targetTabTTY,
                windowID: windowID
            ),
            forKeyword: Code.terminalTarget
        )
        return event
    }

    static func terminalFrontWindowIDQuery() throws
        -> NSAppleEventDescriptor {
        let event = event(
            eventClass: Code.core,
            eventID: Code.getData,
            bundleIdentifier: TerminalHost.terminal.bundleIdentifier
        )
        event.setParam(
            try propertySpecifier(
                Code.terminalWindowID,
                container: try frontWindowSpecifier()
            ),
            forKeyword: Code.directObject
        )
        return event
    }

    static func terminalWindowID(
        from reply: NSAppleEventDescriptor
    ) -> Int32? {
        guard let value = reply.paramDescriptor(
            forKeyword: Code.directObject
        )?.coerce(toDescriptorType: typeSInt32),
              value.int32Value > 0 else {
            return nil
        }
        return value.int32Value
    }

    static func terminalTabTTYsQuery(
        windowID: Int32
    ) throws -> NSAppleEventDescriptor {
        let tabs = try terminalTabsSpecifier(windowID: windowID)
        let event = event(
            eventClass: Code.core,
            eventID: Code.getData,
            bundleIdentifier: TerminalHost.terminal.bundleIdentifier
        )
        event.setParam(
            try propertySpecifier(Code.terminalTTY, container: tabs),
            forKeyword: Code.directObject
        )
        return event
    }

    static func terminalTabTTYs(
        from reply: NSAppleEventDescriptor
    ) -> [String]? {
        guard let values = reply.paramDescriptor(
            forKeyword: Code.directObject
        ), values.descriptorType == Code.list else {
            return nil
        }
        var result: [String] = []
        result.reserveCapacity(values.numberOfItems)
        guard values.numberOfItems > 0 else {
            return result
        }
        for index in 1...values.numberOfItems {
            guard let value = values.atIndex(index)?.stringValue,
                  !value.isEmpty else {
                return nil
            }
            result.append(value)
        }
        return result
    }

    static func systemEventsTerminalNewTabShortcut() throws
        -> NSAppleEventDescriptor {
        let terminalProcess = try objectSpecifier(
            desiredClass: Code.systemEventsProcessSuite,
            container: .null(),
            form: Code.nameForm,
            selector: .init(string: "Terminal")
        )
        let event = event(
            eventClass: Code.systemEventsProcessSuite,
            eventID: Code.systemEventsKeystroke,
            bundleIdentifier: systemEventsBundleIdentifier
        )
        event.setAttribute(terminalProcess, forKeyword: Code.subject)
        event.setParam(.init(string: "t"), forKeyword: Code.directObject)
        event.setParam(
            .init(enumCode: Code.commandDown),
            forKeyword: Code.systemEventsUsing
        )
        return event
    }

    static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        do {
            let reply = try event.sendEvent(
                options: [.waitForReply, .canInteract],
                timeout: 60
            )
            return try validateReply(reply)
        } catch let error as RawAppleEventError {
            throw error
        } catch {
            throw mapTransportError(error)
        }
    }

    static func validateReply(
        _ reply: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        if let error = reply.paramDescriptor(forKeyword: Code.errorNumber),
           error.int32Value != 0 {
            throw RawAppleEventError.status(error.int32Value)
        }
        return reply
    }

    static let transportFailureStatus: Int32 = -10000

    static func mapTransportError(_ error: any Error) -> RawAppleEventError {
        let nsError = error as NSError
        guard nsError.domain == NSOSStatusErrorDomain else {
            return .status(transportFailureStatus)
        }
        return .status(Int32(clamping: nsError.code))
    }

    static var directObjectKeyword: UInt32 {
        Code.directObject
    }

    static let systemEventsBundleIdentifier = "com.apple.systemevents"

    static let missingValueDescriptorType: UInt32 = 0x6d736e67

    static func classifyITermCurrentWindowReply(
        _ reply: NSAppleEventDescriptor
    ) -> ITermCurrentWindowReply {
        guard let directObject = reply.paramDescriptor(
            forKeyword: Code.directObject
        ) else {
            return .invalid(nil)
        }
        if directObject.descriptorType == missingValueDescriptorType {
            return .noWindow
        }
        if directObject.descriptorType == Code.typeCode,
           directObject.typeCodeValue == missingValueDescriptorType {
            return .noWindow
        }
        if directObject.descriptorType == Code.typeCode,
           directObject.typeCodeValue == Code.window {
            return .window
        }
        if directObject.descriptorType == Code.objectSpecifier,
           directObject.numberOfItems == 4,
           let desiredClass = directObject.forKeyword(Code.desiredClass),
           desiredClass.descriptorType == Code.typeCode,
           desiredClass.typeCodeValue == Code.window,
           let container = directObject.forKeyword(Code.container),
           container.descriptorType != missingValueDescriptorType,
           let keyForm = directObject.forKeyword(Code.keyForm),
           keyForm.descriptorType == Code.enumerated,
           let keyData = directObject.forKeyword(Code.keyData),
           keyData.descriptorType != missingValueDescriptorType,
           keyData.descriptorType != Code.null {
            return .window
        }
        return .invalid(directObject.descriptorType)
    }

    private static func frontWindowSpecifier() throws -> NSAppleEventDescriptor {
        try elementSpecifier(
            desiredClass: Code.window,
            index: 1,
            container: .null()
        )
    }

    private static func terminalWindowSpecifier(
        id: Int32
    ) throws -> NSAppleEventDescriptor {
        try objectSpecifier(
            desiredClass: Code.window,
            container: .null(),
            form: Code.uniqueIDForm,
            selector: .init(int32: id)
        )
    }

    private static func terminalTabsSpecifier(
        windowID: Int32
    ) throws -> NSAppleEventDescriptor {
        try objectSpecifier(
            desiredClass: Code.terminalTab,
            container: try terminalWindowSpecifier(id: windowID),
            form: Code.absolutePositionForm,
            selector: try absoluteOrdinal(Code.allElements)
        )
    }

    private static func terminalTabSpecifier(
        tty: String,
        windowID: Int32
    ) throws -> NSAppleEventDescriptor {
        guard let objectBeingExamined = NSAppleEventDescriptor(
            descriptorType: Code.objectBeingExamined,
            data: Data()
        ) else {
            throw AppleEventConstructionError.objectSpecifier
        }
        let comparison = NSAppleEventDescriptor.record()
        comparison.setDescriptor(
            try propertySpecifier(
                Code.terminalTTY,
                container: objectBeingExamined
            ),
            forKeyword: Code.comparisonObject1
        )
        comparison.setDescriptor(
            .init(enumCode: Code.equals),
            forKeyword: Code.comparisonOperator
        )
        comparison.setDescriptor(
            .init(string: tty),
            forKeyword: Code.comparisonObject2
        )
        guard let predicate = comparison.coerce(
            toDescriptorType: Code.comparisonDescriptor
        ) else {
            throw AppleEventConstructionError.objectSpecifier
        }
        return try objectSpecifier(
            desiredClass: Code.terminalTab,
            container: try terminalWindowSpecifier(id: windowID),
            form: Code.testForm,
            selector: predicate
        )
    }

    private static func propertySpecifier(
        _ property: UInt32,
        container: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        try objectSpecifier(
            desiredClass: Code.propertyClass,
            container: container,
            form: Code.propertyForm,
            selector: .init(typeCode: property)
        )
    }

    private static func elementSpecifier(
        desiredClass: UInt32,
        index: Int32,
        container: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        try objectSpecifier(
            desiredClass: desiredClass,
            container: container,
            form: Code.absolutePositionForm,
            selector: .init(int32: index)
        )
    }

    private static func objectSpecifier(
        desiredClass: UInt32,
        container: NSAppleEventDescriptor,
        form: UInt32,
        selector: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(
            .init(typeCode: desiredClass),
            forKeyword: Code.desiredClass
        )
        record.setDescriptor(container, forKeyword: Code.container)
        record.setDescriptor(.init(enumCode: form), forKeyword: Code.keyForm)
        record.setDescriptor(selector, forKeyword: Code.keyData)
        guard let descriptor = record.coerce(
            toDescriptorType: Code.objectSpecifier
        ) else {
            throw AppleEventConstructionError.objectSpecifier
        }
        return descriptor
    }

    private static func absoluteOrdinal(
        _ ordinal: UInt32
    ) throws -> NSAppleEventDescriptor {
        let value = NSAppleEventDescriptor(enumCode: ordinal)
        guard let descriptor = NSAppleEventDescriptor(
            descriptorType: Code.absoluteOrdinal,
            data: value.data
        ) else {
            throw AppleEventConstructionError.objectSpecifier
        }
        return descriptor
    }

    private static func event(
        eventClass: UInt32,
        eventID: UInt32,
        bundleIdentifier: String
    ) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: eventID,
            targetDescriptor: .init(bundleIdentifier: bundleIdentifier),
            returnID: -1,
            transactionID: 0
        )
    }
}
