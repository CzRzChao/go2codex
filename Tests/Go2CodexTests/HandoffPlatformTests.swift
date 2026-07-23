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
    func terminalColdNewWindowTargetsTheStableServiceCreatedTTY()
        async throws {
        let pending = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .notReady)
        )
        let ready = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys009"))
        )
        let state = TerminalApplicationStateStub()
        state.isRunning = false
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let service = TerminalServiceStub()
        let snapshots = TerminalSnapshotReaderStub(
            snapshots: [.empty, .empty, pending, ready, ready]
        )
        let locker = TerminalTabOperationLockerStub()
        var permissionRequestCountWhenServiceRan: Int?
        var snapshotCountWhenServiceRan: Int?
        var changedToRunningDuringServiceWait = false
        service.onPerformNewWindow = { _ in
            permissionRequestCountWhenServiceRan =
                sender.permissionRequests.count
            snapshotCountWhenServiceRan = snapshots.callCount
        }
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
            terminalTabPollAttempts: 5,
            terminalTabPollDelay: {
                if !state.isRunning {
                    state.isRunning = true
                    changedToRunningDuringServiceWait = true
                }
            }
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newWindow
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(permissionRequestCountWhenServiceRan == 0)
        #expect(snapshotCountWhenServiceRan == 0)
        #expect(changedToRunningDuringServiceWait)
        #expect(state.runningLookups == [
            TerminalHost.terminal.bundleIdentifier,
            TerminalHost.terminal.bundleIdentifier,
            TerminalHost.terminal.bundleIdentifier,
        ])
        #expect(sender.permissionRequests == [hostPermissionRequest(.terminal)])
        #expect(sender.events.count == 1)
        try expectTerminalDoScriptEvent(
            #require(sender.events.first),
            targetTabTTY: "/dev/ttys009",
            targetWindowID: 42
        )
        #expect(service.newWindowDirectoryURLs == [testWorkspace.fileURL])
        #expect(service.newTabDirectoryURLs.isEmpty)
        #expect(snapshots.callCount == 5)
        #expect(state.activationRequests == [
            TerminalHost.terminal.bundleIdentifier,
        ])
        #expect(locker.lock.releaseCount == 1)
        #expect(opener.applicationURLs.isEmpty)
        #expect(opener.events.isEmpty)
        #expect(opener.launchesWithoutInitialEvent == 0)
    }

    @Test
    func terminalColdNewWindowServiceFalseFailsBeforeTCCOrSnapshots() async {
        let state = TerminalApplicationStateStub()
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let service = TerminalServiceStub()
        service.newWindowResult = false
        let snapshots = TerminalSnapshotReaderStub()
        let locker = TerminalTabOperationLockerStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newWindow
            )
        }

        #expect(error == .terminalWindowServiceFailed)
        #expect(error?.diagnosticCode.rawValue ==
            "terminal-window-service-failed")
        #expect(service.newWindowDirectoryURLs == [testWorkspace.fileURL])
        #expect(service.newTabDirectoryURLs.isEmpty)
        #expect(sender.permissionRequests.isEmpty)
        #expect(sender.events.isEmpty)
        #expect(snapshots.callCount == 0)
        #expect(opener.applicationURLs.isEmpty)
        #expect(locker.lock.releaseCount == 1)
    }

    @Test
    func terminalColdNewWindowLaunchTimeoutFailsBeforeTCCOrSnapshots() async {
        let state = TerminalApplicationStateStub()
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let service = TerminalServiceStub()
        let snapshots = TerminalSnapshotReaderStub()
        let locker = TerminalTabOperationLockerStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
            terminalTabPollAttempts: 2,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalAdapterError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newWindow
            )
        }

        #expect(error == .terminalWindowServiceLaunchTimedOut)
        #expect(error?.diagnosticCode.rawValue ==
            "terminal-window-service-launch-timeout")
        #expect(service.newWindowDirectoryURLs == [testWorkspace.fileURL])
        #expect(sender.permissionRequests.isEmpty)
        #expect(sender.events.isEmpty)
        #expect(snapshots.callCount == 0)
        #expect(opener.applicationURLs.isEmpty)
        #expect(locker.lock.releaseCount == 1)
    }

    @Test
    func terminalColdNewWindowTCCDenialFollowsServiceWithoutSnapshots()
        async {
        let state = TerminalApplicationStateStub()
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.permissionStatusesByBundleIdentifier[
            TerminalHost.terminal.bundleIdentifier
        ] = -1743
        let service = TerminalServiceStub()
        let snapshots = TerminalSnapshotReaderStub()
        let locker = TerminalTabOperationLockerStub()
        var permissionRequestCountWhenServiceRan: Int?
        service.onPerformNewWindow = { _ in
            permissionRequestCountWhenServiceRan =
                sender.permissionRequests.count
            state.isRunning = true
        }
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newWindow
            )
        }

        #expect(error == .automationPermissionDenied(.terminal))
        #expect(permissionRequestCountWhenServiceRan == 0)
        #expect(service.newWindowDirectoryURLs == [testWorkspace.fileURL])
        #expect(sender.permissionRequests == [hostPermissionRequest(.terminal)])
        #expect(sender.events.isEmpty)
        #expect(snapshots.callCount == 0)
        #expect(opener.applicationURLs.isEmpty)
        #expect(locker.lock.releaseCount == 1)
    }

    @Test
    func terminalColdNewWindowReportsCreationTimeoutWithoutAWindow() async {
        let result = await terminalColdNewWindowFailure(
            observations: [.empty, .empty]
        )

        #expect(result.error?.diagnosticCode.rawValue ==
            "terminal-window-creation-timeout")
        #expect(result.sender.events.isEmpty)
        #expect(result.snapshots.callCount == 2)
        #expect(result.locker.lock.releaseCount == 1)
    }

    @Test
    func terminalColdNewWindowReportsTTYTimeoutWhileCreatedTTYIsPending()
        async {
        let pending = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .notReady)
        )
        let result = await terminalColdNewWindowFailure(
            observations: [pending, pending]
        )

        #expect(result.error?.diagnosticCode.rawValue ==
            "terminal-window-tty-timeout")
        #expect(result.sender.events.isEmpty)
        #expect(result.snapshots.callCount == 2)
        #expect(result.locker.lock.releaseCount == 1)
    }

    @Test
    func terminalColdNewWindowRejectsRestoreLikeMultipleWindows() async {
        let restored = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys009")),
            makeTerminalWindowSnapshot(43, .ready("/dev/ttys010"))
        )
        let result = await terminalColdNewWindowFailure(
            observations: [restored, restored]
        )

        #expect(result.error?.diagnosticCode.rawValue ==
            "terminal-window-identity-timeout")
        #expect(result.sender.events.isEmpty)
        #expect(result.snapshots.callCount == 2)
        #expect(result.locker.lock.releaseCount == 1)
    }

    @Test
    func terminalColdNewWindowRejectsRestoreLikeWindowWithMultipleTabs()
        async {
        let restored = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(
                42,
                .ready("/dev/ttys009"),
                .ready("/dev/ttys010")
            )
        )
        let result = await terminalColdNewWindowFailure(
            observations: [restored, restored]
        )

        #expect(result.error?.diagnosticCode.rawValue ==
            "terminal-window-identity-timeout")
        #expect(result.sender.events.isEmpty)
        #expect(result.snapshots.callCount == 2)
        #expect(result.locker.lock.releaseCount == 1)
    }

    @Test
    func terminalColdNewWindowTargetedDoScriptFailureDoesNotRetry()
        async throws {
        let ready = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys009"))
        )
        let state = TerminalApplicationStateStub()
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.outcomes = [.status(-1719)]
        let service = TerminalServiceStub()
        service.onPerformNewWindow = { _ in
            state.isRunning = true
        }
        let snapshots = TerminalSnapshotReaderStub(
            snapshots: [ready, ready]
        )
        let locker = TerminalTabOperationLockerStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
            terminalTabPollAttempts: 2,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newWindow
            )
        }

        #expect(error == .appleEventFailure(.terminal, status: -1719))
        #expect(sender.events.count == 1)
        try expectTerminalDoScriptEvent(
            #require(sender.events.first),
            targetTabTTY: "/dev/ttys009",
            targetWindowID: 42
        )
        #expect(service.newWindowDirectoryURLs == [testWorkspace.fileURL])
        #expect(snapshots.callCount == 2)
        #expect(opener.applicationURLs.isEmpty)
        #expect(locker.lock.releaseCount == 1)
    }

    @Test
    func terminalRunningNewTabWaitsForStableCandidateAndTargetsItExactly()
        async throws {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001"))
        )
        let pending = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(
                42,
                .ready("/dev/ttys001"),
                .notReady
            )
        )
        let candidate = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(
                42,
                .ready("/dev/ttys001"),
                .ready("/dev/ttys009")
            )
        )
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let service = TerminalServiceStub()
        let snapshots = TerminalSnapshotReaderStub(
            snapshots: [
                baseline,
                baseline,
                pending,
                candidate,
                candidate,
            ]
        )
        let locker = TerminalTabOperationLockerStub()
        locker.busyAttemptCount = 1
        var snapshotCountWhenServiceRan: Int?
        service.onPerformNewTab = { _ in
            snapshotCountWhenServiceRan = snapshots.callCount
        }
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
            terminalTabPollAttempts: 5,
            terminalTabPollDelay: {}
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(snapshotCountWhenServiceRan == 2)
        #expect(snapshots.callCount == 5)
        #expect(service.newTabDirectoryURLs == [testWorkspace.fileURL])
        #expect(locker.tryAcquireCount == 2)
        #expect(locker.lock.releaseCount == 1)
        #expect(sender.permissionRequests == [hostPermissionRequest(.terminal)])
        #expect(sender.events.count == 1)
        try expectTerminalDoScriptEvent(
            #require(sender.events.first),
            targetTabTTY: "/dev/ttys009",
            targetWindowID: 42
        )
        #expect(state.activationRequests == [
            TerminalHost.terminal.bundleIdentifier,
        ])
        #expect(opener.applicationURLs.isEmpty)
    }

    @Test
    func terminalColdNewTabUsesAnEmptyBaselineThenTargetsTheCreatedTab()
        async throws {
        let candidate = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys009"))
        )
        let state = TerminalApplicationStateStub()
        state.isRunning = false
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let service = TerminalServiceStub()
        let snapshots = TerminalSnapshotReaderStub(
            snapshots: [candidate, candidate]
        )
        let locker = TerminalTabOperationLockerStub()
        var permissionRequestCountWhenServiceRan: Int?
        service.onPerformNewTab = { _ in
            permissionRequestCountWhenServiceRan =
                sender.permissionRequests.count
            state.isRunning = true
        }
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
            terminalTabPollAttempts: 2,
            terminalTabPollDelay: {}
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(permissionRequestCountWhenServiceRan == 0)
        #expect(service.newTabDirectoryURLs == [testWorkspace.fileURL])
        #expect(snapshots.callCount == 2)
        #expect(sender.permissionRequests == [hostPermissionRequest(.terminal)])
        #expect(sender.events.count == 1)
        try expectTerminalDoScriptEvent(
            #require(sender.events.first),
            targetTabTTY: "/dev/ttys009",
            targetWindowID: 42
        )
        #expect(state.runningLookups == [
            TerminalHost.terminal.bundleIdentifier,
            TerminalHost.terminal.bundleIdentifier,
        ])
        #expect(locker.lock.releaseCount == 1)
        #expect(opener.applicationURLs.isEmpty)
    }

    @Test
    func terminalNewTabServiceFalseFailsWithoutSubmittingACommand() async {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001"))
        )
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let service = TerminalServiceStub()
        service.newTabResult = false
        let snapshots = TerminalSnapshotReaderStub(
            snapshots: [baseline, baseline]
        )
        let locker = TerminalTabOperationLockerStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
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

        #expect(error == .terminalTabServiceFailed)
        #expect(service.newTabDirectoryURLs == [testWorkspace.fileURL])
        #expect(snapshots.callCount == 2)
        #expect(sender.permissionRequests == [hostPermissionRequest(.terminal)])
        #expect(sender.events.isEmpty)
        #expect(state.activationRequests.isEmpty)
        #expect(locker.lock.releaseCount == 1)
    }

    @Test
    func terminalNewTabAutomationDenialDoesNotInvokeTheService() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        sender.permissionStatusesByBundleIdentifier[
            TerminalHost.terminal.bundleIdentifier
        ] = -1743
        let service = TerminalServiceStub()
        let snapshots = TerminalSnapshotReaderStub()
        let locker = TerminalTabOperationLockerStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
            terminalTabPollDelay: {}
        )

        let error = await capturedTerminalError {
            try await adapter.open(
                testCommand,
                in: .terminal,
                placement: .newTab
            )
        }

        #expect(error == .automationPermissionDenied(.terminal))
        #expect(sender.permissionRequests == [hostPermissionRequest(.terminal)])
        #expect(sender.events.isEmpty)
        #expect(service.newTabDirectoryURLs.isEmpty)
        #expect(snapshots.callCount == 0)
        #expect(locker.lock.releaseCount == 1)
    }

    @Test
    func terminalNewTabZeroDeltaFailsClosedWithoutDoScript() async {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001"))
        )
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let service = TerminalServiceStub()
        let snapshots = TerminalSnapshotReaderStub(
            snapshots: [
                baseline,
                baseline,
                baseline,
                baseline,
            ]
        )
        let locker = TerminalTabOperationLockerStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
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
                initialWindows: [
                    TerminalWindowTabEvidence(
                        windowID: 42,
                        tabCount: 1,
                        readyTTYCount: 1
                    ),
                ],
                latestWindows: [
                    TerminalWindowTabEvidence(
                        windowID: 42,
                        tabCount: 1,
                        readyTTYCount: 1
                    ),
                ],
                sawGlobalTabIncrease: false,
                sawPendingTTY: false,
                sawUniqueNewTTY: false,
                windowSetChanged: false,
                oldTTYOwnerChanged: false,
                snapshotUnstableAfterService: false
            )
        ))
        #expect(error?.diagnosticCode.rawValue ==
            "terminal-tab-creation-timeout")
        #expect(service.newTabDirectoryURLs.count == 1)
        #expect(sender.events.isEmpty)
        #expect(locker.lock.releaseCount == 1)
    }

    @Test
    func terminalNewTabTTYTimeoutPreservesPendingEvidence() async {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001"))
        )
        let pending = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(
                42,
                .ready("/dev/ttys001"),
                .notReady
            )
        )
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let service = TerminalServiceStub()
        let snapshots = TerminalSnapshotReaderStub(
            snapshots: [
                baseline,
                baseline,
                pending,
                pending,
            ]
        )
        let locker = TerminalTabOperationLockerStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
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
                initialWindows: [
                    TerminalWindowTabEvidence(
                        windowID: 42,
                        tabCount: 1,
                        readyTTYCount: 1
                    ),
                ],
                latestWindows: [
                    TerminalWindowTabEvidence(
                        windowID: 42,
                        tabCount: 2,
                        readyTTYCount: 1
                    ),
                ],
                sawGlobalTabIncrease: true,
                sawPendingTTY: true,
                sawUniqueNewTTY: false,
                windowSetChanged: false,
                oldTTYOwnerChanged: false,
                snapshotUnstableAfterService: false
            )
        ))
        #expect(error?.diagnosticCode.rawValue == "terminal-tab-tty-timeout")
        #expect(sender.events.isEmpty)
        #expect(locker.lock.releaseCount == 1)
    }

    @Test
    func terminalNewTabRejectsMultipleAddedTabs() async {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001"))
        )
        let ambiguous = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(
                42,
                .ready("/dev/ttys001"),
                .ready("/dev/ttys009"),
                .ready("/dev/ttys010")
            )
        )

        let result = await terminalNewTabFailure(
            baseline: baseline,
            observations: [ambiguous, ambiguous]
        )

        #expect(result.error?.diagnosticCode.rawValue ==
            "terminal-tab-identity-timeout")
        #expect(result.error == .terminalTabCreationTimedOut(
            TerminalTabCreationEvidence(
                initialWindows: [
                    TerminalWindowTabEvidence(
                        windowID: 42,
                        tabCount: 1,
                        readyTTYCount: 1
                    ),
                ],
                latestWindows: [
                    TerminalWindowTabEvidence(
                        windowID: 42,
                        tabCount: 3,
                        readyTTYCount: 3
                    ),
                ],
                sawGlobalTabIncrease: true,
                sawPendingTTY: false,
                sawUniqueNewTTY: false,
                windowSetChanged: false,
                oldTTYOwnerChanged: false,
                snapshotUnstableAfterService: false
            )
        ))
        #expect(result.sender.events.isEmpty)
        #expect(result.locker.lock.releaseCount == 1)
    }

    @Test
    func terminalNewTabTargetsASingleNewWindowFallbackExactly()
        async throws {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001")),
            makeTerminalWindowSnapshot(43, .ready("/dev/ttys002"))
        )
        let fallback = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001")),
            makeTerminalWindowSnapshot(43, .ready("/dev/ttys002")),
            makeTerminalWindowSnapshot(99, .ready("/dev/ttys009"))
        )
        #expect(fallback.totalTabCount == baseline.totalTabCount + 1)
        #expect(fallback.windows.filter { $0.windowID != 99 } ==
            baseline.windows)
        #expect(fallback.windows.first { $0.windowID == 99 }?.tabTTYValues == [
            .ready("/dev/ttys009"),
        ])
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let service = TerminalServiceStub()
        let snapshots = TerminalSnapshotReaderStub(
            snapshots: [baseline, baseline, fallback, fallback]
        )
        let locker = TerminalTabOperationLockerStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
            terminalTabPollAttempts: 2,
            terminalTabPollDelay: {}
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(snapshots.callCount == 4)
        #expect(service.newTabDirectoryURLs == [testWorkspace.fileURL])
        #expect(locker.lock.releaseCount == 1)
        #expect(sender.events.count == 1)
        try expectTerminalDoScriptEvent(
            #require(sender.events.first),
            targetTabTTY: "/dev/ttys009",
            targetWindowID: 99
        )
    }

    @Test
    func terminalNewTabWaitsForNewWindowFallbackTTYThenTargetsItExactly()
        async throws {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001")),
            makeTerminalWindowSnapshot(43, .ready("/dev/ttys002"))
        )
        let pending = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001")),
            makeTerminalWindowSnapshot(43, .ready("/dev/ttys002")),
            makeTerminalWindowSnapshot(99, .notReady)
        )
        let ready = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001")),
            makeTerminalWindowSnapshot(43, .ready("/dev/ttys002")),
            makeTerminalWindowSnapshot(99, .ready("/dev/ttys009"))
        )
        #expect(pending.totalTabCount == baseline.totalTabCount + 1)
        #expect(pending.windows.filter { $0.windowID != 99 } ==
            baseline.windows)
        #expect(pending.windows.first { $0.windowID == 99 }?.tabTTYValues == [
            .notReady,
        ])
        #expect(ready.totalTabCount == baseline.totalTabCount + 1)
        #expect(ready.windows.filter { $0.windowID != 99 } == baseline.windows)
        #expect(ready.windows.first { $0.windowID == 99 }?.tabTTYValues == [
            .ready("/dev/ttys009"),
        ])
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let service = TerminalServiceStub()
        let snapshots = TerminalSnapshotReaderStub(
            snapshots: [baseline, baseline, pending, ready, ready]
        )
        let locker = TerminalTabOperationLockerStub()
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
            terminalTabPollAttempts: 3,
            terminalTabPollDelay: {}
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(snapshots.callCount == 5)
        #expect(service.newTabDirectoryURLs == [testWorkspace.fileURL])
        #expect(locker.lock.releaseCount == 1)
        #expect(sender.events.count == 1)
        try expectTerminalDoScriptEvent(
            #require(sender.events.first),
            targetTabTTY: "/dev/ttys009",
            targetWindowID: 99
        )
    }

    @Test
    func terminalNewTabRejectsAWindowReplacement() async {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001")),
            makeTerminalWindowSnapshot(43, .ready("/dev/ttys002"))
        )
        let replacement = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001")),
            makeTerminalWindowSnapshot(99, .ready("/dev/ttys009"))
        )

        let result = await terminalNewTabFailure(
            baseline: baseline,
            observations: [replacement, replacement]
        )

        #expect(result.error?.diagnosticCode.rawValue ==
            "terminal-tab-identity-timeout")
        #expect(result.sender.events.isEmpty)
        #expect(result.locker.lock.releaseCount == 1)
    }

    @Test
    func terminalNewTabRejectsOldWindowTTYMutation() async {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001")),
            makeTerminalWindowSnapshot(43, .ready("/dev/ttys002"))
        )
        let ambiguous = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys009")),
            makeTerminalWindowSnapshot(
                43,
                .ready("/dev/ttys002"),
                .ready("/dev/ttys001")
            )
        )

        let result = await terminalNewTabFailure(
            baseline: baseline,
            observations: [ambiguous, ambiguous]
        )

        #expect(result.error?.diagnosticCode.rawValue ==
            "terminal-tab-identity-timeout")
        #expect(result.error == .terminalTabCreationTimedOut(
            TerminalTabCreationEvidence(
                initialWindows: [
                    TerminalWindowTabEvidence(
                        windowID: 42,
                        tabCount: 1,
                        readyTTYCount: 1
                    ),
                    TerminalWindowTabEvidence(
                        windowID: 43,
                        tabCount: 1,
                        readyTTYCount: 1
                    ),
                ],
                latestWindows: [
                    TerminalWindowTabEvidence(
                        windowID: 42,
                        tabCount: 1,
                        readyTTYCount: 1
                    ),
                    TerminalWindowTabEvidence(
                        windowID: 43,
                        tabCount: 2,
                        readyTTYCount: 2
                    ),
                ],
                sawGlobalTabIncrease: true,
                sawPendingTTY: false,
                sawUniqueNewTTY: true,
                windowSetChanged: false,
                oldTTYOwnerChanged: true,
                snapshotUnstableAfterService: false
            )
        ))
        #expect(result.sender.events.isEmpty)
        #expect(result.locker.lock.releaseCount == 1)
    }

    @Test
    func terminalNewTabRejectsTwoNewWindows() async {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001"))
        )
        let ambiguous = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001")),
            makeTerminalWindowSnapshot(99, .ready("/dev/ttys009")),
            makeTerminalWindowSnapshot(100, .ready("/dev/ttys010"))
        )

        let result = await terminalNewTabFailure(
            baseline: baseline,
            observations: [ambiguous, ambiguous]
        )

        #expect(result.error?.diagnosticCode.rawValue ==
            "terminal-tab-identity-timeout")
        #expect(result.sender.events.isEmpty)
        #expect(result.locker.lock.releaseCount == 1)
    }

    @Test
    func terminalNewTabRejectsNewWindowWithMultipleNewTTYs() async {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001"))
        )
        let ambiguous = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001")),
            makeTerminalWindowSnapshot(
                99,
                .ready("/dev/ttys009"),
                .ready("/dev/ttys010")
            )
        )

        let result = await terminalNewTabFailure(
            baseline: baseline,
            observations: [ambiguous, ambiguous]
        )

        #expect(result.error?.diagnosticCode.rawValue ==
            "terminal-tab-identity-timeout")
        #expect(result.sender.events.isEmpty)
        #expect(result.locker.lock.releaseCount == 1)
    }

    @Test
    func terminalNewTabRejectsSimultaneousOldAndNewWindowChanges() async {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001")),
            makeTerminalWindowSnapshot(43, .ready("/dev/ttys002"))
        )
        let ambiguous = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(
                42,
                .ready("/dev/ttys001"),
                .ready("/dev/ttys009")
            ),
            makeTerminalWindowSnapshot(43, .ready("/dev/ttys002")),
            makeTerminalWindowSnapshot(99, .ready("/dev/ttys010"))
        )

        let result = await terminalNewTabFailure(
            baseline: baseline,
            observations: [ambiguous, ambiguous]
        )

        #expect(result.error?.diagnosticCode.rawValue ==
            "terminal-tab-identity-timeout")
        #expect(result.sender.events.isEmpty)
        #expect(result.locker.lock.releaseCount == 1)
    }

    @Test
    func terminalNewTabRejectsDuplicateNewTTYs() async {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001"))
        )
        let ambiguous = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001")),
            makeTerminalWindowSnapshot(
                99,
                .ready("/dev/ttys009"),
                .ready("/dev/ttys009")
            )
        )

        let result = await terminalNewTabFailure(
            baseline: baseline,
            observations: [ambiguous, ambiguous]
        )

        #expect(result.error?.diagnosticCode.rawValue ==
            "terminal-tab-identity-timeout")
        #expect(result.sender.events.isEmpty)
        #expect(result.locker.lock.releaseCount == 1)
    }

    @Test
    func terminalNewTabReportsBusyWhenTheOperationLockNeverBecomesAvailable()
        async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let service = TerminalServiceStub()
        let snapshots = TerminalSnapshotReaderStub()
        let locker = TerminalTabOperationLockerStub()
        locker.busyAttemptCount = 2
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
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

        #expect(error == .terminalTabOperationBusy)
        #expect(locker.tryAcquireCount == 2)
        #expect(locker.lock.releaseCount == 0)
        #expect(sender.permissionRequests.isEmpty)
        #expect(sender.events.isEmpty)
        #expect(service.newTabDirectoryURLs.isEmpty)
        #expect(snapshots.callCount == 0)
    }

    @Test
    func terminalNewTabResamplesRunningStateAfterWaitingForOperationLock()
        async throws {
        let baseline = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(42, .ready("/dev/ttys001"))
        )
        let candidate = makeTerminalSnapshot(
            makeTerminalWindowSnapshot(
                42,
                .ready("/dev/ttys001"),
                .ready("/dev/ttys009")
            )
        )
        let state = TerminalApplicationStateStub()
        state.isRunning = false
        let opener = TerminalApplicationOpenerStub()
        let sender = AppleEventSenderStub()
        let service = TerminalServiceStub()
        let snapshots = TerminalSnapshotReaderStub(
            snapshots: [
                baseline,
                baseline,
                candidate,
                candidate,
            ]
        )
        let locker = TerminalTabOperationLockerStub()
        locker.busyAttemptCount = 1
        var delayCount = 0
        var runningStateWasUnsampledDuringLockWait = false
        var snapshotCountWhenServiceRan: Int?
        service.onPerformNewTab = { _ in
            snapshotCountWhenServiceRan = snapshots.callCount
        }
        let adapter = TerminalOpenAdapter(
            applicationState: state,
            applicationOpener: opener,
            eventSender: sender,
            terminalService: service,
            terminalSnapshotReader: snapshots,
            terminalTabOperationLocker: locker,
            terminalTabPollAttempts: 4,
            terminalTabPollDelay: {
                delayCount += 1
                if delayCount == 1 {
                    runningStateWasUnsampledDuringLockWait =
                        state.runningLookups.isEmpty
                    state.isRunning = true
                }
            }
        )

        let acceptance = try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )

        #expect(acceptance == .acceptedByTerminalHost)
        #expect(runningStateWasUnsampledDuringLockWait)
        #expect(snapshotCountWhenServiceRan == 2)
        #expect(snapshots.callCount == 4)
        #expect(service.newTabDirectoryURLs == [testWorkspace.fileURL])
        #expect(locker.tryAcquireCount == 2)
        #expect(locker.lock.releaseCount == 1)
        #expect(state.runningLookups == [
            TerminalHost.terminal.bundleIdentifier,
        ])
        #expect(sender.permissionRequests == [hostPermissionRequest(.terminal)])
        #expect(sender.events.count == 1)
        try expectTerminalDoScriptEvent(
            #require(sender.events.first),
            targetTabTTY: "/dev/ttys009",
            targetWindowID: 42
        )
        #expect(opener.applicationURLs.isEmpty)
    }

    @Test
    func terminalServicePerformerUsesTheExpectedNamesAndOneFileURL()
        throws {
        var capturedServiceNames: [String] = []
        var capturedPasteboardItemCounts: [Int?] = []
        var capturedURLs: [[URL]] = []
        let performer = WorkspaceTerminalServicePerformer {
            serviceName,
            pasteboard in
            capturedServiceNames.append(serviceName)
            capturedPasteboardItemCounts.append(
                pasteboard.pasteboardItems?.count
            )
            capturedURLs.append(pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: nil
            )?.compactMap {
                ($0 as? NSURL).map { $0 as URL }
            } ?? [])
            return true
        }

        let windowResult = performer.performNewWindow(
            at: testWorkspace.fileURL
        )
        let tabResult = performer.performNewTab(at: testWorkspace.fileURL)

        #expect(windowResult)
        #expect(tabResult)
        #expect(capturedServiceNames == [
            WorkspaceTerminalServicePerformer.newWindowServiceName,
            WorkspaceTerminalServicePerformer.newTabServiceName,
        ])
        #expect(capturedPasteboardItemCounts == [1, 1])
        #expect(capturedURLs == [
            [testWorkspace.fileURL],
            [testWorkspace.fileURL],
        ])
    }

    @Test
    func terminalSnapshotReaderBuildsOneCoherentFrameAcrossWindows()
        throws {
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDsReply([42, 7])),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply([.ready("/dev/ttys007")])),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalTabTTYsReply([
                .ready("/dev/ttys001"),
                .notReady,
            ])),
            .reply(makeTerminalTabCountReply(2)),
            .reply(makeTerminalWindowIDsReply([7, 42])),
        ]
        let reader = AppleEventTerminalSnapshotReader(eventSender: sender)

        let snapshot = try reader.coherentSnapshot()

        #expect(snapshot == makeTerminalSnapshot(
            makeTerminalWindowSnapshot(7, .ready("/dev/ttys007")),
            makeTerminalWindowSnapshot(
                42,
                .ready("/dev/ttys001"),
                .notReady
            )
        ))
        #expect(sender.events.map(\.eventID) == [
            eventCode("getd"),
            eventCode("cnte"),
            eventCode("getd"),
            eventCode("cnte"),
            eventCode("cnte"),
            eventCode("getd"),
            eventCode("cnte"),
            eventCode("getd"),
        ])
        #expect(sender.sendTimeouts == Array(repeating: 2, count: 8))
    }

    @Test
    func terminalSnapshotReaderRejectsAWindowSetChangeWithinTheFrame()
        throws {
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDsReply([42])),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply([.ready("/dev/ttys001")])),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalWindowIDsReply([42, 99])),
        ]
        let reader = AppleEventTerminalSnapshotReader(eventSender: sender)

        let snapshot = try reader.coherentSnapshot()

        #expect(snapshot == nil)
        #expect(sender.events.count == 5)
    }

    @Test
    func terminalSnapshotReaderRejectsDuplicateReadyTTYOwners() throws {
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .reply(makeTerminalWindowIDsReply([42, 99])),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply([.ready("/dev/ttys001")])),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalTabTTYsReply([.ready("/dev/ttys001")])),
            .reply(makeTerminalTabCountReply(1)),
            .reply(makeTerminalWindowIDsReply([99, 42])),
        ]
        let reader = AppleEventTerminalSnapshotReader(eventSender: sender)

        let snapshot = try reader.coherentSnapshot()

        #expect(snapshot == nil)
        #expect(sender.events.count == 8)
    }

    @Test
    func terminalSnapshotReaderMapsMalformedWindowCountAndTTYReplies() {
        let invalidDescriptorType = eventCode("null")

        do {
            let sender = AppleEventSenderStub()
            sender.outcomes = [.reply(makeMalformedTerminalReply())]
            let reader = AppleEventTerminalSnapshotReader(eventSender: sender)

            #expect(throws: TerminalAdapterError
                .terminalWindowListReplyInvalid(invalidDescriptorType)) {
                try reader.coherentSnapshot()
            }
        }

        do {
            let sender = AppleEventSenderStub()
            sender.outcomes = [
                .reply(makeTerminalWindowIDsReply([42])),
                .reply(makeMalformedTerminalReply()),
            ]
            let reader = AppleEventTerminalSnapshotReader(eventSender: sender)

            #expect(throws: TerminalAdapterError
                .terminalTabCountReplyInvalid(invalidDescriptorType)) {
                try reader.coherentSnapshot()
            }
        }

        do {
            let sender = AppleEventSenderStub()
            sender.outcomes = [
                .reply(makeTerminalWindowIDsReply([42])),
                .reply(makeTerminalTabCountReply(1)),
                .reply(makeMalformedTerminalReply()),
            ]
            let reader = AppleEventTerminalSnapshotReader(eventSender: sender)

            #expect(throws: TerminalAdapterError
                .terminalTabTTYListReplyInvalid(invalidDescriptorType)) {
                try reader.coherentSnapshot()
            }
        }
    }

    @Test
    func terminalSnapshotReaderMapsReplyTimeoutWithoutRetry() {
        let sender = AppleEventSenderStub()
        sender.outcomes = [
            .status(-1712),
            .reply(makeTerminalWindowIDsReply([])),
        ]
        let reader = AppleEventTerminalSnapshotReader(eventSender: sender)

        #expect(throws: TerminalAdapterError.terminalSnapshotReplyTimedOut) {
            try reader.coherentSnapshot()
        }

        #expect(sender.events.count == 1)
        #expect(sender.sendTimeouts == [2])
        #expect(sender.outcomes.count == 1)
    }

    @Test
    func terminalTabOperationLockerIsMutuallyExclusiveAndReacquiresAfterRelease()
        throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Go2Codex-HandoffPlatformTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let lockURL = temporaryDirectory.appendingPathComponent(
            "terminal-tab.lock",
            isDirectory: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        #expect(lockURL.isFileURL)
        #expect(lockURL.path.hasPrefix("/"))

        let firstLocker = WorkspaceTerminalTabOperationLocker(
            lockURL: lockURL
        )
        let secondLocker = WorkspaceTerminalTabOperationLocker(
            lockURL: lockURL
        )
        let firstLock = try #require(try firstLocker.tryAcquire())

        #expect(try secondLocker.tryAcquire() == nil)

        firstLock.release()
        let secondLock = try #require(try secondLocker.tryAcquire())
        secondLock.release()

        #expect(FileManager.default.fileExists(atPath: lockURL.path))
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
    func terminalProcessRaceOpenErrorsMapWithoutRetry() async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        opener.failure = TerminalApplicationOpenFailure(
            code: -1743,
            appleEventStatus: -1743
        )
        let sender = AppleEventSenderStub()
        sender.outcomes = [.status(-600)]
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
        #expect(sender.events.count == 1)
        #expect(opener.events.count == 1)
        #expect(opener.launchesWithoutInitialEvent == 0)
    }

    @Test
    func terminalProcessRaceGenericOpenFailureHasItsOwnCodeAndDoesNotRetry()
        async {
        let state = TerminalApplicationStateStub()
        state.isRunning = true
        let opener = TerminalApplicationOpenerStub()
        opener.failure = TerminalApplicationOpenFailure(code: -10810)
        let sender = AppleEventSenderStub()
        sender.outcomes = [.status(-600)]
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
        #expect(sender.events.count == 1)
        #expect(opener.events.count == 1)
        #expect(opener.launchesWithoutInitialEvent == 0)
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
        let workspace = try Workspace(
            absolutePath: "/Users/example/Project"
        )
        let command = TerminalCommand(
            executable: executable,
            line: "cd '/Users/example/Project' && \(executable.rawValue)",
            workspace: workspace
        )

        for host in TerminalHost.allCases {
            for placement in SessionPlacement.allCases {
                let state = TerminalApplicationStateStub()
                state.isRunning = true
                let opener = TerminalApplicationOpenerStub()
                let sender = AppleEventSenderStub()
                let script = ITermScriptExecutorStub()
                let service = TerminalServiceStub()
                let snapshots = TerminalSnapshotReaderStub()
                let locker = TerminalTabOperationLockerStub()
                if host == .terminal && placement == .newTab {
                    let baseline = makeTerminalSnapshot(
                        makeTerminalWindowSnapshot(
                            42,
                            .ready("/dev/ttys001")
                        )
                    )
                    let candidate = makeTerminalSnapshot(
                        makeTerminalWindowSnapshot(
                            42,
                            .ready("/dev/ttys001"),
                            .ready("/dev/ttys009")
                        )
                    )
                    snapshots.snapshots = [
                        baseline,
                        baseline,
                        candidate,
                        candidate,
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
                    terminalService: service,
                    terminalSnapshotReader: snapshots,
                    terminalTabOperationLocker: locker,
                    terminalTabPollAttempts: 4,
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
                        targetWindowID: placement == .newTab ? 42 : 0
                    )
                    #expect(service.newTabDirectoryURLs == (
                        placement == .newTab ? [workspace.fileURL] : []
                    ))
                    #expect(service.newWindowDirectoryURLs.isEmpty)
                case .iTerm2:
                    #expect(service.newTabDirectoryURLs.isEmpty)
                    #expect(service.newWindowDirectoryURLs.isEmpty)
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
private final class TerminalServiceStub: TerminalServicePerforming {
    var newWindowResult = true
    var newTabResult = true
    var onPerformNewWindow: (@MainActor (URL) -> Void)?
    var onPerformNewTab: (@MainActor (URL) -> Void)?
    private(set) var newWindowDirectoryURLs: [URL] = []
    private(set) var newTabDirectoryURLs: [URL] = []

    func performNewWindow(at directoryURL: URL) -> Bool {
        newWindowDirectoryURLs.append(directoryURL)
        onPerformNewWindow?(directoryURL)
        return newWindowResult
    }

    func performNewTab(at directoryURL: URL) -> Bool {
        newTabDirectoryURLs.append(directoryURL)
        onPerformNewTab?(directoryURL)
        return newTabResult
    }
}

@MainActor
private final class TerminalSnapshotReaderStub: TerminalSnapshotReading {
    var snapshots: [TerminalSnapshot?]
    var error: (any Error)?
    private(set) var callCount = 0

    init(snapshots: [TerminalSnapshot?] = []) {
        self.snapshots = snapshots
    }

    func coherentSnapshot() throws -> TerminalSnapshot? {
        callCount += 1
        if let error {
            throw error
        }
        guard !snapshots.isEmpty else {
            return nil
        }
        return snapshots.removeFirst()
    }
}

private final class TerminalTabOperationLockStub:
    TerminalTabOperationLock {
    private(set) var releaseCount = 0

    func release() {
        releaseCount += 1
    }
}

@MainActor
private final class TerminalTabOperationLockerStub:
    TerminalTabOperationLocking {
    var busyAttemptCount = 0
    var error: (any Error)?
    let lock = TerminalTabOperationLockStub()
    private(set) var tryAcquireCount = 0

    func tryAcquire() throws -> (any TerminalTabOperationLock)? {
        tryAcquireCount += 1
        if let error {
            throw error
        }
        guard tryAcquireCount > busyAttemptCount else {
            return nil
        }
        return lock
    }
}

@MainActor
private final class AppleEventSenderStub: NativeAppleEventSending {
    var outcomes: [AppleEventOutcome] = []
    var permissionStatusesByBundleIdentifier: [String: Int32] = [:]
    var operationLog: TerminalOperationLog?
    private(set) var events: [NSAppleEventDescriptor] = []
    private(set) var sendTimeouts: [TimeInterval?] = []
    private(set) var permissionRequests: [AutomationPermissionRequest] = []

    func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        try recordAndSend(event, timeout: nil)
    }

    func send(
        _ event: NSAppleEventDescriptor,
        timeout: TimeInterval
    ) throws -> NSAppleEventDescriptor {
        try recordAndSend(event, timeout: timeout)
    }

    private func recordAndSend(
        _ event: NSAppleEventDescriptor,
        timeout: TimeInterval?
    ) throws -> NSAppleEventDescriptor {
        operationLog?.append(.appleEvent)
        events.append(event)
        sendTimeouts.append(timeout)
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
    line: "cd '/Users/example/Project With Space' && codex",
    workspace: testWorkspace
)

private let testWorkspace = try! Workspace(
    absolutePath: "/Users/example/Project With Space"
)

private func makeTerminalSnapshot(
    _ windows: TerminalWindowSnapshot...
) -> TerminalSnapshot {
    TerminalSnapshot(windows: windows)
}

private func makeTerminalWindowSnapshot(
    _ windowID: Int32,
    _ tabTTYValues: TerminalTabTTYValue...
) -> TerminalWindowSnapshot {
    TerminalWindowSnapshot(
        windowID: windowID,
        tabTTYValues: tabTTYValues
    )
}

@MainActor
private func terminalNewTabFailure(
    baseline: TerminalSnapshot,
    observations: [TerminalSnapshot]
) async -> (
    error: TerminalAdapterError?,
    sender: AppleEventSenderStub,
    locker: TerminalTabOperationLockerStub
) {
    let state = TerminalApplicationStateStub()
    state.isRunning = true
    let opener = TerminalApplicationOpenerStub()
    let sender = AppleEventSenderStub()
    let service = TerminalServiceStub()
    var snapshotValues: [TerminalSnapshot?] = [
        baseline,
        baseline,
    ]
    snapshotValues.append(contentsOf: observations.map(Optional.some))
    let snapshots = TerminalSnapshotReaderStub(
        snapshots: snapshotValues
    )
    let locker = TerminalTabOperationLockerStub()
    let adapter = TerminalOpenAdapter(
        applicationState: state,
        applicationOpener: opener,
        eventSender: sender,
        terminalService: service,
        terminalSnapshotReader: snapshots,
        terminalTabOperationLocker: locker,
        terminalTabPollAttempts: max(2, observations.count),
        terminalTabPollDelay: {}
    )

    let error = await capturedTerminalAdapterError {
        try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newTab
        )
    }
    return (error, sender, locker)
}

@MainActor
private func terminalColdNewWindowFailure(
    observations: [TerminalSnapshot]
) async -> (
    error: TerminalAdapterError?,
    sender: AppleEventSenderStub,
    snapshots: TerminalSnapshotReaderStub,
    locker: TerminalTabOperationLockerStub
) {
    let state = TerminalApplicationStateStub()
    let opener = TerminalApplicationOpenerStub()
    let sender = AppleEventSenderStub()
    let service = TerminalServiceStub()
    service.onPerformNewWindow = { _ in
        state.isRunning = true
    }
    let snapshots = TerminalSnapshotReaderStub(
        snapshots: observations.map(Optional.some)
    )
    let locker = TerminalTabOperationLockerStub()
    let adapter = TerminalOpenAdapter(
        applicationState: state,
        applicationOpener: opener,
        eventSender: sender,
        terminalService: service,
        terminalSnapshotReader: snapshots,
        terminalTabOperationLocker: locker,
        terminalTabPollAttempts: max(2, observations.count),
        terminalTabPollDelay: {}
    )

    let error = await capturedTerminalAdapterError {
        try await adapter.open(
            testCommand,
            in: .terminal,
            placement: .newWindow
        )
    }
    return (error, sender, snapshots, locker)
}

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
private func makeTerminalWindowIDsReply(
    _ windowIDs: [Int32]
) -> NSAppleEventDescriptor {
    let reply = makeReply()
    let values = NSAppleEventDescriptor.list()
    for (offset, windowID) in windowIDs.enumerated() {
        values.insert(.init(int32: windowID), at: offset + 1)
    }
    reply.setParam(values, forKeyword: eventCode("----"))
    return reply
}

@MainActor
private func makeTerminalTabCountReply(
    _ count: Int32
) -> NSAppleEventDescriptor {
    let reply = makeReply()
    reply.setParam(.init(int32: count), forKeyword: eventCode("----"))
    return reply
}

@MainActor
private func makeTerminalTabTTYsReply(
    _ values: [TerminalTabTTYValue]
) -> NSAppleEventDescriptor {
    let reply = makeReply()
    let descriptors = NSAppleEventDescriptor.list()
    for (offset, value) in values.enumerated() {
        let descriptor: NSAppleEventDescriptor
        switch value {
        case let .ready(tty):
            descriptor = .init(string: tty)
        case .notReady:
            descriptor = .init(typeCode: eventCode("msng"))
        }
        descriptors.insert(descriptor, at: offset + 1)
    }
    reply.setParam(descriptors, forKeyword: eventCode("----"))
    return reply
}

@MainActor
private func makeMalformedTerminalReply() -> NSAppleEventDescriptor {
    let reply = makeReply()
    reply.setParam(.null(), forKeyword: eventCode("----"))
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
