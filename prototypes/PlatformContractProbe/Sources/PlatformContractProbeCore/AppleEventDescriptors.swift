import Foundation

public enum AppleEventDescriptors {
    public static func finderWorkspace() -> NSAppleEventDescriptor {
        let finderWindow = elementSpecifier(
            desiredClass: AppleEventCodes.finderWindow,
            index: 1,
            container: .null()
        )
        let finderTarget = propertySpecifier(
            AppleEventCodes.finderTarget,
            container: finderWindow
        )
        let finderURL = propertySpecifier(
            AppleEventCodes.finderURL,
            container: finderTarget
        )
        let event = event(
            eventClass: AppleEventCodes.core,
            eventID: AppleEventCodes.getData,
            bundleIdentifier: "com.apple.finder"
        )
        event.setParam(finderURL, forKeyword: AppleEventCodes.directObject)
        return event
    }

    public static func frontWindowQuery(bundleIdentifier: String) -> NSAppleEventDescriptor {
        let event = event(
            eventClass: AppleEventCodes.core,
            eventID: AppleEventCodes.getData,
            bundleIdentifier: bundleIdentifier
        )
        event.setParam(frontWindowSpecifier(), forKeyword: AppleEventCodes.directObject)
        return event
    }

    public static func iTermCurrentWindowQuery() -> NSAppleEventDescriptor {
        let event = event(
            eventClass: AppleEventCodes.core,
            eventID: AppleEventCodes.getData,
            bundleIdentifier: TerminalHost.iTerm2.bundleIdentifier
        )
        event.setParam(iTermCurrentWindowSpecifier(), forKeyword: AppleEventCodes.directObject)
        return event
    }

    public static func terminal(command: String) -> NSAppleEventDescriptor {
        let event = event(
            eventClass: AppleEventCodes.core,
            eventID: AppleEventCodes.doScript,
            bundleIdentifier: TerminalHost.terminal.bundleIdentifier
        )
        event.setParam(.init(string: command), forKeyword: AppleEventCodes.directObject)
        return event
    }

    public static func iTermCreate(createsTab: Bool) -> NSAppleEventDescriptor {
        let event = event(
            eventClass: AppleEventCodes.iTerm,
            eventID: createsTab ? AppleEventCodes.iTermNewTab : AppleEventCodes.iTermNewWindow,
            bundleIdentifier: TerminalHost.iTerm2.bundleIdentifier
        )
        if createsTab {
            event.setParam(iTermCurrentWindowSpecifier(), forKeyword: AppleEventCodes.directObject)
        }
        return event
    }

    public static func iTermWrite(
        createdObject: NSAppleEventDescriptor,
        text: String
    ) -> NSAppleEventDescriptor {
        let currentSession = propertySpecifier(
            AppleEventCodes.iTermCurrentSession,
            container: createdObject
        )
        let event = event(
            eventClass: AppleEventCodes.iTerm,
            eventID: AppleEventCodes.iTermWrite,
            bundleIdentifier: TerminalHost.iTerm2.bundleIdentifier
        )
        event.setParam(currentSession, forKeyword: AppleEventCodes.directObject)
        event.setParam(.init(string: text), forKeyword: AppleEventCodes.iTermText)
        event.setParam(.init(boolean: true), forKeyword: AppleEventCodes.iTermNewline)
        return event
    }

    public static func frontWindowSpecifier() -> NSAppleEventDescriptor {
        elementSpecifier(
            desiredClass: AppleEventCodes.window,
            index: 1,
            container: .null()
        )
    }

    public static func iTermCurrentWindowSpecifier() -> NSAppleEventDescriptor {
        propertySpecifier(
            AppleEventCodes.iTermCurrentWindow,
            container: .null()
        )
    }

    public static func propertySpecifier(
        _ property: UInt32,
        container: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        objectSpecifier(
            desiredClass: AppleEventCodes.propertyClass,
            container: container,
            form: AppleEventCodes.propertyForm,
            selector: .init(typeCode: property)
        )
    }

    private static func elementSpecifier(
        desiredClass: UInt32,
        index: Int32,
        container: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        objectSpecifier(
            desiredClass: desiredClass,
            container: container,
            form: AppleEventCodes.absolutePositionForm,
            selector: .init(int32: index)
        )
    }

    private static func objectSpecifier(
        desiredClass: UInt32,
        container: NSAppleEventDescriptor,
        form: UInt32,
        selector: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(
            .init(typeCode: desiredClass),
            forKeyword: AppleEventCodes.desiredClass
        )
        record.setDescriptor(container, forKeyword: AppleEventCodes.container)
        record.setDescriptor(
            .init(enumCode: form),
            forKeyword: AppleEventCodes.keyForm
        )
        record.setDescriptor(selector, forKeyword: AppleEventCodes.keyData)
        guard let result = record.coerce(toDescriptorType: AppleEventCodes.objectSpecifier) else {
            preconditionFailure("Unable to construct an Apple Event object specifier")
        }
        return result
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
