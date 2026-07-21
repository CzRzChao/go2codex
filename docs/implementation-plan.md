# Go2Codex implementation plan

Status: M0–M1 exit gates pass. The current source passes 154 SOP safety checks, 249 top-level tests, and 287 expanded parameterized cases with zero failures, skips, or expected failures; the fixed xcresult is parsed fail-closed. The suite includes deterministic coverage for the iTerm2 initial-event preflight, but the fully quit iTerm2 behavior still requires an updated Installed Debug smoke. The installed `0.1.0 (1)` Personal Release is a frozen, known-working pre-SOP baseline with 73 localized strings; current source has 75 and includes the new virtual-Finder-view guidance plus source-only terminal cold-start repairs, so the installed app is not the current source product and has not been promoted. Unit tests build only Core and the test bundle, producing no App product or Launch Services registration. A strict local-development SOP separates Unit, stable-signed Installed Debug, non-installing Release Candidate, and explicit Promote/Rollback lanes; an explicit temporary ad-hoc Debug path exists only for non-authoritative fault observation and cannot create smoke or promotion evidence. Smoke pending/staging evidence blocks candidate generation and promotion even when a pass receipt exists; shared Release transactions carry an explicit install-or-rollback owner and can be recovered only by that owner. Completed transactions are atomically retired to owner-specific cleanup tombstones before recursive deletion, so an interruption cannot turn them into ambiguous half-deleted active state. The missing Apple Development identity currently blocks authoritative Installed Debug; a clean committed Git baseline additionally gates an authoritative smoke record; an incremented build number additionally gates candidate generation and promotion. Historical real-device evidence remains recorded in [Personal MVP validation](personal-mvp-validation.md), but it must not be read as proof that the current source is installed.

This plan turns [the product context](../CONTEXT.md), [ADR 0002](adr/0002-use-scoped-apple-events-for-automation.md), [ADR 0004](adr/0004-use-a-native-swift-trigger-and-handoff-app.md), [ADR 0006](adr/0006-use-a-settings-app-with-an-embedded-toolbar-launcher.md), [ADR 0007](adr/0007-use-guarded-finder-preference-editing-for-toolbar-installation.md), and the two completed Finder spikes into an implementation sequence. A milestone is complete only when its exit gate passes. A later milestone must not weaken an earlier invariant.

## 1. Delivery boundary

The Personal MVP is a local, Apple Silicon-only macOS application with two entry points inside one distributed `Go2Codex.app`:

- the Settings App always opens First Run or Settings;
- the embedded Toolbar Launcher runs only for an explicit Finder toolbar invocation, hands the current Finder Workspace to one of four fixed Agent Targets, and exits;
- automatic Finder toolbar mutation would require both an exact, reversibly validated Finder profile and a supported cross-writer serialization boundary;
- the validated environment has no such serialization boundary, so the Personal MVP uses the manual Command-drag path for every Finder shape;
- the running application performs no networking, telemetry, update checks, crash upload, or background monitoring.

The four Agent Targets remain in this fixed order:

1. Codex App
2. Codex CLI
3. Claude Desktop Code
4. Claude Code CLI

VS Code, an embedded terminal, session restoration, prompts, provider usage monitoring, menu bar residency, Intel support, and Mac App Store distribution are outside this plan.

## 2. Current workspace and prerequisites

The development Mac and project baseline were verified on 2026-07-18:

- macOS 14.6 build 23G80 on arm64;
- Xcode 16.2 build 16C5032a is installed and selected, with Swift 6.0.3 and the macOS 15.2 SDK;
- clean Debug tests and Release builds succeed for the arm64 macOS 14 project;
- the local Git repository is initialized on `main`; the first commit remains deferred until an author identity is configured;
- the GitHub CLI account name is configured, but its current authentication token is invalid;
- both CLI commands and the primary Claude/iTerm test applications are present;
- Finder 14.6 build 1632.6.3 is the sole environment with a validated build-specific toolbar fixture; it is planner evidence, not an enabled automatic-install profile.

M0 pinned Xcode 16.2 because Apple lists it as compatible with macOS Sonoma 14.5 and later and it supplies Swift 6.0. Newer Xcode releases require a newer host macOS, so upgrading tools beyond Xcode 16.2 is not part of the Personal MVP. See Apple's [Xcode support matrix](https://developer.apple.com/support/xcode/).

Repairing GitHub authentication remains a deferred user-visible environment change and does not block local development.

## 3. Product invariants

### 3.1 Entry points and lifecycle

- A launch from Spotlight, Applications, Alfred, `open`, Dock, Xcode, or ordinary reactivation opens or raises Settings only. It never resolves a Finder Workspace, sends a Finder Apple Event, or performs Handoff; Settings may read Finder's toolbar preference value solely to display its read-only installation status.
- Only the embedded Toolbar Launcher resolves a Workspace or performs Handoff.
- The Settings App and Toolbar Launcher do not use normal-launch IPC. The Launcher reads a fresh shared preference snapshot directly.
- The Launcher remains independent while Settings is open.
- The Launcher has no Dock icon or status item and exits after success, failure, or cancellation.
- If First Run is incomplete, the Launcher opens Settings and exits without reading Finder.
- Rapid repeated invocations must not create overlapping pickers or duplicate Handoffs in one Launcher process. A process-local invocation gate accepts one active request and ignores duplicate reopen events until it exits.

### 3.2 Workspace and targets

