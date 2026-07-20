# Go2Codex

Go2Codex hands the folder currently being viewed in Finder to a Codex or Claude coding agent with minimal friction.

Implementation is sequenced by the gated [implementation plan](docs/implementation-plan.md).

## Language

**Workspace**:
The exact folder displayed by the frontmost Finder window and handed to a coding agent as its primary working directory. Selected items and surrounding repository roots do not change it, and when Finder has no window Go2Codex does not substitute the Desktop, home directory, or a previous path.
_Avoid_: Project, current directory

**Launchable Workspace**:
A Workspace that resolves to an accessible directory on a currently mounted filesystem. It need not be a Git repository or reside on the startup disk.
_Avoid_: Repository, local folder

**Agent Target**:
A supported Codex or Claude surface that can be launched with a Workspace. The supported targets are Codex App, Codex CLI, Claude Desktop Code, and Claude Code CLI.
_Avoid_: Editor, IDE

**Unavailable Target**:
An Agent Target that cannot be opened in the current environment. It remains represented, causes the requested launch to fail, and is never hidden or silently replaced by another target.
_Avoid_: Missing app, fallback case

**Desktop Target**:
An Agent Target used through its graphical desktop application.
_Avoid_: GUI mode

**Desktop Handoff**:
A Handoff performed through an Agent Target's application URL scheme. Desktop Target availability requires Launch Services to resolve that scheme to the target's exact bundle identifier (`com.openai.codex` or `com.anthropic.claudefordesktop`), without assuming an application name or installation path; another application claiming the scheme is unavailable. The handoff does not require or invoke the target's CLI installation. Go2Codex reports success only after Launch Services accepts the asynchronous open request. Route acceptance, Target Confirmation, cancellation, and behavior after that point belong to the target and are not inferred or monitored by Go2Codex.
_Avoid_: Shell launch, CLI bridge

**Target Confirmation**:
A trust or security confirmation shown and owned by an Agent Target after Handoff. Claude Desktop requires one before adopting a Workspace supplied by a deep link.
_Avoid_: Launcher prompt, Launch Failure

**CLI Target**:
An Agent Target used through an interactive terminal session.
_Avoid_: Terminal Target, fallback

**CLI Invocation**:
The fixed `codex` or `claude` command sent without extra arguments to the Terminal Host's normally configured user shell after entering the Workspace. It does not depend on a stored absolute executable path or manage the shell after submission.
_Avoid_: Binary path, wrapper command

**Terminal Host**:
An external terminal application that hosts an interactive CLI Target session. The Personal MVP identifies Terminal.app (`com.apple.Terminal`) and iTerm2 (`com.googlecode.iterm2`) by bundle identifier and lets Launch Services resolve their exact application URLs. A fully quit Terminal.app is opened once with the CLI Invocation as its initial Apple Event; a running Terminal.app receives one direct event, with the same cold-open path used once if that process exits before submission. For iTerm2, the Launcher invokes one fixed handler from its precompiled AppleScript resource: the command is one text descriptor argument, while creation and the single write to the returned session stay inside that handler. iTerm2 never uses the Terminal-specific fallback.
_Avoid_: Embedded terminal, console

**Default Terminal Host**:
The single Terminal Host selected for all CLI Targets.
_Avoid_: Per-target terminal, system terminal

**Session Placement**:
The global preference for placing a new CLI Target session in a new tab or a new window. It initially prefers a new tab, creating a window when the Terminal Host has none. Terminal.app New Tab with an existing window fails before command submission because Terminal exposes no verified create-tab event; iTerm2 supports that placement.
_Avoid_: Terminal layout

**Launcher Button**:
The single Finder toolbar control representing the Toolbar Launcher rather than any individual Agent Target.
_Avoid_: Codex button, Claude button, target button

**Toolbar Installation**:
The explicit Settings App operation that reveals the embedded Toolbar Launcher after the containing release build resides in `/Applications` or `~/Applications`, then instructs the user to hold Command and drag it into Finder's toolbar. First Run presents a native Continue Manually or Cancel confirmation before revealing it. The Personal MVP does not write Finder preferences or restart Finder; cancelling changes nothing beyond preferences already committed by the First Run action. Debug builds retain their documented development-location exemption.
_Avoid_: Silent installation, Finder extension registration

**Toolbar Uninstallation**:
The explicit Settings App operation that shows how to hold Command and drag the Go2Codex button out of Finder's toolbar. It does not write Finder preferences, restart Finder, or restore a historical toolbar snapshot.
_Avoid_: Reset Finder toolbar, restore all defaults

**Toolbar Repair**:
The read-only Needs Repair classification used when Finder contains a uniquely recognized Go2Codex item whose stored Toolbar Launcher path is stale. The Personal MVP offers the same manual reveal-and-Command-drag setup path and never rewrites the stale item automatically.
_Avoid_: Automatic repair, reinstall everything

