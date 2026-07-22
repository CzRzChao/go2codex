import AppKit
import Foundation
import Go2CodexCore
import OSLog

@MainActor
struct InvocationSnapshot {
    let modifierFlagsRawValue: UInt
    let pointerLocation: NSPoint

    static func capture() -> InvocationSnapshot {
        InvocationSnapshot(
            modifierFlagsRawValue: NSEvent.modifierFlags.rawValue,
            pointerLocation: NSEvent.mouseLocation
        )
    }

    var deviceIndependentModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
            .intersection(.deviceIndependentFlagsMask)
    }

    var routingModifierFlags: InvocationModifierFlags {
        let flags = deviceIndependentModifierFlags
        var result: InvocationModifierFlags = []
        for (appKitFlag, routingFlag) in [
            (NSEvent.ModifierFlags.option, InvocationModifierFlags.option),
            (.shift, .shift),
            (.capsLock, .capsLock),
            (.function, .function),
            (.command, .command),
            (.control, .control),
        ] where flags.contains(appKitFlag) {
            result.insert(routingFlag)
        }
        return result
    }
}

@MainActor
private final class InvocationGate {
    private var stateMachine = InvocationGateStateMachine()

    func begin() -> Bool {
        stateMachine.begin()
    }

    func beginFinishing() -> Bool {
        stateMachine.beginFinishing()
    }
}

enum LauncherPreferencesReadError: Error, Equatable, DiagnosticCodeProviding {
    case missingDomain
    case unavailableDomain
    case invalidStoredType

    var diagnosticCode: DiagnosticCode {
        switch self {
        case .missingDomain:
            DiagnosticCode(rawValue: "preferences-domain-missing")
        case .unavailableDomain:
            DiagnosticCode(rawValue: "preferences-domain-unavailable")
        case .invalidStoredType:
            DiagnosticCode(rawValue: "preferences-envelope-invalid-type")
        }
    }
}

@MainActor
protocol LauncherUserDefaultsReading: AnyObject {
    func object(forKey defaultName: String) -> Any?

#if DEBUG
    func bool(forKey defaultName: String) -> Bool
    func integer(forKey defaultName: String) -> Int
#endif
}

extension UserDefaults: LauncherUserDefaultsReading {}

@MainActor
struct UserDefaultsPreferencesReader: LauncherPreferencesLoading {
    private let domainProvider: () -> String?
    private let defaultsFactory: (String) -> (any LauncherUserDefaultsReading)?

    init(
        domainProvider: @escaping () -> String? = {
            Bundle.main.object(
                forInfoDictionaryKey: "Go2CodexPreferencesDomain"
            ) as? String
        },
        defaultsFactory: @escaping (String) -> (any LauncherUserDefaultsReading)? = {
            UserDefaults(suiteName: $0)
        }
    ) {
        self.domainProvider = domainProvider
        self.defaultsFactory = defaultsFactory
    }

    func loadPreferences() throws -> PreferencesLoadState {
        let defaults = try defaults()
        guard let stored = defaults.object(forKey: PreferencesStorageKey.envelope) else {
            return .firstRun
        }
        guard let data = stored as? Data else {
            throw LauncherPreferencesReadError.invalidStoredType
        }
        return PreferencesCodec().decode(data)
    }

#if DEBUG
    func modifierProbeIsEnabled() -> Bool {
        (try? defaults().bool(forKey: "M2ModifierProbeEnabled")) == true
    }

    func invocationDelayMilliseconds() -> Int? {
        guard let value = try? defaults().integer(
            forKey: "M2InvocationDelayMilliseconds"
        ) else {
            return nil
        }
        return DebugInvocationDelayPolicy.boundedMilliseconds(value)
    }
#endif

    private func defaults() throws -> any LauncherUserDefaultsReading {
        guard let domain = domainProvider(), !domain.isEmpty else {
            throw LauncherPreferencesReadError.missingDomain
        }
        guard let defaults = defaultsFactory(domain) else {
            throw LauncherPreferencesReadError.unavailableDomain
        }
        return defaults
    }
}

