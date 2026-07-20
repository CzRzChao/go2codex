# Use a settings app with an embedded toolbar launcher

Go2Codex will ship as one outer `Go2Codex.app` containing two native application entry points. The Settings App is the ordinary Launch Services target and always presents First Run or Settings when opened from Spotlight, Applications, Alfred, `open`, or the Dock. An embedded `LSUIElement` Toolbar Launcher is the application represented in Finder's toolbar and is the only entry point that resolves a Workspace and performs Handoff.

The Toolbar Launcher will directly read the Settings App's shared preference domain, capture the invocation's modifier flags, resolve the frontmost Finder window, present the Target Picker when requested, and execute the selected desktop or CLI Handoff before exiting. Apple Event sending code exists only in this Launcher. It will not forward normal toolbar invocations to the Settings App or infer launch intent from Finder state. If required First Run preferences are absent, it will open the Settings App and exit without attempting Handoff.

First Run will offer the explicit, guarded one-click Toolbar Installation defined by [ADR 0007](0007-use-guarded-finder-preference-editing-for-toolbar-installation.md). If the current Finder toolbar preference structure is unsupported or installation fails without a safe write, it will reveal the embedded Toolbar Launcher and explain the manual Command-drag fallback.

Go2Shell v2.5 is the behavioral and process-architecture reference for this split: its ordinary application owns configuration while an embedded, non-Dock helper reads shared preferences, performs the Finder-to-terminal action directly, and exits. It is also the behavioral reference for one-click installation, but Go2Codex does not reuse Go2Shell code, treat Finder's private preference shape as stable, or adopt its background update-check behavior.

## Consequences

- Launch intent is encoded by the selected executable rather than inferred from unreliable Launch Services context.
- One distributable application contains two separately identified and signed application bundles.
- The Settings App and Toolbar Launcher require a shared preference model and shared Swift launch core without requiring a resident process or normal-launch IPC.
- macOS attributes a nested Launcher's Finder and terminal Automation requests to the outer Go2Codex responsible identity. Both bundles therefore declare the Apple Events entitlement and localized usage description, while ordinary Settings launches send no Apple Events. Personal ad-hoc rebuilds do not guarantee consent continuity; Public Release uses Developer ID.
- An explicit toolbar click can perform Handoff even while the Settings App is open.
- Toolbar Installation is a one-time, user-confirmed operation with automatic installation as the primary path and manual Command-drag as the fallback.

## Considered Options

- A single application could inspect Finder state or launch arguments, but ordinary Launch Services invocations do not reliably identify whether the user clicked Finder's toolbar.
- A Finder Sync extension offers an official Finder integration point, but its toolbar contract presents a menu and introduces extension enablement and lifecycle complexity that conflict with Quick Launch.
- A helper that always forwards to the Settings App would add activation and IPC complexity to a short operation the helper can safely complete itself.
- Unconditionally editing Finder's private toolbar preferences, as though their structure were stable, would be too fragile; ADR 0007 instead limits writes to recognized structures and preserves a manual fallback.
- Shipping the Toolbar Launcher as a second top-level application would make it easier to drag but would clutter Applications and expose an action-only executable to Spotlight and Alfred.
