# Finder preference serialization boundary

Status: completed as a read-only investigation on 2026-07-18. The production serialization boundary is unavailable.

## Scope and required invariant

This investigation addresses the concurrency gate in M8.2. It did not write Finder preferences, restart or suspend Finder, terminate `cfprefsd`, or exercise any private preference daemon interface.

Validated environment:

- macOS 14.6 build 23G80;
- Finder 14.6 build 1632.6.3;
- Finder preference domain `com.apple.finder`;
- toolbar preference key `NSToolbar Configuration Browser`; and
- Xcode 16.2 with the public macOS 15.2 SDK, deploying to macOS 14 or later.

The toolbar configuration is one nested property-list value. A safe automatic operation therefore needs one of these two guarantees:

1. a conditional write that replaces the value only when its current version or value still equals the transaction's `before` evidence; or
2. an exclusive boundary honored by Finder, `cfprefsd`, and every other writer from the final converged read through the completed write and synchronization.

The minimum protected sequence would be:

```text
acquire shared-system boundary
  synchronize and read disk/live
  require disk == live == journal.before
  replace toolbar value
  synchronize and verify persistence
release shared-system boundary
```

Serializing only Go2Codex processes does not meet this invariant. Without a system-wide boundary, this ordering remains possible:

```text
Go2Codex reads V0 and derives G(V0)
Finder or another client writes V1
Go2Codex writes G(V0)
```

The final value can look exactly like the planned Go2Codex result while the unrelated V1 change has already been destroyed. A post-write read cannot reconstruct or even reliably detect that lost value.

## Public CFPreferences contract

Apple's public [Preferences Utilities](https://developer.apple.com/documentation/corefoundation/preferences-utilities) surface describes CFPreferences as thread-safe. Thread safety makes individual API use safe; it does not promise an atomic cross-process read-modify-write transaction.

The public Xcode 16.2 `CFPreferences.h` inventory contains these relevant operations:

- `CFPreferencesCopyAppValue` and `CFPreferencesCopyValue`;
- `CFPreferencesSetAppValue` and `CFPreferencesSetValue`;
- `CFPreferencesCopyMultiple` and `CFPreferencesSetMultiple`; and
- `CFPreferencesAppSynchronize` and `CFPreferencesSynchronize`.

None accepts an expected value, generation, revision, transaction handle, or lock token. None returns a conflict result for an intervening writer. `CFPreferencesSetMultiple` is a convenience for changing multiple keys, not compare-and-swap for a value.

