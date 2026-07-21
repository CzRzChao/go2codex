import Combine
import Foundation
import Go2CodexCore
import OSLog

enum ToolbarSettingsStatus: Equatable, Sendable {
    case checking
    case installed
    case notInstalled
    case needsRepair
    case manualSetupRequired
}

enum ToolbarSettingsAction: Equatable, Sendable {
    case install
    case repair
    case uninstall
    case showManualSetup
}

enum ToolbarSettingsActionResult: Equatable, Sendable {
    case status(ToolbarSettingsStatus)
    case cancelled
    case failed
}

@MainActor
protocol ToolbarSettingsServing: AnyObject {
    var supportsAutomaticMutation: Bool { get }
    func currentStatus() async -> ToolbarSettingsStatus
    func perform(_ action: ToolbarSettingsAction) async -> ToolbarSettingsActionResult
}

@MainActor
protocol SettingsPreferencesServing: AnyObject {
    func load() -> PreferencesLoadState
    func completeFirstRun(selection: FirstRunSelection) throws -> PreferencesEnvelope
    func update(_ change: PreferencesChange) throws -> PreferencesEnvelope
    func reset() throws
}

@MainActor
protocol SettingsAvailabilityServing: AnyObject {
    func targetAvailability(
        _ target: AgentTarget,
        terminalHost: TerminalHost?
    ) -> TargetAvailability
    func terminalHostIsAvailable(_ terminalHost: TerminalHost) -> Bool
}