- Workspace means the exact directory displayed by Finder's frontmost window.
- Selected items, Git roots, Desktop, the home directory, and the previous Workspace are never substitutes.
- A mounted, accessible directory is valid even when it is outside the startup disk or is not a Git repository.
- Finder with no window, a virtual/non-file location, an inaccessible directory, or an unmounted volume produces a Launch Failure.
- An unavailable target is never hidden or silently replaced by another target.
- Desktop Handoff uses only the target's validated URL scheme and a Launch Services handler whose bundle identifier exactly matches that target.
- CLI Handoff creates a new terminal session, enters the Workspace, submits only `codex` or `claude`, and ends Go2Codex ownership at submission.
- Default Terminal Host is one global preference for all CLI targets. Terminal.app (`com.apple.Terminal`) and iTerm2 (`com.googlecode.iterm2`) are resolved by bundle identifier through Launch Services.
- Session Placement is one global preference. It initially selects a new tab and creates a window when the selected Terminal Host has no window; the alternative always creates a new window. Because Terminal.app has no verified create-tab event, New Tab with an existing Terminal window fails before command submission rather than reusing that window.
- Terminal.app receives a direct wait-for-reply command while running. When it is fully quit, or exits between the running-state check and a direct event, Go2Codex opens its exact resolved application URL once with the command as the initial Apple Event. It does not create an empty window first, poll, sleep, duplicate the command, or apply this fallback to iTerm2.
- Every iTerm2 Handoff first resolves iTerm2's exact application URL by bundle identifier and opens that URL through `NSWorkspace.OpenConfiguration.appleEvent`. The initial event is `aevt/odoc`; its direct object is a one-item file-URL list containing only the current user's `Library/Application Support/iTerm2/version.txt`, and it carries no generated command. Only a successful open completion may proceed. New Window then runs one fixed handler from the Launcher's precompiled AppleScript resource; New Tab first queries the native current window and then runs exactly one fixed handler. A failed preflight performs no current-window query and no handler invocation, and no path retries or falls back.
- The checked-in iTerm2 handlers still open the same sentinel before their first target operation, but that handler-level open is not the cold-start ordering guarantee: targeting a non-running application from AppleScript can start it before that command reaches the application. The guarantee comes from supplying the sentinel open-documents event as the `NSWorkspace` launch request's initial Apple Event. A generic AppleScript `launch` remains forbidden. Inside the selected handler, the generated command is passed as one text descriptor argument rather than source text; the new window or tab stays inside the interpreter, its current session receives one write, and the returned object never crosses into Swift. The handler omits iTerm2's optional creation `command`, requires explicit Boolean true, and never delays, retries, closes a session after uncertain failure, or guesses from `current window`.
- A target-owned trust prompt or a later terminal error is not a Go2Codex Launch Failure.

### 3.3 Quick Launch and Target Picker

- Ordinary click performs Quick Launch with Default Target.
- Alternate Trigger supports Shift-click or Disabled; its initial value is Shift-click.
- A schema-v1 `option-click` preference is decoded and canonically rewritten as `shift-click`; the preference schema remains version 1.
- Finder reserves Option-click on toolbar items and may close the invoking viewer window. Option-click is unsupported and the user must not use it; the Shift operating contract is to hold Shift until the picker is stably visible.
- Finder/Launch Services `oapp` and `rapp` events have no documented modifier value bound to the originating toolbar click. The Launcher samples `NSEvent.modifierFlags` at startup: if that snapshot still contains Option, including Option+Shift, it fails with `finder-option-modifier-unsupported` before any Finder query, picker, or Handoff. Rapidly released modifiers cannot be strictly classified, so this safety gate remains unresolved.
- Modifier handling adds no retry, fallback, global key or modifier monitor, or Accessibility permission. The picker separately installs a mouse-down-only global monitor only while its panel is visible to detect outside clicks, and removes it immediately when the one-shot session finishes.
- The picker always shows all four targets in fixed order. Default Target is marked but not moved.
- A known unavailable target is disabled rather than removed.
- Picker selection affects one launch and never changes Default Target.
- Escape and clicking elsewhere cancel silently.
- The picker contains no Settings item.
- Settings continues to represent all four Agent Targets even when one is currently unavailable; it labels that state but does not rewrite the user's selection. The invocation picker disables a known unavailable target.

### 3.4 First Run and Settings

- First Run requires explicit Default Target and Default Terminal Host selections.
- Closing before completion stores no partial required configuration and remains First Run.
- The only completion action is Complete Setup and Install in Finder when automatic mutation is available, or Complete Setup and Show Manual Setup when the safety gate requires the manual path. It first commits one complete preference envelope, marks First Run complete, and then presents the install-or-manual-fallback confirmation; there is no Save Only action.
- Cancelling or failing the install-or-manual-fallback step keeps the committed preferences and does not return to First Run.
- Later settings save immediately and have no Save or Cancel buttons.
- Settings uses one page with General, CLI, and Finder Toolbar sections in that order.
- Successful installation leaves Settings open, refreshes the toolbar status to Installed, and does not test Handoff.

### 3.5 Finder toolbar safety

The following mutation requirements remain dormant contracts for any future implementation. The Personal MVP connects no Finder preference setter, Finder restart, transaction journal, or recovery executor; all production setup and removal use Command-drag.

- Install, Repair, and Uninstall each require a native confirmation before any journal write, preference mutation, or Finder restart.
- Cancelling changes neither Finder preferences nor the running Finder process.
- A generic `com.apple.finder.loc ` identifier is never ownership evidence by itself.
- All writes are fail-closed on an unknown shape, ambiguous match, malformed index, disk/live disagreement, invalid URL type, conflicting alias, invalid Launcher identity, or unsupported environment.
- Installation is idempotent, preserves every unrelated item and its order, and inserts at the profile's verified rightmost customizable position.
- Repair changes only the uniquely recognized stale Launcher URL at its current position.
- Uninstall derives its expected result from the current toolbar and removes only the uniquely recognized Go2Codex entry. It never restores a historical whole-toolbar snapshot.
- A successful operation requires a Finder restart followed by repeated disk/live convergence on an accepted semantic representation.
- Recovery is driven by the durable journal plus current disk and live values, never by an assumption about the last completed source line.

### 3.6 Identity, privacy, and localization

- Release bundle identifiers are `io.github.czrzchao.go2codex` and `io.github.czrzchao.go2codex.launcher`.
- Debug bundle identifiers are `io.github.czrzchao.go2codex.debug` and `io.github.czrzchao.go2codex.debug.launcher`.
- Both release entries display as `Go2Codex`; both Debug entries display as `Go2Codex Debug`.
- The Release outer wrapper and executable are `Go2Codex.app` and `Go2Codex`; the Debug outer wrapper and executable are `Go2CodexDebug.app` and `Go2CodexDebug`. Distinct bundle identifiers without distinct wrapper names are insufficient because Launch Services name lookup may select a same-named Debug wrapper.
- Debug and Release preference domains and outer TCC responsible identities remain separate. Their name-based Launch Services lookup is additionally isolated by the configuration-specific wrapper names. The frozen pre-SOP Personal baseline is ad-hoc signed; the strict local SOP performs one explicit migration to Apple Development and requires that stable identity for subsequent Personal builds. Public distribution later uses Developer ID Application.
- Apple Event sending code exists only in the Launcher. For an invocation from the nested Launcher, macOS attributes the TCC responsible identity to the outer Go2Codex application, so both outer and nested bundles declare the Apple Events entitlement and localized `NSAppleEventsUsageDescription`. An ordinary Settings launch sends no Apple Events. Neither entry requests Accessibility, Full Disk Access, Screen Recording, Notifications, or App Sandbox exceptions.
- Release diagnostics omit complete Workspace paths and generated commands. Debug may include them in Unified Logging only.
- English is the base and fallback localization. Simplified Chinese is the only additional localization.

