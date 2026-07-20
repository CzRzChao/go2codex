# Use a draggable app for the Finder toolbar

Status: Superseded by [ADR 0006](0006-use-a-settings-app-with-an-embedded-toolbar-launcher.md) and [ADR 0007](0007-use-guarded-finder-preference-editing-for-toolbar-installation.md).

This decision originally packaged the same standalone application as both the ordinary settings entry point and the Finder toolbar item. That preserves one-click launch but cannot reliably distinguish an explicit toolbar invocation from a launch through Spotlight, Applications, Alfred, or `open`.

The toolbar item now points to an embedded Toolbar Launcher rather than the Settings App. Manual Command-drag remains a compatibility fallback, while a guarded one-click installer is the primary setup path.

## Considered Options

- A Finder Sync extension provides a system-managed toolbar item, but necessarily adds a menu interaction before launch.
- A draggable application preserves the required one-click action and remains the safest compatibility path, but it adds avoidable setup friction when the current Finder toolbar preference structure is recognized.
