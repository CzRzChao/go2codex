import Foundation
import Testing
@testable import Go2CodexCore

@Suite("Production launcher workflow")
@MainActor
struct LauncherWorkflowTests {
    @Test
    func firstRunOpensSettingsWithoutReadingFinder() async throws {
        let fixture = LauncherWorkflowFixture()
        fixture.preferencesState = .firstRun

        let outcome = try await fixture.workflow().run(
            modifiers: [],
            pointerLocation: testPointer
        )

        #expect(outcome == .settingsOpened)
        expectOnlySettingsWasUsed(fixture)
    }

    @Test
    func recoveryOpensSettingsWithoutReadingFinder() async throws {
        let fixture = LauncherWorkflowFixture()
        fixture.preferencesState = .recoveryRequired(.corruptData)

        let outcome = try await fixture.workflow().run(
            modifiers: [.option],
            pointerLocation: testPointer
        )

        #expect(outcome == .settingsOpened)
        expectOnlySettingsWasUsed(fixture)
    }

    @Test
    func preferenceReadFailureOpensSettingsWithoutReadingFinder() async throws {
        let fixture = LauncherWorkflowFixture()
        fixture.preferencesError = WorkflowStubError(
            code: "preferences-test-read-failed",
            detail: "read failed"
        )

        let outcome = try await fixture.workflow().run(
            modifiers: [],
            pointerLocation: testPointer
        )

        #expect(outcome == .settingsOpened)
        expectOnlySettingsWasUsed(fixture)
    }

    @Test
    func settingsOpenFailureIsContextualAndStillSkipsFinder() async {
        let fixture = LauncherWorkflowFixture()
        fixture.preferencesState = .firstRun
        fixture.settingsError = WorkflowStubError(
            code: "settings-test-open-failed",
            detail: "settings failed"
        )

        let failure = await capturedWorkflowFailure {
            try await fixture.workflow().run(
                modifiers: [],
                pointerLocation: testPointer
            )
        }

        #expect(failure?.stage == .settingsOpen)
        #expect(failure?.code.rawValue == "settings-test-open-failed")
        #expect(failure?.detail == "settings failed")
        #expect(fixture.settingsOpenCalls == 1)
        #expect(fixture.workspaceResolveCalls == 0)
    }

    @Test
    func finderFailurePreservesPermissionContextAndStopsRouting() async {
        let fixture = LauncherWorkflowFixture()
        fixture.workspaceError = FinderWorkspaceError.automationPermissionDenied

        let failure = await capturedWorkflowFailure {
            try await fixture.workflow().run(
                modifiers: [],
                pointerLocation: testPointer
            )
        }

        #expect(failure?.stage == .finderWorkspace)
        #expect(failure?.code.rawValue == "finder-automation-denied")
        #expect(failure?.permissionContext == .finder)
        #expect(failure?.workspace == nil)
        #expect(fixture.availabilityCalls.isEmpty)
        #expect(fixture.desktopCalls.isEmpty)
        #expect(fixture.terminalCalls.isEmpty)
    }

    @Test
    func optionModifierFailsBeforeResolvingAnyFinderObject() async {
        let fixture = LauncherWorkflowFixture()

        let failure = await capturedWorkflowFailure {
            try await fixture.workflow().run(
                modifiers: [.option, .shift],
                pointerLocation: testPointer
            )
        }

        #expect(failure?.stage == .finderWorkspace)
        #expect(failure?.code.rawValue == "finder-option-modifier-unsupported")
        #expect(failure?.workspace == nil)
        #expect(fixture.workspaceResolveCalls == 0)
        #expect(fixture.availabilityCalls.isEmpty)
        #expect(fixture.pickerPlans.isEmpty)
        #expect(fixture.desktopCalls.isEmpty)
        #expect(fixture.terminalCalls.isEmpty)
    }