**Finder Toolbar Installer**:
The guarded Core models and read-only Settings adapter that inspect Finder's undocumented toolbar preference structure and fail closed on unknown, inconsistent, or unverifiable data. Mutation planners remain tested evidence for a future supported serialization contract, but the Personal MVP connects no preference setter, Finder restart, automatic repair, or automatic removal.
_Avoid_: Finder extension, privileged installer

**Settings App**:
The outer Settings product (`Go2Codex.app` in Personal Release and `Go2CodexDebug.app` in Debug) and its primary executable. Launching it from Spotlight, Applications, Alfred, `open`, or an existing Dock presence always opens First Run or Settings and never infers a Workspace from Finder, sends an Apple Event, or performs Handoff. It still declares the Apple Events entitlement and localized usage description because macOS treats it as the TCC responsible identity for events sent by its nested Toolbar Launcher.
_Avoid_: Launcher App, toolbar app

**Toolbar Launcher**:
The embedded `LSUIElement` helper application represented by the Launcher Button. Its user-facing display name is `Go2Codex`, matching the Settings App and hiding the internal process split, while its executable and bundle identifier remain distinct. It directly reads the Settings App's shared preferences, samples the current modifier state at startup, rejects an observed Option flag before querying Finder, resolves the Workspace, performs Quick Launch or presents the Target Picker, and exits without a Dock icon; it launches the Settings App only when First Run is incomplete. Finder and Launch Services do not supply a documented modifier value bound to the originating toolbar click, so this startup sample is not proof of a modifier that was released before the Launcher began.
_Avoid_: Finder extension, resident helper, forwarding stub

**Dual-Entry Architecture**:
The packaging of the Settings App and Toolbar Launcher as separate application entry points inside one distributed `Go2Codex.app`. The selected executable identifies user intent without guessing whether Launch Services was invoked from Finder, and ordinary toolbar actions require no IPC with the Settings App.
_Avoid_: Launch-source detection, single-entry mode

**Trigger-and-Handoff Lifecycle**:
The Toolbar Launcher runs only for an explicit Launcher Button invocation and ends after completing or failing it, using an accessory presentation with no Dock or status item for Quick Launch and Target Picker. The Settings App uses a regular Dock presence and standard app menus while First Run or Settings is open, and ordinary reactivation only brings that window forward. A Toolbar Launcher invocation remains independent and can perform Handoff while Settings is open. Neither entry point performs background polling or usage monitoring.
_Avoid_: Menu bar lifecycle, background service

**Default Target**:
The Agent Target preferred by the user when the Launcher Button performs its primary quick action.
_Avoid_: Favorite, fallback target

**Quick Launch**:
The Launcher Button's primary action, which opens the current Workspace directly in the Default Target without first presenting a choice.
_Avoid_: Open, default open

**Handoff**:
The point at which an Agent Target receives a Workspace. A successful Handoff is silent, and the Toolbar Launcher does not own, monitor, resume, or terminate the resulting Agent or terminal session after this point.
_Avoid_: Session, task

**Fresh Session**:
A newly started Agent Target session scoped to a Workspace, created without searching for previous sessions or supplying an initial prompt.
_Avoid_: Reopen, continue, recent session

**Launch Failure**:
A failure the Toolbar Launcher can determine before Handoff and present in a native error dialog, such as an invalid Workspace or unavailable desktop application or Terminal Host. The dialog can copy sanitized diagnostics containing application and system versions, launch stage, target identity, and error details without the full Workspace path; failures produced by an Agent Target after Handoff are outside this term.
_Avoid_: Agent error, command failure

**Target Picker**:
A compact native picker shown near the Launcher Button with all four Agent Targets in fixed order for one launch. The Default Target is marked but not repositioned, known unavailable targets are disabled, choosing a target does not change the default, and clicking elsewhere or pressing Escape cancels silently. The picker branch conditionally waits up to one second for `NSEvent.pressedMouseButtons == 0`, then presents a compact borderless `NSPanel` with the `.nonactivatingPanel` style by calling `orderFrontRegardless()` and maintaining its synchronous lifetime with `NSApp.runModal(for:)`. It neither activates Go2Codex nor treats focus loss as cancellation. While the panel is visible, a temporary global mouse-down monitor detects clicks delivered outside Go2Codex; every selection or cancellation completes once, stops the modal session, and immediately removes that monitor. The ten-millisecond polling is only for physical mouse release and is not a blind fixed delay; mouse-release timeout or cancellation is a typed failure with no panel or Handoff.
_Avoid_: Main menu, settings menu