private enum SettingsOpenError: Error, DiagnosticCodeProviding {
    case invalidLauncherContainment
    case openFailed(code: Int)

    var diagnosticCode: DiagnosticCode {
        switch self {
        case .invalidLauncherContainment:
            DiagnosticCode(rawValue: "settings-containment-invalid")
        case .openFailed:
            DiagnosticCode(rawValue: "settings-open-failed")
        }
    }
}

@MainActor
private struct SettingsOpener: LauncherSettingsOpening {
    func openSettings() async throws {
        let settingsURL = try containingSettingsApplicationURL()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        let errorCode: Int? = await awaitWorkspaceOpen(
            mapError: { error in
                error.map { ($0 as NSError).code }
            }
        ) { completion in
            NSWorkspace.shared.openApplication(
                at: settingsURL,
                configuration: configuration,
                completionHandler: completion
            )
        }
        if let errorCode {
            throw SettingsOpenError.openFailed(code: errorCode)
        }
    }

    private func containingSettingsApplicationURL() throws -> URL {
        let launcherURL = Bundle.main.bundleURL.standardizedFileURL
        let helpersURL = launcherURL.deletingLastPathComponent()
        let contentsURL = helpersURL.deletingLastPathComponent()
        let settingsURL = contentsURL.deletingLastPathComponent()
        let launcherSuffix = ".launcher"

        guard launcherURL.pathExtension == "app",
              helpersURL.lastPathComponent == "Helpers",
              contentsURL.lastPathComponent == "Contents",
              settingsURL.pathExtension == "app",
              launcherURL.resolvingSymlinksInPath() == launcherURL,
              settingsURL.resolvingSymlinksInPath() == settingsURL,
              let launcherIdentifier = Bundle.main.bundleIdentifier,
              launcherIdentifier.hasSuffix(launcherSuffix),
              let settingsIdentifier = Bundle(url: settingsURL)?.bundleIdentifier,
              settingsIdentifier == String(launcherIdentifier.dropLast(launcherSuffix.count)) else {
            throw SettingsOpenError.invalidLauncherContainment
        }
        return settingsURL
    }
}

extension AgentTarget {
    var localizedPickerTitle: String {
        switch self {
        case .codexApp:
            String(localized: "Codex App")
        case .codexCLI:
            String(localized: "Codex CLI")
        case .claudeDesktopCode:
            String(localized: "Claude Desktop Code")
        case .claudeCodeCLI:
            String(localized: "Claude Code CLI")
        }
    }
}

@MainActor
protocol LauncherApplicationLocating {
    func applicationURL(toOpen url: URL) -> URL?
    func applicationURL(withBundleIdentifier bundleIdentifier: String) -> URL?
    func bundleIdentifier(at applicationURL: URL) -> String?
}

