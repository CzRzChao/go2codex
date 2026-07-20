import AppKit
import Foundation
import Testing
@testable import Go2CodexCore

@Suite("Launcher AppKit modifier bridge")
@MainActor
struct LauncherModifierBridgeTests {
    @Test
    func appKitRawFlagsMapOnlyTheSupportedRoutingFlags() {
        let appKitFlags: NSEvent.ModifierFlags = [
            .option,
            .shift,
            .capsLock,
            .function,
            .command,
            .control,
            .numericPad,
        ]
        let snapshot = InvocationSnapshot(
            modifierFlagsRawValue: appKitFlags.rawValue,
            pointerLocation: .zero
        )

        #expect(snapshot.routingModifierFlags == [
            .option,
            .shift,
            .capsLock,
            .function,
            .command,
            .control,
        ])
        #expect(!snapshot.routingModifierFlags.isEmpty)
    }
}

@Suite("Launcher preferences production reader")
@MainActor
struct LauncherPreferencesReaderTests {
    @Test
    func everyLoadCreatesAFreshDomainReaderAndSeesTheLatestEnvelope() throws {
        let firstEnvelope = testEnvelope(defaultTarget: .codexApp)
        let secondEnvelope = testEnvelope(defaultTarget: .claudeCodeCLI)
        let stores = [
            LauncherDefaultsStub(storage: [
                PreferencesStorageKey.envelope: try PreferencesCodec().encode(firstEnvelope),
            ]),
            LauncherDefaultsStub(storage: [
                PreferencesStorageKey.envelope: try PreferencesCodec().encode(secondEnvelope),
            ]),
        ]
        var domainReads = 0
        var factoryDomains: [String] = []
        var nextStore = 0
        let reader = UserDefaultsPreferencesReader(
            domainProvider: {
                domainReads += 1
                return "io.github.czrzchao.go2codex.test"
            },
            defaultsFactory: { domain in
                factoryDomains.append(domain)
                defer { nextStore += 1 }
                return stores[nextStore]
            }
        )

        #expect(try reader.loadPreferences() == .configured(firstEnvelope))
        #expect(try reader.loadPreferences() == .configured(secondEnvelope))
        #expect(domainReads == 2)
        #expect(factoryDomains == [
            "io.github.czrzchao.go2codex.test",
            "io.github.czrzchao.go2codex.test",
        ])
    }

    @Test
    func absentEnvelopeIsFirstRun() throws {
        let reader = UserDefaultsPreferencesReader(
            domainProvider: { "test.domain" },
            defaultsFactory: { _ in LauncherDefaultsStub() }
        )

        #expect(try reader.loadPreferences() == .firstRun)
    }

    @Test
    func legacyOptionTriggerIsReadAsShiftWithoutAWriteBoundary() throws {
        let legacyData = Data("""
        {
          "schemaVersion": 1,
          "firstRunCompletion": "completed",
          "defaultTarget": "codex-app",
          "alternateTrigger": "option-click",
          "defaultTerminalHost": "terminal-app",
          "sessionPlacement": "new-tab"
        }
        """.utf8)
        let reader = UserDefaultsPreferencesReader(
            domainProvider: { "test.domain" },
            defaultsFactory: { _ in
                LauncherDefaultsStub(storage: [
                    PreferencesStorageKey.envelope: legacyData,
                ])
            }
        )

        guard case let .configured(envelope) = try reader.loadPreferences() else {
            Issue.record("Expected migrated launcher preferences")
            return
        }
        #expect(envelope.alternateTrigger == .shiftClick)
    }

    @Test
    func nonDataEnvelopeFailsWithTheStableInvalidTypeError() {
        let reader = UserDefaultsPreferencesReader(
            domainProvider: { "test.domain" },
            defaultsFactory: { _ in
                LauncherDefaultsStub(storage: [
                    PreferencesStorageKey.envelope: "not-data",
                ])
            }
        )

        #expect(capturedPreferencesReadError(reader) == .invalidStoredType)
    }

    @Test
    func missingAndUnavailableDomainsRemainDistinct() {
        let missing = UserDefaultsPreferencesReader(
            domainProvider: { nil },
            defaultsFactory: { _ in LauncherDefaultsStub() }
        )
        let empty = UserDefaultsPreferencesReader(
            domainProvider: { "" },
            defaultsFactory: { _ in LauncherDefaultsStub() }
        )
        var requestedDomain: String?
        let unavailable = UserDefaultsPreferencesReader(
            domainProvider: { "unavailable.domain" },
            defaultsFactory: {
                requestedDomain = $0
                return nil
            }
        )

        #expect(capturedPreferencesReadError(missing) == .missingDomain)
        #expect(capturedPreferencesReadError(empty) == .missingDomain)
        #expect(capturedPreferencesReadError(unavailable) == .unavailableDomain)
        #expect(requestedDomain == "unavailable.domain")
    }
}

