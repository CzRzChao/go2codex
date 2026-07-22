import Foundation
import Go2CodexCore
import Testing

@Suite("Native Apple Event production contracts")
@MainActor
struct NativeAppleEventTests {
    @Test
    func finderWorkspaceUsesTheExactFrontViewerTargetURLChain() throws {
        let event = try NativeAppleEvent.finderWorkspace()

        #expect(event.eventClass == code("core"))
        #expect(event.eventID == code("getd"))
        try expectTarget(event, bundleIdentifier: "com.apple.finder")

        let url = try #require(event.paramDescriptor(forKeyword: code("----")))
        try expectPropertySpecifier(url, selector: "pURL")

        let target = try #require(url.forKeyword(code("from")))
        try expectPropertySpecifier(target, selector: "fvtg")

        let window = try #require(target.forKeyword(code("from")))
        #expect(window.descriptorType == code("obj "))
        #expect(window.numberOfItems == 4)
        #expect(window.forKeyword(code("want"))?.typeCodeValue == code("brow"))
        #expect(window.forKeyword(code("form"))?.enumCodeValue == code("indx"))
        #expect(window.forKeyword(code("seld"))?.int32Value == 1)
        #expect(window.forKeyword(code("from"))?.descriptorType == code("null"))
    }

    @Test
    func terminalNewWindowHasNoFrontWindowTarget() throws {
        let event = NativeAppleEvent.terminalNewWindow(command: "printf marker")

        #expect(event.eventClass == code("core"))
        #expect(event.eventID == code("dosc"))
        try expectTarget(event, bundleIdentifier: "com.apple.Terminal")
        #expect(event.paramDescriptor(forKeyword: code("----"))?.stringValue == "printf marker")
        #expect(event.paramDescriptor(forKeyword: code("kfil")) == nil)
    }

