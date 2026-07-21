import AppKit
import Foundation
import Go2CodexCore
import Testing

@Suite("Production handoff platform adapters")
@MainActor
struct HandoffPlatformTests {
    @Test(arguments: desktopSuccessCases)
    func desktopSubmitsThroughExactVerifiedHandlerURL(
        testCase: DesktopSuccessCase
    ) async throws {
        let platform = DesktopHandoffPlatformStub()
        platform.registration = DesktopHandlerRegistration(
            applicationURL: testCase.handlerURL,
            bundleIdentifier: testCase.bundleIdentifier
        )
        let adapter = DesktopOpenAdapter(platform: platform)

        let acceptance = try await adapter.open(
            testCase.deepLink,
            for: testCase.target
        )

        #expect(acceptance == .acceptedByLaunchServices)
        #expect(platform.lookupURLs == [testCase.deepLink])
        #expect(platform.openCalls == [DesktopPlatformOpenCall(
            url: testCase.deepLink,
            applicationURL: testCase.handlerURL
        )])
    }

    @Test(arguments: DesktopHandlerRejection.allCases)
    func desktopRejectsUnverifiedHandlersWithoutSubmission(
        rejection: DesktopHandlerRejection
    ) async {
        let platform = DesktopHandoffPlatformStub()
        switch rejection {
        case .missing:
            platform.registration = nil
        case .wrongBundleIdentifier:
            platform.registration = DesktopHandlerRegistration(
                applicationURL: URL(fileURLWithPath: "/Applications/Wrong.app"),
                bundleIdentifier: "example.wrong-handler"
            )
        case .nonFileURL:
            platform.registration = DesktopHandlerRegistration(
                applicationURL: URL(string: "https://example.invalid/Codex.app")!,
                bundleIdentifier: "com.openai.codex"
            )
        }
        let adapter = DesktopOpenAdapter(platform: platform)
        let deepLink = URL(string: "codex://new?path=%2FUsers%2Fexample")!

        let error = await capturedDesktopError {
            try await adapter.open(deepLink, for: .codexApp)
        }

        #expect(error == .handlerUnavailable(.codexApp))
        #expect(platform.lookupURLs == [deepLink])
        #expect(platform.openCalls.isEmpty)
    }

    @Test
    func desktopAsyncOpenErrorMapsWithoutAnotherSubmission() async {
        let platform = DesktopHandoffPlatformStub()
        let handlerURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let deepLink = URL(string: "codex://new?path=%2FUsers%2Fexample")!
        platform.registration = DesktopHandlerRegistration(
            applicationURL: handlerURL,
            bundleIdentifier: "com.openai.codex"
        )
        platform.openErrorCode = -10810
        let adapter = DesktopOpenAdapter(platform: platform)

        let error = await capturedDesktopError {
            try await adapter.open(deepLink, for: .codexApp)
        }

        #expect(error == .openFailed(code: -10810))
        #expect(platform.openCalls == [DesktopPlatformOpenCall(
            url: deepLink,
            applicationURL: handlerURL
        )])
    }

    @Test
    func missingTerminalHostSendsNoEvent() async {
        let state = TerminalApplicationStateStub()
        state.applicationURLsByBundleIdentifier.removeValue(
            forKey: TerminalHost.terminal.bundleIdentifier
        )
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newWindow
            )
        }

        #expect(error == .hostUnavailable(.terminal))
        #expect(state.registrationLookups == ["com.apple.Terminal"])
        #expect(state.runningLookups.isEmpty)
        #expect(sender.events.isEmpty)
        #expect(opener.events.isEmpty)
    }

    @Test
    func terminalRunningNewWindowSendsOneCompleteDoScriptEvent() async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newWindow
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(state.runningLookups == ["com.apple.Terminal"])
        #expect(opener.events.isEmpty)
        #expect(sender.events.count == 1)
        try expectTerminalDoScriptEvent(#require(sender.events.first))
    }

    @Test(arguments: [SessionPlacement.newWindow, .newTab])
    func terminalColdStartUsesOneInitialDoScriptEvent(
        placement: SessionPlacement
    ) async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = false
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: placement
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(state.runningLookups == ["com.apple.Terminal"])
        #expect(sender.events.isEmpty)
        #expect(opener.applicationURLs == [URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app"
        )])
        #expect(opener.events.count == 1)
        try expectTerminalDoScriptEvent(#require(opener.events.first))
    }

    @Test
    func terminalNewTabWithExistingWindowFailsBeforeSubmission() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .unsupportedPlacement(.terminal, .newTab))
        #expect(state.runningLookups == ["com.apple.Terminal"])
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(sender.events.first.flatMap {
            targetBundleIdentifier(of: $0)
        } == "com.apple.Terminal")
        #expect(opener.events.isEmpty)
    }

    @Test(arguments: [Int32(-1728), -1719])
    func terminalNewTabWithoutWindowCreatesWindow(
        status: Int32
    ) async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [.status(status)]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(state.runningLookups == ["com.apple.Terminal"])
        #expect(sender.events.map(\.eventID) == [
            eventCode("getd"),
            eventCode("dosc"),
        ])
        try expectTerminalDoScriptEvent(#require(sender.events.last))
        #expect(opener.events.isEmpty)
    }

    @Test
    func terminalNewTabFrontWindowProcessRaceFallsBackOnce() async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [.status(-600)]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(opener.events.count == 1)
        try expectTerminalDoScriptEvent(#require(opener.events.first))
    }

    @Test
    func terminalFrontWindowPermissionFailurePreventsSubmission() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [.status(-1743)]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .automationPermissionDenied(.terminal))
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(opener.events.isEmpty)
    }

    @Test
    func terminalDirectSendProcessRaceFallsBackOnce() async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [.status(-600)]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newWindow
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(sender.events.count == 1)
        try expectTerminalDoScriptEvent(#require(sender.events.first))
        #expect(opener.events.count == 1)
        try expectTerminalDoScriptEvent(#require(opener.events.first))
    }

    @Test
    func terminalOpenErrorsMapWithoutRetry() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = false
        let opener = TerminalApplicationOpenerStub()
        opener.failure = TerminalApplicationOpenFailure(
            code: -1743,
            appleEventStatus: -1743
        )
        let sender = AppleEventSenderStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newWindow
            )
        }

        #expect(error == .automationPermissionDenied(.terminal))
        #expect(sender.events.isEmpty)
        #expect(opener.events.count == 1)
    }

    @Test
    func terminalGenericOpenFailureHasItsOwnCodeAndDoesNotRetry() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = false
        let opener = TerminalApplicationOpenerStub()
        opener.failure = TerminalApplicationOpenFailure(code: -10810)
        let sender = AppleEventSenderStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newWindow
            )
        }

        #expect(error == .applicationOpenFailed(-10810))
        #expect(sender.events.isEmpty)
        #expect(opener.events.count == 1)
    }

    @Test
    func terminalOpenFailureFindsUnderlyingAppleEventStatus() {
        let underlying = NSError(
            domain: NSOSStatusErrorDomain,
            code: -1743
        )
        let outer = NSError(
            domain: NSCocoaErrorDomain,
            code: 1,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        #expect(TerminalApplicationOpenFailure(error: outer) ==
            TerminalApplicationOpenFailure(
                code: 1,
                appleEventStatus: -1743
            ))
    }

    @Test
    func iTermExistingWindowTabQueriesThenRunsOneHandler() async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        sender.outcomes = [.reply(makeITermWindowReply())]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .iTerm2,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        let queryTarget = try #require(
            sender.events[0].paramDescriptor(forKeyword: eventCode("----"))
        )
        try expectPropertySelector(queryTarget, equals: "Crwn")
        #expect(script.events.count == 1)
        try expectITermScriptInvocation(
            #require(script.events.first),
            handler: "go2codexNewTab"
        )
        #expect(opener.events.isEmpty)
    }

    @Test
    func iTermMissingCurrentWindowQueriesThenCreatesWindow() async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        sender.outcomes = [.reply(makeITermMissingWindowReply())]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .iTerm2,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(script.events.count == 1)
        try expectITermScriptInvocation(
            #require(script.events.first),
            handler: "go2codexNewWindow"
        )
        #expect(opener.events.isEmpty)
    }

    @Test(arguments: iTermWindowCases)
    func iTermWindowPlacementRunsOneNewWindowHandler(
        testCase: ITermWindowCase
    ) async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = testCase.isRunning
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .iTerm2,
            placement: testCase.placement
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(sender.events.isEmpty)
        #expect(script.events.count == 1)
        try expectITermScriptInvocation(
            #require(script.events.first),
            handler: "go2codexNewWindow"
        )
        #expect(state.runningLookups == testCase.expectedRunningLookups)
        #expect(opener.events.isEmpty)
    }

    @Test(arguments: [Int32(-1728), -1719])
    func iTermRunningWithoutCurrentWindowQueriesThenCreatesWindow(
        status: Int32
    ) async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        sender.outcomes = [.status(status)]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .iTerm2,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(script.events.count == 1)
        try expectITermScriptInvocation(
            #require(script.events.first),
            handler: "go2codexNewWindow"
        )
        #expect(opener.events.isEmpty)
    }

    @Test
    func iTermWindowQueryWithoutDirectObjectFailsClosed() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        sender.outcomes = [.reply(makeReply())]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newTab
            )
        }

        #expect(error == .iTermWindowQueryReplyInvalid(nil))
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(script.events.isEmpty)
        #expect(opener.events.isEmpty)
    }

    @Test
    func iTermWindowQueryWithUnknownDescriptorFailsClosed() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        sender.outcomes = [.reply(makeITermUnknownWindowReply())]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newTab
            )
        }

        #expect(error == .iTermWindowQueryReplyInvalid(eventCode("long")))
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(script.events.isEmpty)
        #expect(opener.events.isEmpty)
    }

    @Test
    func iTermScriptResourceFailureDoesNotFallback() async {
        let state = TerminalApplicationStateStub()
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        script.error = TerminalAdapterError.iTermScriptResourceMissing
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newWindow
            )
        }

        #expect(error == .iTermScriptResourceMissing)
        #expect(sender.events.isEmpty)
        #expect(script.events.count == 1)
        #expect(opener.events.isEmpty)
    }

    @Test
    func iTermScriptInvalidResultFailsClosed() async {
        let state = TerminalApplicationStateStub()
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        script.result = .init(string: "true")
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newWindow
            )
        }

        #expect(error == .iTermScriptResultInvalid(
            eventCode("utxt")
        ))
        #expect(sender.events.isEmpty)
        #expect(script.events.count == 1)
        #expect(opener.events.isEmpty)
    }

    @Test
    func iTermScriptFalseResultFailsClosed() async {
        let state = TerminalApplicationStateStub()
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        script.result = .init(boolean: false)
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newWindow
            )
        }

        #expect(error == .iTermScriptResultInvalid(
            eventCode("bool")
        ))
        #expect(sender.events.isEmpty)
        #expect(script.events.count == 1)
        #expect(opener.events.isEmpty)
    }

    @Test(arguments: terminalStatusCases)
    func terminalAppleEventStatusesMapWithoutFallback(
        testCase: TerminalStatusCase
    ) async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [.status(testCase.status)]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newWindow
            )
        }

        #expect(error == testCase.expectedError)
        #expect(sender.events.count == 1)
        #expect(sender.events.first?.eventID == eventCode("dosc"))
        #expect(opener.events.isEmpty)
    }

    @Test
    func frontWindowQueryErrorMapsBeforeCommandSubmission() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        sender.outcomes = [.status(-1743)]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newTab
            )
        }

        #expect(error == .automationPermissionDenied(.iTerm2))
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(script.events.isEmpty)
        #expect(opener.events.isEmpty)
    }

    @Test(arguments: iTermStatusCases)
    func iTermScriptErrorsMapWithoutRetry(
        testCase: TerminalStatusCase
    ) async {
        let state = TerminalApplicationStateStub()
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        script.error = RawAppleEventError.status(testCase.status)
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newWindow
            )
        }

        #expect(error == testCase.expectedError)
        #expect(sender.events.isEmpty)
        #expect(script.events.count == 1)
        #expect(opener.events.isEmpty)
    }

    @Test
    func iTermProcessNotFoundNeverUsesTerminalApplicationOpener() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        sender.outcomes = [.status(-600)]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newTab
            )
        }

        #expect(error == .terminalUnavailable(.iTerm2))
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(script.events.isEmpty)
        #expect(opener.events.isEmpty)
    }
}

