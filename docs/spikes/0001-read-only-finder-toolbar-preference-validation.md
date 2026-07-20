# Read-only Finder toolbar preference validation

Status: completed as a read-only investigation on 2026-07-17.

## Scope

This investigation checked whether the guarded Finder Toolbar Installer described in ADR 0007 has a technically plausible preference shape on the development Mac. It did not write Finder preferences, restart Finder, or change any toolbar item.

Environment:

- macOS 14.6 (23G80)
- Finder 14.6 (1632.6.3)
- Finder preference domain `com.apple.finder`
- Toolbar preference key `NSToolbar Configuration Browser`

## Direct observation

The current, uncustomized Finder toolbar configuration contains only:

```text
TB Display Mode = 2
TB Icon Size Mode = 1
TB Is Shown = true
TB Size Mode = 1
```

It does not currently contain `TB Item Identifiers` or `TB Item Plists`. Both direct plist inspection and preference-domain reads returned the same shape.

Finder 14.6 itself still references `NSToolbar Configuration Browser`, `TB Item Identifiers`, `TB Item Plists`, and the generic `com.apple.finder.*` toolbar-item namespace. This confirms that the relevant private schema still exists in this Finder build, but does not by itself prove that a particular write is accepted safely.

## Go2Shell v2.5 behavior

Read-only inspection of the current Go2Shell v2.5 application shows that its installer:

- reads and writes `NSToolbar Configuration Browser` in `com.apple.finder`;
- represents custom toolbar items with the identifier `com.apple.finder.loc `, including the trailing space;
- stores numbered entries in `TB Item Plists` alongside `TB Item Identifiers`;
- stores its nested helper application as a file URL dictionary with `_CFURLString` and `_CFURLStringType = 15`;
- synchronizes the preference domain and restarts Finder after installation; and
- synthesizes a hard-coded default item list only when the entire toolbar configuration value is absent, then inserts its helper into that list; and
- does not synthesize that list when the configuration value exists but its item arrays are absent, which is the shape currently observed on this Mac.

No `_CFURLAliasData` field is required by this implementation.

## Conclusion

The core installation mechanism is technically plausible on macOS 14.6: Finder retains the expected schema, and an embedded application can be represented by the same fields Go2Shell uses.

At this read-only stage, automatic installation from the current system-default state was not yet proven safe. Because the item arrays were absent, the installer could not preserve and extend an existing explicit order; it first had to materialize Finder's implicit default order. Go2Shell contained version-dependent hard-coded defaults for a wholly absent configuration, but did not safely handle the scalar-only shape observed here, and its legacy list could not be assumed correct for Finder 14.6.

The conclusion at this boundary was that the guarded installer had to classify this shape as Manual Setup Required until a supported profile was derived and validated, rather than write a guessed configuration. This was an implementation gate, not a change to the intended one-click product experience.

## Next validation boundary

A separately authorized, reversible write test should:

1. capture the exact original toolbar value and a semantic snapshot before mutation;
2. build a harmless Debug Toolbar Launcher and calculate the proposed preference diff without applying it;
3. expose the exact diff for review before any write or Finder restart;
4. apply one narrowly scoped install mutation only after explicit confirmation;
5. restart Finder and verify the visible toolbar item and stored representation;
6. remove only the test item, restart Finder, and compare the restored value with the original snapshot; and
7. treat any unexpected shape or concurrent change as a fail-closed result.

The captured original value is recovery evidence for the experiment. Ordinary product uninstallation must still remove only Go2Codex and must not overwrite later unrelated toolbar changes with a historic snapshot.

## Dry Run prototype result

The native Swift [Finder Toolbar Dry Run prototype](../../prototypes/FinderToolbarDryRun/README.md) implements only reading, planning, snapshotting, and artifact generation. The compiled binary imports `CFPreferencesCopyAppValue` but no preference setter, and has no Finder-restart path.

Running it against the current Finder 14.6 state produced these results:

- the on-disk toolbar value matched the live `CFPreferences` value;
- five planner self-tests passed;
- the recovery snapshot SHA-256 was `f882519ae7ccf91a2033ed21c1b7a1a1bb1f601a5518037d53c486fedce79c84`;
- the Go2Shell-derived comparison would materialize ten legacy default identifiers, insert `com.apple.finder.loc ` at index 8, and add the nested application URL at `TB Item Plists[8]`;
- the report status was `candidate_blocked` and `writeEligible` remained `false`; and
- the unverified default profile and nonexistent illustrative Launcher path remained blockers, while use of the private schema was reported separately as a warning.

The persistent review artifacts are the [recovery snapshot](artifacts/0001/recovery-toolbar.plist), [blocked candidate](artifacts/0001/candidate-toolbar.plist), and [exact semantic diff](artifacts/0001/candidate.diff). The candidate is evidence for review, not an approved write payload.

### Real Debug Launcher candidate

The [Toolbar Launcher Probe](../../prototypes/ToolbarLauncherProbe/README.md) then produced a valid nested application bundle with these properties:

- both outer and nested entries display as `Go2Codex Debug`;
- bundle identifiers are `io.github.czrzchao.go2codex.debug` and `io.github.czrzchao.go2codex.debug.launcher`;
- the nested application is an `LSUIElement`;
- both executables are arm64-only;
- the nested application shows only a local success dialog and exits;
- the bundle uses the `>_` placeholder icon; and
- the nested and outer bundles pass strict ad-hoc code-signature verification.

The Dry Run was repeated with the existing nested Debug Launcher path. The `launcher_missing` blocker disappeared, the preference file still matched live `CFPreferences`, and the recovery hash remained unchanged. At this stage the sole remaining blocker was `unverified_candidate_profile`; the private Finder schema remained a warning.

Additional static inspection of Finder 14.6 found the relevant toolbar delegate selectors and its dynamic `com.apple.finder.*` identifier construction, but no authoritative serialized default-order array. At the end of this read-only investigation, extracting a stronger answer would have required attaching to the running Finder process or observing a materialized configuration, so the investigation stopped at this boundary rather than treating more reverse-engineering guesses as validation.

## Follow-up

The separately authorized [reversible write validation](0002-reversible-finder-toolbar-write-validation.md) subsequently rejected the legacy candidate, derived distinct default and active layouts from Finder's own representation, validated a corrected index-10 candidate, confirmed the visible button and Debug Launcher click, and restored the original toolbar value.