    @Test
    func terminalTargetedCommandUsesTheFrontWindow() throws {
        let event = try NativeAppleEvent.terminalCommand(
            command: "printf marker",
            targetFrontWindow: true
        )

        #expect(event.eventClass == code("core"))
        #expect(event.eventID == code("dosc"))
        try expectTarget(event, bundleIdentifier: "com.apple.Terminal")
        let target = try #require(event.paramDescriptor(
            forKeyword: code("kfil")
        ))
        #expect(target.descriptorType == code("obj "))
        #expect(target.forKeyword(code("want"))?.typeCodeValue == code("cwin"))
        #expect(target.forKeyword(code("form"))?.enumCodeValue == code("indx"))
        #expect(target.forKeyword(code("seld"))?.int32Value == 1)
    }

    @Test
    func terminalExactTabTargetUsesStableWindowIDAndTTY() throws {
        let event = try NativeAppleEvent.terminalCommand(
            command: "printf marker",
            targetTabTTY: "/dev/ttys009",
            inWindowID: 42
        )

        let target = try #require(event.paramDescriptor(
            forKeyword: code("kfil")
        ))
        #expect(target.forKeyword(code("want"))?.typeCodeValue == code("ttab"))
        #expect(target.forKeyword(code("form"))?.enumCodeValue == code("test"))
        let window = try #require(target.forKeyword(code("from")))
        #expect(window.forKeyword(code("want"))?.typeCodeValue == code("cwin"))
        #expect(window.forKeyword(code("form"))?.enumCodeValue == code("ID  "))
        #expect(window.forKeyword(code("seld"))?.int32Value == 42)
        let predicate = try #require(target.forKeyword(code("seld")))
        #expect(predicate.descriptorType == code("cmpd"))
        #expect(predicate.forKeyword(code("relo"))?.enumCodeValue == code("=   "))
        #expect(predicate.forKeyword(code("obj2"))?.stringValue == "/dev/ttys009")
        let tty = try #require(predicate.forKeyword(code("obj1")))
        try expectPropertySpecifier(tty, selector: "ttty")
        #expect(tty.forKeyword(code("from"))?.descriptorType == code("exmn"))
    }

    @Test
    func terminalWindowIdentityAndTTYQueriesStayInTheSameWindow() throws {
        let identityQuery = try NativeAppleEvent.terminalFrontWindowIDQuery()
        let identity = try #require(identityQuery.paramDescriptor(
            forKeyword: code("----")
        ))
        try expectPropertySpecifier(identity, selector: "ID  ")
        #expect(identity.forKeyword(code("from"))?.forKeyword(
            code("seld")
        )?.int32Value == 1)

        let identityReply = reply()
        identityReply.setParam(.init(int32: 42), forKeyword: code("----"))
        #expect(NativeAppleEvent.terminalWindowID(from: identityReply) == 42)

        let ttyQuery = try NativeAppleEvent.terminalTabTTYsQuery(windowID: 42)
        let ttyProperty = try #require(ttyQuery.paramDescriptor(
            forKeyword: code("----")
        ))
        try expectPropertySpecifier(ttyProperty, selector: "ttty")
        let tabs = try #require(ttyProperty.forKeyword(code("from")))
        #expect(tabs.forKeyword(code("seld"))?.descriptorType == code("abso"))
        #expect(tabs.forKeyword(code("seld"))?.enumCodeValue == code("all "))
        let window = try #require(tabs.forKeyword(code("from")))
        #expect(window.forKeyword(code("form"))?.enumCodeValue == code("ID  "))
        #expect(window.forKeyword(code("seld"))?.int32Value == 42)

        let ttyReply = reply()
        let values = NSAppleEventDescriptor.list()
        values.insert(.init(string: "/dev/ttys001"), at: 1)
        values.insert(.init(string: "/dev/ttys009"), at: 2)
        ttyReply.setParam(values, forKeyword: code("----"))
        #expect(NativeAppleEvent.terminalTabTTYs(from: ttyReply) == [
            "/dev/ttys001",
            "/dev/ttys009",
        ])
        #expect(NativeAppleEvent.terminalTabTTYs(from: reply()) == nil)
    }

    @Test
    func systemEventsShortcutTargetsOnlyTerminalCommandT() throws {
        let event = try NativeAppleEvent.systemEventsTerminalNewTabShortcut()

        #expect(event.eventClass == code("prcs"))
        #expect(event.eventID == code("kprs"))
        try expectTarget(event, bundleIdentifier: "com.apple.systemevents")
        #expect(event.paramDescriptor(
            forKeyword: code("----")
        )?.stringValue == "t")
        #expect(event.paramDescriptor(
            forKeyword: code("faal")
        )?.enumCodeValue == code("Kcmd"))

        let subject = try #require(event.attributeDescriptor(
            forKeyword: code("subj")
        ))
        #expect(subject.descriptorType == code("obj "))
        #expect(subject.forKeyword(code("want"))?.typeCodeValue == code("prcs"))
        #expect(subject.forKeyword(code("form"))?.enumCodeValue == code("name"))
        #expect(subject.forKeyword(code("seld"))?.stringValue == "Terminal")
        #expect(subject.forKeyword(code("from"))?.descriptorType == code("null"))
    }

    @Test
    func terminalFrontWindowQueryUsesExactWindowSpecifier() throws {
        let query = try NativeAppleEvent.frontWindowQuery(
            bundleIdentifier: "com.apple.Terminal"
        )

        #expect(query.eventClass == code("core"))
        #expect(query.eventID == code("getd"))
        try expectTarget(query, bundleIdentifier: "com.apple.Terminal")
        let window = try #require(query.paramDescriptor(
            forKeyword: code("----")
        ))
        #expect(window.descriptorType == code("obj "))
        #expect(window.forKeyword(code("want"))?.typeCodeValue == code("cwin"))
        #expect(window.forKeyword(code("form"))?.enumCodeValue == code("indx"))
        #expect(window.forKeyword(code("seld"))?.int32Value == 1)
        #expect(window.forKeyword(code("from"))?.descriptorType == code("null"))
    }

    @Test
    func iTermCurrentWindowQueryUsesExactProperty() throws {
        let query = try NativeAppleEvent.iTermCurrentWindowQuery()

        #expect(query.eventClass == code("core"))
        #expect(query.eventID == code("getd"))
        try expectTarget(query, bundleIdentifier: "com.googlecode.iterm2")
        let queryTarget = try #require(query.paramDescriptor(forKeyword: code("----")))
        try expectPropertySpecifier(queryTarget, selector: "Crwn")
        #expect(queryTarget.forKeyword(code("from"))?.descriptorType == code("null"))
    }

    @Test
    func iTermQuietLaunchUsesOneExactOpenDocumentURL() throws {
        let sentinelURL = URL(
            fileURLWithPath: "/Users/example/Library/Application Support/iTerm2/version.txt"
        )
        let event = NativeAppleEvent.iTermQuietLaunch(
            sentinelURL: sentinelURL
        )

        #expect(event.eventClass == code("aevt"))
        #expect(event.eventID == code("odoc"))
        #expect(event.attributeDescriptor(forKeyword: code("addr")) == nil)
        let directObject = try #require(event.paramDescriptor(
            forKeyword: code("----")
        ))
        #expect(directObject.descriptorType == code("list"))
        #expect(directObject.numberOfItems == 1)
        let document = try #require(directObject.atIndex(1))
        #expect(document.descriptorType == code("furl"))
        #expect(document.fileURLValue == sentinelURL)
    }

    @Test
    func iTermQuietLaunchDefaultUsesTheUserApplicationSupportSentinel() throws {
        let applicationSupportURL = try #require(FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first)
        let expectedURL = applicationSupportURL.appendingPathComponent(
            "iTerm2/version.txt",
            isDirectory: false
        )

        #expect(NativeAppleEvent.iTermQuietLaunchSentinelURL == expectedURL)
        let event = NativeAppleEvent.iTermQuietLaunch()
        let documents = try #require(event.paramDescriptor(
            forKeyword: code("----")
        ))
        #expect(documents.numberOfItems == 1)
        #expect(documents.atIndex(1)?.fileURLValue == expectedURL)
    }

    @Test
    func iTermCurrentWindowReplyAcceptsOnlyDeclaredWindowShapes() throws {
        let missingDirectObject = reply()
        #expect(NativeAppleEvent.classifyITermCurrentWindowReply(
            missingDirectObject
        ) == .invalid(nil))

        let noWindow = reply()
        noWindow.setParam(
            .init(typeCode: code("msng")),
            forKeyword: code("----")
        )
        #expect(NativeAppleEvent.classifyITermCurrentWindowReply(
            noWindow
        ) == .noWindow)

        let legacyNoWindow = reply()
        legacyNoWindow.setParam(
            try #require(NSAppleEventDescriptor(
                descriptorType: code("msng"),
                data: nil
            )),
            forKeyword: code("----")
        )
        #expect(NativeAppleEvent.classifyITermCurrentWindowReply(
            legacyNoWindow
        ) == .noWindow)

        let nullValue = reply()
        nullValue.setParam(.null(), forKeyword: code("----"))
        #expect(NativeAppleEvent.classifyITermCurrentWindowReply(
            nullValue
        ) == .invalid(code("null")))

        let classValue = reply()
        classValue.setParam(
            .init(typeCode: code("cwin")),
            forKeyword: code("----")
        )
        #expect(NativeAppleEvent.classifyITermCurrentWindowReply(
            classValue
        ) == .window)

        let wrongClassValue = reply()
        wrongClassValue.setParam(
            .init(typeCode: code("ctab")),
            forKeyword: code("----")
        )
        #expect(NativeAppleEvent.classifyITermCurrentWindowReply(
            wrongClassValue
        ) == .invalid(code("type")))

        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(
            .init(typeCode: code("cwin")),
            forKeyword: code("want")
        )
        record.setDescriptor(.null(), forKeyword: code("from"))
        record.setDescriptor(
            .init(enumCode: code("indx")),
            forKeyword: code("form")
        )
        record.setDescriptor(.init(int32: 1), forKeyword: code("seld"))
        let objectSpecifier = try #require(record.coerce(
            toDescriptorType: code("obj ")
        ))
        let objectReference = reply()
        objectReference.setParam(objectSpecifier, forKeyword: code("----"))
        #expect(NativeAppleEvent.classifyITermCurrentWindowReply(
            objectReference
        ) == .window)

        let incompleteRecord = NSAppleEventDescriptor.record()
        incompleteRecord.setDescriptor(
            .init(typeCode: code("cwin")),
            forKeyword: code("want")
        )
        let incompleteSpecifier = try #require(incompleteRecord.coerce(
            toDescriptorType: code("obj ")
        ))
        let incompleteReference = reply()
        incompleteReference.setParam(
            incompleteSpecifier,
            forKeyword: code("----")
        )
        #expect(NativeAppleEvent.classifyITermCurrentWindowReply(
            incompleteReference
        ) == .invalid(code("obj ")))

        let invalidFormRecord = NSAppleEventDescriptor.record()
        invalidFormRecord.setDescriptor(
            .init(typeCode: code("cwin")),
            forKeyword: code("want")
        )
        invalidFormRecord.setDescriptor(.null(), forKeyword: code("from"))
        invalidFormRecord.setDescriptor(
            .init(int32: 1),
            forKeyword: code("form")
        )
        invalidFormRecord.setDescriptor(
            .init(int32: 1),
            forKeyword: code("seld")
        )
        let invalidFormSpecifier = try #require(invalidFormRecord.coerce(
            toDescriptorType: code("obj ")
        ))
        let invalidFormReference = reply()
        invalidFormReference.setParam(
            invalidFormSpecifier,
            forKeyword: code("----")
        )
        #expect(NativeAppleEvent.classifyITermCurrentWindowReply(
            invalidFormReference
        ) == .invalid(code("obj ")))

        let unknown = reply()
        unknown.setParam(.init(int32: 1), forKeyword: code("----"))
        #expect(NativeAppleEvent.classifyITermCurrentWindowReply(
            unknown
        ) == .invalid(code("long")))
    }

    @Test
    func replyAndTransportErrorsMapToRawStatuses() throws {
        let success = reply()
        #expect(try NativeAppleEvent.validateReply(success) === success)

        let explicitZero = reply(status: 0)
        #expect(try NativeAppleEvent.validateReply(explicitZero) === explicitZero)

        for status: Int32 in [-1743, -1744, -1712, -600, -1728, -1719, -1] {
            #expect(capturedRawError {
                try NativeAppleEvent.validateReply(reply(status: status))
            } == .status(status))
        }

        #expect(NativeAppleEvent.mapTransportError(
            NSError(domain: NSOSStatusErrorDomain, code: -1743)
        ) == .status(-1743))
        #expect(NativeAppleEvent.mapTransportError(
            NSError(domain: NSOSStatusErrorDomain, code: Int.max)
        ) == .status(Int32.max))
        #expect(NativeAppleEvent.mapTransportError(
            NSError(domain: "test", code: -1743)
        ) == .status(NativeAppleEvent.transportFailureStatus))
    }
}

