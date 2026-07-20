# Use a native Swift trigger-and-handoff app

Go2Codex will be a native Swift macOS 14+ application for Apple Silicon only. One distributed application bundle will contain a Settings App and an embedded Toolbar Launcher as separate entry points sharing a pure Swift core and preference model. The Settings App will be SwiftUI-first, using the SwiftUI application lifecycle and only a thin AppKit adapter where window or application behavior requires it. The short-lived Toolbar Launcher will be AppKit-first for modifier-key handling, Target Picker presentation, application activation, and other system integration. Narrowly scoped Apple Events will integrate with Finder and terminal hosts, without making Node, Electron, or AppleScript the application runtime. The macOS 14 deployment target and `arm64`-only distribution favor modern system APIs and a small build and test surface over support for Ventura, Intel Macs, or Universal binaries.

The repository will commit one native Xcode project containing separate Settings App, Toolbar Launcher, shared core, and test targets. Xcode target dependencies and a Copy Files build phase will embed the Toolbar Launcher and manage the nested signing order. The Personal MVP will not copy CodexBar's SwiftPM-first, manually assembled application bundle.

CodexBar remains a useful implementation reference for the boundary itself: its SwiftUI application entry and Settings scene use a thin AppKit delegate and AppKit-owned system UI, while a separate `CodexBarCore` holds shared logic. Go2Codex adopts that hybrid separation, but follows a Dual-Entry Architecture and Trigger-and-Handoff Lifecycle rather than a resident menu bar architecture. The Toolbar Launcher performs Handoff directly and exits; the Settings App owns configuration only. Neither process performs provider polling, usage monitoring, or session management after Handoff.

## Project Targets

- `Go2Codex`: SwiftUI-first Settings App with a thin AppKit lifecycle adapter only where required.
- `Go2CodexLauncher`: embedded AppKit-first `LSUIElement` application.
- `Go2CodexCore`: pure Swift settings, target, handoff, and Finder installation logic shared by both applications.
- `Go2CodexTests`: focused tests for the shared core and stable boundaries around platform integration.

## Considered Options

- Node or Electron would add a large runtime and slower startup to a small macOS-only system utility.
- A pure AppleScript app would simplify a first prototype but make the settings UI, target model, modifier handling, testing, packaging, and later public distribution harder to maintain.
- A CodexBar-style resident menu bar app would introduce background lifecycle and monitoring responsibilities that are outside Go2Codex's scope.
- A SwiftPM-first main application with a hand-written bundle assembly script, as used by CodexBar, would provide command-line flexibility but make the nested application, resources, build phases, and signing order less visible to a first-time Xcode maintainer.