## 4. Engineering architecture

### 4.1 Xcode targets

```text
Go2Codex.xcodeproj
├── Go2Codex                 SwiftUI-first Settings App
├── Go2CodexLauncher         embedded AppKit-first LSUIElement App
├── Go2CodexCore             pure Swift static library
└── Go2CodexTests            unit and adapter-contract tests
```

`Go2CodexCore` is a static library, not a dynamic framework. It has no resources and imports no AppKit. Static linking avoids copying and signing another dynamic framework inside both application bundles.

The Settings target owns SwiftUI views, its thin AppKit lifecycle adapter, Finder preference I/O, Finder process control, and Security.framework integration. The Launcher target owns its AppKit lifecycle, Apple Events, Launch Services calls, Target Picker, and terminal integration. Deterministic models, planning, encoding, state transitions, redaction, and transaction decisions live in Core behind injected protocols.

The outer target depends on the Launcher target and uses an Xcode Copy Files phase with the Wrapper destination and `Contents/Applications` subpath. Code Sign On Copy is enabled. The Launcher never depends on the outer target.

### 4.2 Proposed repository layout

```text
Config/
  Base.xcconfig
  Debug.xcconfig
  Release.xcconfig
Sources/
  Go2CodexCore/
    Domain/
    Preferences/
    Handoff/
    FinderToolbar/
    Diagnostics/
  Go2CodexApp/
    App/
    Settings/
    FinderToolbarPlatform/
    Resources/
  Go2CodexLauncher/
    App/
    FinderAutomation/
    TargetPicker/
    HandoffPlatform/
    Resources/
Tests/
  Go2CodexTests/
    Fixtures/
Scripts/
  lib/
    safety.sh
    overlay-transaction.sh
  test-sop.sh
  test.sh
  install-debug.sh
  smoke-debug.sh
  build-personal.sh
  install-personal.sh
  rollback-personal.sh
  verify-app.sh
docs/
prototypes/
```

The prototypes remain evidence. Production targets do not import them. After production Core is stable, the read-only Dry Run may be changed to consume the same planner so two independent implementations cannot drift.

### 4.3 Build configuration

Common settings:

- `MACOSX_DEPLOYMENT_TARGET = 14.0`
- `SUPPORTED_PLATFORMS = macosx`
- `ARCHS = arm64`
- Swift 6 language mode with complete concurrency checking
- `ENABLE_APP_SANDBOX = NO`
- `ENABLE_HARDENED_RUNTIME = YES`
- explicit, committed Info.plists, entitlements, asset catalogs, and localization resources
- no third-party package dependencies for the Personal MVP

The Launcher alone contains `LSUIElement = true`. Both the outer Settings App and nested Launcher contain the Apple Events entitlement and localized `NSAppleEventsUsageDescription`, because macOS uses the outer bundle as the TCC responsible identity for the nested invocation. The Settings target remains an ordinary Dock application, and its ordinary lifecycle contains no Apple Event sending path.

Debug and Release values are defined in xcconfig files rather than edited per developer. Debug assigns a unique outer product, executable, and bundle name so every future build produces `Go2CodexDebug.app`; Release alone produces `Go2Codex.app`. The project must not commit a personal development team, certificate identifier, absolute path, `xcuserdata`, DerivedData, or archive.

### 4.4 Shared preferences

Both targets use the same configuration-specific preference domain supplied through a committed Info.plist build setting. When that domain is the running process's own bundle identifier, the Settings App and its Finder receipt use `UserDefaults.standard`; the separately identified Launcher opens the outer application's exact named suite to read the same envelope. No App Group is required because the application is not sandboxed.

A live installed-build regression exposed Foundation rejecting the Settings App's own bundle identifier when it was passed to `UserDefaults(suiteName:)`, which incorrectly sent the UI to preference recovery. The production resolver now distinguishes own-domain standard access from cross-process named-suite access, and regression tests cover the Settings store, stable failure diagnostics, and Finder receipt read/write. The user confirmed that the corrected installed build presents the normal First Run page.

Preferences are stored as one versioned `PreferencesEnvelope`, rather than unrelated keys. A single envelope contains:

- schema version;
- First Run completion state;
- Default Target;
- Alternate Trigger;
- Default Terminal Host;
- Session Placement.

First Run writes one complete envelope. Later Settings edits replace the complete envelope immediately. Unknown schema versions, corrupt data, or missing required fields fail safely to an explicit recovery state rather than inventing defaults that could trigger a Handoff.

While Settings remains in recovery, application activation performs a read-only retry against the same preference store. Only a newly readable, complete configured envelope restores editing automatically. The recovery page also offers an explicit destructive Reset Settings action with confirmation; it removes the unreadable envelope and returns to First Run only after readback confirms the key is absent. A failed reset reconciles the UI with the store's actual First Run, configured, or recovery state instead of leaving a deleted envelope behind a stale recovery screen.

The schema remains version 1 after removing Option-click as a selectable trigger. A legacy schema-v1 `option-click` value is decoded as `shift-click`; Settings rewrites the complete envelope in canonical form, while the Launcher treats the decoded value as Shift without writing across process domains.

### 4.5 Core boundaries

Core defines stable values such as `AgentTarget`, `TerminalHost`, `SessionPlacement`, `AlternateTrigger`, `Workspace`, `TargetAvailability`, `LaunchRequest`, `ToolbarInstallationStatus`, `ToolbarProfile`, `ToolbarSnapshot`, `ToolbarMutationPlan`, `ToolbarTransaction`, and sanitized diagnostic records.

Platform work is injected behind narrow protocols, including:

- preference envelope storage;
- Finder Workspace resolution;
- target availability lookup;
- desktop and terminal Handoff;
- Finder disk/live preference access;
- Finder restart observation;
- Launcher identity validation;
- Finder alias resolution;
- transaction journal storage;
- operation locking, clock, and retry scheduling.

Tests use fakes for all of these boundaries. Unit and CI tests never modify real Finder preferences, restart Finder, send Apple Events, or write TCC state.

## 5. Execution rules

- Implement one milestone at a time and keep each change reviewable.
- Every milestone begins with failing tests or an explicit manual checklist for its new boundary and ends only after its exit gate passes.
- Pure logic is tested before connecting platform adapters.
- A real Finder preference mutation is never used to discover an algorithm that can first be proven against fixtures.
- Any controlled real install, repair, uninstall, TCC reset, Finder restart, `/Applications` copy, signing identity use, notarization, or GitHub publication requires the authority appropriate to that action at execution time.
- A prototype result may establish a fact or fixture but cannot waive a production test.
- Build scripts wrap `xcodebuild` and verify its product. They do not hand-assemble an application bundle.

