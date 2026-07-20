# Keep Finder toolbar mutation behind a serialization gate

Go2Codex will not connect its production Settings App to a Finder preference setter unless a public, stable serialization boundary protects the complete final-read-to-persisted-write window. On the validated macOS 14.6 environment that boundary is unavailable, so the Personal MVP exposes read-only installation status and the manual Command-drag setup instead of automatic Install, Repair, or Uninstall.

This decision follows the mandatory concurrency gate in the implementation plan and the [read-only serialization investigation](../spikes/0008-finder-preference-serialization-boundary.md). Public CFPreferences operations can synchronize cached preferences, but they do not offer compare-and-swap, a versioned transaction, or a lock honored by Finder and `cfprefsd`. A final equality check would only narrow the race window: an unrelated toolbar change could still occur before Go2Codex replaces the whole nested toolbar value, be silently lost, and leave a result that looks valid afterward.

The typed Detect, mutation planning, journal validation, semantic verification, and recovery decision tables remain useful and tested. The production pre-mutation gate always receives `FinderToolbarSerializationBoundary.unavailable`, before any journal, preference write, or Finder restart can occur. Manual setup reveals the signed embedded Toolbar Launcher; removal and repositioning remain explicit Finder interactions.

Read-only detection may persist a versioned receipt in Go2Codex's own preferences after the current URL, URL type, AliasRecord, and Launcher identity have all been verified as Installed. This does not mutate Finder and grants no automatic-write capability; it only preserves evidence for later fail-closed status detection.

This ADR supersedes only ADR 0007's assumption that automatic installation can be the Personal MVP's primary setup path. ADR 0007's exact-profile classification, ownership checks, surgical mutation rules, confirmation requirements, and fail-closed behavior remain the requirements if a safe boundary becomes available later.

## Consequences

- The Personal MVP cannot honestly claim one-click automatic Finder installation, repair, or uninstallation.
- First Run still commits its required preferences together, then guides the user through manual Command-drag setup without launching an Agent Target.
- No unsupported lock, direct plist mutation, `cfprefsd` control, Finder suspension, or private XPC protocol enters production.
- A supported Finder profile can improve read-only status classification, but it cannot by itself enable mutation.
- Automatic mutation can be reconsidered only after a documented conditional-write API, system-owned transaction, or public Finder integration closes the entire race window and passes adversarial two-writer tests.

## Considered Options

- A Go2Codex-only lock cannot coordinate Finder, `cfprefsd`, or another preferences client.
- Locking the plist is advisory and does not lock the preferences daemon's cache or atomic replacements.
- Quitting or suspending Finder does not exclude `cfprefsd` or other writers.
- Re-reading immediately before and repeatedly after a write cannot recover a value already overwritten inside the remaining race window.
- Private preference-daemon interfaces would replace a known safety limitation with an undocumented and unstable dependency.
