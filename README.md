# Go2Codex

Hand the folder you are looking at in Finder to a Codex or Claude coding agent, with minimal friction.

Go2Codex adds a single button to the Finder toolbar. Click it and Go2Codex takes the exact folder shown by the frontmost Finder window (the **Workspace**) and opens it in your preferred coding agent — either a desktop app (via its URL scheme) or a CLI (by running `cd <folder> && codex` or `cd <folder> && claude` in your terminal).

<!-- TODO: screenshot — Finder toolbar with the Go2Codex button -->
<!-- TODO: demo GIF — click button, agent opens on the current folder -->
<!-- TODO: screenshot — Settings window (General / CLI / Finder Toolbar) -->

## Requirements

- **Apple Silicon** Mac (no Intel or Universal build is shipped).
- **macOS 14 Sonoma** or later.
- At least one supported agent installed:
  - Codex App or Claude Desktop (for the desktop targets), and/or
  - the `codex` / `claude` CLI available on your shell `PATH` (for the CLI targets).
- A supported terminal for CLI targets: **Terminal.app** or **iTerm2**.

Go2Codex does not install or bundle any agent. It only launches agents you already have.

## Supported matrix

Four **Agent Targets** (fixed order) × two **Terminal Hosts**:

| Agent Target        | How it launches                                              | Terminal Host        |
| ------------------- | ----------------------------------------------------------- | -------------------- |
| Codex App           | Desktop deep link via URL scheme (`com.openai.codex`)       | —                    |
| Codex CLI           | `cd <folder> && codex` in the terminal                      | Terminal.app / iTerm2 |
| Claude Desktop Code | Desktop deep link via URL scheme (`com.anthropic.claudefordesktop`) | —            |
| Claude Code CLI     | `cd <folder> && claude` in the terminal                     | Terminal.app / iTerm2 |

- **Desktop targets** open through the target's application URL scheme. Go2Codex resolves the handler by exact bundle identifier, so another app cannot hijack the scheme. Any trust or confirmation prompt after handoff belongs to the target app.
- **CLI targets** open a new terminal session, `cd` into the Workspace, and submit only the fixed `codex` or `claude` command (no extra arguments). What happens after that belongs to the terminal and the CLI.

The **Workspace** is always the exact folder of the frontmost Finder window. Selected items, Git roots, the Desktop, and your home folder are never substituted. If Finder has no open window (or shows a non-file/virtual location), the launch fails cleanly instead of guessing.

## Gatekeeper (important)

The Personal builds published here are **not yet Developer ID signed or notarized**. macOS Gatekeeper will block the first launch of a build downloaded from GitHub with a warning that it "cannot be opened."

To open it anyway, use one of:

- **Finder:** right-click (Control-click) `Go2Codex.app` → **Open** → confirm **Open** in the dialog. You only need to do this once.
- **Terminal:** remove the quarantine attribute, then open normally:

  ```sh
  xattr -dr com.apple.quarantine /path/to/Go2Codex.app
  ```

This is a temporary state. A future Public Release will be signed with a Developer ID Application certificate and notarized by Apple, so this step will no longer be needed. See [ADR 0003](docs/adr/0003-distribute-outside-the-mac-app-store.md).

## Installing the toolbar button

Go2Codex uses a **dual-entry architecture**: one `Go2Codex.app` contains both the Settings app and an embedded toolbar launcher. Installation into the Finder toolbar is a guided **manual** step (Go2Codex never edits Finder's toolbar for you).

1. Move `Go2Codex.app` into `/Applications` or `~/Applications`.
2. Launch Go2Codex to open **Settings** and complete first-run setup (choose your Default Target and Default Terminal Host).
3. In the **Finder Toolbar** section, follow the guided reveal, then **hold Command and drag** the Go2Codex button into the Finder toolbar.

Usage once installed:

- **Click** the toolbar button → **Quick Launch**: opens the current Workspace directly in your Default Target.
- **Shift-click** the toolbar button → **Target Picker**: a small picker to choose any of the four targets for a single launch (this is the Alternate Trigger; it can also be disabled). Hold Shift until the picker is visible.

To remove it, the Settings app shows you how to hold Command and drag the button back out of the toolbar.

## Known limitations

- **Terminal.app cannot safely create a new tab when a window already exists.** In that case Go2Codex fails before submitting a command. If Terminal has no window, New Tab creates a new command-bearing window instead. **iTerm2 supports new tabs.**
- **Option-click is not supported** as a trigger. Finder reserves Option-click on toolbar items and may close the source window before the Workspace can be resolved. Only Shift-click (or disabled) is offered as the Alternate Trigger.
- **No automatic toolbar install/repair/uninstall.** All toolbar setup and removal is the manual Command-drag path.
- **Local only.** Go2Codex makes no network requests and performs no telemetry, crash reporting, background monitoring, or auto-update.
- **Apple Silicon only.**

Not in scope: VS Code / Cursor / other editors, a menu-bar resident, session restore or prompt injection, and Mac App Store distribution.

## Building from source

- Xcode 16.2 (Swift 6), targeting arm64 macOS 14.
- Run the unit tests:

  ```sh
  Scripts/test.sh
  ```

- For the full local build / install / smoke / promote / rollback workflow, see the [Local Development SOP](docs/local-development-sop.md). Build and install scripts (`build-personal.sh`, `install-personal.sh`, etc.) target a real signed Mac and are not meant for CI.

Project context and invariants live in [CONTEXT.md](CONTEXT.md); the gated delivery plan is in [docs/implementation-plan.md](docs/implementation-plan.md).

## License

[MIT](LICENSE).