@Suite("Launcher target availability production glue")
@MainActor
struct LauncherTargetAvailabilityTests {
    @Test
    func desktopAvailabilityUsesTheExactDeepLinkAndExpectedHandlerIdentity() throws {
        let workspace = try Workspace(absolutePath: "/Users/example/Project With Space")
        let cases: [(AgentTarget, String)] = [
            (.codexApp, "com.openai.codex"),
            (.claudeDesktopCode, "com.anthropic.claudefordesktop"),
        ]

        for (target, expectedHandlerIdentifier) in cases {
            let expectedDeepLink = try DesktopURLBuilder.url(
                for: target,
                workspace: workspace
            )
            let applicationURL = URL(
                fileURLWithPath: "/Applications/\(target.rawValue).app"
            )
            let locator = LauncherApplicationLocatorStub()
            locator.openURLResult = applicationURL
            locator.identifiersByApplicationURL[applicationURL] = expectedHandlerIdentifier
            let service = TargetAvailabilityService(applicationLocator: locator)

            #expect(try service.availability(
                for: target,
                workspace: workspace,
                terminalHost: .terminal
            ) == .available)
            #expect(locator.openURLQueries == [expectedDeepLink])
            #expect(locator.applicationIdentifierQueries == [applicationURL])

            locator.identifiersByApplicationURL[applicationURL] = "com.example.scheme-claimant"
            #expect(try service.availability(
                for: target,
                workspace: workspace,
                terminalHost: .terminal
            ) == .unavailable(.desktopHandlerMissing(target)))
        }
    }

    @Test
    func cliAvailabilityUsesOnlyTheSelectedTerminalBundleIdentifier() throws {
        let workspace = try Workspace(absolutePath: "/Users/example/project")
        let cases: [(AgentTarget, TerminalHost)] = [
            (.codexCLI, .terminal),
            (.claudeCodeCLI, .iTerm2),
        ]

        for (target, terminalHost) in cases {
            let locator = LauncherApplicationLocatorStub()
            locator.applicationURLsByIdentifier[terminalHost.bundleIdentifier] = URL(
                fileURLWithPath: "/Applications/Terminal Host.app"
            )
            let service = TargetAvailabilityService(applicationLocator: locator)

            #expect(try service.availability(
                for: target,
                workspace: workspace,
                terminalHost: terminalHost
            ) == .available)
            #expect(locator.bundleIdentifierQueries == [terminalHost.bundleIdentifier])
            #expect(locator.openURLQueries.isEmpty)

            locator.applicationURLsByIdentifier.removeAll()
            #expect(try service.availability(
                for: target,
                workspace: workspace,
                terminalHost: terminalHost
            ) == .unavailable(.terminalHostMissing(terminalHost)))
        }
    }
}

@Suite("Launcher target picker panel wiring")
@MainActor
struct LauncherTargetPickerPanelTests {
    @Test
    func nonactivatingPanelCarriesFixedItemsAndAvailability() throws {
        let session = try makeSession()
        let expectedAction = #selector(TargetPickerPanelSession.selectTarget(_:))

        #expect(session.panel.styleMask.contains(.nonactivatingPanel))
        #expect(!session.panel.styleMask.contains(.titled))
        #expect(session.panel.canBecomeKey)
        #expect(!session.panel.canBecomeMain)
        #expect(!session.panel.hidesOnDeactivate)
        #expect(session.panel.level == .popUpMenu)
        #expect(session.panel.contentView is NSVisualEffectView)
        #expect(session.buttons.map(\.title) == AgentTargetCatalog.targets.map(\.localizedPickerTitle))
        #expect(session.buttons.map(\.tag) == [0, 1, 2, 3])
        #expect(session.buttons.map { $0.state == .on } == [false, false, true, false])
        #expect(session.buttons.map(\.isEnabled) == [true, false, true, false])
        #expect(session.buttons.allSatisfy { $0.action == expectedAction })
        #expect(session.buttons.allSatisfy { $0.target === session })
    }