@MainActor
private struct WorkspaceLauncherApplicationLocator: LauncherApplicationLocating {
    func applicationURL(toOpen url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    func applicationURL(withBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func bundleIdentifier(at applicationURL: URL) -> String? {
        Bundle(url: applicationURL)?.bundleIdentifier
    }
}

@MainActor
struct TargetAvailabilityService: TargetAvailabilityLookingUp {
    private let applicationLocator: any LauncherApplicationLocating

    init(
        applicationLocator: any LauncherApplicationLocating = WorkspaceLauncherApplicationLocator()
    ) {
        self.applicationLocator = applicationLocator
    }

    func availability(
        for target: AgentTarget,
        workspace: Workspace,
        terminalHost: TerminalHost
    ) throws -> TargetAvailability {
        switch target.kind {
        case .desktop:
            let url: URL
            do {
                url = try DesktopURLBuilder.url(for: target, workspace: workspace)
            } catch {
                throw AvailabilityLookupError.lookupFailed(target)
            }
            let handlerURL = applicationLocator.applicationURL(toOpen: url)
            return try classify(
                target: target,
                evidence: .desktopURLHandler(
                    isRegistered: DesktopTargetHandlerPolicy.accepts(
                        target: target,
                        handlerBundleIdentifier: handlerURL.flatMap(
                            applicationLocator.bundleIdentifier(at:)
                        )
                    )
                )
            )
        case .cli:
            return try classify(
                target: target,
                evidence: .terminalHost(
                    terminalHost,
                    isRegistered: applicationLocator.applicationURL(
                        withBundleIdentifier: terminalHost.bundleIdentifier
                    ) != nil
                )
            )
        }
    }

    private func classify(
        target: AgentTarget,
        evidence: TargetAvailabilityEvidence
    ) throws -> TargetAvailability {
        do {
            return try TargetAvailabilityClassifier.classify(
                target: target,
                evidence: evidence
            )
        } catch {
            throw AvailabilityLookupError.inconsistentEvidence(target)
        }
    }
}

enum TargetPickerError: Error, Equatable, DiagnosticCodeProviding {
    case noUsableScreen
    case invalidSelection
    case mouseReleaseTimedOut
    case readinessCancelled

    var diagnosticCode: DiagnosticCode {
        switch self {
        case .noUsableScreen:
            DiagnosticCode(rawValue: "target-picker-no-screen")
        case .invalidSelection:
            DiagnosticCode(rawValue: "target-picker-invalid-selection")
        case .mouseReleaseTimedOut:
            DiagnosticCode(rawValue: "target-picker-mouse-release-timeout")
        case .readinessCancelled:
            DiagnosticCode(rawValue: "target-picker-readiness-cancelled")
        }
    }
}

typealias TargetPickerWaitUntil = @MainActor (
    Duration,
    @escaping @MainActor () -> Bool
) async throws -> Bool

@MainActor
enum TargetPickerConditionWaiter {
    static func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !condition() {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                return false
            }
            try await clock.sleep(for: min(.milliseconds(10), remaining))
        }
        return true
    }
}

@MainActor
struct TargetPickerReadinessGate {
    private let mouseReleaseTimeout: Duration
    private let pressedMouseButtons: @MainActor () -> Int
    private let waitUntil: TargetPickerWaitUntil

    init(
        mouseReleaseTimeout: Duration = .seconds(1),
        pressedMouseButtons: @escaping @MainActor () -> Int = {
            NSEvent.pressedMouseButtons
        },
        waitUntil: @escaping TargetPickerWaitUntil = TargetPickerConditionWaiter.waitUntil
    ) {
        self.mouseReleaseTimeout = mouseReleaseTimeout
        self.pressedMouseButtons = pressedMouseButtons
        self.waitUntil = waitUntil
    }

    func runWhenReady<T>(
        _ operation: @MainActor () throws -> T
    ) async throws -> T {
        do {
            try Task.checkCancellation()

            guard try await waitUntil(
                mouseReleaseTimeout,
                { pressedMouseButtons() == 0 }
            ) else {
                throw TargetPickerError.mouseReleaseTimedOut
            }

            try Task.checkCancellation()
            return try operation()
        } catch is CancellationError {
            throw TargetPickerError.readinessCancelled
        }
    }
}

@MainActor
final class TargetPickerPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode != 53 else {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class TargetPickerRowButton: NSButton {
    private var pointerIsInside = false
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        super.updateTrackingAreas()
        let pointerTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(pointerTrackingArea)
        self.pointerTrackingArea = pointerTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        pointerIsInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointerIsInside = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if pointerIsInside, isEnabled {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0, dy: 1),
                xRadius: 5,
                yRadius: 5
            ).fill()
        }
        super.draw(dirtyRect)
    }
}

