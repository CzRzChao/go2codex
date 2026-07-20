import Foundation
import Testing
@testable import Go2CodexCore

@MainActor
@Suite
struct SettingsModelTests {
    @Test
    func incompleteFirstRunNeverWritesPartialRequiredPreferences() async {
        let preferences = SettingsPreferencesFake(state: .firstRun)
        let toolbar = ToolbarSettingsFake()
        let model = makeModel(preferences: preferences, toolbar: toolbar)

        await model.loadIfNeeded()
        #expect(model.alternateTrigger == .shiftClick)
        model.selectDefaultTarget(.codexApp)
        model.selectDefaultTerminalHost(.iTerm2)
        await model.loadIfNeeded()

        #expect(model.phase == .firstRun)
        #expect(model.canCompleteFirstRun)
        #expect(preferences.completedSelections.isEmpty)
        #expect(preferences.changes.isEmpty)
        #expect(toolbar.currentStatusCalls == 1)
    }

    @Test
    func firstRunCommitsOneEnvelopeBeforeStartingTheInstallOrFallbackFlow() async {
        let events = SettingsEventLog()
        let preferences = SettingsPreferencesFake(state: .firstRun, events: events)
        let toolbar = ToolbarSettingsFake(
            supportsAutomaticMutation: false,
            status: .notInstalled,
            actionResult: .status(.notInstalled),
            events: events
        )
        let model = makeModel(preferences: preferences, toolbar: toolbar)

        await model.loadIfNeeded()
        model.selectDefaultTarget(.claudeDesktopCode)
        model.selectDefaultTerminalHost(.iTerm2)
        model.selectAlternateTrigger(.shiftClick)
        model.selectSessionPlacement(.newWindow)
        await model.completeFirstRunAndInstall()

        #expect(model.phase == .configured)
        #expect(!model.hasSaveError)
        #expect(toolbar.actions == [.install])
        #expect(events.values == [.preferencesComplete, .toolbar(.install)])
        #expect(preferences.completedSelections.count == 1)
        guard case let .configured(envelope) = preferences.state else {
            Issue.record("Expected a configured preference envelope")
            return
        }
        #expect(envelope.defaultTarget == .claudeDesktopCode)
        #expect(envelope.defaultTerminalHost == .iTerm2)
        #expect(envelope.alternateTrigger == .shiftClick)
        #expect(envelope.sessionPlacement == .newWindow)
    }

    @Test
    func automaticCapabilitySelectsInstallAndCancellationKeepsConfiguration() async {
        let preferences = SettingsPreferencesFake(state: .firstRun)
        let toolbar = ToolbarSettingsFake(
            supportsAutomaticMutation: true,
            status: .notInstalled,
            actionResult: .cancelled
        )
        let model = makeModel(preferences: preferences, toolbar: toolbar)

        await model.loadIfNeeded()
        model.selectDefaultTarget(.codexApp)
        model.selectDefaultTerminalHost(.terminal)
        await model.completeFirstRunAndInstall()

        #expect(toolbar.actions == [.install])
        #expect(model.phase == .configured)
        #expect(model.toolbarStatus == .notInstalled)
        #expect(!model.hasToolbarError)
        guard case .configured = preferences.state else {
            Issue.record("Cancellation must not discard committed preferences")
            return
        }
    }

    @Test
    func successfulFakeInstallKeepsSettingsConfiguredAndUpdatesStatus() async {
        let preferences = SettingsPreferencesFake(state: .firstRun)
        let toolbar = ToolbarSettingsFake(
            supportsAutomaticMutation: true,
            status: .notInstalled,
            actionResult: .status(.installed)
        )
        let model = makeModel(preferences: preferences, toolbar: toolbar)

        await model.loadIfNeeded()
        model.selectDefaultTarget(.codexApp)
        model.selectDefaultTerminalHost(.iTerm2)
        await model.completeFirstRunAndInstall()

        #expect(model.phase == .configured)
        #expect(model.toolbarStatus == .installed)
        #expect(toolbar.actions == [.install])
        #expect(!model.hasSaveError)
        #expect(!model.hasToolbarError)
    }

    @Test
    func failedFirstRunSaveDoesNotStartFinderSetup() async {
        let preferences = SettingsPreferencesFake(state: .firstRun)
        preferences.failCompletion = true
        let toolbar = ToolbarSettingsFake()
        let model = makeModel(preferences: preferences, toolbar: toolbar)

        await model.loadIfNeeded()
        model.selectDefaultTarget(.codexApp)
        model.selectDefaultTerminalHost(.iTerm2)
        await model.completeFirstRunAndInstall()

        #expect(model.phase == .firstRun)
        #expect(model.hasSaveError)
        #expect(toolbar.actions.isEmpty)
    }

