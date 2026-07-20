# Known limitations

Deliberately unaddressed low-severity issues. Each was reviewed and left as-is
because the fix carries more risk than the low-probability failure it prevents.
Revisit any of these if its stated assumption changes.

## Launch Services open has no local timeout

The desktop handoff (`WorkspaceDesktopHandoffPlatform.open`) and the Settings
opener wrap a Launch Services completion handler with no local timeout. If
Launch Services never invokes the handler, the accessory launcher process would
stay alive and the invocation gate would remain `.active`. Launch Services has
its own internal timeout, so this is low probability; unlike the terminal path,
there is no additional local timeout as a backstop.

*Assumption:* Launch Services always eventually calls back.

## Reopen during the finishing window can be dropped

After a successful handoff, the launcher sets its gate to `finishing` and calls
`NSApp.terminate`. A reopen event that arrives in the narrow window between the
terminate request and process exit is ignored (`begin()` returns false,
`applicationShouldHandleReopen` returns false). If Launch Services delivered
that reopen to the terminating instance instead of spawning a fresh process,
that single click would be lost. Narrow race, low severity.

*Assumption:* Launch Services routes a fresh invocation to a new process while
one is terminating.

## Stale-path detection treats an unmounted volume as missing

Finder toolbar repair status uses `FileManager.fileExists` to decide whether a
recorded launcher path is stale. A path on a temporarily unmounted volume is
reported as missing and the item is classified "Needs Repair". This only
affects the read-only status label; production builds never write or repair the
Finder toolbar, so there is no destructive consequence.

*Assumption:* The recorded launcher lives on the startup disk in practice.

## Preferences `update` has no compare-and-swap

`SettingsPreferencesStore.update` reads the current envelope, applies a change,
and writes back without verifying the on-disk snapshot is unchanged (unlike the
canonical-rewrite path, which uses a compare-and-swap). Today there is only one
writer — the Launcher is strictly read-only and the Settings app is a single
instance — so no update is lost. If a second writer is ever introduced, add a
compare-and-swap to the update path.

*Assumption:* Exactly one process ever writes the preferences envelope.