@MainActor
private final class DesktopHandoffPlatformStub: DesktopHandoffPlatform {
    var registration: DesktopHandlerRegistration?
    var openErrorCode: Int?
    private(set) var lookupURLs: [URL] = []
    private(set) var openCalls: [DesktopPlatformOpenCall] = []

    func handler(toOpen url: URL) -> DesktopHandlerRegistration? {
        lookupURLs.append(url)
        return registration
    }

    func open(
        _ url: URL,
        withApplicationAt applicationURL: URL
    ) async -> Int? {
        openCalls.append(DesktopPlatformOpenCall(
            url: url,
            applicationURL: applicationURL
        ))
        return openErrorCode
    }
}

private struct DesktopPlatformOpenCall: Equatable {
    let url: URL
    let applicationURL: URL
}

@MainActor
private final class TerminalApplicationStateStub:
    TerminalApplicationStateLookingUp {
    var applicationURLsByBundleIdentifier: [String: URL] = [
        TerminalHost.terminal.bundleIdentifier: URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app"
        ),
        TerminalHost.iTerm2.bundleIdentifier: URL(
            fileURLWithPath: "/Applications/iTerm.app"
        ),
    ]
    var isRunning = false
    private(set) var registrationLookups: [String] = []
    private(set) var runningLookups: [String] = []

    func applicationURL(bundleIdentifier: String) -> URL? {
        registrationLookups.append(bundleIdentifier)
        return applicationURLsByBundleIdentifier[bundleIdentifier]
    }

    func isRunning(bundleIdentifier: String) -> Bool {
        runningLookups.append(bundleIdentifier)
        return isRunning
    }
}