**Alternate Trigger**:
The user-configurable modified click that opens the Target Picker instead of performing Quick Launch. It can be Shift-click or disabled, and its initial value is Shift-click. The Personal MVP operating contract requires holding Shift until the picker is stably visible. Option-click is unsupported and must not be used because Finder may close the invoking viewer window before Go2Codex can resolve its exact Workspace. When the Launcher's startup snapshot still observes Option, including Option+Shift, it fails closed before any Finder query or Handoff; a modifier released before that snapshot cannot be strictly attributed to the originating click.
_Avoid_: Right-click, shortcut

**Settings Window**:
The single-page form shared by First Run and later Settings. It presents three vertically ordered sections: General contains Default Target and Alternate Trigger; CLI contains Default Terminal Host and Session Placement; Finder Toolbar appears last with the detected installation status and its applicable manual setup or removal-instructions action. First Run visually emphasizes the Finder Toolbar section after required preferences are committed. Completing manual Toolbar Installation keeps the window open; returning to Settings refreshes this section without invoking the Toolbar Launcher or testing a Handoff.
_Avoid_: Setup wizard, sidebar, tabbed preferences

**Toolbar Installation Status**:
The Settings App's best-effort, read-only classification of Finder's recognized toolbar configuration as Installed, Not Installed, Needs Repair, or Manual Setup Required. Installed exposes manual removal instructions; every other status exposes manual Command-drag setup. Status describes independently verified stored Finder data rather than claiming that a visible toolbar button was successfully clicked.
_Avoid_: Runtime health, launch verification

**First Run**:
The Settings App state before its required preferences have been saved. It requires explicit Default Target and Default Terminal Host choices and commits them together only when the user activates the single completion action; closing earlier preserves the First Run state. The action is titled Complete Setup and Install in Finder when automatic mutation is available, or Complete Setup and Show Manual Setup when the safety gate requires Command-drag. It commits the preferences, completes First Run, and immediately presents the install-or-manual-fallback confirmation. First Run has no separate Save Only path: saved-but-uninstalled state occurs only when the user actively cancels that confirmation, abandons the subsequent manual drag, or setup fails. None of those outcomes discards preferences or restores First Run, and later Settings continues to show the unresolved Toolbar Installation Status. If the Toolbar Launcher is invoked before required preferences exist, it opens the Settings App and exits without attempting Handoff.
_Avoid_: Onboarding flow

**Settings Launch**:
Any ordinary launch or reactivation of the Settings App, including from Spotlight, Applications, Alfred, `open`, or the Toolbar Launcher's incomplete-setup path. It presents First Run or Settings without resolving a Finder Workspace, sending a Finder Apple Event, or performing Quick Launch; it may refresh Finder's toolbar preference solely for the read-only installation status. Later preference changes save immediately without Save or Cancel controls, and closing the window exits the app.
_Avoid_: Target Picker, preferences gesture

**Automation Permission**:
The macOS consent for Apple Events that the Toolbar Launcher sends to read the active Finder location or control the selected Terminal Host for Handoff. Apple Event sending code exists only in the Launcher, but macOS attributes a nested invocation's TCC responsibility to the outer Go2Codex application, so both bundles declare the entitlement and localized usage description. If denied, Go2Codex explains the required Finder or terminal access and offers to open macOS Automation settings without repeatedly requesting or bypassing consent; it does not include Accessibility, Full Disk Access, screen recording, or notification access.
_Avoid_: Accessibility permission, file permission

**Local Diagnostics**:
Diagnostic output written only to macOS Unified Logging, with exact paths and generated commands available in Debug builds but removed from Release builds. Release diagnostics retain stages, target identities, and error codes without creating a Go2Codex log file or sending telemetry.
_Avoid_: Analytics, crash upload, application log file

## Delivery

**Application Identity**:
The stable identity whose user-facing display name is `Go2Codex` for both application entry points, intended GitHub owner is `CzRzChao`, and Settings App bundle identifier is `io.github.czrzchao.go2codex`. Its embedded Toolbar Launcher uses a distinct executable and `io.github.czrzchao.go2codex.launcher` internally without displaying `Launcher` to the user. Personal Release uses the exact outer wrapper and executable names `Go2Codex.app` and `Go2Codex`. Debug builds display both entry points as `Go2Codex Debug`, use `io.github.czrzchao.go2codex.debug` plus `io.github.czrzchao.go2codex.debug.launcher`, and name the outer wrapper and executable `Go2CodexDebug.app` and `Go2CodexDebug`. The distinct Debug wrapper name is required because Launch Services name-based resolution can match an application wrapper independently of its bundle identifier; distinct identifiers alone do not prevent a Debug `Go2Codex.app` from shadowing Personal Release. Preferences and outer TCC responsible identities remain configuration-specific. The currently frozen pre-SOP Personal baseline is ad-hoc signed; the local-development SOP permits one explicit migration to Apple Development and then requires stable Team and designated requirements for every later Personal update. Public Release uses Developer ID Application signing and notarization.
_Avoid_: personal bundle identifiers, product name as bundle identifier