## 6. Milestones

### M0 — Development environment and repository baseline — complete

Work:

1. Install Xcode 16.2 from Apple, run first-launch setup, accept the license, and select its developer directory.
2. Verify the Xcode, Swift, macOS SDK, and command-line build versions.
3. Initialize a local Git repository with the existing context, ADRs, spikes, artifacts, and prototypes intact.
4. Expand `.gitignore` for DerivedData, `.build`, archives, distributions, `xcuserdata`, local transaction journals, machine-specific Finder captures, and signing material.
5. Keep GitHub publication deferred; repair `gh` authentication only when a remote is about to be created.

Exit gate:

- `xcodebuild -version` succeeds from the selected full Xcode.
- The selected SDK can build an arm64 macOS 14 target.
- `git status` contains only intentional project files and no machine-specific evidence.
- The Dry Run rebuilds with the selected toolchain and all eight self-tests pass before production migration begins. The previously built validation binary still passes all eight tests, but it does not replace this clean rebuild gate.

### M1 — Native project and dual-entry bundle skeleton — complete

Work:

1. Create the four committed targets and shared schemes.
2. Add Base, Debug, and Release xcconfig files.
3. Implement the minimal SwiftUI Settings entry and thin lifecycle adapter.
4. Implement the minimal AppKit Launcher entry that sets accessory activation, proves it started in Debug, and exits.
5. Embed the Launcher through the target dependency and Copy Files phase.
6. Add explicit Info.plists, entitlements, English/zh-Hans resource roots, and the temporary `>_` asset.
7. Add a bundle-verification script.

Exit gate:

- `xcodebuild build` and `xcodebuild test` succeed from a clean DerivedData directory.
- The built product contains `Contents/Applications/Go2CodexLauncher.app`.
- Both executables are arm64-only and have a macOS 14 deployment target.
- Release and Debug bundle identifiers, display names, outer wrapper names, `CFBundleName` values, and executable names match the approved matrix.
- The Settings App has a Dock presence; the Launcher has none.
- Inner-then-outer strict code-signature verification passes.
- Debug and Release builds can coexist, and name-based `Go2Codex` lookup cannot resolve to a Debug outer wrapper.

This milestone replaces the hand-built Toolbar Launcher Probe as the active bundle implementation. The probe remains committed as historical evidence.

### M2 — Platform-contract spikes

These bounded spikes close technical contracts before UI and Handoff code depend on them. Each produces a short document and a deterministic fixture or test where possible.

#### M2.1 Desktop deep-link contracts

- Determine the exact Codex App and Claude Desktop Code URL schemes, query keys, path encoding, and fresh-session behavior from official documentation and the installed application declarations.
- Verify Launch Services handler lookup without assuming an app name or path.
- Verify that accepted handoff and target-owned confirmation can be distinguished from a pre-handoff failure.

#### M2.2 Modifier capture and picker placement

- Launch the real embedded Debug Launcher from Finder and determine how long Shift must remain held for the startup snapshot to observe it.
- Record the platform boundary: Finder/Launch Services `oapp` and `rapp` do not expose a documented modifier value bound to the originating toolbar click, while `NSEvent.modifierFlags` is only the current state at sampling time.
- Record Finder's reserved Option-click behavior: the source viewer window may close before Workspace resolution, so Option is not a picker trigger. Reject an Option or Option+Shift flag before querying Finder whenever the startup snapshot still observes it; do not claim detection after rapid release.
- Define Shift matching as containment of the observed Shift flag while ignoring unrelated Caps Lock and Function flags, except that an observed Option+Shift takes the fail-closed branch.
- Verify picker-panel placement at the invocation pointer location and graceful fallback when Finder does not expose toolbar bounds.
- Before opening the picker, conditionally wait up to one second for all physical mouse buttons to be released, then present one compact borderless `.nonactivatingPanel` using `orderFrontRegardless()` and `NSApp.runModal(for:)`; do not activate Go2Codex, require `NSApp.isActive`, or infer cancellation from focus loss. Install a global mouse-down monitor only for the visible panel lifetime so outside clicks cancel, remove it immediately on every completion path, and verify that selection and Escape are one-shot and repeated-click gating holds.

#### M2.3 Finder Workspace Apple Event

- Prove the Apple Event contract for the frontmost Finder window's displayed file URL across windows, tabs, selected items, no window, virtual views, external volumes, and permission denial.
- Choose the smallest native adapter that preserves the scoped Apple Events boundary and is testable behind a protocol.

#### M2.4 Terminal contracts and CLI availability

- Prove Terminal.app and iTerm2 behaviors for new tab, new window, and no-existing-window cases.
- For iTerm2, prove that the exact version-file open-documents event is supplied to the exact Launch Services application URL before either placement path, and that preflight failure produces no query or command submission.
- Confirm safe POSIX quoting for the Workspace and fixed command submission.
- Compare an optional login-shell `command -v` probe with the actual interactive terminal environment. Use it only if it avoids false unavailable results; otherwise treat an installed Terminal Host as available and let a missing CLI surface in the terminal after Handoff.

#### M2.5 Alias resolution

- Convert Finder's captured `_CFURLAliasData` to a resolved file URL using supported CoreFoundation/Foundation facilities.
- Require the resolved alias, `_CFURLString`, and expected signed Launcher URL to agree.
- Record damaged, empty, unresolvable, and conflicting alias fixtures.

Exit gate:

- No downstream implementation relies on an assumed URL format, picker coordinate, terminal behavior, or alias interpretation.
- Modifier timing is an explicit unresolved exception: `oapp`/`rapp` provides no click-bound modifier payload, startup sampling cannot classify rapid release, and the hold-Shift operating constraint does not close the M2.2 safety gate.
- Every other unsupported or unstable result has an explicit fail-closed behavior; the unresolved modifier gap is not reported as an exit-gate pass.
- The spikes do not change the approved product behavior; they only choose platform adapters.

### M3 — Core domain, preferences, and diagnostics

Work:

1. Implement the versioned domain values and fixed target catalog.
2. Implement a single-envelope shared preference store and First Run state transitions.
3. Implement pure desktop URL construction, terminal command construction, POSIX quoting, and availability classification from the M2 contracts.
4. Implement Debug/Release diagnostic policies and error redaction.
5. Define platform protocols and typed errors.
6. Move only the verified Finder constants and general mutation primitives from the Dry Run into typed production models.

Exit gate:

