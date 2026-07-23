# Contributing to Go2Codex

Thank you for helping improve Go2Codex. This document covers local development and validation. The end-user guide lives in [README.md](README.md), and the maintainer release process lives in [docs/RELEASING.md](docs/RELEASING.md).

## Requirements

- An Apple Silicon Mac
- macOS 14 or later
- A full Xcode installation

CI and published releases use Xcode 16.2 for reproducibility. A compatible newer Xcode may work locally, but release consistency is verified against Xcode 16.2.

Check the active developer directory before building:

```sh
xcode-select -p
xcodebuild -version
```

If `xcode-select` reports an invalid developer directory, select the installed Xcode in Xcode Settings or point `xcode-select --switch` at that app's `Contents/Developer` directory.

The project uses Swift 6, an arm64 macOS 14 deployment target, and an Xcode project rather than Swift Package Manager.

## Set up the repository

```sh
git clone https://github.com/CzRzChao/go2codex.git
cd go2codex
Scripts/test.sh
```

Open `Go2Codex.xcodeproj` in Xcode to build the app.

## Validate changes

Run the complete local test suite:

```sh
Scripts/test.sh
```

The suite validates shell safety, release contracts, generated iTerm resources, and Swift unit and platform behavior without installing or launching the app.

In a clean checkout, you can also verify the ad-hoc Release product without publishing or installing it:

```sh
Scripts/package-github-release.sh --verify-build-only
```

Other scripts under `Scripts/` are maintainer workflows, and some operate on an installed application. Review them before running them.

## Documentation changes

`README.md` is the default English end-user guide. `README.zh-CN.md` is its complete Simplified Chinese counterpart. Keep their user-facing sections, commands, release links, and screenshots synchronized; `Scripts/test-github-release.sh` enforces the machine-checkable parts of that contract.

Do not add build or release procedures back to the READMEs. Put contributor instructions here and release procedures in [docs/RELEASING.md](docs/RELEASING.md).

## Pull requests

Keep each pull request focused, explain its user or developer impact, and include the checks used to validate it. Do not commit generated build products, local signing configuration, credentials, or private certificates.