    @Test
    func ordinaryClickQuickLaunchesOnlyTheConfiguredDefault() async throws {
        let fixture = LauncherWorkflowFixture()
        let envelope = testEnvelope(defaultTarget: .claudeDesktopCode)
        fixture.preferencesState = .configured(envelope)

        let outcome = try await fixture.workflow().run(
            modifiers: [.command, .control],
            pointerLocation: testPointer
        )
        let expectedRequest = try DesktopOpenRequestBuilder.request(
            for: .claudeDesktopCode,
            workspace: fixture.workspace
        )

        #expect(outcome == .handoffAccepted(
            target: .claudeDesktopCode,
            terminalHost: nil,
            acceptance: .acceptedByLaunchServices
        ))
        #expect(fixture.availabilityCalls == [
            AvailabilityCall(
                target: .claudeDesktopCode,
                workspace: fixture.workspace,
                terminalHost: .terminal
            ),
        ])
        #expect(fixture.pickerPlans.isEmpty)
        #expect(fixture.desktopCalls == [
            DesktopCall(request: expectedRequest),
        ])
        #expect(fixture.terminalCalls.isEmpty)
    }

    @Test
    func cursorDesktopQuickLaunchesTheWorkspaceThroughBundleLookup() async throws {
        let fixture = LauncherWorkflowFixture()
        fixture.preferencesState = .configured(testEnvelope(
            defaultTarget: .cursorApp
        ))

        let outcome = try await fixture.workflow().run(
            modifiers: [],
            pointerLocation: testPointer
        )

        #expect(outcome == .handoffAccepted(
            target: .cursorApp,
            terminalHost: nil,
            acceptance: .acceptedByLaunchServices
        ))
        #expect(fixture.desktopCalls == [
            DesktopCall(request: DesktopOpenRequest(
                target: .cursorApp,
                url: fixture.workspace.fileURL,
                applicationLookup: .bundleIdentifier(
                    "com.todesktop.230313mzl4w4u92"
                )
            )),
        ])
        #expect(fixture.terminalCalls.isEmpty)
    }

    @Test
    func modifierPickerCancellationIsSilentAndDoesNotHandoff() async throws {
        let fixture = LauncherWorkflowFixture()
        fixture.pickerAction = .cancel

        let outcome = try await fixture.workflow().run(
            modifiers: [.shift, .capsLock],
            pointerLocation: testPointer
        )

        #expect(outcome == .cancelled)
        #expect(fixture.availabilityCalls.map(\.target) == AgentTargetCatalog.targets)
        #expect(fixture.pickerPlans.count == 1)
        #expect(fixture.pickerPlans.first?.items.map(\.target) == AgentTargetCatalog.targets)
        #expect(fixture.pickerPoints == [testPointer])
        #expect(fixture.desktopCalls.isEmpty)
        #expect(fixture.terminalCalls.isEmpty)
    }

    @Test
    func pickerOverrideDoesNotMutateTheConfiguredDefault() async throws {
        let fixture = LauncherWorkflowFixture()
        let envelope = testEnvelope(
            defaultTarget: .codexApp,
            terminalHost: .iTerm2
        )
        fixture.preferencesState = .configured(envelope)
        fixture.pickerAction = .select(index: 3)

        let outcome = try await fixture.workflow().run(
            modifiers: [.shift],
            pointerLocation: testPointer
        )

        #expect(outcome == .handoffAccepted(
            target: .claudeCodeCLI,
            terminalHost: .iTerm2,
            acceptance: .acceptedByTerminalHost
        ))
        #expect(fixture.preferencesState == .configured(envelope))
        #expect(fixture.availabilityCalls.map(\.target) ==
            AgentTargetCatalog.targets + [.claudeCodeCLI])
        #expect(fixture.terminalCalls.first?.command == TerminalCommand(
            executable: .claude,
            line: "cd '/Users/example/Project With Space' && claude",
            workspace: fixture.workspace
        ))
    }

    @Test
    func invalidPickerIndexFailsClosedThroughTheCoreStateMachine() async {
        let fixture = LauncherWorkflowFixture()
        fixture.pickerAction = .select(index: AgentTargetCatalog.targets.count)

        let failure = await capturedWorkflowFailure {
            try await fixture.workflow().run(
                modifiers: [.shift],
                pointerLocation: testPointer
            )
        }

        #expect(failure?.stage == .targetPicker)
        #expect(failure?.code.rawValue == "target-picker-invalid-selection")
        #expect(failure?.target == nil)
        #expect(fixture.desktopCalls.isEmpty)
        #expect(fixture.terminalCalls.isEmpty)
    }

    @Test
    func disabledPickerSelectionFailsClosedThroughTheCoreStateMachine() async {
        let fixture = LauncherWorkflowFixture()
        fixture.availabilityByTarget[.codexCLI] = .unavailable(
            .terminalHostMissing(.terminal)
        )
        fixture.pickerAction = .select(index: 1)

        let failure = await capturedWorkflowFailure {
            try await fixture.workflow().run(
                modifiers: [.shift],
                pointerLocation: testPointer
            )
        }

        #expect(failure?.stage == .targetPicker)
        #expect(failure?.code.rawValue == "target-picker-unavailable-selection")
        #expect(failure?.target == .codexCLI)
        #expect(fixture.desktopCalls.isEmpty)
        #expect(fixture.terminalCalls.isEmpty)
    }

    @Test
    func pickerReadinessFailureKeepsItsStageAndNeverHandoffs() async {
        let fixture = LauncherWorkflowFixture()
        fixture.pickerError = WorkflowStubError(
            code: "target-picker-mouse-release-timeout",
            detail: "originating click did not finish"
        )

        let failure = await capturedWorkflowFailure {
            try await fixture.workflow().run(
                modifiers: [.shift],
                pointerLocation: testPointer
            )
        }

        #expect(failure?.stage == .targetPicker)
        #expect(failure?.code.rawValue == "target-picker-mouse-release-timeout")
        #expect(failure?.workspace == fixture.workspace)
        #expect(fixture.pickerPlans.count == 1)
        #expect(fixture.desktopCalls.isEmpty)
        #expect(fixture.terminalCalls.isEmpty)
    }

    @Test
    func availabilityLookupFailureIncludesCandidateWorkspaceAndHost() async {
        let fixture = LauncherWorkflowFixture()
        fixture.availabilityErrorTarget = .codexApp

        let failure = await capturedWorkflowFailure {
            try await fixture.workflow().run(
                modifiers: [],
                pointerLocation: testPointer
            )
        }

        #expect(failure?.stage == .targetAvailability)
        #expect(failure?.code.rawValue == "availability-test-failed")
        #expect(failure?.target == .codexApp)
        #expect(failure?.terminalHost == .terminal)
        #expect(failure?.workspace == fixture.workspace)
        #expect(fixture.desktopCalls.isEmpty)
        #expect(fixture.terminalCalls.isEmpty)
    }

    @Test
    func unavailableDefaultFailsWithoutFallback() async {
        let fixture = LauncherWorkflowFixture()
        fixture.availabilityByTarget[.codexApp] = .unavailable(
            .desktopHandlerMissing(.codexApp)
        )

        let failure = await capturedWorkflowFailure {
            try await fixture.workflow().run(
                modifiers: [],
                pointerLocation: testPointer
            )
        }

        #expect(failure?.stage == .targetAvailability)
        #expect(failure?.code.rawValue == "codex-app-handler-unavailable")
        #expect(failure?.target == .codexApp)
        #expect(fixture.availabilityCalls.map(\.target) == [.codexApp])
        #expect(fixture.desktopCalls.isEmpty)
        #expect(fixture.terminalCalls.isEmpty)
    }

    @Test(arguments: workflowHandoffCases)
    func allSixTargetsUseTheirExpectedProductionBoundary(
        testCase: WorkflowHandoffCase
    ) async throws {
        let fixture = LauncherWorkflowFixture()
        fixture.preferencesState = .configured(testEnvelope(
            defaultTarget: testCase.target,
            terminalHost: testCase.terminalHost,
            placement: testCase.placement
        ))

        let outcome = try await fixture.workflow().run(
            modifiers: [],
            pointerLocation: testPointer
        )

        #expect(outcome == .handoffAccepted(
            target: testCase.target,
            terminalHost: testCase.target.kind == .cli
                ? testCase.terminalHost
                : nil,
            acceptance: testCase.target.kind == .desktop
                ? .acceptedByLaunchServices
                : .acceptedByTerminalHost
        ))
        if testCase.target.kind == .desktop {
            #expect(fixture.desktopCalls.count == 1)
            #expect(fixture.desktopCalls.first?.target == testCase.target)
            #expect(fixture.terminalCalls.isEmpty)
        } else {
            #expect(fixture.desktopCalls.isEmpty)
            #expect(fixture.terminalCalls.count == 1)
            #expect(fixture.terminalCalls.first?.host == testCase.terminalHost)
            #expect(fixture.terminalCalls.first?.placement == testCase.placement)
        }
    }

    @Test
    func desktopURLBuildFailureHasItsOwnStageAndNeverSubmits() async {
        let fixture = LauncherWorkflowFixture()
        let workflow = fixture.workflow(
            desktopOpenRequestBuilder: { target, _ in
                throw DesktopURLBuildError.malformedComponents(target)
            }
        )

        let failure = await capturedWorkflowFailure {
            try await workflow.run(
                modifiers: [],
                pointerLocation: testPointer
            )
        }

        #expect(failure?.stage == .desktopURL)
        #expect(failure?.code.rawValue == "desktop-url-malformed")
        #expect(failure?.target == .codexApp)
        #expect(failure?.workspace == fixture.workspace)
        #expect(fixture.desktopCalls.isEmpty)
    }

    @Test
    func desktopSubmitFailurePreservesTargetAndWorkspace() async {
        let fixture = LauncherWorkflowFixture()
        fixture.desktopError = DesktopHandoffError.openFailed(code: -42)

        let failure = await capturedWorkflowFailure {
            try await fixture.workflow().run(
                modifiers: [],
                pointerLocation: testPointer
            )
        }

        #expect(failure?.stage == .desktopHandoff)
        #expect(failure?.code.rawValue == "desktop-open-failed")
        #expect(failure?.target == .codexApp)
        #expect(failure?.workspace == fixture.workspace)
        #expect(failure?.generatedCommand == nil)
        #expect(fixture.desktopCalls.count == 1)
    }

    @Test
    func terminalCommandBuildFailureHasItsOwnStageAndNeverSubmits() async {
        let fixture = LauncherWorkflowFixture()
        fixture.preferencesState = .configured(testEnvelope(
            defaultTarget: .codexCLI
        ))
        let workflow = fixture.workflow(
            terminalCommandBuilder: { target, _ in
                throw TerminalCommandBuildError.unsupportedTarget(target)
            }
        )

        let failure = await capturedWorkflowFailure {
            try await workflow.run(
                modifiers: [],
                pointerLocation: testPointer
            )
        }

        #expect(failure?.stage == .terminalCommand)
        #expect(failure?.code.rawValue == "terminal-target-unsupported")
        #expect(failure?.target == .codexCLI)
        #expect(failure?.terminalHost == .terminal)
        #expect(failure?.workspace == fixture.workspace)
        #expect(failure?.generatedCommand == nil)
        #expect(fixture.terminalCalls.isEmpty)
    }

    @Test
    func terminalSubmitFailurePreservesCommandAndPermissionContext() async {
        let fixture = LauncherWorkflowFixture()
        fixture.preferencesState = .configured(testEnvelope(
            defaultTarget: .claudeCodeCLI,
            terminalHost: .iTerm2
        ))
        fixture.terminalError = TerminalHandoffError.automationPermissionDenied(
            .iTerm2
        )

        let failure = await capturedWorkflowFailure {
            try await fixture.workflow().run(
                modifiers: [],
                pointerLocation: testPointer
            )
        }

        #expect(failure?.stage == .terminalHandoff)
        #expect(failure?.code.rawValue == "terminal-automation-denied")
        #expect(failure?.target == .claudeCodeCLI)
        #expect(failure?.terminalHost == .iTerm2)
        #expect(failure?.workspace == fixture.workspace)
        #expect(failure?.generatedCommand ==
            "cd '/Users/example/Project With Space' && claude")
        #expect(failure?.permissionContext == .terminal(.iTerm2))
    }

    @Test
    func releaseSanitizerRemovesWorkflowPathAndGeneratedCommand() async {
        let fixture = LauncherWorkflowFixture()
        fixture.preferencesState = .configured(testEnvelope(
            defaultTarget: .codexCLI,
            terminalHost: .terminal
        ))
        let command = "cd '/Users/example/Project With Space' && codex"
        fixture.terminalError = WorkflowStubError(
            code: "terminal-test-submit-failed",
            detail: "failed at \(fixture.workspace.path) while sending \(command)"
        )

        let failure = await capturedWorkflowFailure {
            try await fixture.workflow().run(
                modifiers: [],
                pointerLocation: testPointer
            )
        }
        let record = failure.map {
            DiagnosticSanitizer.sanitize(
                DiagnosticInput(
                    applicationVersion: "0.1.0 (1)",
                    systemVersion: "test",
                    stage: $0.stage,
                    target: $0.target,
                    terminalHost: $0.terminalHost,
                    errorCode: $0.code,
                    errorDetail: $0.detail,
                    workspace: $0.workspace,
                    generatedCommand: $0.generatedCommand
                ),
                policy: .release
            )
        }

        #expect(record?.workspacePath == nil)
        #expect(record?.generatedCommand == nil)
        #expect(record?.rendered.contains(fixture.workspace.path) == false)
        #expect(record?.rendered.contains(command) == false)
    }
}

