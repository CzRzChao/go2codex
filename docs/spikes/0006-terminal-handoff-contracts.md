# Terminal handoff contracts

Status: command construction, Terminal.app cold-start handling, process-exit race handling, and the parameterized iTerm2 AppleScript boundary are covered by source tests as of 2026-07-20. Real Installed Debug behavior remains in the checklist below.

## Result

Terminal hosts are resolved by bundle identifier through Launch Services:

- Terminal.app: `com.apple.Terminal`;
- iTerm2: `com.googlecode.iterm2`.

Go2Codex does not search for CLI executables. A login-shell `command -v` probe cannot reproduce terminal profiles, interactive shell startup files, or a user's configured shell and would create false unavailable results. A CLI Target is pre-handoff available when its selected Terminal Host is registered. If `codex` or `claude` is absent from the real interactive environment, the terminal owns and displays its normal command-not-found result after handoff.

The only generated shell line is:

```text
cd '<POSIX-single-quoted absolute Workspace>' && codex
cd '<POSIX-single-quoted absolute Workspace>' && claude
```

Each apostrophe in the path becomes `'\''`. The target command is selected from a closed enum and receives no arguments. Offline `/bin/sh` round trips covered spaces, apostrophes, command substitutions, semicolons, newlines, backslashes, exclamation marks, and non-ASCII characters without executing path text.

Dynamic strings are Apple Event text descriptors. They are never interpolated into AppleScript source.

## iTerm2 parameterized script

iTerm2 declares exact creation events for both placement modes and a write event:

- `Itrm/nwwn`, create window with default profile;
- `Itrm/ntwn`, create tab with default profile in a window;
- `Itrm/sntx`, write text to the new session with optional newline keyword `Wtnl`.

The first native implementation sent create and write as two Swift-owned Apple Events. A real iTerm2 3.6.10 invocation returned a bare `type(cwin)` descriptor whose outer type was `type` (`1954115685`), not an object specifier with the identity of the newly created window. Reproducing the compiled command's `subj` attributes did not change that result. Go2Codex must not guess `current window`, diff window collections, or coerce a class value into object identity, because another window can become current between IPC points.

The Launcher now loads the precompiled `ITermHandoff.scpt` resource and invokes one of two fixed handlers through the standard `ascr/psbr` subroutine event. The generated command is the single `utxt` argument in the `----` list; the handler name is selected from a closed placement enum. Inside the same AppleScript invocation, the handler creates a default-profile window or tab, keeps that returned object inside the interpreter, writes exactly once to its current session, and returns explicit Boolean true. Swift never parses the create result.

iTerm2's [AppleScript documentation](https://iterm2.com/3.5/documentation-scripting.html) says that supplying the optional creation `command` replaces the profile's command or login shell. The handlers therefore omit that parameter and write text after the default-profile shell starts. This preserves the configured profile, shell, PATH, and startup files.

The reviewable `ITermHandoff.applescript` source and its precompiled `.scpt` are checked in together. Only the compiled resource is copied into the nested Launcher. It executes in the Launcher process through `NSAppleScript`; it does not launch `osascript`, use iTerm2's network API, or require Accessibility. Resource, load, execution, timeout, permission, and result-contract failures are typed. No failure retries, falls back to the disproved raw create path, or submits into a guessed session.

## Terminal.app native events

Terminal declares `core/dosc` with command text as the direct parameter and an optional `kfil` target accepting a tab or window. No target creates a new window; a front-window target reuses its selected tab rather than creating one. Terminal's scripting definition exposes tabs as read-only elements, gives them no stable ID, and declares no create-tab event. The existing-window New Tab branch therefore fails before command submission. Go2Codex will not simulate Command-T through System Events because that would broaden permission to Accessibility.

Terminal must receive `core/dosc` differently across its process boundary. When Terminal is already running, Go2Codex sends one wait-for-reply event directly. When Terminal is not running, Go2Codex resolves its exact application URL by bundle identifier and opens that URL once with the same `core/dosc` descriptor as `NSWorkspace.OpenConfiguration.appleEvent`; it does not first open an empty window and then poll or sleep before sending the command. If the process exits after the running-state check and the direct query or command returns `-600`, Go2Codex performs that same one-time open-with-initial-event fallback. Other Apple Event errors retain their normal mapping and are not retried. This Terminal-specific recovery is never applied to iTerm2.

Terminal also registers the public macOS Service “New Terminal Tab at Folder”. The service can create a tab at a supplied directory, but `NSPerformService` returns only a Boolean and the service declares no return type. A later Apple Event cannot identify that exact tab without a race, so the Service is not connected to production.

## Automated cases

- POSIX quoting and exact closed command enum;
- command text contains no target arguments;
- host and placement planning for existing/no-window states;
- exact Terminal event class, ID, target bundle, direct parameter, and cold-open application URL;
- exact iTerm2 subroutine event, fixed handler names, one `utxt` argument, and adversarial command preservation;
- compiled script resource presence and loadability;
- iTerm2 new-window/new-tab selection and exactly one handler invocation;
- explicit Boolean-true success contract;
- resource, load, invalid-result, permission, consent, timeout, unavailable-process, unavailable-object, and generic event failures without retry or cross-host fallback;
- Terminal front-window-query and direct-command `-600` races falling back exactly once, with no duplicate direct submission;
- the async Launcher workflow waiting for terminal acceptance before reporting success;
- no CLI executable probing or silent Terminal Host fallback.

Automated tests load but never execute the production iTerm2 handlers. They send no real Finder or terminal Apple Event and cannot replace visible TCC and session validation.

## Real terminal checklist

1. Completely quit Terminal, then invoke New Window and no-window New Tab; each must create exactly one command-bearing window with no extra blank window.
2. Leave Terminal running with no window, then repeat both placements and confirm one command window each.
3. With an existing Terminal window, New Tab must fail before command submission; New Window must create a distinct window and submit once.
4. In iTerm2, test New Window with and without an existing window.
5. In iTerm2, test New Tab with an existing window and the no-window conversion to New Window.
6. Confirm every iTerm2 session uses the configured default profile and that input lands only in the newly created session.
7. Repeat iTerm2 operations several times to detect duplicate sessions, late submission, or a current-window race.
8. Repeat one invocation in each host with Automation denied and confirm one typed permission error with no retry.
9. Finally launch `codex` and `claude` through each supported host/placement shape and confirm the exact Workspace and lack of target arguments.

Terminal New Tab with an existing window remains a documented product-gate exception. The new iTerm2 boundary remains source-validated but not live-validated until an updated Installed Debug passes this checklist.