    @Test
    func firstRunWriteThenFailureReconcilesPersistedStateWithoutStartingFinderSetup() async {
        let preferences = SettingsPreferencesFake(state: .firstRun)
        preferences.writeThenFailCompletion = true
        let toolbar = ToolbarSettingsFake()
        let model = makeModel(preferences: preferences, toolbar: toolbar)

        await model.loadIfNeeded()
        model.selectDefaultTarget(.claudeDesktopCode)
        model.selectDefaultTerminalHost(.iTerm2)
        await model.completeFirstRunAndInstall()

        #expect(model.phase == .configured)
        #expect(model.defaultTarget == .claudeDesktopCode)
        #expect(model.defaultTerminalHost == .iTerm2)
        #expect(model.hasSaveError)
        #expect(toolbar.actions.isEmpty)
    }

    @Test
    func everyConfiguredEditPersistsImmediately() async {
        let initial = PreferencesEnvelope(
            defaultTarget: .codexApp,
            alternateTrigger: .shiftClick,
            defaultTerminalHost: .terminal,
            sessionPlacement: .newTab
        )
        let preferences = SettingsPreferencesFake(state: .configured(initial))
        let model = makeModel(preferences: preferences)

        await model.loadIfNeeded()
        model.selectDefaultTarget(.claudeDesktopCode)
        model.selectAlternateTrigger(.disabled)
        model.selectDefaultTerminalHost(.iTerm2)
        model.selectSessionPlacement(.newWindow)

        #expect(preferences.changes.count == 4)
        #expect(preferences.changes[0] == PreferencesChange(defaultTarget: .claudeDesktopCode))
        #expect(preferences.changes[1] == PreferencesChange(alternateTrigger: .disabled))
        #expect(preferences.changes[2] == PreferencesChange(defaultTerminalHost: .iTerm2))
        #expect(preferences.changes[3] == PreferencesChange(sessionPlacement: .newWindow))
        #expect(model.defaultTarget == .claudeDesktopCode)
        #expect(model.alternateTrigger == .disabled)
        #expect(model.defaultTerminalHost == .iTerm2)
        #expect(model.sessionPlacement == .newWindow)
        #expect(!model.hasSaveError)
    }

    @Test
    func failedImmediateEditRestoresTheLastPersistedEnvelope() async {
        let initial = PreferencesEnvelope(
            defaultTarget: .codexApp,
            alternateTrigger: .shiftClick,
            defaultTerminalHost: .terminal,
            sessionPlacement: .newTab
        )
        let preferences = SettingsPreferencesFake(state: .configured(initial))
        preferences.failUpdates = true
        let model = makeModel(preferences: preferences)

        await model.loadIfNeeded()
        model.selectDefaultTarget(.claudeDesktopCode)

        #expect(model.hasSaveError)
        #expect(model.defaultTarget == .codexApp)
        #expect(preferences.changes == [PreferencesChange(defaultTarget: .claudeDesktopCode)])
    }

    @Test
    func failedTerminalHostEditRefreshesAvailabilityAfterRollback() async {
        let initial = PreferencesEnvelope(
            defaultTarget: .codexCLI,
            alternateTrigger: .shiftClick,
            defaultTerminalHost: .terminal,
            sessionPlacement: .newTab
        )
        let preferences = SettingsPreferencesFake(state: .configured(initial))
        preferences.failUpdates = true
        let availability = SettingsAvailabilityFake()
        availability.targetsByTerminalHost = [
            .terminal: [.codexCLI: .unavailable(.terminalHostMissing(.terminal))],
            .iTerm2: [.codexCLI: .available],
        ]
        let model = makeModel(preferences: preferences, availability: availability)

        await model.loadIfNeeded()
        model.selectDefaultTerminalHost(.iTerm2)

        #expect(model.defaultTerminalHost == .terminal)
        #expect(model.targetAvailability[.codexCLI]
            == .unavailable(.terminalHostMissing(.terminal)))
        #expect(model.hasSaveError)
    }

    @Test
    func failedToolbarActionRefreshesStatusWithoutChangingPreferences() async {
        let envelope = PreferencesEnvelope(
            defaultTarget: .codexApp,
            alternateTrigger: .shiftClick,
            defaultTerminalHost: .iTerm2,
            sessionPlacement: .newTab
        )
        let preferences = SettingsPreferencesFake(state: .configured(envelope))
        let toolbar = ToolbarSettingsFake(
            status: .manualSetupRequired,
            actionResult: .failed
        )
        let model = makeModel(preferences: preferences, toolbar: toolbar)

        await model.loadIfNeeded()
        toolbar.status = .notInstalled
        await model.performToolbarAction(.showManualSetup)

        #expect(model.phase == .configured)
        #expect(model.hasToolbarError)
        #expect(model.toolbarStatus == .notInstalled)
        #expect(toolbar.currentStatusCalls == 2)
        #expect(preferences.changes.isEmpty)
    }

    @Test
    func activationRecoversOnlyAfterACompleteConfiguredEnvelopeCanBeRead() async {
        let preferences = SettingsPreferencesFake(
            state: .recoveryRequired(.storageReadFailed)
        )
        let toolbar = ToolbarSettingsFake()
        let model = makeModel(preferences: preferences, toolbar: toolbar)

        await model.loadIfNeeded()
        await model.refreshAfterActivation()

        #expect(model.phase == .recoveryRequired)
        #expect(toolbar.currentStatusCalls == 2)

        let envelope = PreferencesEnvelope(
            defaultTarget: .claudeDesktopCode,
            alternateTrigger: .disabled,
            defaultTerminalHost: .iTerm2,
            sessionPlacement: .newWindow
        )
        preferences.state = .configured(envelope)

        await model.refreshAfterActivation()

        #expect(model.phase == .configured)
        #expect(model.defaultTarget == .claudeDesktopCode)
        #expect(model.alternateTrigger == .disabled)
        #expect(model.defaultTerminalHost == .iTerm2)
        #expect(model.sessionPlacement == .newWindow)
        #expect(toolbar.currentStatusCalls == 3)
        #expect(preferences.completedSelections.isEmpty)
        #expect(preferences.changes.isEmpty)
    }

    private func makeModel(
        preferences: SettingsPreferencesFake,
        toolbar: ToolbarSettingsFake = ToolbarSettingsFake(),
        availability: SettingsAvailabilityFake = SettingsAvailabilityFake()
    ) -> SettingsModel {
        SettingsModel(
            preferences: preferences,
            toolbar: toolbar,
            availability: availability
        )
    }
}