enum TargetPickerPanelFrameResolver {
    static func frame(
        near point: ScreenPoint,
        panelSize: ScreenPoint,
        in visibleFrames: [ScreenRect]
    ) throws -> ScreenRect {
        guard panelSize.x.isFinite,
              panelSize.y.isFinite,
              panelSize.x > 0,
              panelSize.y > 0 else {
            throw TargetPickerError.noUsableScreen
        }

        let usableFrames = visibleFrames.filter {
            $0.isUsable
                && $0.width >= panelSize.x
                && $0.height >= panelSize.y
        }
        let resolvedPoint: ScreenPoint
        do {
            resolvedPoint = try ScreenPointClamper.resolve(point, in: usableFrames)
        } catch {
            throw TargetPickerError.noUsableScreen
        }
        guard let screen = usableFrames.first(where: { $0.contains(resolvedPoint) }) else {
            throw TargetPickerError.noUsableScreen
        }

        let originX = min(
            max(resolvedPoint.x, screen.minX),
            screen.maxX - panelSize.x
        )
        let belowOriginY = resolvedPoint.y - panelSize.y
        let originY: Double
        if belowOriginY >= screen.minY {
            originY = belowOriginY
        } else if resolvedPoint.y + panelSize.y <= screen.maxY {
            originY = resolvedPoint.y
        } else {
            originY = min(
                max(belowOriginY, screen.minY),
                screen.maxY - panelSize.y
            )
        }

        return ScreenRect(
            x: originX,
            y: originY,
            width: panelSize.x,
            height: panelSize.y
        )
    }
}

typealias TargetPickerRunModal = @MainActor (NSWindow) -> NSApplication.ModalResponse
typealias TargetPickerStopModal = @MainActor (NSApplication.ModalResponse) -> Void
typealias TargetPickerPanelVisibility = @MainActor (NSPanel) -> Void
typealias TargetPickerOutsideClickHandler = @MainActor @Sendable () -> Void
typealias TargetPickerInstallOutsideClickMonitor = @MainActor (
    @escaping TargetPickerOutsideClickHandler
) -> Any?
typealias TargetPickerRemoveOutsideClickMonitor = @MainActor (Any) -> Void

@MainActor
final class TargetPickerPanelSession: NSObject {
    static let rowHeight: CGFloat = 28
    static let horizontalInset: CGFloat = 6
    static let verticalInset: CGFloat = 6
    static let panelWidth: CGFloat = 240
    static var panelSize: ScreenPoint {
        ScreenPoint(
            x: Double(panelWidth),
            y: Double(
                verticalInset * 2
                    + CGFloat(AgentTargetCatalog.targets.count) * rowHeight
            )
        )
    }

    let panel: TargetPickerPanel
    let buttons: [NSButton]

    private let runModal: TargetPickerRunModal
    private let stopModal: TargetPickerStopModal
    private let showPanel: TargetPickerPanelVisibility
    private let hidePanel: TargetPickerPanelVisibility
    private let installOutsideClickMonitor: TargetPickerInstallOutsideClickMonitor
    private let removeOutsideClickMonitor: TargetPickerRemoveOutsideClickMonitor
    private var selectedIndex: Int?
    private var outsideClickMonitor: Any?
    private var isPresenting = false
    private var modalLoopIsRunning = false
    private var didFinish = false

    init(
        plan: TargetPickerPlan,
        frame: NSRect,
        runModal: @escaping TargetPickerRunModal = { NSApp.runModal(for: $0) },
        stopModal: @escaping TargetPickerStopModal = { NSApp.stopModal(withCode: $0) },
        showPanel: @escaping TargetPickerPanelVisibility = {
            $0.orderFrontRegardless()
        },
        hidePanel: @escaping TargetPickerPanelVisibility = { $0.orderOut(nil) },
        installOutsideClickMonitor: @escaping TargetPickerInstallOutsideClickMonitor = { handler in
            NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { _ in
                MainActor.assumeIsolated {
                    handler()
                }
            }
        },
        removeOutsideClickMonitor: @escaping TargetPickerRemoveOutsideClickMonitor = {
            NSEvent.removeMonitor($0)
        }
    ) throws {
        guard plan.items.map(\.target) == AgentTargetCatalog.targets else {
            throw TargetPickerError.invalidSelection
        }

        let panel = TargetPickerPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.canHide = false
        panel.isMovable = false
        panel.level = .popUpMenu
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let contentView = NSVisualEffectView(
            frame: NSRect(origin: .zero, size: frame.size)
        )
        contentView.material = .menu
        contentView.blendingMode = .behindWindow
        contentView.state = .active
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 8
        contentView.layer?.masksToBounds = true

        let rowHeight = Self.rowHeight
        let horizontalInset = Self.horizontalInset
        let verticalInset = Self.verticalInset
        let buttons = plan.items.enumerated().map { index, item in
            let button = TargetPickerRowButton(
                title: item.target.localizedPickerTitle,
                target: nil,
                action: #selector(TargetPickerPanelSession.selectTarget(_:))
            )
            button.frame = NSRect(
                x: horizontalInset,
                y: frame.height - verticalInset - CGFloat(index + 1) * rowHeight,
                width: frame.width - horizontalInset * 2,
                height: rowHeight
            )
            button.tag = index
            button.isEnabled = item.isEnabled
            button.state = item.isDefault ? .on : .off
            button.isBordered = false
            button.bezelStyle = .inline
            button.alignment = .left
            button.font = .menuFont(ofSize: 0)
            button.focusRingType = .none
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.image = item.isDefault
                ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
                : NSImage(size: NSSize(width: 14, height: 14))
            contentView.addSubview(button)
            return button
        }
        panel.contentView = contentView

        self.panel = panel
        self.buttons = buttons
        self.runModal = runModal
        self.stopModal = stopModal
        self.showPanel = showPanel
        self.hidePanel = hidePanel
        self.installOutsideClickMonitor = installOutsideClickMonitor
        self.removeOutsideClickMonitor = removeOutsideClickMonitor
        super.init()

        buttons.forEach { $0.target = self }
        panel.onCancel = { [weak self] in
            self?.finish()
        }
    }

