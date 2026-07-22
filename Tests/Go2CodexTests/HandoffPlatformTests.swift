import AppKit
import Foundation
import Go2CodexCore
import Testing

@Suite("Production handoff platform adapters")
@MainActor
struct HandoffPlatformTests {
    @Test
    func workspaceOpenCompletionCanResumeFromLaunchServicesQueue() async {
        let expectedCode = -10810
        let result: Int? = await awaitWorkspaceOpen(
            mapError: { error in
                error.map { ($0 as NSError).code }
            }
        ) { completion in
            DispatchQueue(label: "io.github.czrzchao.go2codex.tests.launch-services").async {
                completion(
                    nil,
                    NSError(
                        domain: NSCocoaErrorDomain,
                        code: expectedCode
                    )
                )
            }
        }

        #expect(result == expectedCode)
    }

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
        #expect(sender.permissionRequests == [hostPermissionRequest(.terminal)])
    }

    @Test
    func terminalColdStartNewWindowNeverTargetsARestoredWindow() async throws {
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
            placement: .newWindow
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(state.runningLookups == ["com.apple.Terminal"])
        #expect(sender.permissionRequests == [hostPermissionRequest(.terminal)])
        #expect(sender.events.count == 1)
        try expectTerminalDoScriptEvent(#require(sender.events.first))
        #expect(opener.applicationURLs == [URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app"
        )])
        #expect(opener.events.isEmpty)
        #expect(opener.launchesWithoutInitialEvent == 1)
    }

    @Test
    func terminalColdStartNewTabCreatesAndTargetsATabInTheRestoredFrontWindow()
        async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = false
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
            .reply(makeReply()),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalSelectedTabTTYReply("/dev/ttys009")),
            .reply(makeTerminalTabTTYsReply([
                "/dev/ttys001",
                "/dev/ttys009",
            ])),
            .reply(makeReply()),
        ]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalTabPollDelay: {}
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(sender.permissionRequests == [
            hostPermissionRequest(.terminal),
            systemEventsPermissionRequest(),
        ])
        #expect(sender.events.map(\.eventID) == [
            eventCode("getd"),
            eventCode("getd"),
            eventCode("cnte"),
            eventCode("getd"),
            eventCode("kprs"),
            eventCode("cnte"),
            eventCode("getd"),
            eventCode("getd"),
            eventCode("dosc"),
        ])
        try expectTerminalDoScriptEvent(
            sender.events[8],
            targetTabTTY: "/dev/ttys009",
            targetWindowID: 42
        )
        #expect(opener.applicationURLs == [
            URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app"),
        ])
        #expect(opener.events.isEmpty)
        #expect(opener.launchesWithoutInitialEvent == 2)
    }

    @Test(arguments: [Int32(-1728), -1719, -600])
    func terminalColdStartNewTabWithoutAWindowCreatesANewWindow(
        status: Int32
    ) async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = false
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
        #expect(sender.events.map(\.eventID) == [
            eventCode("getd"),
            eventCode("dosc"),
        ])
        try expectTerminalDoScriptEvent(#require(sender.events.last))
        #expect(opener.events.isEmpty)
        #expect(opener.launchesWithoutInitialEvent == 1)
    }

    @Test
    func terminalColdStartNewTabMalformedWindowReplyFailsBeforeSubmission()
        async {
        let state = TerminalApplicationStateStub()
        state.isRunning = false
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [.reply(makeReply())]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .terminalTabCountReplyInvalid(nil))
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(opener.events.isEmpty)
        #expect(opener.launchesWithoutInitialEvent == 1)
    }

    @Test
    func terminalNewTabWithExistingWindowCreatesAndVerifiesATabBeforeSubmission()
        async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
            .reply(makeReply()),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalSelectedTabTTYReply("/dev/ttys009")),
            .reply(makeTerminalTabTTYsReply([
                "/dev/ttys001",
                "/dev/ttys009",
            ])),
            .reply(makeReply()),
        ]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalTabPollDelay: {}
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(sender.events.map(\.eventID) == [
            eventCode("getd"),
            eventCode("getd"),
            eventCode("cnte"),
            eventCode("getd"),
            eventCode("kprs"),
            eventCode("cnte"),
            eventCode("getd"),
            eventCode("getd"),
            eventCode("dosc"),
        ])
        #expect(sender.permissionRequests == [
            hostPermissionRequest(.terminal),
            systemEventsPermissionRequest(),
        ])
        #expect(sender.accessibilityPermissionRequestCount == 1)
        #expect(state.activationRequests == ["com.apple.Terminal"])
        try expectSystemEventsTerminalNewTabShortcut(sender.events[4])
        try expectTerminalDoScriptEvent(
            sender.events[8],
            targetTabTTY: "/dev/ttys009",
            targetWindowID: 42
        )
        #expect(opener.events.isEmpty)
    }

    @Test
    func terminalNewTabWaitsForFrontmostThenResolvesTheActivatedWindow()
        async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        state.frontmostResults = [false, false, true]
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDReply(41)),
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
            .reply(makeReply()),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalSelectedTabTTYReply("/dev/ttys009")),
            .reply(makeTerminalTabTTYsReply([
                "/dev/ttys001",
                "/dev/ttys009",
            ])),
            .reply(makeReply()),
        ]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalActivationPollAttempts: 3,
            terminalTabPollDelay: {}
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(state.frontmostLookups == [
            "com.apple.Terminal",
            "com.apple.Terminal",
            "com.apple.Terminal",
            "com.apple.Terminal",
        ])
        try expectTerminalDoScriptEvent(
            #require(sender.events.last),
            targetTabTTY: "/dev/ttys009",
            targetWindowID: 42
        )
    }

    @Test
    func terminalNewTabFailsBeforeShortcutWhenActivationNeverBecomesFrontmost()
        async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        state.frontmostResults = [false, false]
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [.reply(makeTerminalWindowIDReply(41))]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalActivationPollAttempts: 2,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .terminalActivationTimedOut)
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(state.frontmostLookups.count == 2)
    }

    @Test
    func terminalNewTabFailsBeforeShortcutWhenTerminalLosesFocus() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        state.frontmostResults = [true, false]
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
        ]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .terminalFocusLostBeforeShortcut)
        #expect(!sender.events.contains(where: { $0.eventID == eventCode("kprs") }))
        #expect(!sender.events.contains(where: { $0.eventID == eventCode("dosc") }))
    }

    @Test
    func terminalNewTabWaitsForTheCreatedTabsTTYWithoutRequiringOldTTYsAgain()
        async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
            .reply(makeReply()),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalSelectedTabTTYNotReadyReply()),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalSelectedTabTTYReply("/dev/ttys009")),
            .reply(makeTerminalTabTTYsReply([
                "/dev/ttys001",
                "/dev/ttys009",
            ])),
            .reply(makeReply()),
        ]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalTabPollAttempts: 2,
            terminalTabPollDelay: {}
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(sender.events.map(\.eventID) == [
            eventCode("getd"),
            eventCode("getd"),
            eventCode("cnte"),
            eventCode("getd"),
            eventCode("kprs"),
            eventCode("cnte"),
            eventCode("getd"),
            eventCode("cnte"),
            eventCode("getd"),
            eventCode("getd"),
            eventCode("dosc"),
        ])
        try expectTerminalDoScriptEvent(
            #require(sender.events.last),
            targetTabTTY: "/dev/ttys009",
            targetWindowID: 42
        )
    }

    @Test
    func terminalNewTabWaitsWhenSelectionStillPointsAtAnExistingTTY()
        async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
            .reply(makeReply()),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalSelectedTabTTYReply("/dev/ttys001")),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalSelectedTabTTYReply("/dev/ttys009")),
            .reply(makeTerminalTabTTYsReply([
                "/dev/ttys001",
                "/dev/ttys009",
            ])),
            .reply(makeReply()),
        ]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalTabPollAttempts: 2,
            terminalTabPollDelay: {}
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        try expectTerminalDoScriptEvent(
            #require(sender.events.last),
            targetTabTTY: "/dev/ttys009",
            targetWindowID: 42
        )
    }

    @Test
    func terminalNewTabNeverSubmitsIntoAnExistingSelectedTTY() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
            .reply(makeReply()),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalSelectedTabTTYReply("/dev/ttys001")),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalSelectedTabTTYReply("/dev/ttys001")),
        ]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalTabPollAttempts: 2,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .terminalTabCreationTimedOut(
            TerminalTabCreationEvidence(
                initialTabCount: 1,
                latestTabCount: 2,
                sawExpectedTabCount: true,
                selectedTabTTYBecameReady: true
            )
        ))
        #expect(error?.diagnosticCode.rawValue ==
            "terminal-tab-identity-timeout")
        #expect(!sender.events.contains(where: { $0.eventID == eventCode("dosc") }))
    }

    @Test
    func terminalNewTabReportsIdentityAmbiguityWhenAnotherTabAppears() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
            .reply(makeReply()),
            .reply(makeTerminalTabCountReply(3)),
        ]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .terminalTabCreationTimedOut(
            TerminalTabCreationEvidence(
                initialTabCount: 1,
                latestTabCount: 3,
                sawExpectedTabCount: false,
                selectedTabTTYBecameReady: false
            )
        ))
        #expect(error?.diagnosticCode.rawValue ==
            "terminal-tab-identity-timeout")
        #expect(!sender.events.contains(where: { $0.eventID == eventCode("dosc") }))
    }

    @Test
    func terminalNewTabRechecksIdentityAfterReadingTheSelectedTTY() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
            .reply(makeReply()),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalSelectedTabTTYReply("/dev/ttys009")),
            .reply(makeTerminalTabTTYsReply([
                "/dev/ttys001",
                "/dev/ttys009",
                "/dev/ttys010",
            ])),
        ]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .terminalTabCreationTimedOut(
            TerminalTabCreationEvidence(
                initialTabCount: 1,
                latestTabCount: 3,
                sawExpectedTabCount: true,
                selectedTabTTYBecameReady: true
            )
        ))
        #expect(error?.diagnosticCode.rawValue ==
            "terminal-tab-identity-timeout")
        #expect(!sender.events.contains(where: { $0.eventID == eventCode("dosc") }))
    }

    @Test
    func terminalCreatedTabWithUnreadyTTYHasADistinctTimeoutDiagnostic()
        async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
            .reply(makeReply()),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalSelectedTabTTYNotReadyReply()),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalSelectedTabTTYNotReadyReply()),
        ]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalTabPollAttempts: 2,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        let expected = TerminalAdapterError.terminalTabCreationTimedOut(
            TerminalTabCreationEvidence(
                initialTabCount: 1,
                latestTabCount: 2,
                sawExpectedTabCount: true,
                selectedTabTTYBecameReady: false
            )
        )
        #expect(error == expected)
        #expect(error?.diagnosticCode.rawValue == "terminal-tab-tty-timeout")
        #expect(!sender.events.contains(where: { $0.eventID == eventCode("dosc") }))
    }

    @Test
    func terminalNewTabRejectsAMalformedSelectedTTYWithoutSubmittingCommand()
        async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
            .reply(makeReply()),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeReply()),
        ]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .terminalSelectedTabTTYReplyInvalid(nil))
        #expect(sender.events.last?.eventID == eventCode("getd"))
        #expect(!sender.events.contains(where: { $0.eventID == eventCode("dosc") }))
    }

    @Test
    func terminalNewTabSystemEventsPermissionFailureIsDiagnosedBeforeShortcut()
        async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [.reply(makeTerminalWindowIDReply(42))]
        sender.permissionStatusesByBundleIdentifier[
            NativeAppleEvent.systemEventsBundleIdentifier
        ] = -1743
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .systemEventsAutomationPermissionDenied)
        #expect(sender.permissionRequests == [
            hostPermissionRequest(.terminal),
            systemEventsPermissionRequest(),
        ])
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(sender.accessibilityPermissionRequestCount == 0)
        #expect(state.activationRequests.isEmpty)
    }

    @Test
    func terminalNewTabAccessibilityFailureIsDiagnosedBeforeShortcut() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [.reply(makeTerminalWindowIDReply(42))]
        sender.accessibilityPermissionGranted = false
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .accessibilityPermissionDenied)
        #expect(sender.permissionRequests == [
            hostPermissionRequest(.terminal),
            systemEventsPermissionRequest(),
        ])
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(sender.accessibilityPermissionRequestCount == 1)
        #expect(state.activationRequests.isEmpty)
    }

    @Test
    func terminalNewTabFailsClosedWhenTheShortcutDoesNotCreateATab() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalWindowIDReply(42)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
            .reply(makeReply()),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabCountReply(1)),
        ]
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalTabPollAttempts: 2,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .terminalTabCreationTimedOut(
            TerminalTabCreationEvidence(
                initialTabCount: 1,
                latestTabCount: 1,
                sawExpectedTabCount: false,
                selectedTabTTYBecameReady: false
            )
        ))
        #expect(sender.events.map(\.eventID) == [
            eventCode("getd"),
            eventCode("getd"),
            eventCode("cnte"),
            eventCode("getd"),
            eventCode("kprs"),
            eventCode("cnte"),
            eventCode("cnte"),
        ])
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
        #expect(sender.accessibilityPermissionRequestCount == 0)
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
        #expect(sender.events.map(\.eventID) == [
            eventCode("getd"),
            eventCode("dosc"),
        ])
        #expect(opener.events.isEmpty)
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
    func terminalAutomationIsRequestedBeforeTheFirstAppleEvent() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.permissionStatusesByBundleIdentifier[
            TerminalHost.terminal.bundleIdentifier
        ] = -1743
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
        #expect(sender.permissionRequests == [hostPermissionRequest(.terminal)])
        #expect(sender.events.isEmpty)
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
        #expect(opener.events.isEmpty)
        #expect(opener.launchesWithoutInitialEvent == 1)
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
        #expect(opener.events.isEmpty)
        #expect(opener.launchesWithoutInitialEvent == 1)
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
    func iTermUnavailableLoginShellFailsBeforeLaunchingOrSubmitting() async {
        let state = TerminalApplicationStateStub()
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script,
            loginShellPathLookup: LoginShellPathLookupStub(
                path: "/missing/go2codex-shell"
            )
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newWindow
            )
        }

        #expect(error == .iTermLoginShellUnavailable)
        #expect(state.runningLookups.isEmpty)
        #expect(opener.applicationURLs.isEmpty)
        #expect(sender.events.isEmpty)
        #expect(script.events.isEmpty)
    }

    @Test
    func iTermQuietLaunchPermissionFailurePreventsSubmission() async {
        let state = TerminalApplicationStateStub()
        let opener = TerminalApplicationOpenerStub()
        opener.failure = TerminalApplicationOpenFailure(
            code: -1743,
            appleEventStatus: -1743
        )
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newTab
            )
        }

        #expect(error == .automationPermissionDenied(.iTerm2))
        expectSingleITermQuietLaunch(opener)
        #expect(state.runningLookups == ["com.googlecode.iterm2"])
        #expect(sender.events.isEmpty)
        #expect(script.events.isEmpty)
    }

    @Test
    func iTermQuietLaunchGenericFailurePreventsSubmission() async {
        let state = TerminalApplicationStateStub()
        let opener = TerminalApplicationOpenerStub()
        opener.failure = TerminalApplicationOpenFailure(code: -10810)
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newWindow
            )
        }

        #expect(error == .applicationOpenFailed(-10810))
        expectSingleITermQuietLaunch(opener)
        #expect(state.runningLookups == ["com.googlecode.iterm2"])
        #expect(sender.events.isEmpty)
        #expect(script.events.isEmpty)
    }

    @Test
    func iTermAutomationIsRequestedBeforeWindowQueriesOrScriptEvents() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.permissionStatusesByBundleIdentifier[
            TerminalHost.iTerm2.bundleIdentifier
        ] = -1743
        let script = ITermScriptExecutorStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newTab
            )
        }

        #expect(error == .automationPermissionDenied(.iTerm2))
        #expect(sender.permissionRequests == [hostPermissionRequest(.iTerm2)])
        #expect(sender.events.isEmpty)
        #expect(script.events.isEmpty)
        #expect(opener.events.isEmpty)
    }

    @Test
    func iTermColdStartPreflightsAfterBootstrapBeforeControlEvents() async throws {
        let operations = TerminalOperationLog()
        let state = TerminalApplicationStateStub()
        state.operationLog = operations
        let opener = TerminalApplicationOpenerStub()
        opener.operationLog = operations
        let sender = AppleEventSenderStub()
        sender.operationLog = operations
        sender.outcomes = [.reply(makeITermWindowReply())]
        let script = ITermScriptExecutorStub()
        script.operationLog = operations
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .iTerm2,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        expectSingleITermQuietLaunch(opener)
        #expect(sender.permissionRequests == [hostPermissionRequest(.iTerm2)])
        #expect(sender.events.map(\.eventID) == [eventCode("getd")])
        #expect(script.events.count == 1)
        #expect(state.activationRequests == [TerminalHost.iTerm2.bundleIdentifier])
        #expect(operations.values == [
            .applicationOpen,
            .automationPermission,
            .appleEvent,
            .script,
            .activation,
        ])
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
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
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
        expectNoITermApplicationOpen(opener)
        #expect(state.runningLookups == ["com.googlecode.iterm2"])
        #expect(state.activationRequests == ["com.googlecode.iterm2"])
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
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
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
        expectNoITermApplicationOpen(opener)
        #expect(state.runningLookups == ["com.googlecode.iterm2"])
        #expect(state.activationRequests.isEmpty)
    }

    @Test
    func iTermNewWindowPreflightsThenRunsOneHandler() async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .iTerm2,
            placement: .newWindow
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(sender.events.isEmpty)
        #expect(script.events.count == 1)
        try expectITermScriptInvocation(
            #require(script.events.first),
            handler: "go2codexNewWindow"
        )
        expectNoITermApplicationOpen(opener)
        #expect(state.runningLookups == ["com.googlecode.iterm2"])
        #expect(state.activationRequests.isEmpty)
    }

    @Test
    func iTermAcceptedTabIsNotReportedAsFailedWhenRevealActivationFails()
        async throws {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        state.activationResult = false
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [.reply(makeITermWindowReply())]
        let script = ITermScriptExecutorStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .iTerm2,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(script.events.count == 1)
        try expectITermScriptInvocation(
            #require(script.events.first),
            handler: "go2codexNewTab"
        )
        #expect(state.activationRequests == ["com.googlecode.iterm2"])
        expectNoITermApplicationOpen(opener)
    }

    @Test(arguments: CLIExecutable.allCases)
    func bothCLIExecutablesSupportEveryTerminalPlacement(
        executable: CLIExecutable
    ) async throws {
        let command = TerminalCommand(
            executable: executable,
            line: "cd '/Users/example/Project' && \(executable.rawValue)"
        )

        for host in TerminalHost.allCases {
            for placement in SessionPlacement.allCases {
                let state = TerminalApplicationStateStub()
                state.isRunning = true
                let opener = TerminalApplicationOpenerStub()
                let sender = AppleEventSenderStub()
                let script = ITermScriptExecutorStub()
                if host == .terminal && placement == .newTab {
                    sender.outcomes = [
                        .reply(makeTerminalWindowIDReply(42)),
                        .reply(makeTerminalWindowIDReply(42)),
                        .reply(makeTerminalTabCountReply(1)),
                        .reply(makeTerminalTabTTYsReply(["/dev/ttys001"])),
                        .reply(makeReply()),
                        .reply(makeTerminalTabCountReply(2)),
                        .reply(makeTerminalSelectedTabTTYReply(
                            "/dev/ttys009"
                        )),
                        .reply(makeTerminalTabTTYsReply([
                            "/dev/ttys001",
                            "/dev/ttys009",
                        ])),
                        .reply(makeReply()),
                    ]
                } else if host == .iTerm2 && placement == .newTab {
                    sender.outcomes = [.reply(makeITermWindowReply())]
                }
                let adapter = TerminalOpenAdapter(
                    applicationState: state,
                    applicationOpener: opener,
                    eventSender: sender,
                    iTermScriptExecutor: script,
                    loginShellPathLookup: supportedLoginShellPathLookup,
                    terminalTabPollDelay: {}
                )

                let acceptance = try await adapter.open(
                    command,
                    in: host,
                    placement: placement
                )

                #expect(acceptance == .acceptedByTerminalHost)
                switch host {
                case .terminal:
                    try expectTerminalDoScriptEvent(
                        #require(sender.events.last),
                        command: command,
                        targetTabTTY: placement == .newTab
                            ? "/dev/ttys009"
                            : nil,
                        targetWindowID: 42
                    )
                case .iTerm2:
                    try expectITermScriptInvocation(
                        #require(script.events.last),
                        handler: placement == .newTab
                            ? "go2codexNewTab"
                            : "go2codexNewWindow",
                        command: command
                    )
                }
            }
        }
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
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
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
        expectNoITermApplicationOpen(opener)
        #expect(state.runningLookups == ["com.googlecode.iterm2"])
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
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
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
        expectNoITermApplicationOpen(opener)
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
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
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
        expectNoITermApplicationOpen(opener)
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
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
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
        expectSingleITermQuietLaunch(opener)
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
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newWindow
            )
        }

        #expect(error == .iTermHandoffOutcomeUnknown(nil))
        #expect(sender.events.isEmpty)
        #expect(script.events.count == 1)
        expectSingleITermQuietLaunch(opener)
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
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newWindow
            )
        }

        #expect(error == .iTermHandoffOutcomeUnknown(nil))
        #expect(sender.events.isEmpty)
        #expect(script.events.count == 1)
        expectSingleITermQuietLaunch(opener)
    }

    @Test(arguments: [Int32(-1712), -1728, -1719, -1708, -600])
    func iTermUncertainExecutionErrorsAreOutcomeUnknownAndAreNotRetried(
        status: Int32
    ) async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let script = ITermScriptExecutorStub()
        script.error = RawAppleEventError.status(status)
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .iTerm2,
                placement: .newWindow
            )
        }

        #expect(error == .iTermHandoffOutcomeUnknown(status))
        #expect(script.events.count == 1)
        #expect(state.activationRequests.isEmpty)
        expectNoITermApplicationOpen(opener)
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
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
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
        expectNoITermApplicationOpen(opener)
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
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
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
        expectSingleITermQuietLaunch(opener)
    }

    @Test
    func iTermWindowQueryProcessNotFoundDoesNotRetryPreflight() async {
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
            iTermScriptExecutor: script,
            loginShellPathLookup: supportedLoginShellPathLookup
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
        expectNoITermApplicationOpen(opener)
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

private enum TerminalOperation: Equatable {
    case applicationOpen
    case automationPermission
    case appleEvent
    case script
    case activation
    case frontmostCheck
}

@MainActor
private final class TerminalOperationLog {
    private(set) var values: [TerminalOperation] = []

    func append(_ operation: TerminalOperation) {
        values.append(operation)
    }
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
        NativeAppleEvent.systemEventsBundleIdentifier: URL(
            fileURLWithPath: "/System/Library/CoreServices/System Events.app"
        ),
    ]
    var isRunning = false
    var activationResult = true
    var isFrontmost = true
    var frontmostResults: [Bool] = []
    var operationLog: TerminalOperationLog?
    private(set) var registrationLookups: [String] = []
    private(set) var runningLookups: [String] = []
    private(set) var frontmostLookups: [String] = []
    private(set) var activationRequests: [String] = []

    func applicationURL(bundleIdentifier: String) -> URL? {
        registrationLookups.append(bundleIdentifier)
        return applicationURLsByBundleIdentifier[bundleIdentifier]
    }

    func isRunning(bundleIdentifier: String) -> Bool {
        runningLookups.append(bundleIdentifier)
        return isRunning
    }

    func isFrontmost(bundleIdentifier: String) -> Bool {
        operationLog?.append(.frontmostCheck)
        frontmostLookups.append(bundleIdentifier)
        guard !frontmostResults.isEmpty else {
            return isFrontmost
        }
        return frontmostResults.removeFirst()
    }

    func activate(bundleIdentifier: String) -> Bool {
        operationLog?.append(.activation)
        activationRequests.append(bundleIdentifier)
        return activationResult
    }
}

