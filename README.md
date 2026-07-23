# Go2Codex

Hand the folder you are looking at in Finder to a Codex or Claude coding agent, with minimal friction.

Go2Codex adds a single button to the Finder toolbar. Click it and Go2Codex takes the exact folder shown by the frontmost Finder window (the **Workspace**) and opens it in your preferred coding agent — either a desktop app (via its URL scheme) or a CLI (by running `cd <folder> && codex` or `cd <folder> && claude` in your terminal).

## Requirements

- **Apple Silicon** Mac (no Intel or Universal build is shipped).
- **macOS 14 Sonoma** or later.
- At least one supported agent installed:
  - Codex App or Claude Desktop (for the desktop targets), and/or
  - the `codex` / `claude` CLI available on your account login shell `PATH` (for the CLI targets).
- A supported terminal for CLI targets: **Terminal.app** or **iTerm2**. iTerm2 handoff requires the account login shell to be **zsh**, **bash**, or **fish**.

Go2Codex does not install or bundle any agent. It only launches agents you already have.

## Download

Download the latest public build from [GitHub Releases](https://github.com/CzRzChao/go2codex/releases). The current stable GitHub Release is **unsigned**: “stable” describes its GitHub Release status, not its macOS signing or notarization status. Version 0.1.1 uses:

- `Go2Codex-0.1.1-macos-arm64.zip`
- `Go2Codex-0.1.1-macos-arm64.zip.sha256`

Optional preview releases may also be published for early testing. Their assets include the preview suffix, for example `Go2Codex-0.1.1-preview.8-macos-arm64.zip`.

Download both files into the same directory and verify the archive before extracting it:

```sh
shasum -a 256 -c Go2Codex-0.1.1-macos-arm64.zip.sha256
```

Then extract the ZIP and, before launching it, move `Go2Codex.app` into `/Applications` or `~/Applications`. Do not run the release directly from Downloads: macOS can launch a quarantined app through App Translocation, and Go2Codex intentionally refuses to install a Finder toolbar item from that temporary location. Updates are manual: download and verify the newer archive, quit Go2Codex, and replace the existing app. If an earlier release was run from Downloads and its Launcher was added manually, first hold Command (⌘) and drag that old button out of the Finder toolbar; after opening the replacement from Applications, install or add the current Launcher again. Because public stable and preview builds are ad-hoc signed, macOS may ask you to grant Finder, Terminal, or iTerm2 Automation access again after an update; review the prompts and the Go2Codex entry under **System Settings** → **Privacy & Security** → **Automation**.

## Supported matrix

Four **Agent Targets** (fixed order) × two **Terminal Hosts**:

| Agent Target        | How it launches                                              | Terminal Host        |
| ------------------- | ----------------------------------------------------------- | -------------------- |
| Codex App           | Desktop deep link via URL scheme (`com.openai.codex`)       | —                    |
| Codex CLI           | `cd <folder> && codex` in the terminal                      | Terminal.app / iTerm2 |
| Claude Desktop Code | Desktop deep link via URL scheme (`com.anthropic.claudefordesktop`) | —            |
| Claude Code CLI     | `cd <folder> && claude` in the terminal                     | Terminal.app / iTerm2 |

- **Desktop targets** open through the target's application URL scheme. Go2Codex resolves the handler by exact bundle identifier, so another app cannot hijack the scheme. Any trust or confirmation prompt after handoff belongs to the target app.
- **CLI targets** are checked without opening a terminal: Settings runs one background account-login-shell probe for both fixed commands. **Available**, **Not Found**, and **Couldn’t Verify** are advisory because a real Terminal or iTerm session can apply terminal-specific shell setup that the background probe cannot reproduce exactly; none of these statuses blocks saving or launching. The probe can run `zsh`, `bash`, or `fish` startup files and is therefore bounded by a short timeout. Go2Codex opens a new terminal session, `cd`s into the Workspace, and submits only the fixed `codex` or `claude` command (no extra arguments). iTerm2 receives the account login shell and CLI command as the session's initial command, rather than opening a prompt and injecting text afterward; unsupported login shells fail before an iTerm session is created. When the CLI exits, the session returns to the login shell. What happens after that belongs to the terminal, shell, and CLI.
- **New Window and New Tab** are supported for both CLI targets in Terminal.app and iTerm2. Terminal New Tab invokes Terminal's public **New Terminal Tab at Folder** service with the Workspace directory; it does not use System Events, simulated keyboard input, or Accessibility. If New Tab is configured but the current active Space has no usable Terminal window, Terminal natively falls back to one new window with one tab; Go2Codex accepts that fallback only after strict identity confirmation and targets that exact tab, still without Accessibility. For a cold Terminal **New Window**, Go2Codex invokes Terminal's public **New Terminal at Folder** service, waits for Terminal to run, requests Automation authorization, and then delivers the command only to the confirmed window. Restored multiple windows or tabs are ambiguous and fail closed; Terminal may leave an empty window when Go2Codex cannot safely identify one target. Go2Codex serializes its own Terminal service transactions, compares stable snapshots of every Terminal window and TTY, and submits the command exactly once only after consecutive snapshots confirm one new, uniquely identified TTY. Terminal does not accept a TTY predicate as a command target in the tested handoff path, so Go2Codex uses that verified snapshot to send once to the matching 1-based tab position in the exact window ID. Terminal Automation is still required to inspect tabs and submit the command. A failed service, unstable or ambiguous state, an observed concurrent session change, or a TTY that never becomes ready stops without guessing; read-only snapshot sampling may repeat for a bounded period, but the service invocation and command submission are never retried. An empty session can remain when Terminal created one but Go2Codex could not safely target it. Terminal exposes TTYs but no stable service-created session ID, so do not open, close, reorder, or move Terminal tabs or windows during the brief handoff; doing so can invalidate the verified tab position.

The **Workspace** is always the exact folder of the frontmost Finder window. Selected items, Git roots, the Desktop, and your home folder are never substituted. If Finder has no open window (or shows a non-file/virtual location), the launch fails cleanly instead of guessing.

## Gatekeeper (important)

GitHub stable and preview builds are ad-hoc signed but **not Developer ID signed or notarized**. A stable GitHub Release is not a Developer ID release. macOS Gatekeeper will block the first launch because Apple cannot verify the developer or scan result.

Only continue if you trust this repository and the downloaded SHA-256 matches the published checksum. After the first blocked launch:

1. Open **System Settings** → **Privacy & Security**.
2. Scroll to **Security** and choose **Open Anyway** for Go2Codex.
3. Authenticate and confirm **Open**. macOS saves this choice as an exception for that app build.

The override might be unavailable on an organization-managed Mac.

## Installing the toolbar button

Go2Codex uses a **dual-entry architecture**: one searchable `Go2Codex.app` contains the Settings app and an internal toolbar Launcher under `Contents/Helpers`.

1. Move `Go2Codex.app` into `/Applications` or `~/Applications`.
2. Launch Go2Codex and choose your Default Target and Default Terminal Host.
3. Choose **Install in Finder**, review the warning, then confirm **Install and Restart Finder**.

Automatic setup is experimental. It updates the current user's private Finder toolbar preference, creates an app-owned recovery journal before writing, verifies the exact pre-write value again, preserves unrelated toolbar items, restarts Finder, and checks Finder's normalized result. It runs only for an exact recognized macOS/Finder build and toolbar shape. Unknown builds, malformed or ambiguous layouts, and failed verification perform no automatic write and fall back to manual setup.

This release recognizes macOS build `23G80` with Finder `14.6 (1632.6.3)`, and macOS build `25F84` with Finder `26.4 (1828.5.2)`. Even a patch-level mismatch uses manual setup until it is separately profiled.

For manual setup, choose **Show Manual Setup**, then use **Show in Finder**. If the toolbar already contains a button from an earlier copy of Go2Codex, first hold Command and drag that old button out. Once Finder reveals the current internal Launcher, hold Command and drag it into the Finder toolbar. The instructions no longer take focus back from Finder after the reveal.

Because Finder offers no public compare-and-swap API for this private preference, user confirmation and the recovery journal reduce risk but cannot make the read-modify-write operation atomic against another process changing the toolbar at exactly the same time. If you do not accept that limitation, cancel and use the manual Command-drag path.

Usage once installed:

- **Click** the toolbar button → **Quick Launch**: opens the current Workspace directly in your Default Target.
- **Shift-click** the toolbar button → **Target Picker**: a small picker to choose any of the four targets for a single launch (this is the Alternate Trigger; it can also be disabled). Hold Shift until the picker is visible.

To remove it, the Settings app shows you how to hold Command and drag the button back out of the toolbar.

## Known limitations

- **Option-click is not supported** as a trigger. Finder reserves Option-click on toolbar items and may close the source window before the Workspace can be resolved. Only Shift-click (or disabled) is offered as the Alternate Trigger.
- **Automatic Finder setup is private and build-specific.** It is enabled only for exact profiled Finder builds; every other build uses the manual Command-drag path. Finder has no public atomic transaction for this preference, so a very small concurrent-update race remains even on a recognized build.
- **Local only.** Go2Codex makes no network requests and performs no telemetry, crash reporting, background monitoring, or auto-update. GitHub stable and preview updates are downloaded manually.
- **Terminal-controlled titles.** Go2Codex does not replace Terminal or iTerm2 title settings. A tab title can still change while the login shell initializes and the foreground process changes to the selected CLI.
- **Uncertain iTerm replies.** If iTerm accepts a create request but its reply is lost or times out, Go2Codex cannot safely determine whether the session exists. It does not retry automatically and asks you to check iTerm first to avoid creating a duplicate session.
- **Apple Silicon only.**

Not in scope: VS Code / Cursor / other editors, a menu-bar resident, session restore or prompt injection, and Mac App Store distribution.

## Building from source

- Xcode 16.2 (Swift 6), targeting arm64 macOS 14.
- Run the unit tests:

  ```sh
  Scripts/test.sh
  ```

The other scripts under `Scripts/` are maintainer workflows for building, verifying, installing, or rolling back local builds. Review them before running them because some operate on an installed application.

## Publishing unsigned GitHub releases (maintainers)

The repository supports two unsigned release channels. A stable release tag is exactly `vX.Y.Z`, where `X.Y.Z` matches `MARKETING_VERSION`; it creates a public GitHub Release. A preview release tag is exactly `vX.Y.Z-preview.N`, where `X.Y.Z` matches `MARKETING_VERSION` and `N` is the positive, no-leading-zero `CURRENT_PROJECT_VERSION`; it creates a GitHub pre-release. Stable status does not change the signing or notarization requirements: both channels are ad-hoc signed, non-notarized arm64 builds and require the Gatekeeper override documented above.

For the current stable release, set `MARKETING_VERSION` to `0.1.1` and `CURRENT_PROJECT_VERSION` to `8` in the reviewed release commit, merge it into `main`, and wait for CI to pass. From a clean, up-to-date `main` checkout, check the release contract and create the annotated stable tag:

```sh
git switch main
git pull --ff-only origin main
Scripts/test-github-release.sh
Scripts/package-github-release.sh --validate-only v0.1.1
git tag -a v0.1.1 -m "Go2Codex 0.1.1"
git push origin v0.1.1
```

Pushing a tag is the publication action; never push a release tag merely to test the workflow. Keep tag-protection rules active for both stable `vX.Y.Z` and preview `vX.Y.Z-preview.N` tags, and never move or delete a published release tag. The workflow builds and verifies an ad-hoc-signed arm64 app, checks the ZIP round trip and SHA-256, and publishes either a public stable GitHub Release or a GitHub pre-release according to the tag. After publication, download both assets, verify the checksum, confirm the documented Gatekeeper override, and manually test the supported Finder and target matrix.

## License

[MIT](LICENSE).