    func present() -> TargetPickerAction {
        guard !isPresenting, !didFinish else {
            return .cancel
        }

        isPresenting = true
        let monitor = installOutsideClickMonitor { [weak self] in
            self?.finish()
        }
        if didFinish {
            if let monitor {
                removeOutsideClickMonitor(monitor)
            }
        } else {
            outsideClickMonitor = monitor
        }
        if !didFinish {
            showPanel(panel)
            modalLoopIsRunning = true
            _ = runModal(panel)
            modalLoopIsRunning = false
        }
        didFinish = true
        removeOutsideClickMonitorIfNeeded()
        panel.onCancel = nil
        hidePanel(panel)
        isPresenting = false

        guard let selectedIndex else {
            return .cancel
        }
        return .select(index: selectedIndex)
    }

    @objc func selectTarget(_ sender: NSButton) {
        guard isPresenting,
              !didFinish,
              sender.isEnabled,
              AgentTargetCatalog.targets.indices.contains(sender.tag) else {
            return
        }
        selectedIndex = sender.tag
        finish()
    }

    private func finish() {
        guard isPresenting, !didFinish else {
            return
        }
        didFinish = true
        removeOutsideClickMonitorIfNeeded()
        if modalLoopIsRunning {
            stopModal(.stop)
        }
    }

    private func removeOutsideClickMonitorIfNeeded() {
        guard let outsideClickMonitor else {
            return
        }
        self.outsideClickMonitor = nil
        removeOutsideClickMonitor(outsideClickMonitor)
    }
}

@MainActor
private struct TargetPicker: TargetPicking {
    private let readiness = TargetPickerReadinessGate()

    func action(
        for plan: TargetPickerPlan,
        at point: ScreenPoint
    ) async throws -> TargetPickerAction {
        let visibleFrames = NSScreen.screens.map { screen in
            let frame = screen.visibleFrame
            return ScreenRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            )
        }
        let frame = try TargetPickerPanelFrameResolver.frame(
            near: point,
            panelSize: TargetPickerPanelSession.panelSize,
            in: visibleFrames
        )
        let session = try TargetPickerPanelSession(
            plan: plan,
            frame: NSRect(
                x: frame.x,
                y: frame.y,
                width: frame.width,
                height: frame.height
            )
        )

        return try await readiness.runWhenReady {
            session.present()
        }
    }
}

private enum ScreenPointResolver {
    static func usablePoint(
        for point: NSPoint,
        screens: [NSScreen]
    ) throws -> NSPoint {
        let frames = screens.map { screen in
            let frame = screen.visibleFrame
            return ScreenRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            )
        }
        let resolved: ScreenPoint
        do {
            resolved = try ScreenPointClamper.resolve(
                ScreenPoint(x: point.x, y: point.y),
                in: frames
            )
        } catch {
            throw TargetPickerError.noUsableScreen
        }
        return NSPoint(x: resolved.x, y: resolved.y)
    }
}