@MainActor
private struct LoginShellPathLookupStub: LoginShellPathLookingUp {
    let path: String?

    func loginShellPath() -> String? {
        path
    }
}

private let testLoginShellPath = "/bin/zsh"

@MainActor
private var supportedLoginShellPathLookup: LoginShellPathLookupStub {
    LoginShellPathLookupStub(path: testLoginShellPath)
}

@MainActor
private final class TerminalApplicationOpenerStub: TerminalApplicationOpening {
    var failure: TerminalApplicationOpenFailure?
    var operationLog: TerminalOperationLog?
    private(set) var applicationURLs: [URL] = []
    private(set) var events: [NSAppleEventDescriptor] = []
    private(set) var activations: [Bool] = []
    private(set) var launchesWithoutInitialEvent = 0

    func openApplication(
        at applicationURL: URL,
        initialAppleEvent: NSAppleEventDescriptor?,
        activates: Bool
    ) async -> TerminalApplicationOpenFailure? {
        operationLog?.append(.applicationOpen)
        applicationURLs.append(applicationURL)
        if let initialAppleEvent {
            events.append(initialAppleEvent)
        } else {
            launchesWithoutInitialEvent += 1
        }
        activations.append(activates)
        await Task.yield()
        return failure
    }
}

@MainActor
private final class AppleEventSenderStub: NativeAppleEventSending {
    var outcomes: [AppleEventOutcome] = []
    var permissionStatusesByBundleIdentifier: [String: Int32] = [:]
    var accessibilityPermissionGranted = true
    var operationLog: TerminalOperationLog?
    private(set) var events: [NSAppleEventDescriptor] = []
    private(set) var permissionRequests: [AutomationPermissionRequest] = []
    private(set) var accessibilityPermissionRequestCount = 0

