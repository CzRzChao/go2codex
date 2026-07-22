# Go2Codex

Hand the folder you are looking at in Finder to a Codex or Claude coding agent, with minimal friction.

Go2Codex adds a single button to the Finder toolbar. Click it and Go2Codex takes the exact folder shown by the frontmost Finder window (the **Workspace**) and opens it in your preferred coding agent — either a desktop app (via its URL scheme) or a CLI (by running `cd <folder> && codex` or `cd <folder> && claude` in your terminal).

## Requirements

- **Apple Silicon** Mac (no Intel or Universal build is shipped).
- **macOS 14 Sonoma** or later.
- At least one supported agent installed:
  - Codex App or Claude Desktop (for the desktop targets), and/or
  - the `codex` / `claude` CLI available on your shell `PATH` (for the CLI targets).
- A supported terminal for CLI targets: **Terminal.app** or **iTerm2**.

Go2Codex does not install or bundle any agent. It only launches agents you already have.

## Download

Download the latest build from [GitHub Releases](https://github.com/CzRzChao/go2codex/releases). Until a Developer ID is available, published builds are explicitly marked as **unsigned previews** and use names such as:

- `Go2Codex-0.1.0-preview.3-macos-arm64.zip`
- `Go2Codex-0.1.0-preview.3-macos-arm64.zip.sha256`

Download both files into the same directory and verify the archive before extracting it:

```sh
shasum -a 256 -c Go2Codex-0.1.0-preview.3-macos-arm64.zip.sha256
```

Then extract the ZIP and move `Go2Codex.app` into `/Applications` or `~/Applications`. Preview updates are manual: download and verify the newer archive, quit Go2Codex, and replace the existing app. Because each preview is ad-hoc signed, macOS may ask you to grant Finder, Terminal, iTerm2, or System Events Automation access again after an update; review the prompts and the Go2Codex entry under **System Settings** → **Privacy & Security** → **Automation**. Terminal New Tab additionally needs Go2Codex enabled under **Accessibility**.

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
- **New Window and New Tab** are supported for both CLI targets in Terminal.app and iTerm2. Terminal New Tab uses System Events to send Command-T, so it explicitly requests System Events Automation and Accessibility before submitting a command. Denied permission, a failed shortcut, or an unconfirmed new tab stops cleanly without submitting the CLI command. New Window does not require Accessibility.

The **Workspace** is always the exact folder of the frontmost Finder window. Selected items, Git roots, the Desktop, and your home folder are never substituted. If Finder has no open window (or shows a non-file/virtual location), the launch fails cleanly instead of guessing.

## Gatekeeper (important)

GitHub preview builds are ad-hoc signed but **not Developer ID signed or notarized**. macOS Gatekeeper will block their first launch because Apple cannot verify the developer or scan result.

Only continue if you trust this repository and the downloaded SHA-256 matches the published checksum. After the first blocked launch:

1. Open **System Settings** → **Privacy & Security**.
2. Scroll to **Security** and choose **Open Anyway** for Go2Codex.
3. Authenticate and confirm **Open**. macOS saves this choice as an exception for that app build.

The override might be unavailable on an organization-managed Mac. A future stable Public Release will be signed with a Developer ID Application certificate and notarized by Apple, so this step will no longer be needed.

## Installing the toolbar button

Go2Codex uses a **dual-entry architecture**: one searchable `Go2Codex.app` contains the Settings app and an internal toolbar Launcher under `Contents/Helpers`.

1. Move `Go2Codex.app` into `/Applications` or `~/Applications`.
2. Launch Go2Codex and choose your Default Target and Default Terminal Host.
3. Choose **Install in Finder**, review the warning, then confirm **Install and Restart Finder**.

Automatic setup is experimental. It updates the current user's private Finder toolbar preference, creates an app-owned recovery journal before writing, verifies the exact pre-write value again, preserves unrelated toolbar items, restarts Finder, and checks Finder's normalized result. It runs only for an exact recognized macOS/Finder build and toolbar shape. Unknown builds, malformed or ambiguous layouts, and failed verification perform no automatic write and fall back to manual setup.

This preview recognizes macOS build `23G80` with Finder `14.6 (1632.6.3)`, and macOS build `25F84` with Finder `26.4 (1828.5.2)`. Even a patch-level mismatch uses manual setup until it is separately profiled.

For manual setup, choose **Show Manual Setup**, then use **Show in Finder**. Once Finder reveals the internal Launcher, hold Command and drag it into the Finder toolbar. The instructions no longer take focus back from Finder after the reveal.

Because Finder offers no public compare-and-swap API for this private preference, user confirmation and the recovery journal reduce risk but cannot make the read-modify-write operation atomic against another process changing the toolbar at exactly the same time. If you do not accept that limitation, cancel and use the manual Command-drag path.

Usage once installed:

- **Click** the toolbar button → **Quick Launch**: opens the current Workspace directly in your Default Target.
- **Shift-click** the toolbar button → **Target Picker**: a small picker to choose any of the four targets for a single launch (this is the Alternate Trigger; it can also be disabled). Hold Shift until the picker is visible.

To remove it, the Settings app shows you how to hold Command and drag the button back out of the toolbar.

## Known limitations

- **Option-click is not supported** as a trigger. Finder reserves Option-click on toolbar items and may close the source window before the Workspace can be resolved. Only Shift-click (or disabled) is offered as the Alternate Trigger.
- **Automatic Finder setup is private and build-specific.** It is enabled only for exact profiled Finder builds; every other build uses the manual Command-drag path. Finder has no public atomic transaction for this preference, so a very small concurrent-update race remains even on a recognized build.
- **Local only.** Go2Codex makes no network requests and performs no telemetry, crash reporting, background monitoring, or auto-update. GitHub preview updates are downloaded manually.
- **Apple Silicon only.**

Not in scope: VS Code / Cursor / other editors, a menu-bar resident, session restore or prompt injection, and Mac App Store distribution.

## Building from source

- Xcode 16.2 (Swift 6), targeting arm64 macOS 14.
- Run the unit tests:

  ```sh
  Scripts/test.sh
  ```

The other scripts under `Scripts/` are maintainer workflows for building, verifying, installing, or rolling back local builds. Review them before running them because some operate on an installed application.

## Publishing an unsigned preview (maintainers)

Preview releases are automated by `.github/workflows/release.yml`. A release tag must be exactly `vX.Y.Z-preview.N`: `X.Y.Z` must match `MARKETING_VERSION`, and `N` must be the positive, no-leading-zero `CURRENT_PROJECT_VERSION`. Stable `vX.Y.Z` tags are rejected until Developer ID signing and notarization are available.

Merge the reviewed release commit into `main` and wait for CI to pass. From a clean, up-to-date `main` checkout, check the release contract and create the annotated tag:

```sh
git switch main
git pull --ff-only origin main
Scripts/test-github-release.sh
Scripts/package-github-release.sh --validate-only v0.1.0-preview.3
git tag -a v0.1.0-preview.3 -m "Go2Codex 0.1.0 preview 3"
git push origin v0.1.0-preview.3
```

Pushing the tag is the publication action; never push a release tag merely to test the workflow. Keep the `v*-preview.*` tag-protection ruleset active, and never move or delete a published release tag. The workflow builds and verifies an ad-hoc-signed arm64 app, checks the ZIP round trip and SHA-256, and publishes a GitHub pre-release that is not marked as the latest stable release. After publication, download both assets, verify the checksum, confirm the documented Gatekeeper override, and manually test the supported Finder and target matrix.

## License

[MIT](LICENSE).