**Supported Platform**:
Apple Silicon Macs running macOS 14 Sonoma or later. Go2Codex does not ship Intel (`x86_64`) or Universal binaries in either Personal MVP or Public Release.
_Avoid_: Intel support, Universal build

**Supported Locales**:
The two user-interface localizations shipped by Go2Codex: English as the base and fallback language, and Simplified Chinese (`zh-Hans`). Traditional Chinese and every other system language fall back to English, while product and command names remain untranslated.
_Avoid_: Chinese-only UI, automatic translation

**Implementation Architecture**:
The native `.xcodeproj` structure containing a SwiftUI-first Settings App target with only a thin AppKit lifecycle adapter, an embedded AppKit-first `LSUIElement` Toolbar Launcher target, a pure Swift shared core target, and a test target. Xcode owns target dependencies, Launcher embedding, resources, and nested signing order; the Personal MVP does not use a SwiftPM-first executable plus a hand-written application-bundle assembly script.
_Avoid_: Pure SwiftUI, AppKit-only Settings, hand-assembled main application bundle

**Personal MVP**:
The first usable release, validated against its owner's Mac and workflow while avoiding personal data or machine-specific paths that would prevent later publication. It is entirely local and makes no network requests for analytics, crash reporting, or update checks.
_Avoid_: Prototype, private fork

**Public Release**:
A later Developer ID-signed and notarized release prepared for other developers to obtain from GitHub Releases, with Homebrew Cask as a possible additional channel and no Mac App Store target.
_Avoid_: App Store version

## Current Personal MVP limitations

- Automatic Finder Toolbar Installation, Repair, and Uninstallation are not connected to production. The [serialization investigation](docs/spikes/0008-finder-preference-serialization-boundary.md) found no public atomic boundary that can prevent a concurrent Finder or `cfprefsd` update from being overwritten, so [ADR 0008](docs/adr/0008-keep-finder-toolbar-mutation-behind-a-serialization-gate.md) requires the manual Command-drag path.
- Finder owns Option-click on toolbar items and may close the invoking viewer window as part of that system behavior. Go2Codex therefore supports only Shift-click or Disabled as Alternate Trigger values, instructs the user to hold Shift until the picker is stable, and does not support Option-click. Finder/Launch Services `oapp` and `rapp` delivery has no documented click-bound modifier contract: the Launcher rejects Option before reading Finder only when its startup snapshot still observes the flag, while a rapidly released modifier cannot be classified strictly. This modifier safety gate remains unresolved; Go2Codex does not add a global key or modifier monitor, Accessibility permission, retry, or fallback. The picker separately uses a mouse-down-only global monitor while its panel is visible solely to detect outside clicks, then removes it immediately.
- The first real Shift-click displayed the four-item Target Picker but it immediately vanished, and replacing cooperative activation with `activate(ignoringOtherApps: true)` alone still flashed. A later readiness build that also required `NSApp.isActive` passed its first real Shift check but failed the second with `target-picker-activation-timeout`; the subsequent mouse-release-plus-best-effort-activation `NSMenu` repair also flashed. The frozen installed baseline replaces that disconnected menu with a compact borderless nonactivating panel that waits for physical mouse release, uses `orderFrontRegardless()` plus `runModal`, and does not depend on application activation or focus-loss cancellation. Historical real checks confirmed stable display, silent Escape/outside cancellation, one exact Codex App Handoff, and five consecutive open/Escape cycles. The installed baseline is not byte-identical to current source: the two new virtual-view localization keys and friendly “最近使用” handling, plus the Terminal.app cold-start repair, remain source-only until they complete the strict SOP lanes. The installed `0.1.0 (1)` must not be treated as containing either repair. The separate rapid-overlap invocation check remains pending.
- Terminal.app does not expose a verified Apple Event that creates a new tab before submitting a command. New Tab with an existing Terminal window therefore fails closed instead of writing into the active tab. Current source repairs cold New Window and no-window New Tab by opening Terminal's exact URL once with the command as its initial Apple Event, plus a one-time recovery when a direct event races with process exit. A real iTerm2 3.6.10 check disproved the raw create-result repair: even with the compiled command's `subj` bindings, iTerm returned only `type(cwin)` without object identity. Current source therefore uses a precompiled parameterized AppleScript handler that keeps create and write inside one interpreter invocation, never guesses `current window`, and never retries. The frozen Release and currently installed Debug predate this handler, so real updated Installed Debug smoke remains pending.
