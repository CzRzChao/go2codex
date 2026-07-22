# Finder Toolbar Dry Run

This Swift prototype reads Finder's current toolbar preference value and creates review artifacts without changing Finder.

It has no installation mode. It does not call a preference setter, run `defaults write`, restart Finder, or modify a toolbar item. When reading the real Finder plist, it also compares the file value with the live `CFPreferences` value and blocks planning if they differ.

Two optional profiles are available. `go2shell-v2.5-modern-unverified` preserves the legacy Go2Shell-derived list as rejected comparison evidence. `finder-14.6-23G80-verified` uses the distinct default and active layouts observed and then validated by the reversible write experiment on Finder 14.6 build 1632.6.3. The planner binds that profile to macOS build 23G80, Finder 14.6, and Finder bundle version 1632.6.3; any mismatch is a blocker. This prototype remains read-only with either profile.

```sh
swift run finder-toolbar-dry-run \
  --launcher /Applications/Go2Codex.app/Contents/Helpers/Go2CodexLauncher.app \
  --output /tmp/go2codex-finder-dry-run \
  --candidate-profile finder-14.6-23G80-verified
```

The output directory contains:

- `recovery-toolbar.plist`: the exact toolbar preference value used for planning, serialized as an XML property list;
- `candidate-toolbar.plist`: the candidate value when one can be calculated;
- `candidate.diff`: a unified diff between the recovery value and candidate; and
- `report.json`: machine-readable status, blockers, hashes, and artifact names.

The recovery artifact is experimental evidence. It is not an ordinary uninstall strategy and must not be restored over unrelated toolbar changes made later.

Recognizing an existing Launcher requires both its standardized file URL and `_CFURLStringType = 15`. A matching URL with a missing or different type is blocked rather than treated as installed.

The prototype includes a dependency-free self-test executable so its planning rules can be checked on a Command Line Tools-only Mac:

```sh
swift run finder-toolbar-dry-run-self-test
```