    @Test
    func selectionWinsOnceAndRemovesTheOutsideClickMonitor() throws {
        var stopCodes: [NSApplication.ModalResponse] = []
        var outsideClick: TargetPickerOutsideClickHandler?
        let monitor = NSObject()
        var removedMonitors: [Any] = []
        var session: TargetPickerPanelSession!
        session = try makeSession(
            runModal: { _ in
                session.selectTarget(session.buttons[2])
                outsideClick?()
                return .stop
            },
            stopModal: { stopCodes.append($0) },
            installOutsideClickMonitor: {
                outsideClick = $0
                return monitor
            },
            removeOutsideClickMonitor: { removedMonitors.append($0) }
        )

        #expect(session.present() == .select(index: 2))
        #expect(stopCodes == [.stop])
        #expect(removedMonitors.count == 1)
        #expect((removedMonitors[0] as? NSObject) === monitor)
    }

    @Test
    func outsideClickCancelsOnceAndCannotBeOverwritten() throws {
        var stopCodes: [NSApplication.ModalResponse] = []
        var outsideClick: TargetPickerOutsideClickHandler?
        let monitor = NSObject()
        var removedMonitors: [Any] = []
        var session: TargetPickerPanelSession!
        session = try makeSession(
            runModal: { _ in
                outsideClick?()
                outsideClick?()
                session.selectTarget(session.buttons[0])
                return .stop
            },
            stopModal: { stopCodes.append($0) },
            installOutsideClickMonitor: {
                outsideClick = $0
                return monitor
            },
            removeOutsideClickMonitor: { removedMonitors.append($0) }
        )

        #expect(session.present() == .cancel)
        #expect(stopCodes == [.stop])
        #expect(removedMonitors.count == 1)
        #expect((removedMonitors[0] as? NSObject) === monitor)
    }

    @Test
    func escapeKeyCancelsExactlyOnceAndRemovesTheMonitor() throws {
        var stopCodes: [NSApplication.ModalResponse] = []
        let monitor = NSObject()
        var removedMonitors: [Any] = []
        var session: TargetPickerPanelSession!
        session = try makeSession(
            runModal: { _ in
                session.panel.keyDown(with: escapeKeyEvent())
                session.panel.keyDown(with: escapeKeyEvent())
                return .stop
            },
            stopModal: { stopCodes.append($0) },
            installOutsideClickMonitor: { _ in monitor },
            removeOutsideClickMonitor: { removedMonitors.append($0) }
        )

        #expect(session.present() == .cancel)
        #expect(stopCodes == [.stop])
        #expect(removedMonitors.count == 1)
        #expect((removedMonitors[0] as? NSObject) === monitor)
    }

    @Test
    func missingOutsideClickMonitorStillAllowsSelection() throws {
        var session: TargetPickerPanelSession!
        session = try makeSession(
            runModal: { _ in
                session.selectTarget(session.buttons[0])
                return .stop
            },
            installOutsideClickMonitor: { _ in nil }
        )

        #expect(session.present() == .select(index: 0))
    }

    @Test
    func monitorIsRemovedWhenTheModalLoopReturnsWithoutAnAction() throws {
        let monitor = NSObject()
        var removedMonitors: [Any] = []
        let session = try makeSession(
            installOutsideClickMonitor: { _ in monitor },
            removeOutsideClickMonitor: { removedMonitors.append($0) }
        )

        #expect(session.present() == .cancel)
        #expect(removedMonitors.count == 1)
        #expect((removedMonitors[0] as? NSObject) === monitor)
    }