struct LauncherFailureCopyResolver {
    func messageKey(for failure: LauncherWorkflowFailure) -> String {
        switch failure.code.rawValue {
        case "finder-option-modifier-unsupported":
            "Option-click is reserved by Finder. Use Shift-click."
        case "finder-object-unavailable":
            "The original Finder folder is no longer available"
        case "finder-unavailable":
            "Finder is unavailable"
        case "finder-malformed-reply", "finder-unsupported-location":
            "This Finder view is not a folder"
        case "workspace-inaccessible", "workspace-invalid":
            "The Finder folder is not accessible"
        case "terminal-accessibility-denied":
            "Accessibility permission is required for Terminal tabs"
        case "terminal-system-events-automation-denied",
             "terminal-system-events-consent-required":
            "Automation permission is required for Terminal tabs"
        case "terminal-tab-count-malformed",
             "terminal-tab-creation-timeout",
             "terminal-tab-shortcut-failed",
             "terminal-activation-failed":
            "Go2Codex could not create a Terminal tab"
        case "iterm-window-query-malformed":
            "Go2Codex could not determine whether iTerm has a window"
        case "target-picker-mouse-release-timeout",
             "target-picker-activation-timeout",
             "target-picker-readiness-cancelled":
            "Target Picker could not be shown"
        case let code where code.contains("unavailable"):
            "The selected target is unavailable"
        default:
            "Go2Codex could not complete the handoff"
        }
    }

    func informativeTextKey(for failure: LauncherWorkflowFailure) -> String {
        switch failure.code.rawValue {
        case "finder-malformed-reply", "finder-unsupported-location":
            return "Open a regular folder in Finder, then try again. Smart folders such as Recents cannot be used as a workspace."
        case "terminal-accessibility-denied":
            return "Allow Go2Codex in System Settings > Privacy & Security > Accessibility, then try again."
        case "terminal-system-events-automation-denied",
             "terminal-system-events-consent-required":
            return "Allow Go2Codex to control System Events in System Settings > Privacy & Security > Automation, then try again."
        case "terminal-tab-count-malformed",
             "terminal-tab-creation-timeout",
             "terminal-tab-shortcut-failed",
             "terminal-activation-failed":
            return "No command was submitted. Bring Terminal to the front and try again, or choose New Window in Go2Codex Settings."
        case "iterm-window-query-malformed":
            return "No terminal session was opened. Try again, or choose New Window in Go2Codex Settings."
        case "target-picker-mouse-release-timeout",
             "target-picker-activation-timeout",
             "target-picker-readiness-cancelled":
            return "Try again and keep holding Shift until the menu is visible."
        default:
            break
        }
        return switch failure.permissionContext {
        case .finder:
            "Allow Go2Codex to control Finder in System Settings > Privacy & Security > Automation, then try again."
        case .terminal(.terminal):
            "Allow Go2Codex to control Terminal in System Settings > Privacy & Security > Automation, then try again."
        case .terminal(.iTerm2):
            "Allow Go2Codex to control iTerm2 in System Settings > Privacy & Security > Automation, then try again."
        case nil:
            "No alternate target was used. You can copy sanitized diagnostics for troubleshooting."
        }
    }
}