@MainActor
private final class TerminalApplicationOpenerStub: TerminalApplicationOpening {
    var failure: TerminalApplicationOpenFailure?
    private(set) var applicationURLs: [URL] = []
    private(set) var events: [NSAppleEventDescriptor] = []

    func openApplication(
        at applicationURL: URL,
        initialAppleEvent: NSAppleEventDescriptor
    ) async -> TerminalApplicationOpenFailure? {
        applicationURLs.append(applicationURL)
        events.append(initialAppleEvent)
        await Task.yield()
        return failure
    }
}

@MainActor
private final class AppleEventSenderStub: NativeAppleEventSending {
    var outcomes: [AppleEventOutcome] = []
    private(set) var events: [NSAppleEventDescriptor] = []

    func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        events.append(event)
        guard !outcomes.isEmpty else {
            return makeReply()
        }
        switch outcomes.removeFirst() {
        case let .reply(reply):
            return reply
        case let .status(status):
            throw RawAppleEventError.status(status)
        }
    }
}

@MainActor
private final class ITermScriptExecutorStub: ITermHandoffScriptExecuting {
    var result = NSAppleEventDescriptor(boolean: true)
    var error: (any Error)?
    private(set) var events: [NSAppleEventDescriptor] = []

    func execute(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        events.append(event)
        if let error {
            throw error
        }
        return result
    }
}