    func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        operationLog?.append(.appleEvent)
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

    func requestAutomationPermission(
        _ request: AutomationPermissionRequest
    ) async -> Int32 {
        operationLog?.append(.automationPermission)
        permissionRequests.append(request)
        await Task.yield()
        return permissionStatusesByBundleIdentifier[request.bundleIdentifier]
            ?? noErr
    }

    func requestAccessibilityPermission() -> Bool {
        accessibilityPermissionRequestCount += 1
        return accessibilityPermissionGranted
    }
}

@MainActor
private final class ITermScriptExecutorStub: ITermHandoffScriptExecuting {
    var result = NSAppleEventDescriptor(boolean: true)
    var error: (any Error)?
    var operationLog: TerminalOperationLog?
    private(set) var events: [NSAppleEventDescriptor] = []

    func execute(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        operationLog?.append(.script)
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
    _ event: NSAppleEventDescriptor,
    command: TerminalCommand = testCommand,
    targetsFrontWindow: Bool = false,
    targetTabTTY: String? = nil,
    targetWindowID: Int32 = 0
) throws {
    #expect(event.eventClass == eventCode("core"))
    #expect(event.eventID == eventCode("dosc"))
    #expect(targetBundleIdentifier(of: event) == "com.apple.Terminal")
    #expect(event.paramDescriptor(
        forKeyword: eventCode("----")
    )?.stringValue == command.line)
    let target = event.paramDescriptor(forKeyword: eventCode("kfil"))
    if let targetTabTTY {
        let target = try #require(target)
        #expect(target.descriptorType == eventCode("obj "))
        #expect(target.forKeyword(
            eventCode("want")
        )?.typeCodeValue == eventCode("ttab"))
        #expect(target.forKeyword(
            eventCode("form")
        )?.enumCodeValue == eventCode("test"))
        let window = try #require(target.forKeyword(eventCode("from")))
        #expect(window.forKeyword(
            eventCode("want")
        )?.typeCodeValue == eventCode("cwin"))
        #expect(window.forKeyword(
            eventCode("form")
        )?.enumCodeValue == eventCode("ID  "))
        #expect(window.forKeyword(
            eventCode("seld")
        )?.int32Value == targetWindowID)
        let predicate = try #require(target.forKeyword(eventCode("seld")))
        #expect(predicate.descriptorType == eventCode("cmpd"))
        #expect(predicate.forKeyword(
            eventCode("relo")
        )?.enumCodeValue == eventCode("=   "))
        #expect(predicate.forKeyword(
            eventCode("obj2")
        )?.stringValue == targetTabTTY)
        let tty = try #require(predicate.forKeyword(eventCode("obj1")))
        #expect(tty.forKeyword(
            eventCode("seld")
        )?.typeCodeValue == eventCode("ttty"))
        #expect(tty.forKeyword(
            eventCode("from")
        )?.descriptorType == eventCode("exmn"))
    } else if targetsFrontWindow {
        let target = try #require(target)
        #expect(target.descriptorType == eventCode("obj "))
        #expect(target.forKeyword(
            eventCode("want")
        )?.typeCodeValue == eventCode("cwin"))
        #expect(target.forKeyword(
            eventCode("seld")
        )?.int32Value == 1)
    } else {
        #expect(target == nil)
    }
}