- First Run required values commit together, with no half-complete state.
- Debug and Release suites are isolated.
- Corrupt, incomplete, and future-version envelopes have deterministic safe outcomes.
- The target order is fixed and no availability result creates a fallback.
- CLI command construction cannot inject through a Workspace path and sends no target arguments.
- Release diagnostic records cannot contain the complete Workspace path or generated command.
- Core's link and import graph contains no AppKit and no direct platform side effects.
- Swift Testing covers every enum case, state transition, encoding rule, and redaction branch.

### M4 — Settings and First Run

Work:

1. Build the single-page SwiftUI form with General, CLI, and Finder Toolbar sections.
2. Require explicit Default Target and Terminal Host selections during First Run.
3. Implement the single completion action as preference commit followed by an injected Install action whose toolbar service either presents the automatic-install confirmation or explicitly confirms the manual fallback.
4. Implement immediate saving for later changes.
5. Implement normal launch, repeated activation, window raising, and quit-on-window-close behavior without resolving a Finder Workspace or sending Finder Apple Events; read-only toolbar status refresh remains allowed.
6. Connect a fake/read-only toolbar status provider until M7.
7. Complete English and Simplified Chinese strings, accessibility labels, keyboard traversal, and fallback behavior.

Exit gate:

- All ordinary launch sources only open or raise Settings.
- Closing incomplete First Run leaves it incomplete.
- Cancelling the installation confirmation after completion keeps Settings configured and Not Installed.
- Later edits persist immediately.
- Settings never requests Finder or terminal Automation permission.
- All required strings exist in both supported localizations; another system locale falls back to English.
- Successful fake installation keeps the window open and does not invoke a target.

### M5 — Toolbar Launcher, Workspace, and Target Picker

Work:

1. Sample the current modifier state at the proven lifecycle point without treating it as a click-bound event payload.
2. Read a fresh preference envelope; open Settings and exit when it is incomplete or invalid.
3. Reject an Option flag before any Finder Workspace query when the startup snapshot still observes it.
4. Resolve and validate the Finder Workspace through the M2 adapter.
5. Implement Quick Launch routing and the native Target Picker with a bounded physical mouse-release gate followed by one compact borderless nonactivating panel presented through `orderFrontRegardless()` and `runModal`, without application activation or focus-loss cancellation. Scope a global mouse-down monitor to the visible panel lifetime for outside-click cancellation, and make selection, Escape, and cancellation one-shot.
6. Enforce the one-active-invocation gate.
7. Exit cleanly on handoff completion, cancellation, or failure.

Exit gate:

- Ordinary click routes to Default Target; configured Shift opens the picker; Disabled never does.
- An Option or Option+Shift flag observed in the startup snapshot fails with `finder-option-modifier-unsupported` before the Finder adapter is called and never retries or substitutes another Finder window.
- Real Shift-click must keep the picker visible and interactive when Shift is held until it is stably shown; rapid modifier release is not claimed to be strictly attributable to the original click.
- Picker order, marking, disabled state, one-shot selection, and silent cancellation match the product invariants.
- Finder selection does not alter Workspace.
- No-window, virtual location, inaccessible directory, and unmounted-volume cases do not fall back.
- Settings can remain open while the Launcher runs independently.
- Launcher shows neither Dock icon nor status item and leaves no resident process.
- Repeated clicks do not create duplicate handoffs.

### M6 — Four Handoffs, permissions, and Launch Failures

Work:

1. Implement Codex App and Claude Desktop Code handoffs through their validated URL contracts.
2. Implement Terminal.app and iTerm2 adapters for both placement modes.
3. Implement target and Terminal Host availability without guessing application locations.
4. Implement Finder and terminal permission-denied errors, the best available Privacy & Security navigation, and a textual fallback when a system-settings deep link is unavailable.
5. Implement native error dialogs, copyable sanitized diagnostics, and categorized Unified Logging.

Exit gate:

- Both desktop targets receive the exact Workspace through a registered handler.
- Both CLI targets enter the Workspace and submit only their fixed command.
- Terminal.app and iTerm2 pass new-tab, new-window, and no-window tests; a fully quit iTerm2 produces one command-bearing window and no default blank window.
- A Default Target that is unavailable fails without fallback.
- Known unavailable picker entries remain visible and disabled.
- Permission denial does not create a request loop or broaden permissions.
- Success is silent and the Launcher stops observing after Handoff.
- Release logs and copied diagnostics contain no complete Workspace path or generated command.

### M7 — Read-only Finder status, Launcher identity, and manual setup

Work:

1. Replace the prototype's `[String: Any]` planning domain with typed snapshots at the Core boundary while keeping raw property-list values inside the adapter.
2. Implement an exact environment and before-shape profile registry. The first automatic profile accepts only the reversibly tested 23G80/Finder 14.6/1632.6.3 scalar shape, not every configuration on that build.
3. Implement Detect for Installed, Not Installed, Needs Repair, and Manual Setup Required.
4. Implement Security.framework and Mach-O checks for nested containment, symlink/path traversal, bundle identifier, `LSUIElement`, arm64-only executable, outer/inner static-code validity, and the expected signing relationship.
5. Implement alias validation from M2.5.
6. Implement a versioned installation receipt recording the last successfully verified Launcher URL and identity. A missing stale path becomes Needs Repair only when the unique toolbar entry matches that receipt; otherwise it is ambiguous and fails closed.
7. Implement reveal-in-Finder for the embedded Launcher and localized Command-drag instructions.

Exit gate:

- The exact validated environment and input shape are eligible for an install plan; every mismatch performs zero writes and reports Manual Setup Required.
- A valid unique current URL/type/alias/identity is Installed.
- A unique receipt-backed stale URL is Needs Repair.
- A generic orphan identifier, duplicate, wrong type, invalid index, conflicting alias, invalid signature, wrong architecture, symlink escape, or unknown schema never becomes Installed or Needs Repair.
- Release automatic installation is unavailable outside `/Applications` or `~/Applications`; Debug retains its documented development exemption.
- Manual Setup reveals the nested Launcher, not the outer Settings App.
- Status text claims only verified stored configuration, not a successful visual click.

### M8 — Production Finder transaction

M8 is the highest-risk Personal MVP gate. The one-off experimental write binary is not production code and must not be copied.

#### M8.1 Pure mutation plans

Implement typed pure functions for Detect, Install, Repair, and Uninstall:

- profile-specific schema classification;
- exact ownership matching by current URL or validated receipt;
- insert/remove index remapping for every unrelated `TB Item Plists` entry;
- install idempotence;
- repair at the current position;
- surgical uninstall from the current snapshot;
- accepted Finder normalizations defined by the selected profile.

The rejected Go2Shell-derived index-8 candidate remains a negative fixture. The scalar original and Finder-normalized V1 representation become fixtures, not writable defaults.