@MainActor
private final class LauncherWorkflowFixture: LauncherPreferencesLoading,
    LauncherSettingsOpening, FinderWorkspaceResolving,
    TargetAvailabilityLookingUp, TargetPicking, DesktopHandoffPerforming,
    TerminalHandoffPerforming {
    var preferencesState: PreferencesLoadState = .configured(testEnvelope())
    var preferencesError: (any Error)?
    var settingsError: (any Error)?
    var workspaceError: (any Error)?
    var availabilityErrorTarget: AgentTarget?
    var pickerError: (any Error)?
    var desktopError: (any Error)?
    var terminalError: (any Error)?
    var pickerAction: TargetPickerAction = .cancel
    var availabilityByTarget = Dictionary(
        uniqueKeysWithValues: AgentTargetCatalog.targets.map {
            ($0, TargetAvailability.available)
        }
    )
    let workspace = try! Workspace(
        absolutePath: "/Users/example/Project With Space"
    )

    private(set) var preferencesLoadCalls = 0
    private(set) var settingsOpenCalls = 0
    private(set) var workspaceResolveCalls = 0
    private(set) var availabilityCalls: [AvailabilityCall] = []
    private(set) var pickerPlans: [TargetPickerPlan] = []
    private(set) var pickerPoints: [ScreenPoint] = []
    private(set) var desktopCalls: [DesktopCall] = []
    private(set) var terminalCalls: [TerminalCall] = []

    func workflow(
        desktopOpenRequestBuilder: @escaping DesktopOpenRequestBuildingOperation = {
            try DesktopOpenRequestBuilder.request(for: $0, workspace: $1)
        },
        terminalCommandBuilder: @escaping TerminalCommandBuildingOperation = {
            try TerminalCommandBuilder.command(for: $0, workspace: $1)
        }
    ) -> LauncherWorkflow {
        LauncherWorkflow(
            preferencesLoader: self,
            settingsOpener: self,
            workspaceResolver: self,
            availabilityLookup: self,
            targetPicker: self,
            desktopHandoff: self,
            terminalHandoff: self,
            desktopOpenRequestBuilder: desktopOpenRequestBuilder,
            terminalCommandBuilder: terminalCommandBuilder
        )
    }

    func loadPreferences() throws -> PreferencesLoadState {
        preferencesLoadCalls += 1
        if let preferencesError {
            throw preferencesError
        }
        return preferencesState
    }

    func openSettings() async throws {
        settingsOpenCalls += 1
        if let settingsError {
            throw settingsError
        }
    }

    func resolveFrontmostWorkspace() throws -> Workspace {
        workspaceResolveCalls += 1
        if let workspaceError {
            throw workspaceError
        }
        return workspace
    }

    func availability(
        for target: AgentTarget,
        workspace: Workspace,
        terminalHost: TerminalHost
    ) throws -> TargetAvailability {
        availabilityCalls.append(AvailabilityCall(
            target: target,
            workspace: workspace,
            terminalHost: terminalHost
        ))
        if availabilityErrorTarget == target {
            throw WorkflowStubError(
                code: "availability-test-failed",
                detail: "availability failed"
            )
        }
        return availabilityByTarget[target] ?? .unavailable(.notEvaluated)
    }

    func action(
        for plan: TargetPickerPlan,
        at point: ScreenPoint
    ) async throws -> TargetPickerAction {
        pickerPlans.append(plan)
        pickerPoints.append(point)
        if let pickerError {
            throw pickerError
        }
        return pickerAction
    }

    func open(
        _ request: DesktopOpenRequest
    ) async throws -> HandoffAcceptance {
        desktopCalls.append(DesktopCall(request: request))
        if let desktopError {
            throw desktopError
        }
        return .acceptedByLaunchServices
    }

    func open(
        _ command: TerminalCommand,
        in host: TerminalHost,
        placement: SessionPlacement
    ) async throws -> HandoffAcceptance {
        await Task.yield()
        terminalCalls.append(TerminalCall(
            command: command,
            host: host,
            placement: placement
        ))
        if let terminalError {
            throw terminalError
        }
        return .acceptedByTerminalHost
    }
}