@MainActor
private func expectSystemEventsTerminalNewTabShortcut(
    _ event: NSAppleEventDescriptor
) throws {
    #expect(event.eventClass == eventCode("prcs"))
    #expect(event.eventID == eventCode("kprs"))
    #expect(targetBundleIdentifier(of: event) == "com.apple.systemevents")
    #expect(event.paramDescriptor(
        forKeyword: eventCode("----")
    )?.stringValue == "t")
    #expect(event.paramDescriptor(
        forKeyword: eventCode("faal")
    )?.enumCodeValue == eventCode("Kcmd"))
    let subject = try #require(event.attributeDescriptor(
        forKeyword: eventCode("subj")
    ))
    #expect(subject.forKeyword(
        eventCode("seld")
    )?.stringValue == "Terminal")
}

@MainActor
private func expectITermScriptInvocation(
    _ event: NSAppleEventDescriptor,
    handler: String,
    command: TerminalCommand = testCommand
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
    let expectedCommand = try ITermCustomCommandBuilder.command(
        for: command,
        loginShellPath: testLoginShellPath
    )
    #expect(arguments.atIndex(1)?.stringValue == expectedCommand)
}

@MainActor
private func expectSingleITermQuietLaunch(
    _ opener: TerminalApplicationOpenerStub
) {
    #expect(opener.applicationURLs == [URL(
        fileURLWithPath: "/Applications/iTerm.app"
    )])
    #expect(opener.events.count == 1)
    #expect(opener.activations == [false])
    guard let event = opener.events.first else {
        return
    }
    #expect(event.eventClass == eventCode("aevt"))
    #expect(event.eventID == eventCode("odoc"))
    #expect(event.attributeDescriptor(
        forKeyword: eventCode("addr")
    ) == nil)
    let documents = event.paramDescriptor(
        forKeyword: eventCode("----")
    )
    #expect(documents?.descriptorType == eventCode("list"))
    #expect(documents?.numberOfItems == 1)
    #expect(documents?.atIndex(1)?.fileURLValue ==
        NativeAppleEvent.iTermQuietLaunchSentinelURL)
}