#### M8.2 Durable write-ahead transaction

A Go2Codex operation lock serializes only Go2Codex processes; it does not make Finder's whole-value `CFPreferences` write an operating-system compare-and-swap. Before automatic writes are enabled, this milestone must demonstrate and document a serialization boundary that prevents Finder or another writer from being silently overwritten between the final read and mutation. A pre-write equality check alone is only an optimistic stale-plan check. If a safe Finder/cfprefsd mutation window cannot be established on the validated environment, the automatic-install gate does not pass and the product remains on Manual Setup rather than claiming concurrent-change safety.

Before mutation, atomically persist a journal containing:

- journal schema and operation UUID;
- operation type and profile identity;
- exact macOS/Finder environment;
- verified Launcher identity and receipt relationship;
- exact before snapshot and hash;
- exact expected staged result and hash;
- profile semantic verifier identity;
- current transaction state.

Journal replacement must use a temporary file, file synchronization, atomic replacement, and parent-directory synchronization. It lives in Application Support as recovery state, not as a user log.

The transaction then:

1. takes a cross-process operation lock;
2. requires disk/live preference convergence;
3. derives the operation plan;
4. writes and durably verifies the journal;
5. establishes the proven Finder/cfprefsd serialization boundary, re-reads disk/live, and rejects a stale plan before mutation;
6. writes the smallest preference change and synchronizes it;
7. records restart intent and restarts Finder;
8. proves the Finder process changed;
9. requires repeated disk/live semantic convergence from the new Finder;
10. updates the receipt and records a terminal journal state only after success.

On next launch, recovery classifies the journal, disk value, and live value. Known before, exact expected, and accepted enriched values have explicit resume/verify actions. Any unknown, divergent, corrupt, mismatched-profile, or mismatched-identity combination performs no guessed cleanup and falls back to a recoverable error or Manual Setup Required.

#### M8.3 Controlled integration validation

After all fixture, fault-injection, and fake-store tests pass, perform separately confirmed real tests on the validated development environment:

1. install from the exact scalar state;
2. verify restart, three consecutive disk/live semantic matches, visible button, and click;
3. move the item and prove detection still finds its new index;
4. simulate a receipt-backed stale path and prove Repair changes only the URL in place;
5. make an unrelated toolbar change and prove surgical Uninstall preserves it;
6. verify the final state contains no Go2Codex item and retains every unrelated change.

Exit gate:

- Cancel creates no journal, changes no preference, and does not restart Finder.
- Install, Repair, and Uninstall are idempotent and preserve unrelated identity/order.
- Every journal/write/sync/restart/verification boundary has a fault-injection test with one deterministic recovery decision.
- Plan-after-read changes are rejected before mutation, and the separately proven serialization boundary prevents a blind whole-value overwrite during mutation.
- Disk/live lag, restart failure, PID non-change, timeout, and unknown Finder normalization never report success.
- Alias and signature validation remain mandatory after Finder enrichment.
- The controlled surgical real test passes; exact experimental snapshot restoration is not used as ordinary Uninstall.
- Success returns to the still-open Settings window and never launches a target.

### M9 — Personal MVP hardening and local package

Work:

1. Finish all localized copy, permission explanations, diagnostics, and settings status transitions.
2. Set marketing and build versions.
3. Enforce the complete script set in the [local development SOP](local-development-sop.md): gate tests, stable Debug installation and smoke receipts, candidate-only Release builds, explicit promotion, verified backup, and rollback.
4. Build a Release-configured, hardened-runtime product with Apple Development for Personal use. Treat the currently installed ad-hoc build only as the legacy input to one explicit migration.
5. Generate the fixed hidden candidate first, then use the explicit installation script to back up and overlay it at `~/Applications/Go2Codex.app` while preserving the outer and nested Launcher directory identities. Never copy an Xcode product directly into Applications.
6. Run the complete manual acceptance matrix and record results without machine-specific paths.

Exit gate:

- Clean build and all automated tests pass.
- Outer and nested products are arm64-only, correctly embedded, strictly signed from inside out, and contain only their intended entitlements.
- No runtime network API, analytics, updater, crash uploader, or standalone log file is present.
- First Run, installation cancellation/failure/success, all four target routes, both Terminal Hosts, both placement modes, permission allow/deny, Repair, Uninstall, and manual fallback pass.
- Debug and Release coexist with independent preferences and distinct outer TCC responsible identities; post-migration Personal updates preserve the Apple Development team and designated requirements.
- English, Simplified Chinese, and English fallback pass.
- Release diagnostics contain no sensitive path or full command.
- Known limitation is explicit: automatic Finder mutation is disabled for every profile. The exact validated fixture remains dormant planner evidence, while the Personal MVP remains usable through manual Command-drag installation and removal.

### M10 — Public GitHub release

This milestone begins only after the Personal MVP is used successfully and the user explicitly chooses to publish it.

Work:

1. Remove any remaining personal paths or machine-specific artifacts and write public README, privacy, support-matrix, install, uninstall, and troubleshooting documentation.
2. Repair GitHub CLI authentication, create the `CzRzChao` repository, and push reviewed history.
3. Configure a stable Developer ID Application identity and release entitlements.
4. Archive with Xcode, preserving its inner-to-outer signing order. Do not use `codesign --deep` to repair signing.
5. Submit with `notarytool`, staple the accepted ticket, validate it, and create the zip only afterward.
6. Verify strict signature, Gatekeeper assessment, designated requirements, entitlements, architecture, and hashes.
7. Test the notarized download in a clean macOS user account or another Apple Silicon Mac.
8. Create a GitHub tag and Release with the notarized zip and SHA-256.

The frozen pre-SOP Personal baseline is ad-hoc signed. Local promotion first migrates it to a stable Apple Development identity and then preserves that identity for subsequent Personal updates. Public Release replaces the local-development identity with Developer ID Application and notarization.

Exit gate:

- Developer ID signing, notarization, stapling, Gatekeeper, and clean-user launch pass.
- The published support matrix distinguishes macOS app support from Finder toolbar setup mode and documents that automatic Finder mutation is currently unavailable.
- Every newly supported macOS/Finder build has its own read-only investigation, reversible install, alias check, visible/click check, surgical Repair/Uninstall validation, and fixtures.
- Homebrew Cask remains optional and separate. Sparkle or another network updater is not added without a new product decision.

## 7. Verification strategy

### 7.1 Automated tests

Use Swift Testing for pure Core behavior and XCTest only where an AppKit lifecycle or Xcode-hosted integration requires it. No third-party property-testing dependency is needed; deterministic generated layouts can exercise mutation invariants.