private enum AppleEventOutcome {
    case reply(NSAppleEventDescriptor)
    case status(Int32)
}

struct DesktopSuccessCase: Sendable, CustomTestStringConvertible {
    let target: AgentTarget
    let deepLink: URL
    let handlerURL: URL
    let bundleIdentifier: String

    var testDescription: String {
        target.rawValue
    }
}

enum DesktopHandlerRejection: CaseIterable, Sendable,
    CustomTestStringConvertible {
    case missing
    case wrongBundleIdentifier
    case nonFileURL

    var testDescription: String {
        switch self {
        case .missing: "missing"
        case .wrongBundleIdentifier: "wrong-bundle-identifier"
        case .nonFileURL: "non-file-url"
        }
    }
}

struct ITermWindowCase: Sendable, CustomTestStringConvertible {
    let placement: SessionPlacement
    let isRunning: Bool

    var expectedRunningLookups: [String] {
        placement == .newTab ? ["com.googlecode.iterm2"] : []
    }

    var testDescription: String {
        "\(placement.rawValue)-running-\(isRunning)"
    }
}

struct TerminalStatusCase: Sendable, CustomTestStringConvertible {
    let status: Int32
    let expectedError: TerminalHandoffError

    var testDescription: String {
        String(status)
    }
}

private let desktopSuccessCases = [
    DesktopSuccessCase(
        target: .codexApp,
        deepLink: URL(string: "codex://new?path=%2FUsers%2Fexample")!,
        handlerURL: URL(fileURLWithPath: "/Applications/Codex.app"),
        bundleIdentifier: "com.openai.codex"
    ),
    DesktopSuccessCase(
        target: .claudeDesktopCode,
        deepLink: URL(string: "claude://code/new?folder=%2FUsers%2Fexample")!,
        handlerURL: URL(fileURLWithPath: "/Applications/Claude.app"),
        bundleIdentifier: "com.anthropic.claudefordesktop"
    ),
]