@MainActor
private func expectNoITermApplicationOpen(
    _ opener: TerminalApplicationOpenerStub
) {
    #expect(opener.applicationURLs.isEmpty)
    #expect(opener.events.isEmpty)
    #expect(opener.activations.isEmpty)
    #expect(opener.launchesWithoutInitialEvent == 0)
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
private func makeTerminalWindowIDReply(_ windowID: Int32)
    -> NSAppleEventDescriptor {
    let reply = makeReply()
    reply.setParam(.init(int32: windowID), forKeyword: eventCode("----"))
    return reply
}

@MainActor
private func makeTerminalTabCountReply(_ count: Int32)
    -> NSAppleEventDescriptor {
    let reply = makeReply()
    reply.setParam(.init(int32: count), forKeyword: eventCode("----"))
    return reply
}

@MainActor
private func makeTerminalTabTTYsReply(_ ttys: [String])
    -> NSAppleEventDescriptor {
    let reply = makeReply()
    let values = NSAppleEventDescriptor.list()
    for (offset, tty) in ttys.enumerated() {
        values.insert(.init(string: tty), at: offset + 1)
    }
    reply.setParam(values, forKeyword: eventCode("----"))
    return reply
}

@MainActor
private func makeTerminalSelectedTabTTYReply(_ tty: String)
    -> NSAppleEventDescriptor {
    let reply = makeReply()
    reply.setParam(.init(string: tty), forKeyword: eventCode("----"))
    return reply
}

@MainActor
private func makeTerminalSelectedTabTTYNotReadyReply()
    -> NSAppleEventDescriptor {
    let reply = makeReply()
    reply.setParam(
        .init(typeCode: eventCode("msng")),
        forKeyword: eventCode("----")
    )
    return reply
}

private func hostPermissionRequest(
    _ host: TerminalHost
) -> AutomationPermissionRequest {
    switch host {
    case .terminal:
        AutomationPermissionRequest(
            bundleIdentifier: host.bundleIdentifier,
            eventClass: eventCode("core"),
            eventID: eventCode("dosc")
        )
    case .iTerm2:
        AutomationPermissionRequest(
            bundleIdentifier: host.bundleIdentifier,
            eventClass: AutomationPermissionRequest.allEvents,
            eventID: AutomationPermissionRequest.allEvents
        )
    }
}

@MainActor
private func systemEventsPermissionRequest() -> AutomationPermissionRequest {
    AutomationPermissionRequest(
        bundleIdentifier: NativeAppleEvent.systemEventsBundleIdentifier,
        eventClass: eventCode("prcs"),
        eventID: eventCode("kprs")
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
        .init(typeCode: eventCode("msng")),
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
