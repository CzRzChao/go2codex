# Security Policy

## Reporting a vulnerability

Please report security issues **privately**. Do not open a public issue for a suspected vulnerability.

Open a **GitHub Security Advisory** (repository → **Security** → **Report a vulnerability**), which keeps the report private until a fix is ready.

Please include the affected version, macOS version, and reproduction steps. You can expect an acknowledgement and, where applicable, a coordinated fix and disclosure.

## Supported versions

Until a stable release exists, only the most recently published **GitHub Preview Release** receives security fixes. Stable-version support will be documented here when that channel is introduced.

## Security posture

Go2Codex is a local-only macOS utility. Its design deliberately limits its attack surface:

- **No network activity.** The app makes no network requests. It performs no telemetry, analytics, crash reporting, background monitoring, or auto-update checks.
- **App Sandbox status.** App Sandbox is currently disabled, so Go2Codex is not confined to an App Sandbox container. Ordinary macOS account permissions and system protections still apply, while Transparency, Consent, and Control (TCC) separately requires user consent for Finder and terminal Automation. Go2Codex does not request Accessibility, Full Disk Access, Screen Recording, or Notifications.
- **Minimal entitlements.** The only declared privacy entitlement is `com.apple.security.automation.apple-events`, used to read the frontmost Finder window's folder and to open a terminal session for CLI handoffs. Apple Event sending code exists only in the embedded Toolbar Launcher; ordinary launches of the Settings app send no Apple Events. (macOS attributes TCC responsibility for the nested launcher's events to the outer app, so both bundles declare this one entitlement and its localized usage description.)
- **URL handler validation.** Desktop handoff resolves the target's URL scheme handler by **exact bundle identifier** — `com.openai.codex` for Codex App and `com.anthropic.claudefordesktop` for Claude Desktop. An application that merely claims the scheme without matching the expected bundle identifier is treated as unavailable, which prevents scheme hijacking.
- **No shell injection via the Workspace.** CLI handoff enters the Workspace and submits only the fixed `codex` or `claude` command with no extra arguments; the Workspace path is quoted so it cannot inject additional commands.
- **Redacted diagnostics.** Release diagnostics are written only to macOS Unified Logging (no standalone log file) and omit the complete Workspace path and any generated command.

## Scope notes

Go2Codex hands a folder to a separate coding agent and stops observing after handoff. The behavior, trust prompts, and data handling of Codex, Claude, your terminal, and your shell are outside the control and scope of Go2Codex.

## Distribution and Gatekeeper

GitHub Preview Releases are ad-hoc signed and are not Developer ID signed or notarized, so Gatekeeper blocks their first launch; see the Gatekeeper section of the [README](README.md). A future stable release will use Developer ID Application signing and Apple notarization while remaining distributed as a ZIP through GitHub Releases.
