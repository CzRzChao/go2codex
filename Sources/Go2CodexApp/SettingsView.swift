import AppKit
import Combine
import Foundation
import Go2CodexCore
import OSLog
import SwiftUI

@MainActor
final class LaunchServicesSettingsAvailabilityService: SettingsAvailabilityServing {
    func targetAvailability(
        _ target: AgentTarget,
        terminalHost: TerminalHost?
    ) -> TargetAvailability {
        switch target.kind {
        case .desktop:
            guard let workspace = try? Workspace(absolutePath: "/"),
                  let url = try? DesktopURLBuilder.url(for: target, workspace: workspace) else {
                return .unavailable(.notEvaluated)
            }
            let handlerURL = NSWorkspace.shared.urlForApplication(toOpen: url)
            return DesktopTargetHandlerPolicy.accepts(
                target: target,
                handlerBundleIdentifier: handlerURL.flatMap {
                    Bundle(url: $0)?.bundleIdentifier
                }
            ) ? .available : .unavailable(.desktopHandlerMissing(target))
        case .cli:
            guard let terminalHost else {
                return .unavailable(.notEvaluated)
            }
            return terminalHostIsAvailable(terminalHost)
                ? .available
                : .unavailable(.terminalHostMissing(terminalHost))
        }
    }

    func terminalHostIsAvailable(_ terminalHost: TerminalHost) -> Bool {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: terminalHost.bundleIdentifier
        ) != nil
    }
}

extension SettingsModel {
    static func live() -> SettingsModel {
        let preferences: any SettingsPreferencesServing
        do {
            preferences = try UserDefaultsPreferencesStore.fromMainBundle()
        } catch {
            let code = (error as? any DiagnosticCodeProviding)?.diagnosticCode.rawValue
                ?? "preferences-store-unexpected"
            let subsystem = Bundle.main.bundleIdentifier
                ?? "io.github.czrzchao.go2codex"
            Logger(subsystem: subsystem, category: "Settings")
                .error("Preferences store unavailable code=\(code, privacy: .public)")
            preferences = UnavailableSettingsPreferencesService()
        }
        return SettingsModel(
            preferences: preferences,
            toolbar: FinderToolbarSettingsService(),
            availability: LaunchServicesSettingsAvailabilityService(),
            cliAvailabilityProbe: SystemCLIExecutableAvailabilityProbe(
                loginShellPathLookup: SystemLoginShellPathLookup(),
                runner: SystemLoginShellCommandRunner()
            )
        )
    }
}

struct SettingsRootView: View {
    @StateObject private var model = SettingsModel.live()