private let iTermWindowCases = [
    ITermWindowCase(placement: .newWindow, isRunning: true),
    ITermWindowCase(placement: .newTab, isRunning: false),
]

private let terminalStatusCases = [
    TerminalStatusCase(
        status: -1743,
        expectedError: .automationPermissionDenied(.terminal)
    ),
    TerminalStatusCase(
        status: -1744,
        expectedError: .consentRequired(.terminal)
    ),
    TerminalStatusCase(
        status: -1712,
        expectedError: .replyTimeout(.terminal)
    ),
    TerminalStatusCase(
        status: -1719,
        expectedError: .appleEventFailure(.terminal, status: -1719)
    ),
    TerminalStatusCase(
        status: -1708,
        expectedError: .appleEventFailure(.terminal, status: -1708)
    ),
]

private let iTermStatusCases = [
    TerminalStatusCase(
        status: -1743,
        expectedError: .automationPermissionDenied(.iTerm2)
    ),
    TerminalStatusCase(
        status: -1744,
        expectedError: .consentRequired(.iTerm2)
    ),
    TerminalStatusCase(
        status: -1712,
        expectedError: .replyTimeout(.iTerm2)
    ),
    TerminalStatusCase(
        status: -600,
        expectedError: .terminalUnavailable(.iTerm2)
    ),
    TerminalStatusCase(
        status: -1728,
        expectedError: .appleEventFailure(.iTerm2, status: -1728)
    ),
    TerminalStatusCase(
        status: -1719,
        expectedError: .appleEventFailure(.iTerm2, status: -1719)
    ),
    TerminalStatusCase(
        status: -1708,
        expectedError: .appleEventFailure(.iTerm2, status: -1708)
    ),
]