    @Test
    func synchronousMonitorCancellationSkipsPresentationAndStillRemovesItsToken() throws {
        let monitor = NSObject()
        var showCount = 0
        var runModalCount = 0
        var removedMonitors: [Any] = []
        let session = try TargetPickerPanelSession(
            plan: pickerPlan(),
            frame: NSRect(x: 100, y: 100, width: 240, height: 124),
            runModal: { _ in
                runModalCount += 1
                return .stop
            },
            showPanel: { _ in showCount += 1 },
            hidePanel: { _ in },
            installOutsideClickMonitor: { handler in
                handler()
                return monitor
            },
            removeOutsideClickMonitor: { removedMonitors.append($0) }
        )

        #expect(session.present() == .cancel)
        #expect(showCount == 0)
        #expect(runModalCount == 0)
        #expect(removedMonitors.count == 1)
        #expect((removedMonitors[0] as? NSObject) === monitor)
    }

    private func makeSession(
        runModal: @escaping TargetPickerRunModal = { _ in .stop },
        stopModal: @escaping TargetPickerStopModal = { _ in },
        installOutsideClickMonitor: @escaping TargetPickerInstallOutsideClickMonitor = { _ in nil },
        removeOutsideClickMonitor: @escaping TargetPickerRemoveOutsideClickMonitor = { _ in }
    ) throws -> TargetPickerPanelSession {
        try TargetPickerPanelSession(
            plan: pickerPlan(),
            frame: NSRect(x: 100, y: 100, width: 240, height: 124),
            runModal: runModal,
            stopModal: stopModal,
            showPanel: { _ in },
            hidePanel: { _ in },
            installOutsideClickMonitor: installOutsideClickMonitor,
            removeOutsideClickMonitor: removeOutsideClickMonitor
        )
    }

    private func escapeKeyEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        )!
    }

    private func pickerPlan() -> TargetPickerPlan {
        TargetPickerPlan(
            defaultTarget: .claudeDesktopCode,
            availability: [
                .codexApp: .available,
                .codexCLI: .unavailable(.terminalHostMissing(.terminal)),
                .claudeDesktopCode: .available,
                .claudeCodeCLI: .unavailable(.notEvaluated),
            ]
        )
    }
}

@Suite("Launcher target picker panel frame")
struct LauncherTargetPickerPanelFrameTests {
    @Test
    func panelPrefersBelowThePointerAndClampsHorizontally() throws {
        let frame = try TargetPickerPanelFrameResolver.frame(
            near: ScreenPoint(x: 990, y: 850),
            panelSize: ScreenPoint(x: 240, y: 124),
            in: [ScreenRect(x: 0, y: 0, width: 1_000, height: 900)]
        )

        #expect(frame == ScreenRect(x: 760, y: 726, width: 240, height: 124))
    }

    @Test
    @MainActor
    func panelSizeScalesWithTargetCountRatherThanBeingFixed() {
        let expectedHeight = Double(
            TargetPickerPanelSession.verticalInset * 2
                + CGFloat(AgentTargetCatalog.targets.count)
                * TargetPickerPanelSession.rowHeight
        )
        #expect(TargetPickerPanelSession.panelSize.y == expectedHeight)
        #expect(
            TargetPickerPanelSession.panelSize.x
                == Double(TargetPickerPanelSession.panelWidth)
        )
    }

    @Test
    func panelMovesAboveThePointerWhenBelowDoesNotFit() throws {
        let frame = try TargetPickerPanelFrameResolver.frame(
            near: ScreenPoint(x: 100, y: 50),
            panelSize: ScreenPoint(x: 240, y: 124),
            in: [ScreenRect(x: 0, y: 0, width: 1_000, height: 900)]
        )

        #expect(frame == ScreenRect(x: 100, y: 50, width: 240, height: 124))
    }

    @Test
    func panelUsesTheNearestUsableScreenAndRejectsUndersizedScreens() throws {
        let frame = try TargetPickerPanelFrameResolver.frame(
            near: ScreenPoint(x: -100, y: 500),
            panelSize: ScreenPoint(x: 240, y: 124),
            in: [
                ScreenRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
                ScreenRect(x: 0, y: 0, width: 1_440, height: 900),
            ]
        )
        #expect(frame == ScreenRect(x: -240, y: 376, width: 240, height: 124))

        #expect(throws: TargetPickerError.noUsableScreen) {
            try TargetPickerPanelFrameResolver.frame(
                near: ScreenPoint(x: 0, y: 0),
                panelSize: ScreenPoint(x: 240, y: 124),
                in: [ScreenRect(x: 0, y: 0, width: 200, height: 100)]
            )
        }
    }
}

