# Finder alias resolution contract

Status: completed on 2026-07-18 with the ignored Finder-produced alias artifact.

## Result

Finder's `_CFURLAliasData` is a Carbon AliasRecord, not Foundation bookmark data and not an alias file on disk. The supported public conversion path available on the deployment system is:

1. convert the AliasRecord with `CFURLCreateBookmarkDataFromAliasRecord`;
2. take ownership of the returned `CFData`;
3. resolve the transient bookmark with `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)` using `.withoutUI` and `.withoutMounting`;
4. for Installed, require the resolved file URL, stored `_CFURLString`, and expected validated embedded Launcher URL to be equal after file-URL standardization;
5. independently require the expected Launcher identity and signature checks from M7.

Needs Repair is narrower: the stored `_CFURLString` must be a missing URL from a matching verified receipt, while the AliasRecord must resolve to the current verified embedded Launcher URL. If the missing target makes the AliasRecord unresolvable, repair remains unavailable and detection fails closed to Manual Setup Required.

`CFURLCreateBookmarkDataFromAliasRecord` is public but deprecated since macOS 11. Apple's API note limits it to converting Carbon AliasRecords to bookmark data, which is exactly this read-only compatibility use. `URL(resolvingAliasFileAt:)` is not applicable because it accepts a filesystem alias file, not raw preference data. The implementation resolves this one compatibility symbol from CoreFoundation at runtime because Apple provides no raw-record replacement; a missing symbol fails closed as unresolvable, while the rest of the target remains subject to warnings-as-errors.

The ignored Finder-produced fixture is stored under `.build-probes/validation-0002/transaction-3/evidence/` and is intentionally not committed because it contains a machine-specific path. Its 566-byte AliasRecord converted to a 660-byte bookmark and resolved to the same URL as `_CFURLString`. The resolver reported the transient bookmark as stale. Staleness alone is therefore not a rejection condition; identity agreement is mandatory.

## Fail-closed classification

The resolver rejects:

- a non-Data or empty value;
- converter or bookmark-resolution failure;
- a non-file URL;
- a target that would require UI or mounting;
- a missing target that cannot resolve to the current verified Launcher through the separate receipt-backed repair rule;
- disagreement with `_CFURLString`;
- disagreement with the expected embedded Launcher;
- failed path-containment, architecture, bundle, or signing validation.

Conversion returning non-nil is not proof of validity. Empty, one-byte, truncated, and zero-filled input can survive the converter and then fail during bookmark resolution. A one-bit mutation may still resolve, so byte-level novelty is not a damage detector.

## Test fixtures

Pure Core tests inject an `AliasResolving` fake for matching, stale-but-matching, empty, damaged, unresolvable, stored-URL conflict, and expected-Launcher conflict cases. Platform integration support may create a temporary AliasRecord at test runtime, resolve it entirely in memory, then exercise truncation, zero fill, removal of the target, and conflicting URLs. It must not commit the real path-bearing artifact.

Any ambiguity becomes Manual Setup Required, or Needs Repair only when the separate receipt rules make ownership unique. No alias failure authorizes a preference write.

## Automated platform support evidence

The App and test targets compile the same production support source. Deterministic tests cover absent, non-Data, empty, one-byte, synthetic truncated, zero-filled, and deterministic damaged AliasRecord input. Every nonempty damaged record reaches the public converter/resolver path and remains unresolvable; none is treated as Installed or authorizes a write.

The same production path inspector walks each absolute file-path component with `lstat`. Temporary on-disk tests cover ordinary directories and files, parent and leaf symlinks, missing components, relative file URLs, non-file URLs, and non-canonical dot components. All ambiguous paths fail closed before bundle, executable, or signing evidence is accepted.

The SDK's public Carbon creation functions such as `FSNewAliasFromPath` are not imported into Swift by Xcode 16.2. The suite therefore does not add a C shim or commit a path-bearing fixture solely to generate a valid record. The ignored Finder-produced artifact above remains the valid-record and removed-target spike evidence.
