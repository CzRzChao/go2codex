# GitHub Preview Release SOP

This SOP publishes an Apple Silicon ZIP through GitHub Releases without a paid Apple Developer account. The result is an ad-hoc-signed, non-notarized preview. It is public and downloadable, but it is not the stable Public Release defined by the project.

## Scope

The preview channel produces exactly two assets:

- `Go2Codex-X.Y.Z-preview.N-macos-arm64.zip`
- `Go2Codex-X.Y.Z-preview.N-macos-arm64.zip.sha256`

It does not produce a DMG, Homebrew Cask, Intel or Universal build, Sparkle feed, installer package, or automatic updater.

## Release contract

- `MARKETING_VERSION` in `Config/Base.xcconfig` remains numeric `X.Y.Z`.
- A preview tag must be exactly `vX.Y.Z-preview.N`, where `N` is a positive integer without a leading zero.
- The tag's `X.Y.Z` must equal `MARKETING_VERSION`.
- `N` must equal the positive integer `CURRENT_PROJECT_VERSION`, so every published preview carries the bundle build number in its tag and artifact name.
- The tagged commit must be clean, must be the workflow checkout's `HEAD`, and must already be reachable from `main`.
- Immediately before publication, the workflow fetches the remote tag and `main` again. It refuses to publish unless the tag still resolves to the event's exact commit and that commit is still reachable from the refreshed `main`.
- Stable `vX.Y.Z` tags are rejected by the unsigned packaging script. They are reserved for a future Developer ID-signed and notarized release.
- The GitHub release is always marked as a pre-release and is explicitly prevented from becoming the repository's latest stable release.

The contract can be checked without Xcode:

```sh
./Scripts/package-github-release.sh --validate-only v0.1.0-preview.1
./Scripts/test-github-release.sh
```

Every pull request and push to `main` also runs the packaging script in non-publishing verification mode:

```sh
./Scripts/package-github-release.sh --verify-build-only
```

That mode requires a clean checkout, builds and verifies the same ad-hoc arm64 Release product with warnings treated as errors, and then removes its work directories. It does not require a tag and cannot create a ZIP, checksum, GitHub tag, or GitHub Release.

## Automated workflow

Pull-request and `main` CI first run shell syntax checks, the SOP safety suite, release-contract checks, unit tests with warnings treated as errors, and the real Release-product verification described above. Pushing a matching tag then triggers `.github/workflows/release.yml`. The release workflow:

1. Checks out the complete tagged history and verifies Xcode 16.2.
2. Runs shell syntax checks, the SOP safety suite, release-contract tests, generated iTerm resource verifier, and unit tests with warnings treated as errors.
3. Builds the existing `Go2Codex` Xcode scheme in Release configuration for arm64 with explicit ad-hoc signing.
4. Runs `Scripts/verify-app.sh` against the outer app and embedded Launcher.
5. Creates a versioned ZIP, checks every archive entry, extracts it with `ditto`, and verifies the extracted app against the original product.
6. Generates and verifies the SHA-256 checksum.
7. Creates a GitHub pre-release with an unavoidable non-notarized-build warning.

The workflow does not install or launch the app and does not modify Finder, TCC, Terminal.app, or iTerm2 state.

## One-time repository protection

Before the first preview, create an active GitHub tag ruleset targeting `v*-preview.*`. Enable **Restrict updates** and **Restrict deletions**, with no routine bypass actor. Initial tag creation remains allowed, but an existing release tag cannot be moved or deleted. The workflow also re-fetches the tag immediately before publishing, but that check is not a substitute for server-side tag protection.

## Publishing

Before tagging, review the current manual validation record and either complete its pending checks or explicitly accept the documented preview risks. Merge the reviewed release commit to `main`, wait for CI to pass, then create and push an annotated tag:

```sh
git checkout main
git pull --ff-only origin main
git tag -a v0.1.0-preview.1 -m "Go2Codex 0.1.0 preview 1"
git push origin v0.1.0-preview.1
```

Pushing the tag is the publication action. Do not push it merely to test the workflow; use a pull request and the contract test for review first.

After publication, download both assets from GitHub on a separate account or Mac, verify the checksum, extract the ZIP, confirm the documented Gatekeeper override, and run the supported Finder/target matrix. Because every preview is ad-hoc signed, an update may cause macOS to request Finder, Terminal, or iTerm Automation consent again; verify the prompts and the app's entry under **System Settings** → **Privacy & Security** → **Automation**. A packaging pass is not evidence that the real Finder, Automation, or terminal interaction passed.

## Future signed release

When a Developer ID Application certificate and notarization credentials become available, keep GitHub Releases and ZIP distribution but add Developer ID signing, `notarytool` submission, ticket stapling, Gatekeeper assessment, and a clean-machine installation test. Only that workflow may accept stable `vX.Y.Z` tags.
