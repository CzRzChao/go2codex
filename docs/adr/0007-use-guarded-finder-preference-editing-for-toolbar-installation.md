# Use guarded Finder preference editing for toolbar installation

Go2Codex will make one-click Toolbar Installation the primary setup path. After an explicit user action in the Settings App, a native confirmation will offer Cancel or Install and Restart Finder before any state change. Once confirmed, the Finder Toolbar Installer will locate the embedded Toolbar Launcher, read the current user's Finder toolbar preferences, and proceed only when their structure matches a supported macOS shape. It will preserve the identity and order of every unrelated toolbar item, avoid duplicate Go2Codex entries, append Go2Codex at the rightmost available customizable position, record the affected configuration for recovery, write the smallest possible change, and restart Finder so the new item can load. Users remain free to Command-drag the installed item elsewhere afterward.

Toolbar Uninstallation will be equally explicit and surgical: a native confirmation offers Cancel or Uninstall and Restart Finder, and confirmation removes only entries that can be identified as Go2Codex's Toolbar Launcher. If a recognized Go2Codex item instead points to a missing or different Launcher path, Settings will report Needs Repair and offer Cancel or Repair and Restart Finder. Repair replaces the path in place while retaining the item's toolbar position and preventing a duplicate. Cancelling any operation leaves Finder preferences and the running Finder process untouched. Uninstallation will not overwrite the current toolbar with a full pre-installation snapshot because that could discard unrelated changes made later. If installation, detection, repair, or uninstallation cannot recognize the configuration safely, Go2Codex will not write and will instead reveal the Toolbar Launcher with Apple-supported Command-drag instructions.

Release installation is available only while the containing `Go2Codex.app` resides in `/Applications` or `~/Applications`, because Finder stores a path to the nested Toolbar Launcher and moving the outer application would invalidate it. Debug builds may install from a development location for testing, accepting that rebuilding or moving the bundle can require reinstallation.

Go2Shell v2.5 demonstrates that a non-sandboxed macOS application can install an embedded helper this way without administrator or Accessibility privileges. Its behavior is the reference, but its implementation is not available as source and does not make Finder's undocumented preference format a supported API.

## Validation Status

A [read-only validation on Finder 14.6](../spikes/0001-read-only-finder-toolbar-preference-validation.md) confirmed that Finder retains the expected private schema and that Go2Shell v2.5 uses the described nested-helper representation. Its legacy hard-coded list did not safely model the scalar-only toolbar shape on this Mac.

The subsequent [reversible write validation](../spikes/0002-reversible-finder-toolbar-write-validation.md) rejected that legacy candidate: after restart, Finder moved the generic custom identifier from active index 8 to 10 and discarded `TB Item Plists`, leaving no Launcher URL. A corrected profile separated Finder's observed nine-item default array from its active layout, placed the custom identifier and URL at index 10, and survived restart. Finder added only `_CFURLAliasData`; the identifier, index, URL, and URL type remained intact. Three consecutive semantic storage checks passed, the button was visible, clicking it launched the Debug helper, and the exact original value was restored and reverified after a second Finder restart.

The profile is validated only for macOS 14.6 build 23G80 and Finder 14.6 build 1632.6.3. Other builds remain unsupported for automatic writes until separately profiled and reversibly tested; they must fail closed to manual setup.

## Consequences

- Personal MVP setup can match Go2Shell's one-click installation experience.
- First Run exposes one Complete Setup and Install in Finder action rather than separate install and Save Only choices. It commits the required preferences before presenting the restart confirmation; only actively cancelling that confirmation or encountering an installation failure produces a saved-but-uninstalled state, which can be retried later from Settings.
- The installer must maintain version-specific readers and writers for every supported Finder preference shape and test them on each supported macOS release.
- Installation is idempotent, and an unknown or malformed structure fails closed without changing Finder preferences.
- Installation is successful only after Finder restarts and repeated disk/live reads converge on a recognized semantic representation. Staging the candidate or requiring byte-for-byte equality before Finder finishes enriching the URL is not a success criterion.
- The generic `com.apple.finder.loc ` identifier is not Go2Codex ownership evidence by itself. Detection, repair, and removal also require one uniquely matching Launcher URL with the expected URL type; an orphaned or ambiguous identifier fails closed.
- A verified materialization profile is bound to the exact macOS build, Finder short version, and Finder bundle version on which it was reversibly tested. Selecting it on any other environment is a blocker, not a warning.
- Before each preference mutation, the transaction journal must persist its intent, schema and identity fields, recovery value, and expected result or hash. Recovery must be a tested decision over the journal, disk value, and live value so a crash between the preference write and the next journal update remains resumable.
- Exact recovery and surgical removal have different expected final values. A surgical operation derives and records its expected result from the current toolbar, preserves concurrent changes, and verifies that result after restart instead of requiring the historic original snapshot.
- Finder-added alias data cannot silently replace Launcher identity. If it is actionable, the installer must resolve it to the expected signed embedded Launcher; malformed, unresolvable, or conflicting alias data fails closed.
- The installer verifies that the nested Launcher belongs to the signed outer application and has the expected architecture and designated requirement, rather than trusting a matching path, bundle identifier, or executable bit alone.
- Initial placement is the rightmost available customizable position; installation never reorders existing toolbar items, while later user-driven Command-drag repositioning remains supported.
- Moving or renaming the same verified build can produce Needs Repair; a rebuilt or updated identity fails closed to Manual Setup Required. Repair is explicit, changes only the recognized stale Launcher path, and retains the toolbar item's position.
- Finder visibly restarts after a successful install, repair, or uninstall, so the user must be warned before each restart.
- A successful install returns to the still-open Settings Window and reports Installed; it does not launch a target or treat installation as a Handoff test.
- Recovery data is for repairing an interrupted or corrupt write, not for replacing the user's later toolbar configuration during ordinary uninstall.
- Manual Command-drag remains a documented, supported fallback for compatibility and recovery.
- Public releases inherit ongoing maintenance risk from relying on undocumented Finder state despite using Developer ID signing and notarization.

## Considered Options

- Manual Command-drag alone uses an Apple-supported interaction and avoids private state, but adds friction to the primary setup and is less approachable for users unfamiliar with Finder toolbar customization.
- A Finder Sync extension uses a public extension point, but its toolbar contract presents a menu and introduces enablement and lifecycle complexity that conflict with Quick Launch.
- An unconditional private-preference write would be simpler, but could corrupt or reset a toolbar when Apple changes Finder's schema.
- A guarded automatic installer with a manual fallback preserves the desired setup experience while containing, rather than eliminating, the compatibility risk.
