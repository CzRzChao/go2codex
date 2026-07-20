# Platform Contract Probe

This is an independent SwiftPM probe for the remaining M2 Finder and terminal
checks. Production targets do not import it, and it does not modify the Xcode
project.

It has no third-party dependencies and never uses AppleScript source, System
Events, Accessibility, Codex, or Claude. Running it without an explicit
subcommand performs no system control.

## Build and self-test

```sh
cd prototypes/PlatformContractProbe
swift build
swift run platform-contract-probe-self-test
swift run platform-contract-probe inspect
```

The self-test only inspects deterministic command parsing, URL validation,
error mapping, marker generation, and in-memory Apple Event descriptors. It
does not send an Apple Event or open an application.

`inspect` is also read-only. It reports terminal handler presence and requires
the Codex and Claude scheme handlers to match their exact expected bundle
identifiers, without printing application paths. It prints the exact event
shapes and deliberately reports the modifier/picker Finder-toolbar test as
pending. A command-line process cannot reproduce the immutable modifier snapshot
received by the real embedded Finder Launcher, so that evidence must come from
the production Debug probe described in spike 0004. A restricted command runner
can prevent Launch Services lookup; if even Finder and Terminal report absent,
repeat `inspect` directly in Terminal.

## Explicit controlled checks

These commands send Apple Events and can show the normal macOS Automation
consent prompt. They are intentionally never run by the build or self-test:

```sh
swift run platform-contract-probe finder
swift run platform-contract-probe terminal-host terminal tab
swift run platform-contract-probe terminal-host terminal window
swift run platform-contract-probe terminal-host iterm2 tab
swift run platform-contract-probe terminal-host iterm2 window
```

`finder` sends exactly one `core/getd` event for
`pURL(fvtg(brow[1]))`. Success output contains only a redacted classification,
never the returned Finder path.

Each terminal check submits a closed, harmless `printf` marker containing a
random UUID. The output prints that UUID so the observer can identify the new
session and confirm that the previous tab was untouched.

Terminal uses `core/dosc` only for a new-window candidate. When New Tab is
requested and Terminal already has a window, the probe fails before submitting
the marker because Terminal exposes no verified create-tab event. When Terminal
has no window, New Tab falls back to the same new-window event.

iTerm2 resolves its declared `current window` property (`Crwn`) before New Tab
and uses that property as the direct object of `Itrm/ntwn`. It intentionally
omits `Nwcm` from `Itrm/nwwn` and `Itrm/ntwn`, because the creation-time command
overrides the profile's normal command/login shell. It waits for the returned
window/tab specifier, derives that object's `Wcsn` current-session specifier,
then sends `Itrm/sntx` with `Wtnl=true`. This preserves the default profile's
normal shell setup, but introduces a create-to-write race. The observer must
confirm that the printed marker appears in the newly created session. A missing
returned specifier or failed write is a typed failure rather than a fallback.

For a requested tab, a host that is not running is treated as having no window.
For a running host, the probe performs a bounded front-window `core/getd` query.
No window selects the new-window candidate; other errors fail closed.
