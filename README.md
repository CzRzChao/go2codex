English | [简体中文](README.zh-CN.md)

<!-- readme-section: overview -->

# Go2Codex

Open the folder shown in Finder in Codex or Claude with one toolbar click.

Go2Codex adds one button to the Finder toolbar. It passes the exact folder shown by the frontmost Finder window to Codex App, Codex CLI, Claude Desktop, or Claude Code CLI. The public package contains one top-level `Go2Codex.app`; its Finder Launcher is embedded inside that app.

[Download the latest stable release](https://github.com/CzRzChao/go2codex/releases/tag/v0.1.1) · [All releases](https://github.com/CzRzChao/go2codex/releases) · [Security policy](SECURITY.md)

> [!WARNING]
> The current public build is ad-hoc signed, not Developer ID signed, and not notarized. A browser-downloaded copy is normally blocked by Gatekeeper on first launch. The GitHub release being marked Stable does not change its Apple signing status.

<p align="center">
  <img src="docs/assets/settings-en.png" alt="Go2Codex settings in English" width="640">
</p>

<!-- readme-section: quick-start -->

## 60-second quick start

1. Download both assets from [the current stable release](https://github.com/CzRzChao/go2codex/releases/tag/v0.1.1):
   - `Go2Codex-0.1.1-macos-arm64.zip`
   - `Go2Codex-0.1.1-macos-arm64.zip.sha256`
2. In Terminal, verify the ZIP from the directory where both files were downloaded:

   ```sh
   cd ~/Downloads
   shasum -a 256 -c Go2Codex-0.1.1-macos-arm64.zip.sha256
   ```

3. Double-click the ZIP, then move `Go2Codex.app` to `/Applications` or `~/Applications` before opening it.
4. Open Go2Codex once. If macOS blocks it, follow the [Gatekeeper steps](#download-checksum-and-gatekeeper) below.
5. Choose a Default Target, Default Terminal Host, and whether CLI sessions should use a New Tab or New Window. If iTerm2 is not installed, choose Terminal.
6. Choose **Complete Setup and Install in Finder**. If automatic setup is unavailable, choose **Complete Setup and Show Manual Setup** and follow the Command-drag instructions.
7. Open a regular folder in Finder and click the Go2Codex toolbar button. Shift-click and keep Shift held until the one-time Target Picker appears.

The Settings window itself does not request Automation access. The first real toolbar launch asks for Finder Automation access; the first CLI launch also asks for Terminal or iTerm2 Automation access.

<!-- readme-section: requirements -->

## Requirements

- An **Apple Silicon** Mac. Intel and Universal builds are not published.
- **macOS 14 Sonoma** or later.
- At least one supported coding agent already installed:
  - Codex App or Claude Desktop for a desktop target; and/or
  - `codex` or `claude` available in your shell for a CLI target.
- Terminal.app or iTerm2 for CLI targets. iTerm2 handoff requires the account login shell to be an executable **zsh**, **bash**, or **fish**.

Go2Codex does not install or bundle Codex, Claude, or iTerm2. Xcode and a paid Apple Developer account are not required to use the prebuilt release.

<!-- readme-section: download-and-gatekeeper -->

## Download, checksum, and Gatekeeper

### Download and verify

Download the ZIP and its checksum file from [the current stable GitHub Release](https://github.com/CzRzChao/go2codex/releases/tag/v0.1.1) into the same directory:

- `Go2Codex-0.1.1-macos-arm64.zip`
- `Go2Codex-0.1.1-macos-arm64.zip.sha256`

Verify before extracting:

```sh
shasum -a 256 -c Go2Codex-0.1.1-macos-arm64.zip.sha256
```

Continue only if the command reports `OK` and you trust this repository. Optional preview tags use the `vX.Y.Z-preview.N` form; previews are early-testing builds and do not replace the stable release.

### First launch through Gatekeeper

Before the first launch, move the app to `/Applications` or `~/Applications`. Running it from Downloads can use App Translocation, and Go2Codex intentionally refuses to install a Finder toolbar item from that temporary location.

Public stable and preview builds are ad-hoc signed but are **not Developer ID signed or notarized**. A quarantined browser download may show “Apple could not verify” or recommend moving the app to Trash.

After the first blocked launch:

1. Open **System Settings** → **Privacy & Security**.
2. Scroll to **Security** and choose **Open Anyway** for Go2Codex.
3. Authenticate and confirm **Open**.

Do not remove the quarantine attribute merely to bypass this review. The Open Anyway option may be unavailable on an organization-managed Mac. See [SECURITY.md](SECURITY.md) for the application’s security posture.

<!-- readme-section: finder-toolbar -->

## Finder toolbar setup

The public package has one searchable `Go2Codex.app`. Its toolbar Launcher lives at `Go2Codex.app/Contents/Helpers`, so no second top-level app needs to be installed.

### Automatic setup

1. Put `Go2Codex.app` in `/Applications` or `~/Applications`.
2. Complete the settings shown on first launch.
3. Choose **Complete Setup and Install in Finder** or, after initial setup, **Install in Finder**.
4. Review the warning and confirm **Install and Restart Finder**. Finder briefly restarts.

Automatic install, repair, and removal are experimental. They preserve unrelated toolbar items, write a recovery journal before changing the current user’s private Finder toolbar preference, restart Finder, and verify the result.

The current stable release enables automatic changes only for these exact environments:

- macOS build `23G80` with Finder `14.6 (1632.6.3)`
- macOS build `25F84` with Finder `26.4 (1828.5.2)`

A different macOS/Finder patch level, an unknown toolbar shape, or a failed safety check normally falls back to manual setup. That fallback does not mean the app itself failed to install.

### Manual setup

1. Choose **Show Manual Setup**, then **Show in Finder**.
2. If an old Go2Codex button is present, hold Command (⌘) and drag it out of the toolbar.
3. In the Finder window that reveals the current embedded Launcher, hold Command (⌘) and drag Go2Codex into the toolbar.

Finder has no public atomic API for this private toolbar preference. The confirmation and recovery journal reduce risk, but cannot eliminate the very small race with another process changing the toolbar at the same moment. Use the manual Command-drag path if you do not accept that limitation.

<!-- readme-section: targets-and-terminal -->

## Targets and terminal configuration

| Agent Target | Launch behavior | Terminal Host |
| --- | --- | --- |
| Codex App | Opens a `codex:` deep link after verifying that its registered handler has bundle identifier `com.openai.codex` | — |
| Codex CLI | Runs `cd <folder> && codex` | Terminal.app / iTerm2 |
| Claude Desktop Code | Opens a `claude:` deep link after verifying that its registered handler has bundle identifier `com.anthropic.claudefordesktop` | — |
| Claude Code CLI | Runs `cd <folder> && claude` | Terminal.app / iTerm2 |

Settings checks desktop URL handlers by exact bundle identifier and marks unavailable targets accordingly. If iTerm2 is not installed, Settings marks it unavailable and does not allow it to be selected; choose Terminal and continue. Desktop targets do not use the Terminal Host setting, but first-run setup still asks for one so Shift-click can launch a CLI target later.

### CLI status

Settings checks `codex` and `claude` together in one background account-login-shell process. No terminal window is opened, but zsh, bash, or fish startup files can run during the short probe.

| Status | Meaning |
| --- | --- |
| **Available** | The background login shell found an executable command. |
| **Not Found** | That shell did not find the command. Install it or update `PATH`, then choose **Refresh CLI Status**. |
| **Couldn’t Verify** | The shell was unsupported, timed out, failed to start, or produced an inconclusive result. This does not mean the CLI is absent. |

All three statuses are advisory. They do not block saving or launching because a real Terminal or iTerm profile may configure the shell differently. Verify from the terminal you plan to use when necessary:

```sh
command -v codex
command -v claude
```

### New Tab or New Window

- **New Tab** asks the selected terminal for a new tab. Terminal may natively fall back to a new window when no suitable window exists.
- **New Window** asks for a separate window.
- Both placements are supported for Codex CLI and Claude Code CLI in Terminal.app and iTerm2.

Go2Codex submits only the fixed `codex` or `claude` command after entering the Workspace. Terminal handoff fails closed if it cannot uniquely identify the new session; it does not guess a target or automatically retry, so an empty tab or window can remain. iTerm2 receives the login shell and CLI command as the session’s initial command, and an uncertain iTerm result is not automatically retried.

<!-- readme-section: usage -->

## Usage

- **Click** the Finder toolbar button for Quick Launch into the Default Target.
- **Shift-click** for the Target Picker. Keep Shift held until the picker is visible. The Alternate Trigger can also be disabled in Settings.

The **Workspace** is the actual folder shown by the frontmost Finder window. Go2Codex does not use Finder’s selected items, infer a Git root, or substitute another directory when the location cannot be resolved. A real Home or Desktop folder is valid when Finder is actually showing it; virtual locations such as Recents are not.

<!-- readme-section: update-and-uninstall -->

## Updating and fully uninstalling

### Update

1. Download and verify the new ZIP and checksum.
2. Quit Go2Codex and replace the existing app in `/Applications` or `~/Applications`.
3. Open the replacement and complete any new Gatekeeper prompt.
4. Check **Finder Toolbar** in Settings:
   - choose **Repair in Finder** if it appears; or
   - for a manual installation, Command-drag the old button out and add the current embedded Launcher again.
5. Launch one target you actually use. If macOS requests Finder, Terminal, or iTerm2 Automation access again, review and grant it then.

Because public builds are ad-hoc signed, macOS may ask for Finder, Terminal, or iTerm2 Automation access again after an update.

### Full uninstall

1. Remove the toolbar button before deleting the app:
   - choose **Uninstall from Finder** when automatic removal is available; or
   - choose **Show Removal Instructions**, then hold Command (⌘) and drag the button out of the Finder toolbar.
2. Confirm the button is gone, quit Go2Codex, and move `Go2Codex.app` from Applications to Trash.
3. Optional preference cleanup:

   ```sh
   defaults delete io.github.czrzchao.go2codex
   ```

4. Optional recovery-data cleanup: in Finder choose **Go** → **Go to Folder…**, enter `~/Library/Application Support/io.github.czrzchao.go2codex`, and move that folder to Trash. Do this only after toolbar removal is confirmed, because the folder can contain the recovery journal.
5. Optional Automation cleanup:

   ```sh
   tccutil reset AppleEvents io.github.czrzchao.go2codex
   ```

The **Reset Settings** action appears only when saved settings need recovery. It is not a general uninstaller and does not remove the Finder button, app, recovery data, or Automation permissions.

<!-- readme-section: troubleshooting -->

## Troubleshooting

### Automation was denied, or no permission prompt appeared

Permission is requested on demand, not while viewing Settings or installing the toolbar button. First click the Finder toolbar button; a CLI target requests terminal access only when it is actually launched.

If a launch fails, choose **Open Automation Settings** in the error dialog, or open **System Settings** → **Privacy & Security** → **Automation** manually. Under Go2Codex, enable Finder and the terminal you selected. Go2Codex does **not** require Accessibility, Full Disk Access, Screen Recording, or Notifications.

If the entry is missing or a previous denial is stuck, quit Go2Codex, run the following scoped reset, reopen the app, and trigger the launch again:

```sh
tccutil reset AppleEvents io.github.czrzchao.go2codex
```

### Finder reports that the location is not a folder

Open a regular, accessible folder in Finder and try again. Recents, search results, Smart Folders, and other virtual views cannot be used as a Workspace. Go2Codex also fails safely when Finder has no open window.

### CLI shows Not Found or Couldn’t Verify

Run `command -v codex` or `command -v claude` in the terminal profile you intend to use. Install or repair the CLI’s `PATH`, then choose **Refresh CLI Status**. These advisory states never block saving or launching.

### Terminal leaves an empty tab or window

Go2Codex did not submit the CLI command because it could not safely identify a unique target. Close the empty session, wait for Terminal to finish other window or tab changes, and try again. If New Tab repeatedly fails, select New Window in Settings. Do not create, close, reorder, or move Terminal tabs or windows during the brief handoff.

If another Go2Codex Terminal handoff is already running, wait for it to finish before retrying.

### iTerm2 reports an unknown outcome

iTerm2 may already have created the requested session even though Go2Codex did not receive a conclusive reply. Check iTerm2 before retrying to avoid creating a duplicate session.

### Titles change while a CLI starts

Terminal and iTerm2 control their own titles. A title can change while the login shell initializes and the foreground process changes to Codex or Claude; this does not mean Go2Codex is repeatedly submitting the command.

### Report a problem

Use **Copy Diagnostics** in the error dialog and attach the redacted record to a [GitHub issue](https://github.com/CzRzChao/go2codex/issues). Release diagnostics omit the complete Workspace path and generated command. Report suspected vulnerabilities privately through a [GitHub Security Advisory](https://github.com/CzRzChao/go2codex/security/advisories/new), as described in [SECURITY.md](SECURITY.md).

<!-- readme-section: known-limitations -->

## Known limitations

- **Option-click is not supported.** Finder reserves it and may close the source window. Use Shift-click or disable the Alternate Trigger.
- **Automatic Finder setup is private and build-specific.** Unrecognized builds use manual setup, and a very small concurrent-update race remains on recognized builds.
- **A failed automatic Finder action may not expose the manual shortcut immediately.** On a recognized build, Settings can continue to show Install or Repair after an execution failure. Manual Command-drag still works by revealing `Go2Codex.app/Contents/Helpers/Go2CodexLauncher.app`, but that fallback is not directly exposed in this state.
- **Apple Silicon only.** No Intel or Universal package is published.
- **No automatic updates.** Stable and preview updates are downloaded and installed manually.
- **Terminal-controlled titles.** Go2Codex does not override Terminal or iTerm2 title behavior.
- **Uncertain iTerm replies are not retried.** Check iTerm2 before retrying manually.
- **Go2Codex itself is local-only.** It makes no network requests and performs no telemetry, crash reporting, or background monitoring. Coding agents, terminals, shells, and shell startup files that Go2Codex invokes are separate software and may have their own network behavior or side effects.

Not in scope: VS Code, Cursor, other editors, a resident menu-bar app, session restore, arbitrary prompt injection, Mac App Store distribution, or automatic installation of coding agents.

<!-- readme-section: building-from-source -->

## Building from source

A full Xcode installation is required to build from source. CI and published Release builds pin Xcode 16.2 for reproducibility. A compatible newer Xcode may work for local development, but release consistency is verified against 16.2. Check the active developer directory before building:

```sh
xcode-select -p
xcodebuild -version
```

If `xcode-select` reports an invalid developer directory, select the installed Xcode in Xcode Settings or point `xcode-select --switch` at that app’s `Contents/Developer` directory.

The project uses Swift 6, an arm64 macOS 14 deployment target, and an Xcode project rather than Swift Package Manager.

```sh
git clone https://github.com/CzRzChao/go2codex.git
cd go2codex
Scripts/test.sh
```

Open `Go2Codex.xcodeproj` in Xcode to build the app. In a clean checkout, maintainers can also verify the ad-hoc Release product without publishing or installing it:

```sh
Scripts/package-github-release.sh --verify-build-only
```

Other scripts under `Scripts/` are maintainer workflows and some operate on an installed application. Review them before running them.

<!-- readme-section: publishing -->

## Publishing GitHub releases

The repository supports two public release channels:

- Stable tag: `vX.Y.Z`, where `X.Y.Z` equals `MARKETING_VERSION`.
- Preview tag: `vX.Y.Z-preview.N`, where `X.Y.Z` equals `MARKETING_VERSION` and `N` equals the positive, no-leading-zero `CURRENT_PROJECT_VERSION`.

Both channels publish ad-hoc-signed, non-notarized arm64 builds. “Stable” describes the GitHub Release channel only.

The stable release recorded in `Config/PublishedRelease.xcconfig` is already published, and its protected tag must not be recreated. This value tells the two READMEs which successful stable release to present; it is intentionally independent of the version currently being built.

For every new build, increment `CURRENT_PROJECT_VERSION` in `Config/Base.xcconfig`. Change `MARKETING_VERSION` only when the target product version changes. A preview must use its current build number as `N`; preparing or publishing a preview must not change `PUBLISHED_STABLE_VERSION`.

From a clean checkout, choose either `stable_tag` or `preview_tag` below. The preflight refuses a dirty tree, a local commit that is not exactly `origin/main`, or a tag that already exists locally or remotely:

```sh
set -euo pipefail

test -z "$(git status --porcelain)"
git switch main
git fetch --no-tags origin "refs/heads/main:refs/remotes/origin/main"
git merge --ff-only origin/main
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"

release_version="$(awk -F= '/^[[:space:]]*MARKETING_VERSION[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' Config/Base.xcconfig)"
build_version="$(awk -F= '/^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' Config/Base.xcconfig)"
stable_tag="v${release_version}"
preview_tag="v${release_version}-preview.${build_version}"
release_tag="" # Set to "$stable_tag" or "$preview_tag".

case "$release_tag" in
    "$stable_tag"|"$preview_tag") ;;
    *) echo "Choose a stable or preview release tag." >&2; exit 64 ;;
esac
test -z "$(git tag --list "$release_tag")"
remote_tag_refs="$(git ls-remote --tags origin "refs/tags/${release_tag}")"
test -z "$remote_tag_refs"
Scripts/test-github-release.sh
Scripts/package-github-release.sh --validate-only "$release_tag"
git tag -a "$release_tag" -m "Go2Codex ${release_tag#v}"
git push origin "refs/tags/${release_tag}"
```

Pushing a release tag is the publication action; never push one merely to test the workflow. Keep stable and preview tag-protection rules active, and never move or delete a published release tag.

The GitHub Actions workflow builds and verifies the app, checks the ZIP round trip and SHA-256, then publishes the matching stable release or pre-release. After publication, download both assets, verify the checksum, confirm the Gatekeeper instructions, and manually test the supported Finder and target matrix.

Keep `PUBLISHED_STABLE_VERSION` pointing to the previous successful stable release throughout preview work and the stable publication itself. Only after a new stable workflow succeeds and its downloaded assets pass verification, update `Config/PublishedRelease.xcconfig`, the stable links, the asset names, and any release-specific prose in both READMEs in a follow-up documentation pull request. The README contract test keeps the machine-checkable values synchronized.

<!-- readme-section: license -->

## License

[MIT](LICENSE).