private struct AvailabilityCall: Equatable, Sendable {
    let target: AgentTarget
    let workspace: Workspace
    let terminalHost: TerminalHost
}

private struct DesktopCall: Equatable, Sendable {
    let request: DesktopOpenRequest

    var url: URL {
        request.url
    }

    var target: AgentTarget {
        request.target
    }
}

private struct TerminalCall: Equatable, Sendable {
    let command: TerminalCommand
    let host: TerminalHost
    let placement: SessionPlacement
}

struct WorkflowHandoffCase: Sendable, CustomTestStringConvertible {
    let target: AgentTarget
    let terminalHost: TerminalHost
    let placement: SessionPlacement

    var testDescription: String {
        "\(target.rawValue)-\(terminalHost.rawValue)-\(placement.rawValue)"
    }
}

private struct WorkflowStubError: Error, Equatable, Sendable,
    DiagnosticCodeProviding, CustomDebugStringConvertible {
    let code: String
    let detail: String

    var diagnosticCode: DiagnosticCode {
        DiagnosticCode(rawValue: code)
    }

    var debugDescription: String {
        detail
    }
}

private let workflowHandoffCases = [
    WorkflowHandoffCase(
        target: .codexApp,
        terminalHost: .terminal,
        placement: .newWindow
    ),
    WorkflowHandoffCase(
        target: .codexCLI,
        terminalHost: .terminal,
        placement: .newWindow
    ),
    WorkflowHandoffCase(
        target: .claudeDesktopCode,
        terminalHost: .iTerm2,
        placement: .newTab
    ),
    WorkflowHandoffCase(
        target: .claudeCodeCLI,
        terminalHost: .iTerm2,
        placement: .newTab
    ),
    WorkflowHandoffCase(
        target: .cursorApp,
        terminalHost: .terminal,
        placement: .newWindow
    ),
    WorkflowHandoffCase(
        target: .cursorCLI,
        terminalHost: .iTerm2,
        placement: .newTab
    ),
]