private func code(_ value: String) -> UInt32 {
    precondition(value.utf8.count == 4)
    return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

private func expectTarget(
    _ event: NSAppleEventDescriptor,
    bundleIdentifier: String
) throws {
    let address = try #require(
        event.attributeDescriptor(forKeyword: code("addr"))
    )
    #expect(address.descriptorType == code("bund"))
    #expect(String(data: address.data, encoding: .utf8) == bundleIdentifier)
}

private func expectPropertySpecifier(
    _ descriptor: NSAppleEventDescriptor,
    selector: String
) throws {
    #expect(descriptor.descriptorType == code("obj "))
    #expect(descriptor.numberOfItems == 4)
    #expect(descriptor.forKeyword(code("want"))?.typeCodeValue == code("prop"))
    #expect(descriptor.forKeyword(code("form"))?.enumCodeValue == code("prop"))
    #expect(descriptor.forKeyword(code("seld"))?.typeCodeValue == code(selector))
    _ = try #require(descriptor.forKeyword(code("from")))
}

private func reply(status: Int32? = nil) -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor(
        eventClass: code("aevt"),
        eventID: code("ansr"),
        targetDescriptor: .null(),
        returnID: -1,
        transactionID: 0
    )
    if let status {
        event.setParam(.init(int32: status), forKeyword: code("errn"))
    }
    return event
}

private func capturedRawError<T>(
    _ operation: () throws -> T
) -> RawAppleEventError? {
    do {
        _ = try operation()
        return nil
    } catch let error as RawAppleEventError {
        return error
    } catch {
        return nil
    }
}
