# Modifier capture and Target Picker contracts

Status: picker presentation was revised again on 2026-07-19 after the hard-foreground readiness build passed one real Shift check but the second failed with `target-picker-activation-timeout`, and the installed mouse-release-plus-best-effort-activation `NSMenu` repair still flashed. Its installed compact borderless nonactivating-panel replacement now passes real stable-display, Escape, outside-click, one-shot Codex App selection, and five-cycle sequential invocation checks; only the separate rapid-overlap invocation check remains pending. Modifier capture is not a closed contract because Finder/Launch Services do not bind `oapp` or `rapp` delivery to the originating click's modifiers.

## Result

The Toolbar Launcher captures one immutable startup snapshot at the start of `LauncherMain.main()`, before application activation:

- `NSEvent.modifierFlags`;
- `NSEvent.mouseLocation`.

It does not depend on `NSApp.currentEvent`: Finder consumes the original toolbar click and Launch Services starts or reopens the Launcher through `oapp` or `rapp`. Those events contain no documented modifier value bound to that click. `NSEvent.modifierFlags` therefore reports only the current global modifier state at the instant the Launcher samples it; a key released before startup cannot be attributed to the click. Go2Codex does not install a global key or modifier monitor, so it requires no Accessibility permission, but the click-bound modifier safety gate remains unresolved. The picker separately uses a temporary mouse-down-only global monitor to detect outside clicks while its panel is visible; it does not capture modifier state.

A real toolbar invocation established that Option-click is a Finder-owned system gesture which may close the invoking viewer window. If Go2Codex queried `brow[1]` afterward, a different background viewer could become frontmost and produce the wrong Workspace. Option is therefore unsupported and must not be used. If the startup snapshot still contains Option, including Option+Shift, the Launcher fails with `finder-option-modifier-unsupported` before any Finder query, picker, retry, fallback, or Handoff. This guard cannot claim to recognize Option released before the snapshot.

Observed Shift matching uses containment after intersecting with `NSEvent.ModifierFlags.deviceIndependentFlagsMask`. Caps Lock, Function, and unrelated flags do not prevent an observed Shift from matching, except that an observed Option+Shift takes the fail-closed branch. Disabled never matches. Settings offers only Shift-click and Disabled, with Shift-click as the default; a legacy schema-v1 `option-click` value migrates to `shift-click` without changing the schema version. The Personal MVP operating constraint is to hold Shift until the picker is stably visible; rapid release is not guaranteed to select the Shift branch.

The Target Picker is a compact borderless `NSPanel` using the `.nonactivatingPanel` style. The captured point is a screen coordinate used to position its fixed-size frame near the invocation point. A point outside every screen is clamped to the nearest visible frame; the panel prefers the space below the point, uses the space above when needed, and remains within the chosen screen. Absence of a usable screen is a typed presentation failure. Finder toolbar bounds are not queried because Finder exposes no public toolbar-item geometry API.

The panel contains the four fixed targets in product order. The Default Target is marked without moving it, and known unavailable targets remain visible and disabled. Quick Launch does not activate Go2Codex UI. The picker uses a `ContinuousClock` gate that checks every ten milliseconds for at most one second until all physical mouse buttons are released, calls `orderFrontRegardless()`, and maintains the synchronous picker lifetime with `NSApp.runModal(for:)`. It does not call `NSApp.activate()`, inspect `NSApp.isActive`, or treat focus loss as cancellation. While the panel is visible, a temporary global mouse-down monitor turns clicks delivered outside Go2Codex into silent cancellation; the monitor is removed immediately when selection, Escape, outside click, or modal return completes the one-shot session. Mouse-release timeout and cancellation are typed failures and never present the panel or perform Handoff. There is no blind fixed delay, activation retry, global key or modifier monitor, or Accessibility permission.

## Repeated invocation

A MainActor-owned process-local gate has `idle`, `active`, and `finishing` states. Initial launch and `applicationShouldHandleReopen` enter through the same gate. Only `idle -> active` succeeds; another launch while active or finishing is ignored. Selection, cancellation, and failure transition to finishing before termination.

This gate prevents overlap inside one Launcher process. It does not claim a cross-process lock; Launch Services normally reopens the registered application instance.

## Debug switches

The Debug Launcher can pause after the invocation gate is acquired and before any picker or Handoff work. The value is clamped to 5,000 milliseconds and the entire path is excluded from Release builds:

```sh
defaults write io.github.czrzchao.go2codex.debug M2InvocationDelayMilliseconds -int 2000
defaults delete io.github.czrzchao.go2codex.debug M2InvocationDelayMilliseconds
```

Enable the delay only for the rapid-click check, then delete the key. A missing, zero, or negative value disables it.

## Automated cases

- Shift, Caps Lock, Function, and mixed-flag containment;
- Option and Option+Shift rejection before the Finder resolver when those flags are supplied in the startup snapshot;
- bounded physical mouse release before a single nonactivating-panel presentation, without activation or an active-state gate;
- mouse-release timeout plus waiting and pre-existing cancellation without a panel or Handoff, and no reachable activation-timeout branch;
- Disabled never matching;
- panel placement on one screen, multiple screens, negative-coordinate screens, outside all screens, and near screen edges;
- every invocation-gate transition and duplicate rejection;
- fixed item order, default marking, disabled availability, and one-shot selection, Escape, outside-click cancellation, and monitor cleanup without Handoff.

## Real Finder checklist

Observed before the current repair: a real Option-click closed the invoking Finder viewer window, a later real Shift-click displayed the correct four-item picker but immediately vanished, and strong activation alone also flashed. A readiness build that waited for mouse release and then required `NSApp.isActive` succeeded on its first real Shift check, but the second ended with `target-picker-activation-timeout`; the installed mouse-release-plus-best-effort-activation `NSMenu` repair also flashed. This proves that foreground activation is not a reliable lifecycle for the disconnected menu. The replacement nonactivating-panel repair is installed and has passed real stable-display, Escape, outside-click, one-shot Codex App selection, and five consecutive open/Escape checks through Finder; the selected task used the exact Finder Workspace.

With the installed nonactivating-panel repair, run consecutive retests:

1. hold Shift before clicking and keep it held until the picker is stably visible;
2. confirm the four-item panel remains interactive next to the invocation pointer rather than flashing away;
3. confirm Escape and click-outside exit silently;
4. repeat with Shift plus Caps Lock or Function while keeping Shift held;
5. select each intended item in later route checks and confirm a selection produces only one Handoff;
6. with a Debug-only artificial delay in a separate Debug check, click rapidly and confirm at most one picker and one Handoff.

Do not use Option or Option+Shift as a manual operating gesture. If capture timing needs further investigation, the embedded Debug Launcher may record only temporary on-screen startup-snapshot rows; that probe cannot turn the sample into a click-bound event contract.

Fail-closed behavior: an Option flag observed in the startup snapshot, unusable panel frame, panel construction error, or duplicate invocation performs no Handoff. The observed-Option path never queries Finder and does not add a delay, retry, fallback, global key or modifier monitor, or Accessibility permission. The panel's mouse-down-only outside-click monitor exists only during presentation and is removed when that one-shot session ends. A modifier released before the snapshot cannot be classified strictly, so automated guard tests and the hold-Shift operating constraint do not close the modifier safety gate.