private let testCommand = TerminalCommand(
    executable: .codex,
    line: "cd '/Users/example/Project With Space' && codex"
)

@MainActor
private func capturedDesktopError(
    _ operation: @MainActor () async throws -> HandoffAcceptance
) async -> DesktopHandoffError? {
    do {
        _ = try await operation()
        return nil
    } catch let error as DesktopHandoffError {
        return error
    } catch {
        return nil
    }
}

@MainActor
private func capturedTerminalError(
    _ operation: @MainActor () async throws -> HandoffAcceptance
) async -> TerminalHandoffError? {
    do {
        _ = try await operation()
        return nil
    } catch let error as TerminalHandoffError {
        return error
    } catch {
        return nil
    }
}

@MainActor
private func capturedTerminalAdapterError(
    _ operation: @MainActor () async throws -> HandoffAcceptance
) async -> TerminalAdapterError? {
    do {
        _ = try await operation()
        return nil
    } catch let error as TerminalAdapterError {
        return error
    } catch {
        return nil
    }
}

@MainActor
private func expectTerminalDoScriptEvent(
    _ event: NSAppleEventDescriptor
) throws {
    #expect(event.eventClass == eventCode("core"))
    #expect(event.eventID == eventCode("dosc"))
    #expect(targetBundleIdentifier(of: event) == "com.apple.Terminal")
    #expect(event.paramDescriptor(
        forKeyword: eventCode("----")
    )?.stringValue == testCommand.line)
}

@MainActor
private func expectITermScriptInvocation(
    _ event: NSAppleEventDescriptor,
    handler: String
) throws {
    #expect(event.eventClass == eventCode("ascr"))
    #expect(event.eventID == eventCode("psbr"))
    #expect(event.paramDescriptor(
        forKeyword: eventCode("snam")
    )?.stringValue == handler)
    let arguments = try #require(event.paramDescriptor(
        forKeyword: eventCode("----")
    ))
    #expect(arguments.numberOfItems == 1)
    #expect(arguments.atIndex(1)?.stringValue == testCommand.line)
}

@MainActor
private func makeReply() -> NSAppleEventDescriptor {
    NSAppleEventDescriptor(
        eventClass: eventCode("aevt"),
        eventID: eventCode("ansr"),
        targetDescriptor: .null(),
        returnID: -1,
        transactionID: 0
    )
}

@MainActor
private func makeITermWindowReply() -> NSAppleEventDescriptor {
    let reply = makeReply()
    reply.setParam(
        .init(typeCode: eventCode("cwin")),
        forKeyword: eventCode("----")
    )
    return reply
}

@MainActor
private func makeITermMissingWindowReply() -> NSAppleEventDescriptor {
    let reply = makeReply()
    reply.setParam(
        NSAppleEventDescriptor(descriptorType: eventCode("msng"), data: nil)
            ?? .null(),
        forKeyword: eventCode("----")
    )
    return reply
}

@MainActor
private func makeITermUnknownWindowReply() -> NSAppleEventDescriptor {
    let reply = makeReply()
    reply.setParam(.init(int32: 1), forKeyword: eventCode("----"))
    return reply
}

private func eventCode(_ value: String) -> UInt32 {
    precondition(value.utf8.count == 4)
    return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

private func targetBundleIdentifier(
    of event: NSAppleEventDescriptor
) -> String? {
    guard let address = event.attributeDescriptor(
        forKeyword: eventCode("addr")
    ) else {
        return nil
    }
    return String(data: address.data, encoding: .utf8)
}

private func expectPropertySelector(
    _ descriptor: NSAppleEventDescriptor,
    equals expected: String
) throws {
    #expect(descriptor.descriptorType == eventCode("obj "))
    #expect(descriptor.forKeyword(
        eventCode("seld")
    )?.typeCodeValue == eventCode(expected))
    _ = try #require(descriptor.forKeyword(eventCode("from")))
}
