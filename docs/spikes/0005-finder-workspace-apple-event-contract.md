# Finder Workspace Apple Event contract

Status: descriptor construction compiled and was inspected on 2026-07-18. On 2026-07-19, the installed Personal build passed one real Finder Automation Allow flow, and an ordinary toolbar click delivered the exact folder displayed by Finder to the configured Codex App. A later real Option-click closed the invoking Finder viewer window, establishing that Option is unsupported. Picker repairs then flashed or, with a hard `NSApp.isActive` gate, succeeded once before the second real check produced `target-picker-activation-timeout`; the installed mouse-release-plus-best-effort-activation `NSMenu` repair also flashed. Its installed replacement compact nonactivating-panel repair now passes real stable-display, Escape, outside-click, one-shot Codex App selection with exact Workspace delivery, and five-cycle sequential invocation checks; only the separate rapid-overlap check remains pending, while the click-bound modifier safety contract is still open.

## Result

The Toolbar Launcher sends one native `core/getd` Apple Event to bundle identifier `com.apple.finder`. Its direct object is this object-specifier chain:

```text
pURL property
└── fvtg property
    └── brow element at absolute index 1
```

Finder's scripting definition identifies `brow` as a Finder file-viewer window, `fvtg` as its displayed target, and `pURL` as the target item's URL. This reads the active tab of the front Finder viewer window and never references Finder selection. Get Info and preference windows are not `brow` elements.

This request is never constructed or sent when the Launcher's startup snapshot still contains Option, including Option+Shift. Finder may close the source viewer window for its own Option-click behavior, after which another viewer could become `brow[1]`; an observed Option therefore returns `finder-option-modifier-unsupported` before any Finder query and performs no retry, delay, fallback, or Handoff. Finder/Launch Services `oapp` and `rapp` events do not carry a documented modifier value bound to the originating click, so this guarantee does not cover Option released before `NSEvent.modifierFlags` is sampled. Option is unsupported and must not be used.

The sending implementation remains confined to the nested Launcher, but the installed-build TCC trace identifies the outer Go2Codex application as the responsible identity for that invocation. Both outer and nested bundles therefore declare the Apple Events entitlement and localized `NSAppleEventsUsageDescription`; an ordinary Settings launch contains no Apple Event send. Personal ad-hoc rebuilds do not guarantee authorization continuity, while Public Release is gated on Developer ID signing.

The event uses `NSAppleEventDescriptor`, waits for one reply with a bounded timeout, and allows the normal macOS consent interaction. No ScriptingBridge code generation, AppleScript source interpolation, System Events, Accessibility, preflight event, or retry loop is used. Descriptor construction was compiled with Swift 6.0.3 and confirmed as `core/getd/obj ` without sending the event.

The platform boundary returns only reply text or a typed Apple Event error. A separate Workspace resolver accepts a non-empty absolute file URL whose resource is reachable and a directory. It permits the root directory and mounted local, external, iCloud, or network volumes. It does not resolve a Git root or symlink, inspect selection, mount volumes, or substitute Desktop, home, or a previous path.

## Error mapping

| Condition | Typed result |
| --- | --- |
| startup snapshot contains Option or Option+Shift | `finder-option-modifier-unsupported` before any Finder request |
| `-1743` | Automation permission denied |
| `-1744` | consent required when interaction was disabled |
| `-1712` | Finder reply timeout |
| `-600` | Finder unavailable |
| `-1728` | `finder-object-unavailable`; the requested Finder object no longer resolves |
| missing or malformed text | malformed Finder reply |
| non-file URL or virtual target | unsupported Finder location |
| unreachable URL | inaccessible or unmounted Workspace |
| reachable non-directory | invalid Workspace |

Finder status `-1728` is not treated as proof that no viewer window exists. The user-facing message is “The original Finder folder is no longer available” (“原 Finder 文件夹已不可用”), and the invocation terminates without querying a different window. Release diagnostics retain only the stage and typed code. They do not include the reply URL, complete path, or Finder's raw error string.

## Automated cases

- exact event class, event ID, target bundle, direct-object keyword, and nested four-character object specifiers;
- one sender call per eligible resolution and zero sender calls when the supplied startup snapshot contains Option or Option+Shift;
- every listed OSStatus mapping;
- percent-encoded and Unicode file URLs, root, and external-volume-shaped paths;
- empty, malformed, relative, non-file, unreachable, and non-directory replies;
- proof that the request contains no selection specifier.

These cases prove the behavior of an observed snapshot; they do not prove that Finder/Launch Services binds that snapshot to the toolbar click or preserves a rapidly released modifier.

## Real Finder checklist

Observed Personal Release evidence: the user allowed Finder Automation and confirmed that an ordinary toolbar click opened the configured Codex App with the exact folder displayed by the frontmost Finder window. TCC logged `authValue=2` and no missing-entitlement denial. A later Option-click closed the invoking Finder window, confirming the Finder-owned conflict. Subsequent picker builds flashed until a mouse-release plus hard-foreground readiness build displayed the menu once; its second real check failed with `target-picker-activation-timeout`, and the installed disconnected-menu repair still flashed. The installed replacement panel now remains visible and interactive, Escape and outside-click cancellation both pass, selecting Codex App performs one Handoff with the exact frontmost Workspace, five consecutive open/Escape cycles remain stable, selecting a child item in Finder does not replace the displayed folder as Workspace, two different Finder windows each hand off their own displayed folder, and two tabs in one Finder window each hand off the active tab's folder. All real Workspace handoffs so far used non-Git folders successfully. This evidence confirms the Allow path, default and explicit target opening, exact frontmost-folder delivery across windows and tabs and independent of selection or Git status, the Option conflict, and the repaired sequential selection/cancellation lifecycle; external-volume, separate rapid-overlap, and click-bound modifier safety checks remain open.

For the remaining controlled checks:

1. close all viewer windows and confirm there is no Desktop fallback;
2. verify Recents or another virtual view fails rather than substitutes a path;
3. verify a directory on a mounted external volume succeeds;
4. disable Finder Automation in System Settings and confirm one permission error with no request loop.

Do not use Option or Option+Shift for a real Finder check. Fail-closed behavior applies when Option is still visible in the startup snapshot and to every event, decoding, or filesystem validation error; each terminates without a Handoff. A rapidly released modifier cannot be classified strictly. No branch retries against or falls back to another Finder window, installs a global key or modifier monitor, or requests Accessibility, so the modifier safety gate remains open. The picker panel's temporary mouse-down-only global monitor is scoped solely to outside-click cancellation while visible and is removed immediately afterward.