@MainActor
private struct FailurePresenter {
    private let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )!
    private let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!
    private let copyResolver = LauncherFailureCopyResolver()

    func present(
        failure: LauncherWorkflowFailure,
        diagnostics: DiagnosticRecord
    ) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message(for: failure)
        alert.informativeText = informativeText(for: failure)

        if let permissionSettings = permissionSettings(for: failure) {
            alert.addButton(withTitle: String(localized:
                permissionSettings == accessibilitySettingsURL
                    ? "Open Accessibility Settings"
                    : "Open Automation Settings"
            ))
            alert.addButton(withTitle: String(localized: "Copy Diagnostics"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                openPermissionSettingsOrShowFallback(permissionSettings)
            case .alertSecondButtonReturn:
                copy(diagnostics)
            default:
                break
            }
        } else {
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Copy Diagnostics"))
            if alert.runModal() == .alertSecondButtonReturn {
                copy(diagnostics)
            }
        }
    }

    private func message(for failure: LauncherWorkflowFailure) -> String {
        String(localized: String.LocalizationValue(
            copyResolver.messageKey(for: failure)
        ))
    }

    private func informativeText(for failure: LauncherWorkflowFailure) -> String {
        String(localized: String.LocalizationValue(
            copyResolver.informativeTextKey(for: failure)
        ))
    }

    private func permissionSettings(
        for failure: LauncherWorkflowFailure
    ) -> URL? {
        if failure.code.rawValue == "terminal-accessibility-denied" {
            return accessibilitySettingsURL
        }
        return failure.permissionContext == nil ? nil : automationSettingsURL
    }

    private func openPermissionSettingsOrShowFallback(_ settingsURL: URL) {
        guard NSWorkspace.shared.urlForApplication(
            toOpen: settingsURL
        ) != nil,
              NSWorkspace.shared.open(settingsURL) else {
            let fallback = NSAlert()
            fallback.alertStyle = .informational
            fallback.messageText = String(localized: "Open Privacy Settings manually")
            fallback.informativeText = String(localized: "Open System Settings, choose Privacy & Security, then enable Go2Codex in the requested Automation or Accessibility section.")
            fallback.addButton(withTitle: String(localized: "OK"))
            fallback.runModal()
            return
        }
    }

    private func copy(_ diagnostics: DiagnosticRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.rendered, forType: .string)
    }
}

#if DEBUG
@MainActor
private struct ModifierProbePresenter {
    private let readiness = TargetPickerReadinessGate()

    func present(_ snapshot: InvocationSnapshot) async throws {
        let point = try ScreenPointResolver.usablePoint(
            for: snapshot.pointerLocation,
            screens: NSScreen.screens
        )
        let menu = NSMenu(title: "Go2Codex Modifier Probe")
        menu.autoenablesItems = false

        let flags = String(
            format: "Flags: 0x%llx %@",
            UInt64(snapshot.modifierFlagsRawValue),
            readableFlags(snapshot.deviceIndependentModifierFlags)
        )
        let location = String(
            format: "Point: %.1f, %.1f",
            snapshot.pointerLocation.x,
            snapshot.pointerLocation.y
        )
        for title in [flags, location] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Close Probe"),
            action: nil,
            keyEquivalent: ""
        )

        _ = try await readiness.runWhenReady {
            menu.popUp(positioning: nil, at: point, in: nil)
        }
    }

    private func readableFlags(_ flags: NSEvent.ModifierFlags) -> String {
        var names: [String] = []
        if flags.contains(.option) { names.append("Option") }
        if flags.contains(.shift) { names.append("Shift") }
        if flags.contains(.capsLock) { names.append("CapsLock") }
        if flags.contains(.function) { names.append("Function") }
        if flags.contains(.command) { names.append("Command") }
        if flags.contains(.control) { names.append("Control") }
        return names.isEmpty ? "None" : names.joined(separator: "+")
    }
}
#endif

@MainActor
final class LauncherCoordinator {
    private let gate = InvocationGate()
    private let preferencesReader: UserDefaultsPreferencesReader
    private let workflow: LauncherWorkflow
    private let launcherLogger: Logger
    private let handoffLogger: Logger

    init() {
        let preferencesReader = UserDefaultsPreferencesReader()
        self.preferencesReader = preferencesReader
        workflow = LauncherWorkflow(
            preferencesLoader: preferencesReader,
            settingsOpener: SettingsOpener(),
            workspaceResolver: FinderWorkspaceResolver(),
            availabilityLookup: TargetAvailabilityService(),
            targetPicker: TargetPicker(),
            desktopHandoff: DesktopOpenAdapter(),
            terminalHandoff: TerminalOpenAdapter()
        )
        let subsystem = Bundle.main.object(
            forInfoDictionaryKey: "Go2CodexPreferencesDomain"
        ) as? String ?? "io.github.czrzchao.go2codex"
        launcherLogger = Logger(subsystem: subsystem, category: "Launcher")
        handoffLogger = Logger(subsystem: subsystem, category: "Handoff")
    }