Apple documents that [`CFPreferencesAppSynchronize`](https://developer.apple.com/documentation/corefoundation/cfpreferencesappsynchronize%28_%3A%29) writes pending changes, then reads the latest values from permanent storage. The same documentation states that externally made changes are not automatically incorporated into a process's cache. [`CFPreferencesSetAppValue`](https://developer.apple.com/documentation/corefoundation/cfpreferencessetappvalue%28_%3A_%3A_%3A%29) stages a replacement and requires a later synchronize call for persistence. These are separate calls with no documented exclusion between them.

The local `cfprefsd(8)` manual identifies `cfprefsd` as the service behind CFPreferences and NSUserDefaults and exposes no configuration or transaction interface. The local `defaults(1)` manual explicitly warns that changing a running application's domain can be overwritten by that application. That warning describes the exact lost-update class M8 must prevent.

Conclusion: the public CFPreferences contract provides storage synchronization, not an atomic conditional mutation or a caller-acquirable daemon lock.

## Rejected candidate boundaries

| Candidate | Why it does not establish the required boundary |
| --- | --- |
| Go2Codex operation lock, `flock`, `fcntl`, or `NSDistributedLock` on a Go2Codex lock file | These coordinate only clients that voluntarily acquire the same lock. Apple's [`flock(2)` manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html) calls the lock advisory and says non-cooperating processes may still access the file. Finder and `cfprefsd` have no documented participation in a Go2Codex lock. |
| Locking `com.apple.finder.plist` itself | File locks remain advisory, and a preferences daemon may replace a plist by rename rather than mutate the locked inode. More importantly, direct file locking is not part of the CFPreferences contract and does not lock the daemon's cached domain or its API requests. |
| Final `CFPreferencesAppSynchronize`, equality check, `SetAppValue`, then another synchronize | This narrows the race window but leaves a gap between the equality check and the set request. The setter carries no expected value or revision, so an intervening write is silently replaceable. |
| `CFPreferencesSetMultiple` | It groups keys to set or remove but has no expected-value condition and no public lock token. The toolbar is already one key, so this does not make its nested read-modify-write conditional. |
| Direct plist mutation, `plutil`, or `defaults write` | Apple says preferences should be accessed through NSUserDefaults or CFPreferences, and the `defaults(1)` manual warns about overwrite races with running applications. Direct plist replacement can also diverge from `cfprefsd`'s live cache. It is not a safe bypass. |
| `NSFileCoordinator` / `NSFilePresenter` | [`NSFilePresenter`](https://developer.apple.com/documentation/foundation/nsfilepresenter) explicitly limits notifications to changes that pass through file coordination; direct low-level changes are not coordinated. There is no public evidence that `cfprefsd` and Finder coordinate this domain through `NSFileCoordinator`, so a Go2Codex coordination block cannot exclude them. |
| `SCPreferencesLock` | [`SCPreferencesLock`](https://developer.apple.com/documentation/systemconfiguration/scpreferenceslock%28_%3A_%3A%29) promises exclusive access among System Configuration preferences sessions. `SCPreferences` is a different framework and storage protocol for system configuration preferences. Apple does not document its lock as being honored by CFPreferences, `cfprefsd`, or Finder. Pointing an `SCPreferences` session at a plist path cannot create an undocumented cross-framework guarantee. |
| Ask Finder to quit, then write | [`NSRunningApplication.forceTerminate`](https://developer.apple.com/documentation/appkit/nsrunningapplication/forceterminate%28%29) may return before the process exits. Even after observing termination, no public API prevents Finder from relaunching or excludes pending and new `cfprefsd` or third-party writes. Process absence is not a preferences transaction. |
| Send `SIGSTOP` to Finder during the mutation | Suspending Finder would not suspend `cfprefsd` or another preferences client. It also has no documented relationship with preference daemon queues and can freeze Finder while it owns unrelated resources. It cannot satisfy the all-writer boundary. |
| Stop, kill, or replace `cfprefsd` | `cfprefsd` has no public control or transaction API and its manual says users should not run it manually. Interfering with the per-user preferences service risks unrelated cached preferences and still does not provide a supported lock. This option was not executed and is outside the product boundary. |
| Darwin/distributed notifications or repeated post-write verification | Notifications and polling can observe some changes after they occur; they do not prevent the V0/V1/G(V0) lost-update sequence. Once G(V0) replaces V1, final convergence can falsely look successful. |
| Private `cfprefsd` XPC, reverse-engineered locks, or Finder internals | Private symbols and protocols are not public or stable contracts. Depending on them would weaken the exact safety gate this investigation is meant to close. No private interface was exercised. |

The prior reversible write validation in [spike 0002](0002-reversible-finder-toolbar-write-validation.md) proves that one exact candidate survives Finder normalization on one Finder build. It does not prove concurrent-change safety: its runs had converged before-values and did not establish an exclusion boundary against a simultaneous writer.

## Personal MVP decision

No public, stable API available on the validated environment establishes the required boundary. Production must therefore report:

```swift
FinderToolbarSerializationBoundary.unavailable
```

The existing `FinderToolbarPreMutationGate` must reject this result before any preference setter is reachable. For the Personal MVP:

- automatic Install, Repair, and Uninstall remain disabled, including on the otherwise validated 23G80/Finder 1632.6.3 profile;
- an unavailable boundary creates no transaction journal, writes no Finder preference, and does not restart Finder;
- read-only environment, identity, and installation-status detection may remain enabled;
- setup reveals the embedded Launcher and gives localized Command-drag instructions;
- removal and repositioning remain user-driven Finder toolbar actions; and
- pure mutation, journal, recovery, semantic-verification, and fault-planning code can remain covered by fixtures without being connected to a real setter.

This is a fail-closed product decision, not a claim that the M8 automatic-install exit gate passed. M8.1 deterministic planning can pass independently, but M8.2 automatic mutation and M8.3 controlled production integration must not be reported as complete while the boundary is unavailable.

## Conditions that can unlock automatic installation

Automatic mutation can be reconsidered only when at least one supported mechanism has a public contract that closes the complete final-read-to-persisted-write window, for example:

1. CFPreferences gains a conditional set or versioned transaction API that reports conflicts;
2. Apple documents a lock/session that Finder and `cfprefsd` both honor around the relevant domain;
3. Finder exposes a public atomic API for installing and removing a toolbar item without editing its private whole-value preference; or
4. the product adopts a different public extension point whose system-owned transaction replaces private preference mutation.

Any candidate must then be bound to a documented API and availability range, covered by adversarial two-writer tests that force a change after the final read, and re-run through the journal fault matrix and exact Finder profile validation. A smaller race window, repeated successful experiments, Go2Shell compatibility, or reverse-engineered daemon behavior alone is not an unlock condition.
