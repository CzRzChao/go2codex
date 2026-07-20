# Security Policy

## Reporting a vulnerability

Please report security issues **privately**. Do not open a public issue for a suspected vulnerability.

Open a **GitHub Security Advisory** (repository → **Security** → **Report a vulnerability**), which keeps the report private until a fix is ready.

Please include the affected version, macOS version, and reproduction steps. You can expect an acknowledgement and, where applicable, a coordinated fix and disclosure.

## Supported versions

Only the **latest release** receives security fixes.

## Security posture

Go2Codex is a local-only macOS utility. Its design deliberately limits its attack surface:

- **No network activity.** The app makes no network requests. It performs no telemetry, analytics, crash reporting, background monitoring, or auto-update checks.
- **Minimal entitlements.** The only entitlement requested is `com.apple.security.automation.apple-events`, used to read the frontmost Finder window's folder and to open a terminal session for CLI handoffs. It does **not** request Accessibility, Full Disk Access, Screen Recording, Notifications, or App Sandbox exceptions. Apple Event sending code exists only in the embedded Toolbar Launcher; ordinary launches of the Settings app send no Apple Events. (macOS attributes TCC responsibility for the nested launcher's events to the outer app, so both bundles declare this one entitlement and its localized usage description.)
- **URL handler validation.** Desktop handoff resolves the target's URL scheme handler by **exact bundle identifier** — `com.openai.codex` for Codex App and `com.anthropic.claudefordesktop` for Claude Desktop. An application that merely claims the scheme without matching the expected bundle identifier is treated as unavailable, which prevents scheme hijacking.
- **No shell injection via the Workspace.** CLI handoff enters the Workspace and submits only the fixed `codex` or `claude` command with no extra arguments; the Workspace path is quoted so it cannot inject additional commands.
- **Redacted diagnostics.** Release diagnostics are written only to macOS Unified Logging (no standalone log file) and omit the complete Workspace path and any generated command.

## Scope notes

Go2Codex hands a folder to a separate coding agent and stops observing after handoff. The behavior, trust prompts, and data handling of Codex, Claude, your terminal, and your shell are outside the control and scope of Go2Codex.

## Distribution and Gatekeeper

Current Personal builds are not yet Developer ID signed or notarized, so Gatekeeper blocks first launch of downloaded builds; see the Gatekeeper section of the [README](README.md). A future Public Release will use Developer ID Application signing and Apple notarization ([ADR 0003](docs/adr/0003-distribute-outside-the-mac-app-store.md)).