private let testPointer = ScreenPoint(x: 300, y: 200)

private func testEnvelope(
    defaultTarget: AgentTarget = .codexApp,
    terminalHost: TerminalHost = .terminal,
    placement: SessionPlacement = .newWindow
) -> PreferencesEnvelope {
    PreferencesEnvelope(
        defaultTarget: defaultTarget,
        alternateTrigger: .shiftClick,
        defaultTerminalHost: terminalHost,
        sessionPlacement: placement
    )
}

@MainActor
private func expectOnlySettingsWasUsed(_ fixture: LauncherWorkflowFixture) {
    #expect(fixture.preferencesLoadCalls == 1)
    #expect(fixture.settingsOpenCalls == 1)
    #expect(fixture.workspaceResolveCalls == 0)
    #expect(fixture.availabilityCalls.isEmpty)
    #expect(fixture.pickerPlans.isEmpty)
    #expect(fixture.desktopCalls.isEmpty)
    #expect(fixture.terminalCalls.isEmpty)
}

@MainActor
private func capturedWorkflowFailure(
    _ operation: @MainActor () async throws -> LauncherWorkflowOutcome
) async -> LauncherWorkflowFailure? {
    do {
        _ = try await operation()
        return nil
    } catch let failure as LauncherWorkflowFailure {
        return failure
    } catch {
        return nil
    }
}