The current Unit suite passes all 249 top-level tests and all 287 expanded device/configuration cases with zero failures or skips. This includes production Finder Workspace resolver/resource-inspector cases, production Finder Toolbar identity/signing inspector cases, platform-context and read-only status-service cases, Launcher runtime glue, the virtual Finder view classification that now produces a user-facing non-folder result instead of a malformed-reply diagnostic, Terminal.app warm/cold/process-exit-race Handoff regressions, and deterministic iTerm2 preflight tests for the exact `aevt/odoc` sentinel event, exact resolved application URL, one successful downstream handler, and zero query/handler work after preflight failure. Preference, modifier, readiness, picker, terminal, and lifecycle regressions remain covered. The separate rebuild gate still proves that the unchanged compiled handlers open the same sentinel before their first target operation. Neither boundary executes a real iTerm2 cold start, so neither is Installed Debug evidence. App identity tests assemble isolated temporary outer and nested fixtures from the test Mach-O and ad-hoc sign those fixtures; the Unit scheme does not build, register, install, or launch a Debug or Release App. These tests do not send a real Finder or terminal Apple Event, modify Finder, present UI, or exercise TCC.

Minimum automated coverage:

| Area | Required cases |
|---|---|
| Preferences | first-run atomic commit, immediate later save, Debug/Release isolation, own-domain standard versus cross-process named-suite access, schema-v1 `option-click` migration and canonical rewrite/rollback, corrupt/missing/future schemas |
| Target catalog | fixed order, default marking, disabled-known-unavailable behavior, no fallback |
| Encoding | desktop URL path encoding, shell quoting, fixed CLI commands, diagnostics redaction |
| Terminal handoff | Terminal warm direct submission; cold New Window/New Tab through one initial event at the exact application URL; front-window-query and direct-command `-600` fallback exactly once; async workflow completion; permission/generic open errors; iTerm2 preflight through one exact `aevt/odoc` sentinel event at the resolved app URL before both placements, no query or handler after preflight failure, exact subroutine event and text argument, compiled-resource loading, fixed handler selection, explicit-success contract, and every no-retry/no-cross-host-fallback error path |
| Workspace | 23 production-platform cases covering the exact Finder request, raw status mapping including `-1728` as `finder-object-unavailable`, valid/malformed/unsupported replies, URL normalization, and directory/file/missing resource inspection; real Finder UI/TCC outcomes remain manual |
| Launcher runtime | AppKit modifier sampling and translation, observed-Option rejection before Finder resolution, bounded physical mouse release before one compact borderless nonactivating panel, mouse-release timeout and cancellation fail-closed behavior, panel placement, fixed target wiring, one-shot selection/Escape/outside-click cancellation and monitor cleanup, fresh preference-domain reads, exact desktop/terminal availability lookup, and initial/reopen delegate submission; no automated case claims click-bound modifier delivery |
| Toolbar profile | exact environment and exact before shape; every build/version/shape mismatch |
| Detection | valid current URL/type/alias, receipt-backed stale URL, generic orphan, duplicate, wrong type, invalid indexes, alias conflict |
| Mutation | first/middle/last insertion/removal, arbitrary current index, multiple unrelated custom apps, index remapping, idempotence |
| Identity and context | production-inspector identity/signing cases using isolated temporary outer/Launcher fixtures assembled from the test Mach-O, plus injected production environment/snapshot/receipt assembly, fail-closed boundary, read-only status mapping, and exact verified-receipt tests; pure policy tests retain the remaining architecture and signing-relationship negatives |
| Journal | corrupt/missing/future schema, wrong profile/identity, durable-before-write ordering |
| Fault injection | every boundary before/after journal, preference write, sync, restart request, new PID, semantic verification, terminal state |
| Recovery matrix | disk/live as before, expected, accepted enrichment, divergent, or unknown, with an exhaustive explicit decision |
| Concurrency | process lock, plan/write compare-and-swap failure, unrelated concurrent toolbar change |
| Local release SOP | atomic stale-lock competition, explicit INT/TERM failure propagation, smoke pass-plus-pending rejection, unfinished Release-state gates, install/rollback transaction ownership, wrong-owner recover/commit rejection with unchanged target and preserved evidence, owner-only abandoned-preparation cleanup with an unchanged target, atomic owner-specific cleanup tombstones with interrupted-deletion resumption, payload tamper detection, fault-injected recovery, hard-link-safe output replacement, and exact candidate outer/Launcher Launch Services cleanup |
| UI state | First Run close/complete/cancel, toolbar status transitions, confirmation cancellation, localization presence |

### 7.2 Bundle verification

`Scripts/verify-app.sh` checks, without changing the product:

- expected nested path;
- configuration-specific outer wrapper and executable names, plus Info.plist identifiers, bundle names, minimum OS, `LSUIElement`, preference domain, and usage descriptions;
- arm64-only Mach-O files;
- intended entitlements for each entry;
- inner and outer strict code signatures;
- absence of unexpected dynamic frameworks and third-party dependencies;
- English and `zh-Hans` resources;
- a loadable compiled `ITermHandoff.scpt` packaged only in the nested Launcher for the current-content contract.
- for Release, absence of personal or machine-specific build paths across every packaged file, including user-home, temporary-directory, DerivedData, and `.build` paths.

The strict current-content verifier applies to newly built Debug and Release candidates. The frozen installed `0.1.0 (1)` baseline predates two localization keys plus the current Terminal.app and iTerm2 cold-start repairs and is therefore checked only by the backward-compatible historical contract plus its recorded tree, identity, signature, version, and privacy invariants during migration or rollback; it must not be described as identical to the current source product. Bundle evidence alone does not complete any visible launch, Finder, terminal, target, or TCC gate.

`codesign --deep` may be used for verification, never for signing or repair.

### 7.3 Manual application matrix

Before Personal MVP completion, test:

- all ordinary Settings launch sources and repeated activation;
- Settings open while the Launcher performs Handoff;
- Finder windows, tabs, selections, no window, external volume, non-Git folder, and inaccessible location;
- ordinary click; Shift held until the picker is stable; Disabled; Escape; click outside; rapid repeated click; and the observed-startup-Option fail-closed path, without using Option as a supported gesture;
- four targets, each unavailable case, and absence of fallback;
- Terminal.app and iTerm2 with new tab/new window and with/without an existing window, including fully quit iTerm2 before each cold case and confirmation that no default blank window or tab appears;
- first permission allow, denial, later settings recovery, without permission loops;
- First Run install success, confirmation cancellation, unsupported profile, and safe failure;
- `/Applications`, `~/Applications`, and unsupported release locations;
- moved/rebuilt application producing receipt-backed Needs Repair or fail-closed Manual Setup;
- Debug/Release coexistence and independent TCC state;
- English, Simplified Chinese, and another locale's English fallback;
- absence of network traffic, standalone log files, and sensitive Release diagnostics.