@Suite("Launcher target picker readiness gate")
@MainActor
struct LauncherTargetPickerReadinessGateTests {
    @Test
    func presentationRunsAfterMouseRelease() async throws {
        let mouseStates = [2, 1, 0]
        var mouseIndex = 0
        var trace: [String] = []
        let gate = TargetPickerReadinessGate(
            pressedMouseButtons: {
                let state = mouseStates[min(mouseIndex, mouseStates.count - 1)]
                mouseIndex += 1
                trace.append("mouse:\(state)")
                return state
            },
            waitUntil: { _, condition in
                for _ in 0..<4 {
                    if condition() {
                        return true
                    }
                }
                return false
            }
        )

        let result = try await gate.runWhenReady {
            trace.append("popup")
            return 42
        }

        #expect(result == 42)
        #expect(trace == [
            "mouse:2",
            "mouse:1",
            "mouse:0",
            "popup",
        ])
    }

    @Test
    func mouseReleaseTimeoutDoesNotRunPresentation() async {
        var didRunPopup = false
        let gate = TargetPickerReadinessGate(
            pressedMouseButtons: { 1 },
            waitUntil: { _, condition in condition() }
        )

        let error = await capturedTargetPickerError {
            _ = try await gate.runWhenReady {
                didRunPopup = true
            }
        }

        #expect(error == .mouseReleaseTimedOut)
        #expect(error?.diagnosticCode.rawValue == "target-picker-mouse-release-timeout")
        #expect(!didRunPopup)
    }

    @Test
    func cancellationIsConvertedToAStableReadinessError() async {
        var waitCalls = 0
        var didRunPopup = false
        let gate = TargetPickerReadinessGate(
            pressedMouseButtons: { 0 },
            waitUntil: { _, condition in
                waitCalls += 1
                _ = condition()
                throw CancellationError()
            }
        )

        let error = await capturedTargetPickerError {
            _ = try await gate.runWhenReady {
                didRunPopup = true
            }
        }

        #expect(error == .readinessCancelled)
        #expect(error?.diagnosticCode.rawValue == "target-picker-readiness-cancelled")
        #expect(!didRunPopup)
    }

    @Test
    func preCancelledTaskDoesNotRunPresentation() async {
        var didRunPopup = false
        let gate = TargetPickerReadinessGate(
            pressedMouseButtons: { 0 },
            waitUntil: { _, condition in condition() }
        )
        let task = Task { @MainActor () -> TargetPickerError? in
            while !Task.isCancelled {
                await Task.yield()
            }
            do {
                _ = try await gate.runWhenReady {
                    didRunPopup = true
                }
                return nil
            } catch let error as TargetPickerError {
                return error
            } catch {
                return nil
            }
        }

        task.cancel()
        let error = await task.value

        #expect(error == .readinessCancelled)
        #expect(!didRunPopup)
    }

    private func capturedTargetPickerError(
        _ operation: @MainActor () async throws -> Void
    ) async -> TargetPickerError? {
        do {
            try await operation()
            return nil
        } catch let error as TargetPickerError {
            return error
        } catch {
            return nil
        }
    }
}

