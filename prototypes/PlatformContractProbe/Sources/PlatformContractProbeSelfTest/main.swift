import Foundation
import PlatformContractProbeCore

private struct TestFailure: Error {
    let message: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure(message: message)
    }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw TestFailure(message: message)
    }
    return value
}

private func objectCode(
    _ descriptor: NSAppleEventDescriptor,
    keyword: UInt32
) -> UInt32? {
    descriptor.forKeyword(keyword)?.typeCodeValue
}

private func selectorCode(_ descriptor: NSAppleEventDescriptor) -> UInt32? {
    descriptor.forKeyword(AppleEventCodes.keyData)?.typeCodeValue
}

private func expectTarget(
    _ event: NSAppleEventDescriptor,
    bundleIdentifier: String
) throws {
    let address = try require(
        event.attributeDescriptor(forKeyword: AppleEventCodes.addressAttribute),
        "missing target address"
    )
    try expect(
        address.descriptorType == AppleEventCodes.applicationBundleIdentifier,
        "target address type differs"
    )
    try expect(
        String(data: address.data, encoding: .utf8) == bundleIdentifier,
        "target bundle differs"
    )
}

private let tests: [(String, () throws -> Void)] = [
    ("four-character codes round trip", {
        let value = try require(FourCharacterCode("Itrm"), "code was rejected")
        try expect(value.rawValue == AppleEventCodes.iTerm, "raw code differs")
        try expect(value.description == "Itrm", "description differs")
        try expect(FourCharacterCode("bad") == nil, "short code was accepted")
        try expect(FourCharacterCode("你好ab") == nil, "non-ASCII code was accepted")
    }),
    ("finder descriptor has the exact object chain", {
        let event = AppleEventDescriptors.finderWorkspace()
        try expect(event.eventClass == AppleEventCodes.core, "wrong event class")
        try expect(event.eventID == AppleEventCodes.getData, "wrong event id")
        try expectTarget(event, bundleIdentifier: "com.apple.finder")
        let url = try require(
            event.paramDescriptor(forKeyword: AppleEventCodes.directObject),
            "missing direct object"
        )
        try expect(url.descriptorType == AppleEventCodes.objectSpecifier, "URL is not an object specifier")
        try expect(objectCode(url, keyword: AppleEventCodes.desiredClass) == AppleEventCodes.propertyClass, "URL desired class differs")
        try expect(selectorCode(url) == AppleEventCodes.finderURL, "URL selector differs")
        try expect(url.forKeyword(AppleEventCodes.keyForm)?.enumCodeValue == AppleEventCodes.propertyForm, "URL key form differs")
        let target = try require(url.forKeyword(AppleEventCodes.container), "missing target container")
        try expect(selectorCode(target) == AppleEventCodes.finderTarget, "target selector differs")
        try expect(target.forKeyword(AppleEventCodes.keyForm)?.enumCodeValue == AppleEventCodes.propertyForm, "target key form differs")
        let window = try require(target.forKeyword(AppleEventCodes.container), "missing window container")
        try expect(objectCode(window, keyword: AppleEventCodes.desiredClass) == AppleEventCodes.finderWindow, "window class differs")
        try expect(window.forKeyword(AppleEventCodes.keyForm)?.enumCodeValue == AppleEventCodes.absolutePositionForm, "window key form differs")
        try expect(window.forKeyword(AppleEventCodes.keyData)?.int32Value == 1, "window index differs")
        try expect(selectorCode(url) != AppleEventCodes.selection, "selection leaked into descriptor")
        try expect(selectorCode(target) != AppleEventCodes.selection, "selection leaked into descriptor")
    }),
    ("Terminal new window omits a target", {
        let event = AppleEventDescriptors.terminal(command: "printf marker")
        try expect(event.eventClass == AppleEventCodes.core, "wrong event class")
        try expect(event.eventID == AppleEventCodes.doScript, "wrong event id")
        try expectTarget(event, bundleIdentifier: TerminalHost.terminal.bundleIdentifier)
        try expect(event.paramDescriptor(forKeyword: AppleEventCodes.directObject)?.stringValue == "printf marker", "command differs")
        try expect(event.paramDescriptor(forKeyword: AppleEventCodes.terminalTarget) == nil, "unexpected target")
    }),
    ("Terminal existing-window tab fails closed while iTerm creates a tab", {
        try expect(
            TerminalPlacementContract.resolve(host: .terminal, placement: .tab, hasWindow: true) == .unsupported,
            "Terminal existing-window tab was accepted"
        )
        try expect(
            TerminalPlacementContract.resolve(host: .iTerm2, placement: .tab, hasWindow: true) == .createTabInCurrentWindow,
            "iTerm existing-window tab was not accepted"
        )
    }),
    ("tab without a window and every new-window request create a window", {
        for host in TerminalHost.allCases {
            try expect(
                TerminalPlacementContract.resolve(host: host, placement: .tab, hasWindow: false) == .createWindow,
                "tab without a window did not create a window"
            )
            for hasWindow in [false, true] {
                try expect(
                    TerminalPlacementContract.resolve(host: host, placement: .window, hasWindow: hasWindow) == .createWindow,
                    "new-window request did not create a window"
                )
            }
        }
    }),
    ("iTerm creates without overriding the profile command", {
        let window = AppleEventDescriptors.iTermCreate(createsTab: false)
        try expect(window.eventClass == AppleEventCodes.iTerm, "wrong event class")
        try expect(window.eventID == AppleEventCodes.iTermNewWindow, "wrong window event id")
        try expectTarget(window, bundleIdentifier: TerminalHost.iTerm2.bundleIdentifier)
        try expect(window.paramDescriptor(forKeyword: AppleEventCodes.iTermCommand) == nil, "profile command was overridden")

        let tab = AppleEventDescriptors.iTermCreate(createsTab: true)
        try expect(tab.eventID == AppleEventCodes.iTermNewTab, "wrong tab event id")
        try expect(tab.paramDescriptor(forKeyword: AppleEventCodes.iTermCommand) == nil, "profile command was overridden")
        let currentWindow = try require(
            tab.paramDescriptor(forKeyword: AppleEventCodes.directObject),
            "missing current-window target"
        )
        try expect(selectorCode(currentWindow) == AppleEventCodes.iTermCurrentWindow, "current-window selector differs")
        let query = AppleEventDescriptors.iTermCurrentWindowQuery()
        let queryTarget = try require(
            query.paramDescriptor(forKeyword: AppleEventCodes.directObject),
            "missing current-window query target"
        )
        try expect(selectorCode(queryTarget) == AppleEventCodes.iTermCurrentWindow, "current-window query differs")
    }),
    ("iTerm writes the marker to the returned object's current session", {
        let created = AppleEventDescriptors.frontWindowSpecifier()
        let write = AppleEventDescriptors.iTermWrite(
            createdObject: created,
            text: "printf marker"
        )
        try expect(write.eventClass == AppleEventCodes.iTerm, "wrong event class")
        try expect(write.eventID == AppleEventCodes.iTermWrite, "wrong write event id")
        try expectTarget(write, bundleIdentifier: TerminalHost.iTerm2.bundleIdentifier)
        try expect(write.paramDescriptor(forKeyword: AppleEventCodes.iTermText)?.stringValue == "printf marker", "write text differs")
        try expect(write.paramDescriptor(forKeyword: AppleEventCodes.iTermNewline)?.booleanValue == true, "newline flag differs")
        let session = try require(
            write.paramDescriptor(forKeyword: AppleEventCodes.directObject),
            "missing write target"
        )
        try expect(selectorCode(session) == AppleEventCodes.iTermCurrentSession, "current-session selector differs")
        try expect(session.forKeyword(AppleEventCodes.container) != nil, "returned object was not retained as the container")
    }),
    ("marker text is a closed harmless printf line", {
        let identifier = "5B0C47F2-4A69-4CF5-8077-669B1D23F21D"
        let line = MarkerContract.shellLine(identifier: identifier)
        try expect(
            line == "printf '%s\\n' 'Go2Codex placement probe 5b0c47f2-4a69-4cf5-8077-669b1d23f21d'",
            "marker line differs"
        )
        try expect(!line.contains("cd "), "marker changes directory")
        try expect(!line.contains("codex"), "marker opens Codex")
        try expect(!line.contains("claude"), "marker opens Claude")
    }),
    ("Apple Event statuses map to typed failures", {
        try expect(AppleEventFailureCode.map(status: -1743) == .automationPermissionDenied, "permission mapping differs")
        try expect(AppleEventFailureCode.map(status: -1744) == .automationConsentRequired, "consent mapping differs")
        try expect(AppleEventFailureCode.map(status: -1712) == .replyTimeout, "timeout mapping differs")
        try expect(AppleEventFailureCode.map(status: -600) == .applicationUnavailable, "unavailable mapping differs")
        try expect(AppleEventFailureCode.map(status: -1728) == .missingObject, "missing-object mapping differs")
        try expect(AppleEventFailureCode.map(status: -1) == .eventFailure, "unknown mapping differs")
    }),
    ("Workspace replies require an absolute file URL", {
        let unicode = try WorkspaceReplyContract.absoluteFileURL(
            from: "file:///Volumes/External/%E6%B5%8B%E8%AF%95%20Folder"
        )
        try expect(unicode.path == "/Volumes/External/测试 Folder", "URL decoding differs")
        let root = try WorkspaceReplyContract.absoluteFileURL(from: "file:///")
        try expect(root.path == "/", "root was rejected")
        do {
            _ = try WorkspaceReplyContract.absoluteFileURL(from: "https://example.com/path")
            throw TestFailure(message: "non-file URL was accepted")
        } catch AppleEventFailureCode.unsupportedLocation {}
        do {
            _ = try WorkspaceReplyContract.absoluteFileURL(from: nil)
            throw TestFailure(message: "missing reply was accepted")
        } catch AppleEventFailureCode.malformedReply {}
    }),
    ("only explicit subcommands can perform system control", {
        let inspect = try ProbeInvocation.parse(["inspect"])
        let finder = try ProbeInvocation.parse(["finder"])
        let terminal = try ProbeInvocation.parse(["terminal-host", "iterm2", "tab"])
        try expect(inspect == .inspect, "inspect parse differs")
        try expect(!inspect.performsSystemControl, "inspect controls the system")
        try expect(finder.performsSystemControl, "finder is not explicit control")
        try expect(
            terminal == .terminalHost(.iTerm2, .tab),
            "terminal-host parse differs"
        )
        do {
            _ = try ProbeInvocation.parse([])
            throw TestFailure(message: "empty invocation was accepted")
        } catch ProbeArgumentError.usage {}
    })
]

var failureCount = 0
for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch let failure as TestFailure {
        failureCount += 1
        print("FAIL \(name): \(failure.message)")
    } catch {
        failureCount += 1
        print("FAIL \(name): \(error)")
    }
}

if failureCount > 0 {
    print("\(failureCount) self-test(s) failed")
    exit(1)
}

print("All \(tests.count) self-tests passed")
