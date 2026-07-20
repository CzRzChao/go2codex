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
    func replyAndTransportErrorsMapToRawStatuses() throws {
        let success = reply()
        #expect(try NativeAppleEvent.validateReply(success) === success)

        let explicitZero = reply(status: 0)
        #expect(try NativeAppleEvent.validateReply(explicitZero) === explicitZero)

        for status: Int32 in [-1743, -1744, -1712, -600, -1728, -1] {
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