@MainActor
final class SettingsModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case firstRun
        case configured
        case recoveryRequired
    }

    @Published var phase: Phase = .loading
    @Published var defaultTarget: AgentTarget?
    @Published var defaultTerminalHost: TerminalHost?
    @Published var alternateTrigger: AlternateTrigger = .shiftClick
    @Published var sessionPlacement: SessionPlacement = .newTab
    @Published var toolbarStatus: ToolbarSettingsStatus = .checking
    @Published var isPerformingAction = false
    @Published var hasSaveError = false
    @Published var hasToolbarError = false
    @Published private(set) var targetAvailability: [AgentTarget: TargetAvailability] = [:]
    @Published private(set) var terminalHostAvailability: [TerminalHost: Bool] = [:]

    private let preferences: any SettingsPreferencesServing
    private let toolbar: any ToolbarSettingsServing
    private let availability: any SettingsAvailabilityServing
    private let logger: Logger
    private var didLoad = false

    init(
        preferences: any SettingsPreferencesServing,
        toolbar: any ToolbarSettingsServing,
        availability: any SettingsAvailabilityServing
    ) {
        self.preferences = preferences
        self.toolbar = toolbar
        self.availability = availability
        let subsystem = Bundle.main.object(
            forInfoDictionaryKey: "Go2CodexPreferencesDomain"
        ) as? String ?? "io.github.czrzchao.go2codex"
        logger = Logger(subsystem: subsystem, category: "Settings")
    }

    var isFirstRun: Bool {
        phase == .firstRun
    }

    var controlsAreEnabled: Bool {
        (phase == .firstRun || phase == .configured) && !isPerformingAction
    }

    var canCompleteFirstRun: Bool {
        phase == .firstRun
            && defaultTarget != nil
            && defaultTerminalHost != nil
            && !isPerformingAction
    }

    var supportsAutomaticToolbarMutation: Bool {
        toolbar.supportsAutomaticMutation
    }

    func loadIfNeeded() async {
        guard !didLoad else {
            return
        }
        didLoad = true

        switch preferences.load() {
        case .firstRun:
            phase = .firstRun
        case let .configured(envelope):
            apply(envelope)
            phase = .configured
        case .recoveryRequired:
            phase = .recoveryRequired
            logger.error("Saved settings require recovery")
        }
        refreshAvailability()
        toolbarStatus = await toolbar.currentStatus()
    }

    func selectDefaultTarget(_ value: AgentTarget?) {
        defaultTarget = value
        guard phase == .configured, let value else {
            return
        }
        persist(PreferencesChange(defaultTarget: value))
    }

    func selectAlternateTrigger(_ value: AlternateTrigger) {
        alternateTrigger = value
        guard phase == .configured else {
            return
        }
        persist(PreferencesChange(alternateTrigger: value))
    }

    func selectDefaultTerminalHost(_ value: TerminalHost?) {
        defaultTerminalHost = value
        refreshAvailability()
        guard phase == .configured, let value else {
            return
        }
        persist(PreferencesChange(defaultTerminalHost: value))
    }

    func selectSessionPlacement(_ value: SessionPlacement) {
        sessionPlacement = value
        guard phase == .configured else {
            return
        }
        persist(PreferencesChange(sessionPlacement: value))
    }

    func completeFirstRunAndInstall() async {
        guard canCompleteFirstRun else {
            return
        }

        isPerformingAction = true
        hasSaveError = false
        hasToolbarError = false
        defer { isPerformingAction = false }

        do {
            let envelope = try preferences.completeFirstRun(
                selection: FirstRunSelection(
                    defaultTarget: defaultTarget,
                    defaultTerminalHost: defaultTerminalHost,
                    alternateTrigger: alternateTrigger,
                    sessionPlacement: sessionPlacement
                )
            )
            apply(envelope)
            phase = .configured
        } catch {
            hasSaveError = true
            logger.error("First Run preferences could not be saved")
            reconcileAfterFirstRunWriteFailure()
            return
        }

        await executeToolbarAction(.install)
    }

    func resetToFirstRun() async {
        guard phase == .recoveryRequired else {
            return
        }

        do {
            try preferences.reset()
        } catch {
            logger.error("Settings could not be reset")
            reconcileAfterResetFailure()
            return
        }

        applyFirstRunDefaults()
        hasSaveError = false
        phase = .firstRun
        refreshAvailability()
    }

    private func applyFirstRunDefaults() {
        defaultTarget = nil
        defaultTerminalHost = nil
        alternateTrigger = .shiftClick
        sessionPlacement = .newTab
    }

    func refreshToolbarStatus() async {
        guard phase != .loading else {
            return
        }
        refreshAvailability()
        toolbarStatus = await toolbar.currentStatus()
    }

    func refreshAfterActivation() async {
        if phase == .recoveryRequired,
           case let .configured(envelope) = preferences.load() {
            apply(envelope)
            phase = .configured
        }
        await refreshToolbarStatus()
    }

    func targetIsKnownUnavailable(_ target: AgentTarget) -> Bool {
        guard case let .unavailable(reason) = targetAvailability[target] else {
            return false
        }
        return reason != .notEvaluated
    }

    func terminalHostIsKnownUnavailable(_ terminalHost: TerminalHost) -> Bool {
        terminalHostAvailability[terminalHost] == false
    }

    func performToolbarAction(_ action: ToolbarSettingsAction) async {
        guard phase == .configured, !isPerformingAction else {
            return
        }

        await executeToolbarAction(action)
    }

    private func executeToolbarAction(_ action: ToolbarSettingsAction) async {
        guard phase == .configured else {
            return
        }

        let wasAlreadyPerforming = isPerformingAction
        isPerformingAction = true
        hasToolbarError = false
        defer {
            if !wasAlreadyPerforming {
                isPerformingAction = false
            }
        }

        switch await toolbar.perform(action) {
        case let .status(status):
            toolbarStatus = status
        case .cancelled:
            break
        case .failed:
            hasToolbarError = true
            logger.error("Finder toolbar action failed")
            toolbarStatus = await toolbar.currentStatus()
        }
    }

    private func persist(_ change: PreferencesChange) {
        do {
            apply(try preferences.update(change))
            hasSaveError = false
        } catch {
            hasSaveError = true
            logger.error("A settings change could not be saved")
            switch preferences.load() {
            case let .configured(envelope):
                apply(envelope)
                phase = .configured
            case .firstRun, .recoveryRequired:
                phase = .recoveryRequired
            }
            refreshAvailability()
        }
    }

    private func reconcileAfterFirstRunWriteFailure() {
        switch preferences.load() {
        case .firstRun:
            phase = .firstRun
        case let .configured(envelope):
            apply(envelope)
            phase = .configured
        case .recoveryRequired:
            phase = .recoveryRequired
        }
        refreshAvailability()
    }

    private func reconcileAfterResetFailure() {
        switch preferences.load() {
        case .firstRun:
            applyFirstRunDefaults()
            hasSaveError = false
            phase = .firstRun
        case let .configured(envelope):
            apply(envelope)
            hasSaveError = false
            phase = .configured
        case .recoveryRequired:
            hasSaveError = true
            phase = .recoveryRequired
        }
        refreshAvailability()
    }

    private func apply(_ envelope: PreferencesEnvelope) {
        defaultTarget = envelope.defaultTarget
        alternateTrigger = envelope.alternateTrigger
        defaultTerminalHost = envelope.defaultTerminalHost
        sessionPlacement = envelope.sessionPlacement
    }

    private func refreshAvailability() {
        targetAvailability = Dictionary(
            uniqueKeysWithValues: AgentTargetCatalog.targets.map { target in
                (
                    target,
                    availability.targetAvailability(
                        target,
                        terminalHost: defaultTerminalHost
                    )
                )
            }
        )
        terminalHostAvailability = Dictionary(
            uniqueKeysWithValues: TerminalHost.allCases.map { terminalHost in
                (terminalHost, availability.terminalHostIsAvailable(terminalHost))
            }
        )
    }
}
