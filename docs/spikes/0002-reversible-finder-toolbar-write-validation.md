# Reversible Finder toolbar write validation

Status: completed on the development Mac on 2026-07-18.

## Scope

This controlled experiment tested the write boundary left open by [the read-only investigation](0001-read-only-finder-toolbar-preference-validation.md). It used a harmless arm64 Debug Toolbar Launcher, an exact recovery snapshot, transaction journals, explicit Finder restarts, post-restart storage checks, a human visibility and click check, and a final recovery verification.

Environment:

- macOS 14.6 (23G80)
- Finder 14.6 (1632.6.3)
- Finder preference domain `com.apple.finder`
- Toolbar preference key `NSToolbar Configuration Browser`

The original scalar-only toolbar value had SHA-256 `f882519ae7ccf91a2033ed21c1b7a1a1bb1f601a5518037d53c486fedce79c84`. Direct plist reads and live `CFPreferences` reads matched before each candidate installation.

## Rejected legacy candidate

The first candidate used the Go2Shell-derived legacy default and active identifier lists, `com.apple.finder.loc ` at active index 8, and the Debug Launcher URL at `TB Item Plists[8]`. Its SHA-256 was `fc9baf65596ec62a26e5c6ea8325aa583960d65ef36b3cfd397a881177c16b53`.

After Finder restarted, it produced a different representation:

- the default array contained 9 identifiers;
- the active array contained 13 identifiers;
- the generic custom identifier appeared at active index 10; and
- `TB Item Plists` was absent, so no Launcher URL remained.

The normalized value had SHA-256 `5b3fc7c1ea919aeaecd01b823ec5d54ba8fb7a43edc2fe25377d243e8083120f`. A transient disk/live disagreement caused the transaction verifier to fail closed. The hash-locked recovery path required the disk value to match the captured normalized artifact and the live value to match either that artifact or the staged candidate; it then staged the exact original, restarted Finder, and verified three consecutive original-state matches.

The most plausible explanation is that the legacy profile confused Finder's default identifiers with its active layout: Finder moved the custom identifier from 8 to 10, while the URL mapping remained associated with 8 and was discarded. That explanation was a hypothesis at this stage, not yet a conclusion.

## Validated Finder 14.6 candidate

The second profile separated Finder's observed default and active layouts. Its default array is:

```text
BACK, SWCH, Space, ARNG, SHAR, LABL, ACTN, Space, SRCH
```

Its active baseline is:

```text
BACK, FlexibleSpace, SWCH, Space, ARNG, ACTN, Space,
SHAR, LABL, FlexibleSpace, FlexibleSpace, SRCH
```

The candidate inserts `com.apple.finder.loc ` at active index 10 and stores the Debug Launcher URL only at `TB Item Plists[10]`. Its SHA-256 was `4b53ff338769cfd7380cf7e0a64187ed2b720c9176f06b63ec8a06aa92de746e`.

Finder preserved the default array, active array, index 10, file URL, and `_CFURLStringType = 15`. It enriched the item dictionary with a non-empty `_CFURLAliasData` value. After that enrichment reached both disk and live preferences, the stored representation stabilized with SHA-256 `a5242e8c6850e8b3759170427d98e035698aca058246a20ef399fe9bd462ebc3` on this machine.

The initial transaction binary required byte-for-byte candidate equality. It correctly refused the normal Finder enrichment and performed no ambiguous cleanup. After the enriched disk and live values converged and were captured, a reviewed semantic verifier was built and run against the unchanged installed state. It accepts either the exact candidate or this constrained Finder enrichment: all outer keys and values must match, the only additional item field may be non-empty `_CFURLAliasData`, and the identifier, index, URL, and URL type must remain exact. Three consecutive disk/live semantic checks then passed.

The exact-only binary had SHA-256 `cadf8d36323c72366f1e0ca72a25c4f120627a223057b83ec229c3dec0a0225d`; the semantic-verifier binary had SHA-256 `e787d48a6406e855e335d1eb9d72f42f7f67a3f7db758fdd5ce6ce574484acd3`. The experiment wrapper now points to the latter, but the evidence sequence remains exact-only rejection followed by semantic verification of the same Finder state.

The user then confirmed that the `>_` button was visible in Finder and that clicking it displayed the Debug Launcher's success dialog. This validated storage, rendering, and application launch for this exact Finder build.

The semantic verifier checks that alias data is the only extra field and is non-empty; it does not decode the private alias record. The real 566-byte alias plus the successful click supplied end-to-end evidence for this experiment. A product implementation must validate that any actionable alias resolves to the expected signed Launcher, or fail closed when it cannot do so.

## Recovery result

After the UI check, the transaction recognized that the only difference from the reviewed candidate was Finder's alias enrichment. It restored the exact original snapshot, restarted Finder, required three consecutive matching disk/live reads, and returned the journal to `restored_verified`. The final toolbar hash was again `f882519ae7ccf91a2033ed21c1b7a1a1bb1f601a5518037d53c486fedce79c84`.

Exact snapshot recovery is valid only for this short, controlled experiment where the recognized Finder enrichment was the sole intervening change. Product Toolbar Uninstallation must still identify the Launcher by its URL and remove only that item; it must not replace later user changes with an old snapshot.

## Conclusion

The scalar-only Finder toolbar shape on macOS 14.6 build 23G80 now has a validated, build-specific materialization profile. Installation success means that Finder has restarted, disk and live preferences have converged on a recognized semantic representation, the Launcher URL is still paired with the custom identifier, and no unexpected change occurred. Merely staging the candidate is not success.

`com.apple.finder.loc ` is a generic custom-item identifier and is never sufficient ownership evidence by itself. Detection, repair, and removal require the uniquely matching Launcher URL and URL type. Unknown layouts, missing URL mappings, unexpected enrichment, or ambiguous matches must fail closed and use the manual Command-drag path.

This result does not validate another Finder or macOS build. Each supported build still needs a reviewed profile and the same reversible validation.

## Prototype limitations carried into product design

The ignored write tool proved the Finder behavior; it is not reusable production transaction code. Its journal updates occur after some preference writes, leaving a crash window where system state can advance beyond the recorded state. Its wrapper also assumes final cleanup equals the original snapshot, which is true for this controlled exact-recovery run but false when a surgical removal intentionally preserves concurrent user changes.

The product transaction model must therefore:

- persist write intent, the before value, and the exact expected after value or hash before mutating Finder;
- recover from every allowed combination of journal state, disk value, and live value without guessing;
- verify surgical cleanup against its current-derived expected result rather than the historic original;
- record a terminal state only after Finder restart and repeated disk/live verification;
- validate schema versions and journal identity fields on every transition; and
- validate the embedded Launcher's architecture and signing relationship, not only its path and Info.plist metadata.

## Artifacts

- [Sanitized experiment evidence summary](artifacts/0002/evidence-summary.json)
- [Finder-produced representation after the rejected V1 restart](artifacts/0002/normalized-after-v1-restart.plist)
- The legacy blocked candidate remains in the [0001 artifacts](artifacts/0001/) as rejected-hypothesis evidence.
- Machine-specific candidates, alias data, launcher paths, and transaction journals remain in ignored local experiment directories rather than committed documentation.