    func submit(_ snapshot: InvocationSnapshot) {
        guard gate.begin() else {
            launcherLogger.debug("Duplicate invocation ignored")
            return
        }
        Task { @MainActor [self] in
            await run(snapshot)
        }
    }

    private func run(_ snapshot: InvocationSnapshot) async {
        defer { finishAndExit() }
#if DEBUG
        if let delay = preferencesReader.invocationDelayMilliseconds() {
            try? await Task.sleep(for: .milliseconds(delay))
        }
        if preferencesReader.modifierProbeIsEnabled() {
            do {
                try await ModifierProbePresenter().present(snapshot)
                launcherLogger.debug("Modifier probe completed without handoff")
            } catch {
                fail(
                    LauncherWorkflowFailure(
                        error: error,
                        stage: .targetPicker
                    )
                )
            }
            return
        }
#endif

        do {
            let outcome = try await workflow.run(
                modifiers: snapshot.routingModifierFlags,
                pointerLocation: ScreenPoint(
                    x: snapshot.pointerLocation.x,
                    y: snapshot.pointerLocation.y
                )
            )
            switch outcome {
            case .settingsOpened:
                launcherLogger.info("Settings requested because configuration is incomplete or invalid")
            case .cancelled:
                launcherLogger.debug("Target picker cancelled")
            case let .handoffAccepted(target, terminalHost, _):
                if let terminalHost {
                    handoffLogger.info("Terminal handoff accepted target=\(target.rawValue, privacy: .public) host=\(terminalHost.rawValue, privacy: .public)")
                } else {
                    handoffLogger.info("Desktop handoff accepted target=\(target.rawValue, privacy: .public)")
                }
            }
        } catch let failure as LauncherWorkflowFailure {
            fail(failure)
        } catch {
            fail(
                LauncherWorkflowFailure(
                    error: error,
                    stage: .launcherInternal
                )
            )
        }
    }

    private func fail(_ failure: LauncherWorkflowFailure) {
#if DEBUG
        let policy = DiagnosticPolicy.debug
#else
        let policy = DiagnosticPolicy.release
#endif
        let record = DiagnosticSanitizer.sanitize(
            DiagnosticInput(
                applicationVersion: applicationVersion,
                systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                stage: failure.stage,
                target: failure.target,
                terminalHost: failure.terminalHost,
                errorCode: failure.code,
                errorDetail: failure.detail,
                workspace: failure.workspace,
                generatedCommand: failure.generatedCommand
            ),
            policy: policy
        )
        handoffLogger.error("\(record.rendered, privacy: .public)")
        FailurePresenter().present(failure: failure, diagnostics: record)
    }

    private var applicationVersion: String {
        let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        return "\(shortVersion) (\(build))"
    }

    private func finishAndExit() {
        guard gate.beginFinishing() else {
            return
        }
        NSApp.terminate(nil)
    }
}

@MainActor
protocol LauncherInvocationSubmitting: AnyObject {
    func submit(_ snapshot: InvocationSnapshot)
}

extension LauncherCoordinator: LauncherInvocationSubmitting {}

@MainActor
final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private let initialSnapshot: InvocationSnapshot
    private let coordinator: any LauncherInvocationSubmitting
    private let snapshotCapture: @MainActor () -> InvocationSnapshot

    init(
        initialSnapshot: InvocationSnapshot,
        coordinator: any LauncherInvocationSubmitting = LauncherCoordinator(),
        snapshotCapture: @escaping @MainActor () -> InvocationSnapshot = InvocationSnapshot.capture
    ) {
        self.initialSnapshot = initialSnapshot
        self.coordinator = coordinator
        self.snapshotCapture = snapshotCapture
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.submit(initialSnapshot)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        coordinator.submit(snapshotCapture())
        return false
    }
}