@MainActor
private enum SettingsEvent: Equatable {
    case preferencesComplete
    case toolbar(ToolbarSettingsAction)
}

@MainActor
private final class SettingsEventLog {
    var values: [SettingsEvent] = []
}

@MainActor
private final class SettingsPreferencesFake: SettingsPreferencesServing {
    var state: PreferencesLoadState
    var completedSelections: [FirstRunSelection] = []
    var changes: [PreferencesChange] = []
    var failCompletion = false
    var failUpdates = false
    var writeThenFailCompletion = false

    private let events: SettingsEventLog?

    init(state: PreferencesLoadState, events: SettingsEventLog? = nil) {
        self.state = state
        self.events = events
    }

    func load() -> PreferencesLoadState {
        state
    }

    func completeFirstRun(selection: FirstRunSelection) throws -> PreferencesEnvelope {
        completedSelections.append(selection)
        if failCompletion {
            throw PreferencesStoreError.writeFailed
        }
        let envelope = try PreferencesStateMachine.completeFirstRun(
            from: state,
            selection: selection
        )
        state = .configured(envelope)
        if writeThenFailCompletion {
            throw PreferencesStoreError.writeFailed
        }
        events?.values.append(.preferencesComplete)
        return envelope
    }

    func update(_ change: PreferencesChange) throws -> PreferencesEnvelope {
        changes.append(change)
        if failUpdates {
            throw PreferencesStoreError.writeFailed
        }
        let envelope = try PreferencesStateMachine.apply(change, to: state)
        state = .configured(envelope)
        return envelope
    }
}

@MainActor
private final class ToolbarSettingsFake: ToolbarSettingsServing {
    let supportsAutomaticMutation: Bool
    var status: ToolbarSettingsStatus
    var actionResult: ToolbarSettingsActionResult
    var actions: [ToolbarSettingsAction] = []
    var currentStatusCalls = 0

    private let events: SettingsEventLog?

    init(
        supportsAutomaticMutation: Bool = false,
        status: ToolbarSettingsStatus = .manualSetupRequired,
        actionResult: ToolbarSettingsActionResult = .status(.manualSetupRequired),
        events: SettingsEventLog? = nil
    ) {
        self.supportsAutomaticMutation = supportsAutomaticMutation
        self.status = status
        self.actionResult = actionResult
        self.events = events
    }

    func currentStatus() async -> ToolbarSettingsStatus {
        currentStatusCalls += 1
        return status
    }

    func perform(_ action: ToolbarSettingsAction) async -> ToolbarSettingsActionResult {
        actions.append(action)
        events?.values.append(.toolbar(action))
        return actionResult
    }
}

@MainActor
private final class SettingsAvailabilityFake: SettingsAvailabilityServing {
    var targets: [AgentTarget: TargetAvailability] = [:]
    var targetsByTerminalHost: [TerminalHost: [AgentTarget: TargetAvailability]] = [:]
    var terminalHosts: [TerminalHost: Bool] = [:]

    func targetAvailability(
        _ target: AgentTarget,
        terminalHost: TerminalHost?
    ) -> TargetAvailability {
        if let terminalHost,
           let value = targetsByTerminalHost[terminalHost]?[target] {
            return value
        }
        return targets[target] ?? .available
    }

    func terminalHostIsAvailable(_ terminalHost: TerminalHost) -> Bool {
        terminalHosts[terminalHost] ?? true
    }
}