    var body: some View {
        SettingsView(model: model)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            if model.phase == .recoveryRequired {
                recoverySection
            }

            generalSection
            cliSection
            finderToolbarSection

            if model.hasSaveError {
                Label("Settings could not be saved. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings-save-error")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 600)
        .task {
            await model.loadIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.refreshAfterActivation()
            }
        }
    }

    private var generalSection: some View {
        Section("General") {
            Picker(
                "Default Target",
                selection: Binding(
                    get: { model.defaultTarget },
                    set: { model.selectDefaultTarget($0) }
                )
            ) {
                if model.isFirstRun {
                    Text("Choose…").tag(nil as AgentTarget?)
                }
                ForEach(AgentTargetCatalog.targets, id: \.self) { target in
                    pickerLabel(
                        target.displayName,
                        unavailable: model.targetIsKnownUnavailable(target)
                    )
                    .tag(Optional(target))
                }
            }
            .disabled(!model.controlsAreEnabled)
            .accessibilityIdentifier("default-target")

            Picker(
                "Alternate Trigger",
                selection: Binding(
                    get: { model.alternateTrigger },
                    set: { model.selectAlternateTrigger($0) }
                )
            ) {
                Text("Shift-click").tag(AlternateTrigger.shiftClick)
                Text("Disabled").tag(AlternateTrigger.disabled)
            }
            .disabled(!model.controlsAreEnabled)
            .accessibilityIdentifier("alternate-trigger")
        }
    }

    private var cliSection: some View {
        Section("CLI") {
            cliAvailabilityRow(
                "Codex CLI",
                executable: .codex,
                accessibilityIdentifier: "codex-cli-availability"
            )
            cliAvailabilityRow(
                "Claude Code CLI",
                executable: .claude,
                accessibilityIdentifier: "claude-cli-availability"
            )

            HStack {
                Button("Refresh CLI Status") {
                    Task {
                        await model.refreshCLIExecutableStatus()
                    }
                }
                .disabled(isCheckingCLIAvailability)
                .accessibilityIdentifier("refresh-cli-availability")

                Spacer()
            }

            Text("CLI checks run in the background using your account login shell. Results are advisory and do not block saving or launching because terminal-specific shell setup can differ. Refresh after installing a CLI.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Picker(
                "Default Terminal Host",
                selection: Binding(
                    get: { model.defaultTerminalHost },
                    set: { model.selectDefaultTerminalHost($0) }
                )
            ) {
                if model.isFirstRun {
                    Text("Choose…").tag(nil as TerminalHost?)
                }
                ForEach(TerminalHost.allCases, id: \.self) { terminalHost in
                    pickerLabel(
                        terminalHost.displayName,
                        unavailable: model.terminalHostIsKnownUnavailable(terminalHost)
                    )
                    .tag(Optional(terminalHost))
                    .disabled(model.terminalHostIsKnownUnavailable(terminalHost))
                }
            }
            .disabled(!model.controlsAreEnabled)
            .accessibilityIdentifier("default-terminal-host")

            Picker(
                "Session Placement",
                selection: Binding(
                    get: { model.sessionPlacement },
                    set: { model.selectSessionPlacement($0) }
                )
            ) {
                Text("New Tab").tag(SessionPlacement.newTab)
                Text("New Window").tag(SessionPlacement.newWindow)
            }
            .pickerStyle(.segmented)
            .disabled(!model.controlsAreEnabled)
            .accessibilityIdentifier("session-placement")
        }
    }

    private func cliAvailabilityRow(
        _ title: LocalizedStringKey,
        executable: CLIExecutable,
        accessibilityIdentifier: String
    ) -> some View {
        let status = model.cliStatus(for: executable)
        return LabeledContent(title) {
            HStack(spacing: 6) {
                if status == .checking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(cliStatusTitle(status))
                    .foregroundStyle(cliStatusColor(status))
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var isCheckingCLIAvailability: Bool {
        CLIExecutable.allCases.contains {
            model.cliStatus(for: $0) == .checking
        }
    }

    private func cliStatusTitle(
        _ status: CLIExecutableSettingsStatus
    ) -> LocalizedStringKey {
        switch status {
        case .checking:
            "Checking…"
        case .available:
            "Available"
        case .missing:
            "Not Found"
        case .couldNotVerify:
            "Couldn’t Verify"
        }
    }

    private func cliStatusColor(
        _ status: CLIExecutableSettingsStatus
    ) -> Color {
        switch status {
        case .available:
            .green
        case .missing, .couldNotVerify:
            .orange
        case .checking:
            .secondary
        }
    }

    private var finderToolbarSection: some View {
        Section("Finder Toolbar") {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    if model.toolbarStatus == .checking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(toolbarStatusTitle)
                        .foregroundStyle(toolbarStatusColor)
                }
            }
            .accessibilityIdentifier("finder-toolbar-status")

            if model.isFirstRun {
                Text(firstRunExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button(firstRunActionTitle) {
                    Task {
                        await model.completeFirstRunAndInstall()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCompleteFirstRun)
                .accessibilityIdentifier("complete-setup-and-install")

                if model.defaultTarget == nil || model.defaultTerminalHost == nil {
                    Text("Choose a default target and terminal host to continue.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if model.phase == .configured {
                toolbarActionButton

                if !model.supportsAutomaticToolbarMutation
                    || model.toolbarStatus == .manualSetupRequired {
                    Text("Automatic Finder setup is unavailable. Use the manual Command-drag setup instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if model.hasToolbarError {
                Label("Finder toolbar setup could not be completed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("finder-toolbar-error")
            }
        }
    }

    @ViewBuilder
    private var toolbarActionButton: some View {
        if model.supportsAutomaticToolbarMutation {
            switch model.toolbarStatus {
            case .checking:
                EmptyView()
            case .notInstalled:
                toolbarButton("Install in Finder", action: .install)
            case .installed:
                toolbarButton("Uninstall from Finder", action: .uninstall)
            case .needsRepair:
                toolbarButton("Repair in Finder", action: .repair)
            case .manualSetupRequired:
                toolbarButton("Show Manual Setup", action: .showManualSetup)
            }
        } else {
            switch model.toolbarStatus {
            case .checking:
                EmptyView()
            case .installed:
                toolbarButton("Show Removal Instructions", action: .uninstall)
            case .notInstalled, .needsRepair, .manualSetupRequired:
                toolbarButton("Show Manual Setup", action: .showManualSetup)
            }
        }
    }

    private var firstRunActionTitle: LocalizedStringKey {
        model.supportsAutomaticToolbarMutation && model.toolbarStatus != .manualSetupRequired
            ? "Complete Setup and Install in Finder"
            : "Complete Setup and Show Manual Setup"
    }

    private var firstRunExplanation: LocalizedStringKey {
        model.supportsAutomaticToolbarMutation && model.toolbarStatus != .manualSetupRequired
            ? "Your choices are saved before Finder installation begins."
            : "Your choices are saved before manual Finder setup begins."
    }

    private func toolbarButton(
        _ title: LocalizedStringKey,
        action: ToolbarSettingsAction
    ) -> some View {
        Button(title) {
            Task {
                await model.performToolbarAction(action)
            }
        }
        .disabled(model.isPerformingAction)
        .accessibilityIdentifier("finder-toolbar-action")
    }

    private func pickerLabel(_ title: String, unavailable: Bool) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
            if unavailable {
                Text("Unavailable")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recoverySection: some View {
        Section {
            Label("Settings Need Attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Go2Codex couldn't read its saved settings. No launch action will run.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Reset Settings", role: .destructive) {
                isConfirmingReset = true
            }
            .accessibilityIdentifier("settings-recovery-reset")
            .alert("Reset Settings?", isPresented: $isConfirmingReset) {
                Button("Cancel", role: .cancel) {}
                Button("Reset Settings", role: .destructive) {
                    Task {
                        await model.resetToFirstRun()
                    }
                }
            } message: {
                Text("This clears your saved settings and starts setup again.")
            }
        }
        .accessibilityIdentifier("settings-recovery")
    }

    private var toolbarStatusTitle: LocalizedStringKey {
        switch model.toolbarStatus {
        case .checking:
            "Checking…"
        case .installed:
            "Installed"
        case .notInstalled:
            "Not Installed"
        case .needsRepair:
            "Needs Repair"
        case .manualSetupRequired:
            "Manual Setup Required"
        }
    }

    private var toolbarStatusColor: Color {
        switch model.toolbarStatus {
        case .installed:
            .green
        case .needsRepair:
            .orange
        case .checking, .notInstalled, .manualSetupRequired:
            .secondary
        }
    }
}