@Suite("Launcher application delegate")
@MainActor
struct LauncherAppDelegateTests {
    @Test
    func launchUsesTheInitialSnapshotAndEveryReopenCapturesAgain() {
        let initial = InvocationSnapshot(
            modifierFlagsRawValue: NSEvent.ModifierFlags.option.rawValue,
            pointerLocation: NSPoint(x: 10, y: 20)
        )
        let reopened = [
            InvocationSnapshot(
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue,
                pointerLocation: NSPoint(x: 30, y: 40)
            ),
            InvocationSnapshot(
                modifierFlagsRawValue: NSEvent.ModifierFlags.command.rawValue,
                pointerLocation: NSPoint(x: 50, y: 60)
            ),
        ]
        let coordinator = LauncherInvocationSubmitterSpy()
        var captureCount = 0
        let delegate = LauncherAppDelegate(
            initialSnapshot: initial,
            coordinator: coordinator,
            snapshotCapture: {
                defer { captureCount += 1 }
                return reopened[captureCount]
            }
        )

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        #expect(!delegate.applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: false
        ))
        #expect(!delegate.applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: true
        ))

        #expect(captureCount == 2)
        #expect(coordinator.snapshots.count == 3)
        #expect(coordinator.snapshots.map(\.modifierFlagsRawValue) == [
            initial.modifierFlagsRawValue,
            reopened[0].modifierFlagsRawValue,
            reopened[1].modifierFlagsRawValue,
        ])
        #expect(coordinator.snapshots.map(\.pointerLocation) == [
            initial.pointerLocation,
            reopened[0].pointerLocation,
            reopened[1].pointerLocation,
        ])
    }
}

@Suite("Launcher failure copy")
@MainActor
struct LauncherFailureCopyTests {
    @Test(arguments: [
        FinderWorkspaceError.malformedReply,
        FinderWorkspaceError.unsupportedLocation,
    ])
    func virtualFinderViewsHaveActionableGuidance(
        error: FinderWorkspaceError
    ) {
        let failure = LauncherWorkflowFailure(
            error: error,
            stage: .finderWorkspace
        )
        let resolver = LauncherFailureCopyResolver()

        #expect(resolver.messageKey(for: failure) ==
            "This Finder view is not a folder")
        #expect(resolver.informativeTextKey(for: failure) ==
            "Open a regular folder in Finder, then try again. Smart folders such as Recents cannot be used as a workspace.")
    }
}

@MainActor
private final class LauncherDefaultsStub: LauncherUserDefaultsReading {
    var storage: [String: Any]

    init(storage: [String: Any] = [:]) {
        self.storage = storage
    }

    func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

#if DEBUG
    func bool(forKey defaultName: String) -> Bool {
        storage[defaultName] as? Bool ?? false
    }

    func integer(forKey defaultName: String) -> Int {
        storage[defaultName] as? Int ?? 0
    }
#endif
}

@MainActor
private final class LauncherApplicationLocatorStub: LauncherApplicationLocating {
    var openURLResult: URL?
    var applicationURLsByIdentifier: [String: URL] = [:]
    var identifiersByApplicationURL: [URL: String] = [:]
    private(set) var openURLQueries: [URL] = []
    private(set) var bundleIdentifierQueries: [String] = []
    private(set) var applicationIdentifierQueries: [URL] = []

    func applicationURL(toOpen url: URL) -> URL? {
        openURLQueries.append(url)
        return openURLResult
    }

    func applicationURL(withBundleIdentifier bundleIdentifier: String) -> URL? {
        bundleIdentifierQueries.append(bundleIdentifier)
        return applicationURLsByIdentifier[bundleIdentifier]
    }

    func bundleIdentifier(at applicationURL: URL) -> String? {
        applicationIdentifierQueries.append(applicationURL)
        return identifiersByApplicationURL[applicationURL]
    }
}

@MainActor
private final class LauncherInvocationSubmitterSpy: LauncherInvocationSubmitting {
    private(set) var snapshots: [InvocationSnapshot] = []

    func submit(_ snapshot: InvocationSnapshot) {
        snapshots.append(snapshot)
    }
}

@MainActor
private func capturedPreferencesReadError(
    _ reader: UserDefaultsPreferencesReader
) -> LauncherPreferencesReadError? {
    do {
        _ = try reader.loadPreferences()
        return nil
    } catch let error as LauncherPreferencesReadError {
        return error
    } catch {
        return nil
    }
}

private func testEnvelope(defaultTarget: AgentTarget) -> PreferencesEnvelope {
    PreferencesEnvelope(
        defaultTarget: defaultTarget,
        alternateTrigger: .shiftClick,
        defaultTerminalHost: .terminal,
        sessionPlacement: .newWindow
    )
}
