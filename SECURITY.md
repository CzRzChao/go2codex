# Security Policy

## Reporting a vulnerability

Please report security issues **privately**. Do not open a public issue for a suspected vulnerability.

Open a **GitHub Security Advisory** (repository → **Security** → **Report a vulnerability**), which keeps the report private until a fix is ready.

Please include the affected version, macOS version, and reproduction steps. You can expect an acknowledgement and, where applicable, a coordinated fix and disclosure.

## Supported versions

The most recently published **stable GitHub Release** receives security fixes. Preview releases are optional early-testing builds and do not replace the stable support channel.

## Security posture

Go2Codex is a local-only macOS utility. Its design deliberately limits its attack surface:

- **No network activity.** The app makes no network requests. It performs no telemetry, analytics, crash reporting, background monitoring, or auto-update checks.
- **App Sandbox status.** App Sandbox is currently disabled, so Go2Codex is not confined to an App Sandbox container. Ordinary macOS account permissions and system protections still apply. Transparency, Consent, and Control (TCC) separately requires user consent for Finder, Terminal, and iTerm2 Automation. Go2Codex does not request Accessibility, Full Disk Access, Screen Recording, or Notifications.
- **Minimal entitlements.** The only declared privacy entitlement is `com.apple.security.automation.apple-events`, used to read the frontmost Finder window and open terminal sessions. Apple Event calls exist only in the embedded Toolbar Launcher; ordinary launches of the Settings app send no Apple Events. macOS attributes the nested Launcher's TCC responsibility to the outer app, so both bundles declare the Automation entitlement and localized usage description.
- **Opt-in Finder toolbar mutation.** Experimental automatic install, repair, and removal run only after a native confirmation and only for an exact recognized Finder build and preference shape. The app writes the current user's Finder toolbar preference without administrator access, preserves unrelated items, and restarts Finder. It creates a mode-`0600` recovery journal under the user's Application Support directory before writing and verifies the post-restart representation. Finder exposes no public atomic compare-and-swap API for this preference, so an extremely small concurrent-update race remains; manual Command-drag setup is always the lower-risk fallback.
- **URL handler validation.** Desktop handoff resolves the target's URL scheme handler by **exact bundle identifier** — `com.openai.codex` for Codex App and `com.anthropic.claudefordesktop` for Claude Desktop. An application that merely claims the scheme without matching the expected bundle identifier is treated as unavailable, which prevents scheme hijacking.
- **No shell injection via the Workspace.** CLI handoff enters the Workspace and submits only the fixed `codex` or `claude` command with no extra arguments; the Workspace path is quoted so it cannot inject additional commands. For iTerm2, the account login-shell path is read from the local account record, required to be an existing executable `zsh`, `bash`, or `fish`, and encoded as a separate iTerm command argument from the already-quoted Workspace command before it becomes the session's initial command.
- **Bounded advisory CLI availability checks.** Settings checks both fixed CLI names in one headless account-login-shell process. The probe accepts only an existing executable `zsh`, `bash`, or `fish` from the local account record, passes no Workspace path or user-provided command text, uses shell builtins with a per-probe marker, supplies no terminal input, continuously drains output, and has a short timeout. Cancellation or timeout terminates the probe's isolated process group so child processes do not outlive the check. Results are advisory and never block saving or launching because a background shell cannot exactly reproduce every Terminal or iTerm profile. The user's normal shell startup files do run during each probe and can have their own side effects.
- **Fail-closed terminal targeting.** Terminal New Tab uses Terminal's public folder service instead of keyboard simulation or Accessibility. A mode-`0600` advisory lock serializes Go2Codex Terminal service transactions across Launcher processes. Before and after the service call, Go2Codex reads coherent snapshots of all Terminal window IDs, tab counts, and TTY readiness; it submits only after consecutive snapshots preserve every prior TTY and contain exactly one new TTY. Terminal New Window cold start uses the public `New Terminal at Folder` service, then explicitly requests Terminal TCC Automation permission and reads consecutive global snapshots. Terminal does not accept a TTY predicate as a `do script` target in the tested handoff path, so Go2Codex uses the verified new TTY only to establish the matching 1-based tab position within the exact recovered window ID, then submits once. During multi-window recovery, missing, malformed, timed-out, observably concurrent, or ambiguous state fails closed: Go2Codex never falls back to an untargeted command. It may repeat read-only snapshot sampling for a bounded period, but it never retries the service invocation or final command submission. Terminal exposes TTYs but no stable service-created session ID, so an external close/open/reorder action during the brief handoff can invalidate that tab position; users should not modify Terminal windows or tabs then. iTerm creation also has no automatic retry: an execution result that could have been lost after iTerm accepted the request is reported as outcome-unknown so the user can check for an existing session before trying again.
- **Redacted diagnostics.** Release diagnostics are written only to macOS Unified Logging (no standalone log file) and omit the complete Workspace path and any generated command.

## Scope notes

Go2Codex hands a folder to a separate coding agent and stops observing after handoff. The behavior, trust prompts, and data handling of Codex, Claude, your terminal, and your shell are outside the control and scope of Go2Codex.

## Distribution and Gatekeeper

GitHub stable and preview releases are currently ad-hoc signed and are not Developer ID signed or notarized, so Gatekeeper blocks their first launch; see the Gatekeeper section of the [README](README.md). “Stable” identifies the public GitHub Release channel only; it does not represent Developer ID signing, notarization, or a different Gatekeeper experience. All releases remain distributed as ZIP files through GitHub Releases.