Real Finder mutations remain a separate, explicitly confirmed checklist and never run as part of the ordinary automated suite.

## 8. Development and debugging workflow

The authoritative operating procedure is [Local Development, On-device Validation, and Release SOP](local-development-sop.md). It divides every change into four fail-closed lanes: isolated Unit work, separately signed Installed Debug validation, a non-installing Release Candidate, and an explicitly confirmed Promote or Rollback.

Raw `xcodebuild`, Xcode Run, Finder copying, ad-hoc signing, TCC reset, and Launch Services changes are not substitutes for that procedure. Automated tests never mutate the installed Personal Release, and visible Finder, TCC, terminal, and target behavior is recorded only through the Installed Debug smoke gate before a clean-HEAD candidate can be produced.

A smoke pass is authoritative only when its pending and staging files are absent. Any unfinished Release transaction, operation-specific preparation or cleanup tombstone, install/rollback pending record, or staging receipt blocks Installed Debug, Debug smoke, and candidate work while still allowing isolated Unit diagnosis. The shared Release transaction records `release-install` or `release-rollback`; cleanup and recovery require that exact owner, and a wrong-owner or unknown state is preserved without changing the installed target. Completion first atomically renames the active transaction to an owner-specific cleanup tombstone; the owner reconciles pending state and the installed tree before safely deleting it.

## 9. Risk register

| Risk | Containment and release gate |
|---|---|
| Finder private schema changes | exact build/profile and before-shape match; manual fallback everywhere else |
| Finder reserves toolbar Option-click and may close the source viewer | Shift is the only enabled Alternate Trigger and must be held until the picker is stable; Option is unsupported and must not be used; an Option flag still present in the startup snapshot fails before any Finder query, with no retry or fallback |
| Finder/Launch Services do not bind `oapp`/`rapp` to the click's modifiers | `NSEvent.modifierFlags` is only a startup-time sample; rapid release cannot be classified strictly, no global key or modifier monitor or Accessibility permission is added, and the modifier safety gate remains open. The picker panel's temporary mouse-down-only outside-click monitor does not change this capture boundary |
| Prototype transaction crash window | new durable write-ahead journal plus exhaustive fault injection |
| Historical snapshot overwrites user changes | current-derived surgical Repair/Uninstall, stale-plan rejection, and the proven mutation boundary |
| Finder preferences lack a public atomic conditional write | M8 must prove a Finder/cfprefsd serialization boundary; otherwise automatic write remains disabled |
| Generic custom identifier misidentifies another app | unique URL/type/alias plus signed identity or validated receipt |
| Finder alias points elsewhere | mandatory alias resolution and agreement with signed Launcher |
| Nested app is moved or tampered with | location, containment, Mach-O, Info.plist, static-code, and signing checks |
| TCC responsibility and rebuild continuity | Apple Event code remains Launcher-only, both bundles declare the required capability and usage text, consent is attributed to the outer responsible identity, the legacy ad-hoc baseline has one explicit migration, subsequent Personal updates preserve Apple Development designated requirements, and Public Release uses Developer ID |
| Same-named Debug wrapper shadows Personal Release | Debug produces `Go2CodexDebug.app` and the verifier rejects any configuration-specific wrapper or executable mismatch; local backups use a non-`.app` suffix and stale same-named registrations are removed before ordinary-launch validation |
| Terminal shell differs from probe shell | contract spike; conservative availability; fixed command submitted to the user's terminal shell |
| Terminal exits around Handoff | exact Launch Services URL; one command-bearing initial Apple Event on cold start or `-600` race; no polling, empty-window prelaunch, duplicate submission, or iTerm2 fallback; stable Installed Debug smoke required before promotion |
| iTerm2 creates its default window before a later handler command | every placement first sends the exact version-file `aevt/odoc` as the `NSWorkspace` open request's initial Apple Event and waits for successful completion; the preflight carries no command and failure stops all downstream work; the handler-level sentinel is not treated as an ordering guarantee; repeated Installed Debug cold/warm smoke is required before promotion |
| iTerm2 returns a class value instead of the created object's identity | never coerce or guess a current session; one precompiled parameterized AppleScript handler keeps create and exact-session write inside the interpreter, omits the profile-replacing creation command, and fails without retry; repeated Installed Debug smoke is required before promotion |
| Desktop target changes its deep-link contract | validated contract isolated behind an adapter and targeted integration test |
| Short Launcher exits before debugging | wait-for-process attachment and categorized Unified Logging |
| First-time Xcode maintenance is opaque | native targets, committed xcconfig, small scripts, no hand-built bundle |
| Current host cannot run latest Xcode | pin Xcode 16.2 for Sonoma; tool upgrade is a separate future migration |
| GitHub credentials or signing are unavailable | GitHub credentials gate only M10 publication; missing Apple Development identity blocks Installed Debug, while missing clean Git baseline blocks authoritative smoke and therefore candidate generation and Personal promotion |
| A smoke pass is written immediately before the process is interrupted | pending or pass-staging evidence invalidates the pass; candidate and install lanes require all smoke staging paths to be absent and the same smoke command must complete reconciliation |
| Install and rollback share one Release transaction directory | every transaction state records one explicit operation owner; the wrong script cannot recover or commit it, conflicting pending evidence stops all mutation, and evidence remains for deterministic owner recovery |

## 10. Personal MVP definition of done

The Personal MVP is complete only when all of the following are true:

- M0 through M9 exit gates pass.
- The product can be rebuilt, tested, smoke-checked, promoted, and rolled back through the complete SOP script set without manual bundle assembly or Finder copying.
- Settings and Launcher behavior matches every entry-point invariant.
- All four target paths work or report their own unavailable state without fallback.
- The exact supported Finder environment passes crash-safe Install, receipt-backed Repair, and surgical Uninstall.
- Every unsupported Finder environment or shape performs zero private preference writes and offers manual setup.
- Debug and Release identities, preferences, permissions, diagnostics, and resources are verified.
- The app remains local-only and arm64-only.
- Known limitations and recovery instructions are documented.

The next executable steps are to review and create the first Git baseline commit, configure a valid Apple Development identity, increment `CURRENT_PROJECT_VERSION`, and then run the four SOP lanes in order. The current friendly virtual-view behavior and both Terminal.app and iTerm2 cold-start repairs must be verified through the stable Installed Debug lane before any Release candidate is promoted. M10 remains out of scope until the user chooses to publish.
