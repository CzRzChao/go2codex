import Foundation
import Testing
@testable import Go2CodexCore

private let profile = FinderToolbarProfile.finder146Build23G80
private let currentLauncherURL = URL(fileURLWithPath: "/Applications/Go2Codex.app/Contents/Helpers/Go2CodexLauncher.app")
private let staleLauncherURL = URL(fileURLWithPath: "/Applications/Old Go2Codex.app/Contents/Helpers/Go2CodexLauncher.app")
private let otherLauncherURL = URL(fileURLWithPath: "/Applications/Other.app")
private let opaqueFinderFileReference = "file:///.file/id=999999999.999999999/"

private let launcherIdentity = FinderToolbarLauncherIdentity(
    url: currentLauncherURL,
    fingerprint: "current-code-identity",
    launcherBundleIdentifier: "io.github.czrzchao.go2codex.launcher",
    outerBundleIdentifier: "io.github.czrzchao.go2codex"
)

private let validReceipt = FinderToolbarInstallationReceipt(
    profileIdentifier: profile.identifier,
    environment: profile.environment,
    lastVerifiedLauncherURL: staleLauncherURL,
    launcherIdentityFingerprint: launcherIdentity.fingerprint,
    launcherBundleIdentifier: launcherIdentity.launcherBundleIdentifier,
    outerBundleIdentifier: launcherIdentity.outerBundleIdentifier
)

private func scalarSnapshot() -> FinderToolbarSnapshot {
    FinderToolbarSnapshot(configurationWasPresent: true, fields: profile.scalarFields)
}

private func payload(
    url: URL,
    type: FinderToolbarPropertyListValue = .integer(15),
    alias: Data? = Data([1, 2, 3]),
    extra: [String: FinderToolbarPropertyListValue] = [:]
) -> FinderToolbarItemPayload {
    var result: FinderToolbarItemPayload = [
        FinderToolbarPreferenceKey.urlString: .string(url.standardizedFileURL.absoluteString),
        FinderToolbarPreferenceKey.urlStringType: type,
    ]
    if let alias {
        result[FinderToolbarPreferenceKey.aliasData] = .data(alias)
    }
    result.merge(extra) { _, new in new }
    return result
}

private func explicitSnapshot(
    identifiers: [String],
    itemPlists: [Int: FinderToolbarItemPayload],
    defaults: [String]? = profile.defaultIdentifiers
) -> FinderToolbarSnapshot {
    scalarSnapshot().replacingLayout(
        FinderToolbarLayout(
            identifiers: identifiers,
            defaultIdentifiers: defaults,
            itemPlists: itemPlists
        )
    )
}

private func installedContext(index: Int = 3) -> FinderToolbarDetectionContext {
    var identifiers = profile.activeBaseline
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: index)
    return FinderToolbarDetectionContext(
        snapshot: explicitSnapshot(
            identifiers: identifiers,
            itemPlists: [index: payload(url: currentLauncherURL)]
        ),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity),
        aliasResolutions: [index: .resolved(currentLauncherURL)]
    )
}

private func staleContext(index: Int = 4) -> FinderToolbarDetectionContext {
    var identifiers = profile.activeBaseline
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: index)
    return FinderToolbarDetectionContext(
        snapshot: explicitSnapshot(
            identifiers: identifiers,
            itemPlists: [index: payload(url: staleLauncherURL)]
        ),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity),
        receipt: .valid(validReceipt),
        aliasResolutions: [index: .resolved(currentLauncherURL)],
        storedPathStates: [staleLauncherURL.standardizedFileURL.absoluteString: .missing]
    )
}

private func installPlan() throws -> FinderToolbarMutationPlan {
    let context = FinderToolbarDetectionContext(
        snapshot: scalarSnapshot(),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity)
    )
    guard case let .mutation(plan) = FinderToolbarMutationPlanner.install(context) else {
        Issue.record("Expected an install mutation")
        throw TestFailure()
    }
    return plan
}

private struct TestFailure: Error {}

private func journal(
    plan: FinderToolbarMutationPlan,
    state: FinderToolbarTransactionState = .prepared,
    schemaVersion: Int = FinderToolbarTransactionJournal.currentSchemaVersion,
    identity: FinderToolbarLauncherIdentity = launcherIdentity,
    beforeFingerprint: String = "before-hash",
    expectedFingerprint: String = "expected-hash",
    semanticVerifierIdentifier: String = profile.semanticVerifierIdentifier
) -> FinderToolbarTransactionJournal {
    FinderToolbarTransactionJournal(
        schemaVersion: schemaVersion,
        operationIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        plan: plan,
        launcherIdentity: identity,
        beforeFingerprint: beforeFingerprint,
        expectedFingerprint: expectedFingerprint,
        semanticVerifierIdentifier: semanticVerifierIdentifier,
        state: state
    )
}

private func enrichedExpected(
    _ plan: FinderToolbarMutationPlan,
    alias: Data = Data([9, 8, 7])
) throws -> FinderToolbarSnapshot {
    guard case let .explicit(layout) = plan.expected.layoutClassification,
          case let .success(updated) = FinderToolbarLayoutMutation.replacePayload(
            at: plan.affectedIndex,
            in: layout,
            transform: { payload in
                var payload = payload
                payload[FinderToolbarPreferenceKey.aliasData] = .data(alias)
                return payload
            }
          ) else {
        throw TestFailure()
    }
    return plan.expected.replacingLayout(updated)
}

@Test
func snapshotAdapterRoundTripsEverySupportedPropertyListType() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let raw: [String: Any] = [
        "string": "value",
        "data": Data([1, 2]),
        "date": date,
        "integer": NSNumber(value: 42),
        "real": NSNumber(value: 1.5),
        "boolean": NSNumber(value: true),
        "array": ["nested", NSNumber(value: 7)],
        "dictionary": ["key": "value"],
    ]
    let decoded = try FinderToolbarSnapshotAdapter.decode(
        raw,
        configurationWasPresent: true
    ).get()

    #expect(decoded.fields["integer"] == .integer(42))
    #expect(decoded.fields["real"] == .real(1.5))
    #expect(decoded.fields["boolean"] == .boolean(true))
    #expect(decoded.fields["date"] == .date(date))

    let encoded = FinderToolbarSnapshotAdapter.encode(decoded)
    let roundTrip = try FinderToolbarSnapshotAdapter.decode(
        encoded,
        configurationWasPresent: true
    ).get()
    #expect(roundTrip == decoded)
}

@Test
func snapshotAdapterRejectsPresenceAndRawTypeMismatches() {
    #expect(
        FinderToolbarSnapshotAdapter.decode(["key": "value"], configurationWasPresent: false)
            == .failure(.presenceMismatch)
    )
    #expect(
        FinderToolbarSnapshotAdapter.decode(nil, configurationWasPresent: true)
            == .failure(.presenceMismatch)
    )
    #expect(
        FinderToolbarSnapshotAdapter.decode(["url": currentLauncherURL], configurationWasPresent: true)
            == .failure(.unsupportedValue)
    )
    let invalidKey = NSDictionary(object: "value", forKey: NSNumber(value: 1))
    #expect(
        FinderToolbarSnapshotAdapter.decode(invalidKey, configurationWasPresent: true)
            == .failure(.nonStringDictionaryKey)
    )
}

@Test
func layoutAdapterRejectsPartialWrongAndNonCanonicalIndexes() {
    var partial = profile.scalarFields
    partial[FinderToolbarPreferenceKey.itemIdentifiers] = .array([.string("one")])
    #expect(
        FinderToolbarSnapshot(configurationWasPresent: true, fields: partial).layoutClassification
            == .invalid(.partialItemStructure)
    )

    var nonCanonical = profile.scalarFields
    nonCanonical[FinderToolbarPreferenceKey.itemIdentifiers] = .array([.string("one")])
    nonCanonical[FinderToolbarPreferenceKey.itemPlists] = .dictionary(["01": .dictionary([:])])
    #expect(
        FinderToolbarSnapshot(configurationWasPresent: true, fields: nonCanonical).layoutClassification
            == .invalid(.nonCanonicalIndex("01"))
    )

    nonCanonical[FinderToolbarPreferenceKey.itemPlists] = .dictionary(["1": .dictionary([:])])
    #expect(
        FinderToolbarSnapshot(configurationWasPresent: true, fields: nonCanonical).layoutClassification
            == .invalid(.indexOutOfRange(1))
    )
}

@Test
func detectionAndMutationPlannersRejectRemainingMalformedLayouts() {
    let validIdentifiers: FinderToolbarPropertyListValue = .array([.string("one")])
    let validDefaults: FinderToolbarPropertyListValue = .array(
        profile.defaultIdentifiers.map { .string($0) }
    )
    let validItemPlists: FinderToolbarPropertyListValue = .dictionary([:])

    func context(
        identifiers: FinderToolbarPropertyListValue,
        defaults: FinderToolbarPropertyListValue,
        itemPlists: FinderToolbarPropertyListValue
    ) -> FinderToolbarDetectionContext {
        var fields = profile.scalarFields
        fields[FinderToolbarPreferenceKey.itemIdentifiers] = identifiers
        fields[FinderToolbarPreferenceKey.defaultItemIdentifiers] = defaults
        fields[FinderToolbarPreferenceKey.itemPlists] = itemPlists
        return FinderToolbarDetectionContext(
            snapshot: FinderToolbarSnapshot(configurationWasPresent: true, fields: fields),
            environment: profile.environment,
            launcherIdentity: .verified(launcherIdentity)
        )
    }

    let cases: [(FinderToolbarDetectionContext, FinderToolbarLayoutProblem)] = [
        (
            context(
                identifiers: .string("one"),
                defaults: validDefaults,
                itemPlists: validItemPlists
            ),
            .unexpectedIdentifiersType
        ),
        (
            context(
                identifiers: validIdentifiers,
                defaults: .string("default"),
                itemPlists: validItemPlists
            ),
            .unexpectedDefaultIdentifiersType
        ),
        (
            context(
                identifiers: validIdentifiers,
                defaults: validDefaults,
                itemPlists: .array([])
            ),
            .unexpectedItemPlistsType
        ),
        (
            context(
                identifiers: validIdentifiers,
                defaults: validDefaults,
                itemPlists: .dictionary(["0": .string("not-a-payload")])
            ),
            .unexpectedItemPayloadType(0)
        ),
    ]

    for (context, problem) in cases {
        let reason = FinderToolbarManualReason.unsupportedProfile(.malformed(problem))
        #expect(FinderToolbarDetector.detect(context) == .manualSetupRequired(reason))
        #expect(FinderToolbarMutationPlanner.install(context) == .blocked(.unsafe(reason)))
        #expect(FinderToolbarMutationPlanner.repair(context) == .blocked(.unsafe(reason)))
        #expect(FinderToolbarMutationPlanner.uninstall(context) == .blocked(.unsafe(reason)))
    }
}

@Test
func profileAcceptsOnlyExact23G80ScalarBeforeShape() {
    #expect(
        FinderToolbarProfileRegistry.classify(
            environment: profile.environment,
            snapshot: scalarSnapshot()
        ) == .exactBeforeShape(profile)
    )

    let environments = [
        FinderToolbarEnvironment(macOSBuild: "23G79", finderVersion: "14.6", finderBundleVersion: "1632.6.3"),
        FinderToolbarEnvironment(macOSBuild: "23G80", finderVersion: "14.5", finderBundleVersion: "1632.6.3"),
        FinderToolbarEnvironment(macOSBuild: "23G80", finderVersion: "14.6", finderBundleVersion: "1632.6.4"),
    ]
    for environment in environments {
        #expect(
            FinderToolbarProfileRegistry.classify(environment: environment, snapshot: scalarSnapshot())
                == .unsupported(.environment)
        )
    }

    var changed = profile.scalarFields
    changed["TB Size Mode"] = .integer(2)
    #expect(
        FinderToolbarProfileRegistry.classify(
            environment: profile.environment,
            snapshot: FinderToolbarSnapshot(configurationWasPresent: true, fields: changed)
        ) == .unsupported(.beforeShape)
    )
    #expect(
        FinderToolbarProfileRegistry.classify(
            environment: profile.environment,
            snapshot: FinderToolbarSnapshot(configurationWasPresent: false, fields: [:])
        ) == .unsupported(.configurationAbsent)
    )
}

@Test
func profileRegistrySelectsOnlyExactSupportedFinderBuilds() {
    let current = FinderToolbarProfile.finder264Build25F84
    #expect(FinderToolbarProfileRegistry.profile(for: profile.environment) == profile)
    #expect(FinderToolbarProfileRegistry.profile(for: current.environment) == current)
    #expect(
        FinderToolbarProfileRegistry.profile(
            for: FinderToolbarEnvironment(
                macOSBuild: current.environment.macOSBuild,
                finderVersion: current.environment.finderVersion,
                finderBundleVersion: "1828.5.3"
            )
        ) == nil
    )
}

@Test
func rejectedLegacyIndexEightCandidateIsNotAProfileMatch() {
    let legacyDefaults = [
        "com.apple.finder.BACK", "NSToolbarFlexibleSpaceItem", "com.apple.finder.SWCH",
        "com.apple.finder.ARNG", "com.apple.finder.ACTN", "com.apple.finder.SHAR",
        "com.apple.finder.LABL", "NSToolbarFlexibleSpaceItem", "NSToolbarFlexibleSpaceItem",
        "com.apple.finder.SRCH",
    ]
    var identifiers = legacyDefaults
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: 8)
    let candidate = explicitSnapshot(
        identifiers: identifiers,
        itemPlists: [8: payload(url: currentLauncherURL, alias: nil)],
        defaults: legacyDefaults
    )
    #expect(
        FinderToolbarProfileRegistry.classify(environment: profile.environment, snapshot: candidate)
            == .unsupported(.explicitShape)
    )
}

@Test
func detectionFindsNotInstalledAndInstalledAtArbitraryPosition() {
    let notInstalled = FinderToolbarDetectionContext(
        snapshot: scalarSnapshot(),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity)
    )
    #expect(FinderToolbarDetector.detect(notInstalled) == .notInstalled)
    #expect(FinderToolbarDetector.detect(installedContext(index: 7)) == .installed(index: 7))
}

@Test
func detectionAndMutationPlannersRejectEveryInvalidLauncherIdentityComponent() {
    func identity(
        url: URL = currentLauncherURL,
        fingerprint: String = launcherIdentity.fingerprint,
        launcherBundleIdentifier: String = launcherIdentity.launcherBundleIdentifier,
        outerBundleIdentifier: String = launcherIdentity.outerBundleIdentifier
    ) -> FinderToolbarLauncherIdentity {
        FinderToolbarLauncherIdentity(
            url: url,
            fingerprint: fingerprint,
            launcherBundleIdentifier: launcherBundleIdentifier,
            outerBundleIdentifier: outerBundleIdentifier
        )
    }

    let evidence: [FinderToolbarLauncherIdentityEvidence] = [
        .invalid,
        .verified(identity(url: URL(string: "https://example.com/Go2CodexLauncher.app")!)),
        .verified(identity(fingerprint: "")),
        .verified(identity(launcherBundleIdentifier: "")),
        .verified(identity(outerBundleIdentifier: "")),
    ]

    for launcherIdentity in evidence {
        let context = FinderToolbarDetectionContext(
            snapshot: scalarSnapshot(),
            environment: profile.environment,
            launcherIdentity: launcherIdentity
        )
        let reason = FinderToolbarManualReason.invalidLauncherIdentity
        #expect(FinderToolbarDetector.detect(context) == .manualSetupRequired(reason))
        #expect(FinderToolbarMutationPlanner.install(context) == .blocked(.unsafe(reason)))
        #expect(FinderToolbarMutationPlanner.repair(context) == .blocked(.unsafe(reason)))
        #expect(FinderToolbarMutationPlanner.uninstall(context) == .blocked(.unsafe(reason)))
    }
}

@Test
func detectionDoesNotConfuseOtherCustomApplicationsWithOwnership() {
    let identifiers = [
        FinderToolbarPreferenceKey.customItemIdentifier,
        "com.apple.finder.BACK",
        FinderToolbarPreferenceKey.customItemIdentifier,
        FinderToolbarPreferenceKey.customItemIdentifier,
        "com.apple.finder.SRCH",
    ]
    let snapshot = explicitSnapshot(
        identifiers: identifiers,
        itemPlists: [
            0: payload(url: otherLauncherURL),
            2: payload(url: currentLauncherURL),
            3: payload(url: URL(fileURLWithPath: "/Applications/Third.app")),
        ]
    )
    let context = FinderToolbarDetectionContext(
        snapshot: snapshot,
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity),
        aliasResolutions: [2: .resolved(currentLauncherURL)]
    )
    #expect(FinderToolbarDetector.detect(context) == .installed(index: 2))

    var orphanIdentifiers = profile.activeBaseline
    orphanIdentifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: 2)
    let orphan = FinderToolbarDetectionContext(
        snapshot: explicitSnapshot(identifiers: orphanIdentifiers, itemPlists: [:]),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity)
    )
    #expect(
        FinderToolbarDetector.detect(orphan)
            == .manualSetupRequired(.orphanCustomIdentifier(2))
    )
}

@Test
func detectionRejectsDuplicateAndWrongTypeOwnership() {
    let identifiers = [
        FinderToolbarPreferenceKey.customItemIdentifier,
        FinderToolbarPreferenceKey.customItemIdentifier,
    ]
    let duplicate = FinderToolbarDetectionContext(
        snapshot: explicitSnapshot(
            identifiers: identifiers,
            itemPlists: [
                0: payload(url: currentLauncherURL),
                1: payload(url: currentLauncherURL),
            ]
        ),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity),
        aliasResolutions: [
            0: .resolved(currentLauncherURL),
            1: .resolved(currentLauncherURL),
        ]
    )
    #expect(FinderToolbarDetector.detect(duplicate) == .manualSetupRequired(.duplicateOwnership))

    var identifiersWithItem = profile.activeBaseline
    identifiersWithItem.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: 1)
    let wrongType = FinderToolbarDetectionContext(
        snapshot: explicitSnapshot(
            identifiers: identifiersWithItem,
            itemPlists: [1: payload(url: currentLauncherURL, type: .integer(14))]
        ),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity)
    )
    #expect(FinderToolbarDetector.detect(wrongType) == .manualSetupRequired(.wrongURLType(1)))
}

@Test
func detectionAndMutationPlannersRejectInvalidCustomItemURLs() {
    let index = 2
    var identifiers = profile.activeBaseline
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: index)
    let invalidRepresentations: [FinderToolbarPropertyListValue?] = [
        nil,
        .integer(1),
        .string("https://example.com/Go2CodexLauncher.app"),
        .string("Go2CodexLauncher.app"),
        .string("file:///.file/id="),
        .string("file:///.file/id=1/"),
        .string("file:///.file/id=1.2/extra/"),
        .string("file:///.file/id=1.2/?query=1"),
        .string("file:///.file/id=1.2/#fragment"),
    ]

    for representation in invalidRepresentations {
        var invalidPayload = payload(url: currentLauncherURL)
        invalidPayload[FinderToolbarPreferenceKey.urlString] = representation
        let context = FinderToolbarDetectionContext(
            snapshot: explicitSnapshot(
                identifiers: identifiers,
                itemPlists: [index: invalidPayload]
            ),
            environment: profile.environment,
            launcherIdentity: .verified(launcherIdentity),
            aliasResolutions: [index: .resolved(currentLauncherURL)]
        )
        let reason = FinderToolbarManualReason.invalidURL(index)
        #expect(FinderToolbarDetector.detect(context) == .manualSetupRequired(reason))
        #expect(FinderToolbarMutationPlanner.install(context) == .blocked(.unsafe(reason)))
        #expect(FinderToolbarMutationPlanner.repair(context) == .blocked(.unsafe(reason)))
        #expect(FinderToolbarMutationPlanner.uninstall(context) == .blocked(.unsafe(reason)))
    }
}

@Test
func detectionRequiresNonemptyResolvedAgreeingAlias() {
    var identifiers = profile.activeBaseline
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: 5)

    func context(
        alias: Data?,
        resolution: FinderToolbarAliasResolution
    ) -> FinderToolbarDetectionContext {
        FinderToolbarDetectionContext(
            snapshot: explicitSnapshot(
                identifiers: identifiers,
                itemPlists: [5: payload(url: currentLauncherURL, alias: alias)]
            ),
            environment: profile.environment,
            launcherIdentity: .verified(launcherIdentity),
            aliasResolutions: [5: resolution]
        )
    }

    #expect(FinderToolbarDetector.detect(context(alias: nil, resolution: .absent)) == .manualSetupRequired(.missingAlias(5)))
    #expect(FinderToolbarDetector.detect(context(alias: Data(), resolution: .unresolvable)) == .manualSetupRequired(.emptyAlias(5)))
    #expect(FinderToolbarDetector.detect(context(alias: Data([1]), resolution: .unresolvable)) == .manualSetupRequired(.unresolvedAlias(5)))
    #expect(FinderToolbarDetector.detect(context(alias: Data([1]), resolution: .resolved(otherLauncherURL))) == .manualSetupRequired(.conflictingAlias(5)))
}

@Test
func detectionAcceptsFinderFileReferenceOnlyWhenAliasResolvesToLauncher() {
    let index = 1
    var identifiers = profile.activeBaseline
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: index)
    var fileReferencePayload = payload(url: currentLauncherURL)
    fileReferencePayload[FinderToolbarPreferenceKey.urlString] = .string(
        opaqueFinderFileReference
    )

    func context(alias: FinderToolbarAliasResolution) -> FinderToolbarDetectionContext {
        FinderToolbarDetectionContext(
            snapshot: explicitSnapshot(
                identifiers: identifiers,
                itemPlists: [index: fileReferencePayload]
            ),
            environment: profile.environment,
            launcherIdentity: .verified(launcherIdentity),
            aliasResolutions: [index: alias]
        )
    }

    #expect(FinderToolbarDetector.detect(context(alias: .resolved(currentLauncherURL))) == .installed(index: index))
    #expect(
        FinderToolbarDetector.detect(context(alias: .resolved(otherLauncherURL)))
            == .manualSetupRequired(.unmanagedExplicitShape)
    )
    #expect(
        FinderToolbarDetector.detect(context(alias: .absent))
            == .manualSetupRequired(.unmanagedExplicitShape)
    )
    #expect(
        FinderToolbarDetector.detect(context(alias: .unresolvable))
            == .manualSetupRequired(.unmanagedExplicitShape)
    )
}

@Test
func receiptBackedMissingStaleURLIsTheOnlyRepairClassification() {
    #expect(
        FinderToolbarDetector.detect(staleContext(index: 6))
            == .needsRepair(index: 6, staleURL: staleLauncherURL)
    )

    let base = staleContext(index: 6)
    let noReceipt = FinderToolbarDetectionContext(
        snapshot: base.snapshot,
        environment: base.environment,
        launcherIdentity: base.launcherIdentity,
        aliasResolutions: base.aliasResolutions,
        storedPathStates: base.storedPathStates
    )
    #expect(FinderToolbarDetector.detect(noReceipt) == .manualSetupRequired(.unmanagedExplicitShape))

    let presentPath = FinderToolbarDetectionContext(
        snapshot: base.snapshot,
        environment: base.environment,
        launcherIdentity: base.launcherIdentity,
        receipt: base.receipt,
        aliasResolutions: base.aliasResolutions,
        storedPathStates: [staleLauncherURL.standardizedFileURL.absoluteString: .present]
    )
    #expect(FinderToolbarDetector.detect(presentPath) == .manualSetupRequired(.stalePathNotMissing))

    let staleAlias = FinderToolbarDetectionContext(
        snapshot: base.snapshot,
        environment: base.environment,
        launcherIdentity: base.launcherIdentity,
        receipt: base.receipt,
        aliasResolutions: [6: .resolved(staleLauncherURL)],
        storedPathStates: base.storedPathStates
    )
    #expect(FinderToolbarDetector.detect(staleAlias) == .manualSetupRequired(.conflictingAlias(6)))

    let futureReceipt = FinderToolbarInstallationReceipt(
        schemaVersion: 2,
        profileIdentifier: validReceipt.profileIdentifier,
        environment: validReceipt.environment,
        lastVerifiedLauncherURL: staleLauncherURL,
        launcherIdentityFingerprint: validReceipt.launcherIdentityFingerprint,
        launcherBundleIdentifier: validReceipt.launcherBundleIdentifier,
        outerBundleIdentifier: validReceipt.outerBundleIdentifier
    )
    let invalidReceipt = FinderToolbarDetectionContext(
        snapshot: base.snapshot,
        environment: base.environment,
        launcherIdentity: base.launcherIdentity,
        receipt: .valid(futureReceipt),
        aliasResolutions: base.aliasResolutions,
        storedPathStates: base.storedPathStates
    )
    #expect(FinderToolbarDetector.detect(invalidReceipt) == .manualSetupRequired(.invalidReceipt))

    let mismatchedIdentityReceipt = FinderToolbarInstallationReceipt(
        profileIdentifier: validReceipt.profileIdentifier,
        environment: validReceipt.environment,
        lastVerifiedLauncherURL: staleLauncherURL,
        launcherIdentityFingerprint: "different-code-identity",
        launcherBundleIdentifier: validReceipt.launcherBundleIdentifier,
        outerBundleIdentifier: validReceipt.outerBundleIdentifier
    )
    let mismatchedIdentity = FinderToolbarDetectionContext(
        snapshot: base.snapshot,
        environment: base.environment,
        launcherIdentity: base.launcherIdentity,
        receipt: .valid(mismatchedIdentityReceipt),
        aliasResolutions: base.aliasResolutions,
        storedPathStates: base.storedPathStates
    )
    #expect(FinderToolbarDetector.detect(mismatchedIdentity) == .manualSetupRequired(.invalidReceipt))
}

@Test
func exactMissingLegacyLauncherPathCanBeRepairedWithoutAReceipt() {
    let legacyURL = URL(
        fileURLWithPath: "/Applications/Go2Codex.app/Contents/Applications/Go2CodexLauncher.app"
    )
    let index = 4
    var identifiers = profile.activeBaseline
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: index)
    let context = FinderToolbarDetectionContext(
        snapshot: explicitSnapshot(
            identifiers: identifiers,
            itemPlists: [index: payload(url: legacyURL)]
        ),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity),
        aliasResolutions: [index: .resolved(legacyURL)],
        storedPathStates: [legacyURL.standardizedFileURL.absoluteString: .missing],
        legacyLauncherURLs: [legacyURL]
    )

    #expect(
        FinderToolbarDetector.detect(context)
            == .needsRepair(index: index, staleURL: legacyURL)
    )
    guard case let .mutation(plan) = FinderToolbarMutationPlanner.repair(context) else {
        Issue.record("Expected a legacy path repair")
        return
    }
    #expect(plan.ownership == .legacy(legacyURL))
    #expect(plan.affectedIndex == index)
}

@Test
func currentAndReceiptBackedStaleEntriesAreDuplicateOwnership() {
    var identifiers = profile.activeBaseline
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: 2)
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: 7)
    let context = FinderToolbarDetectionContext(
        snapshot: explicitSnapshot(
            identifiers: identifiers,
            itemPlists: [
                2: payload(url: currentLauncherURL),
                7: payload(url: staleLauncherURL),
            ]
        ),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity),
        receipt: .valid(validReceipt),
        aliasResolutions: [
            2: .resolved(currentLauncherURL),
            7: .resolved(currentLauncherURL),
        ],
        storedPathStates: [staleLauncherURL.standardizedFileURL.absoluteString: .missing]
    )

    #expect(FinderToolbarDetector.detect(context) == .manualSetupRequired(.duplicateOwnership))
}

@Test
func receiptBackedDuplicateStaleEntriesRemainAmbiguous() {
    var identifiers = profile.activeBaseline
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: 2)
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: 7)
    let context = FinderToolbarDetectionContext(
        snapshot: explicitSnapshot(
            identifiers: identifiers,
            itemPlists: [
                2: payload(url: staleLauncherURL),
                7: payload(url: staleLauncherURL),
            ]
        ),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity),
        receipt: .valid(validReceipt),
        aliasResolutions: [
            2: .resolved(currentLauncherURL),
            7: .resolved(currentLauncherURL),
        ],
        storedPathStates: [staleLauncherURL.standardizedFileURL.absoluteString: .missing]
    )
    let reason = FinderToolbarManualReason.duplicateOwnership

    #expect(FinderToolbarDetector.detect(context) == .manualSetupRequired(reason))
    #expect(FinderToolbarMutationPlanner.install(context) == .blocked(.unsafe(reason)))
    #expect(FinderToolbarMutationPlanner.repair(context) == .blocked(.unsafe(reason)))
    #expect(FinderToolbarMutationPlanner.uninstall(context) == .blocked(.unsafe(reason)))
}

@Test
func validReceiptCanRecognizeSurgicalUninstallResultAsNotInstalled() {
    let context = FinderToolbarDetectionContext(
        snapshot: explicitSnapshot(identifiers: profile.activeBaseline, itemPlists: [:]),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity),
        receipt: .valid(validReceipt)
    )
    #expect(FinderToolbarDetector.detect(context) == .notInstalled)
    #expect(FinderToolbarMutationPlanner.uninstall(context) == .noChange(.alreadyNotInstalled))
}

@Test
func exactCurrentOwnershipCanRefreshAnInvalidReceipt() {
    let base = installedContext(index: 4)
    let invalidReceipt = FinderToolbarDetectionContext(
        snapshot: base.snapshot,
        environment: base.environment,
        launcherIdentity: base.launcherIdentity,
        receipt: .invalid,
        aliasResolutions: base.aliasResolutions,
        storedPathStates: base.storedPathStates
    )
    #expect(FinderToolbarDetector.detect(invalidReceipt) == .installed(index: 4))

    let mismatchedReceipt = FinderToolbarInstallationReceipt(
        profileIdentifier: validReceipt.profileIdentifier,
        environment: validReceipt.environment,
        lastVerifiedLauncherURL: validReceipt.lastVerifiedLauncherURL,
        launcherIdentityFingerprint: "different-code-identity",
        launcherBundleIdentifier: validReceipt.launcherBundleIdentifier,
        outerBundleIdentifier: validReceipt.outerBundleIdentifier
    )
    let mismatched = FinderToolbarDetectionContext(
        snapshot: base.snapshot,
        environment: base.environment,
        launcherIdentity: base.launcherIdentity,
        receipt: .valid(mismatchedReceipt),
        aliasResolutions: base.aliasResolutions,
        storedPathStates: base.storedPathStates
    )
    #expect(FinderToolbarDetector.detect(mismatched) == .installed(index: 4))
}

@Test
func explicitBuiltInLayoutWithoutCustomItemsIsNotInstalled() {
    let context = FinderToolbarDetectionContext(
        snapshot: explicitSnapshot(identifiers: profile.activeBaseline, itemPlists: [:]),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity)
    )
    #expect(FinderToolbarDetector.detect(context) == .notInstalled)
}

@Test
func installMaterializesValidatedBaselineAndPreservesExplicitLayouts() throws {
    let plan = try installPlan()
    #expect(plan.operation == .install)
    #expect(plan.affectedIndex == 10)
    #expect(plan.before == scalarSnapshot())
    guard case let .explicit(layout) = plan.expected.layoutClassification else {
        Issue.record("Expected explicit layout")
        return
    }
    #expect(layout.identifiers.count == 13)
    #expect(layout.identifiers[10] == FinderToolbarPreferenceKey.customItemIdentifier)
    #expect(layout.defaultIdentifiers == profile.defaultIdentifiers)
    #expect(layout.itemPlists[10]?[FinderToolbarPreferenceKey.urlStringType] == .integer(15))
    #expect(layout.itemPlists[10]?[FinderToolbarPreferenceKey.aliasData] == nil)
    #expect(profile.scalarFields.allSatisfy { plan.expected.fields[$0.key] == $0.value })

    #expect(FinderToolbarMutationPlanner.install(installedContext()) == .noChange(.alreadyInstalled))

    let explicitNotInstalled = FinderToolbarDetectionContext(
        snapshot: explicitSnapshot(
            identifiers: profile.activeBaseline,
            itemPlists: [:]
        ),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity)
    )
    guard case let .mutation(explicitPlan) = FinderToolbarMutationPlanner.install(explicitNotInstalled),
          case let .explicit(explicitLayout) = explicitPlan.expected.layoutClassification else {
        Issue.record("Expected an explicit-layout install mutation")
        return
    }
    #expect(explicitPlan.before == explicitNotInstalled.snapshot)
    #expect(explicitPlan.affectedIndex == 10)
    #expect(explicitLayout.identifiers.count == profile.activeBaseline.count + 1)
    #expect(explicitLayout.identifiers[10] == FinderToolbarPreferenceKey.customItemIdentifier)
}

@Test
func indexInsertionRemapsEveryPayloadAtFirstMiddleAndLast() throws {
    let base = FinderToolbarLayout(
        identifiers: ["a", "b", "c"],
        defaultIdentifiers: ["default"],
        itemPlists: [
            0: ["marker": .string("zero")],
            1: ["marker": .string("one")],
            2: ["marker": .string("two")],
        ]
    )
    for index in 0...3 {
        let inserted = try FinderToolbarLayoutMutation.insert(
            identifier: "new",
            payload: ["marker": .string("new")],
            at: index,
            into: base
        ).get()
        #expect(inserted.identifiers[index] == "new")
        #expect(inserted.itemPlists[index]?["marker"] == .string("new"))
        for originalIndex in 0..<3 {
            let expectedIndex = originalIndex >= index ? originalIndex + 1 : originalIndex
            #expect(inserted.itemPlists[expectedIndex]?["marker"] == .string(["zero", "one", "two"][originalIndex]))
        }
        #expect(inserted.defaultIdentifiers == base.defaultIdentifiers)
    }
}

@Test
func indexRemovalRemapsEveryPayloadAtFirstMiddleAndLast() throws {
    let base = FinderToolbarLayout(
        identifiers: ["a", "b", "c", "d"],
        defaultIdentifiers: ["default"],
        itemPlists: Dictionary(uniqueKeysWithValues: (0..<4).map {
            ($0, ["marker": .integer(Int64($0))])
        })
    )
    for removedIndex in 0..<4 {
        let removed = try FinderToolbarLayoutMutation.remove(at: removedIndex, from: base).get()
        #expect(removed.identifiers.count == 3)
        #expect(removed.itemPlists.count == 3)
        for originalIndex in 0..<4 where originalIndex != removedIndex {
            let expectedIndex = originalIndex > removedIndex ? originalIndex - 1 : originalIndex
            #expect(removed.itemPlists[expectedIndex]?["marker"] == .integer(Int64(originalIndex)))
        }
        #expect(removed.defaultIdentifiers == base.defaultIdentifiers)
    }
}

@Test
func repairKeepsPositionAndUnrelatedPayloadsWhileReplacingURLRepresentation() {
    let context = staleContext(index: 4)
    guard case let .mutation(plan) = FinderToolbarMutationPlanner.repair(context),
          case let .explicit(beforeLayout) = plan.before.layoutClassification,
          case let .explicit(afterLayout) = plan.expected.layoutClassification else {
        Issue.record("Expected repair mutation")
        return
    }
    #expect(plan.operation == .repair)
    #expect(plan.affectedIndex == 4)
    #expect(beforeLayout.identifiers == afterLayout.identifiers)
    #expect(afterLayout.itemPlists[4]?[FinderToolbarPreferenceKey.urlString] == .string(currentLauncherURL.standardizedFileURL.absoluteString))
    #expect(afterLayout.itemPlists[4]?[FinderToolbarPreferenceKey.aliasData] == nil)
    #expect(FinderToolbarMutationPlanner.repair(installedContext()) == .noChange(.alreadyInstalled))
}

@Test
func uninstallIsSurgicalForCurrentAndReceiptOwnership() {
    for context in [installedContext(index: 2), staleContext(index: 2)] {
        guard case let .mutation(plan) = FinderToolbarMutationPlanner.uninstall(context),
              case let .explicit(beforeLayout) = plan.before.layoutClassification,
              case let .explicit(afterLayout) = plan.expected.layoutClassification else {
            Issue.record("Expected uninstall mutation")
            return
        }
        #expect(plan.operation == .uninstall)
        #expect(plan.affectedIndex == 2)
        #expect(afterLayout.identifiers == Array(beforeLayout.identifiers.enumerated().filter { $0.offset != 2 }.map(\.element)))
        #expect(afterLayout.defaultIdentifiers == beforeLayout.defaultIdentifiers)
        #expect(afterLayout.itemPlists[2] == beforeLayout.itemPlists[3])
    }
}

@Test
func uninstallPreservesMultipleUnrelatedCustomApplicationsAndTheirOrder() {
    let identifiers = [
        FinderToolbarPreferenceKey.customItemIdentifier,
        FinderToolbarPreferenceKey.customItemIdentifier,
        FinderToolbarPreferenceKey.customItemIdentifier,
        "com.apple.finder.SRCH",
    ]
    let context = FinderToolbarDetectionContext(
        snapshot: explicitSnapshot(
            identifiers: identifiers,
            itemPlists: [
                0: payload(url: otherLauncherURL, extra: ["owner": .string("other")]),
                1: payload(url: currentLauncherURL),
                2: payload(url: URL(fileURLWithPath: "/Applications/Third.app"), extra: ["owner": .string("third")]),
            ]
        ),
        environment: profile.environment,
        launcherIdentity: .verified(launcherIdentity),
        aliasResolutions: [1: .resolved(currentLauncherURL)]
    )
    guard case let .mutation(plan) = FinderToolbarMutationPlanner.uninstall(context),
          case let .explicit(layout) = plan.expected.layoutClassification else {
        Issue.record("Expected uninstall mutation")
        return
    }
    #expect(layout.itemPlists[0]?["owner"] == .string("other"))
    #expect(layout.itemPlists[1]?["owner"] == .string("third"))
    #expect(layout.identifiers.prefix(2).allSatisfy { $0 == FinderToolbarPreferenceKey.customItemIdentifier })
}

@Test
func semanticVerifierAcceptsOnlyExactOrResolvedAliasOnlyEnrichment() throws {
    let plan = try installPlan()
    #expect(FinderToolbarSemanticVerifier.verify(plan: plan, observed: plan.expected) == .exactExpected)

    let enriched = try enrichedExpected(plan)
    #expect(
        FinderToolbarSemanticVerifier.verify(
            plan: plan,
            observed: enriched,
            aliasResolution: .resolved(currentLauncherURL)
        ) == .acceptedAliasEnrichment
    )
    #expect(
        FinderToolbarSemanticVerifier.verify(
            plan: plan,
            observed: enriched,
            aliasResolution: .resolved(otherLauncherURL)
        ) == .rejected(.conflictingAlias)
    )
    #expect(
        FinderToolbarSemanticVerifier.verify(
            plan: plan,
            observed: enriched,
            aliasResolution: .unresolvable
        ) == .rejected(.unresolvedAlias)
    )
}

@Test
func semanticVerifierAcceptsFinderFileReferenceNormalizationWithMatchingAlias() throws {
    let plan = try installPlan()
    let enriched = try enrichedExpected(plan)
    guard case let .explicit(layout) = enriched.layoutClassification,
          case let .success(normalizedLayout) = FinderToolbarLayoutMutation.replacePayload(
            at: plan.affectedIndex,
            in: layout,
            transform: { payload in
                var payload = payload
                payload[FinderToolbarPreferenceKey.urlString] = .string(
                    opaqueFinderFileReference
                )
                return payload
            }
          ) else {
        Issue.record("Expected a normalized Finder payload")
        return
    }
    let normalized = enriched.replacingLayout(normalizedLayout)
    #expect(
        FinderToolbarSemanticVerifier.verify(
            plan: plan,
            observed: normalized,
            aliasResolution: .resolved(currentLauncherURL)
        ) == .acceptedAliasEnrichment
    )
    #expect(
        FinderToolbarSemanticVerifier.verify(
            plan: plan,
            observed: normalized,
            aliasResolution: .resolved(otherLauncherURL)
        ) == .rejected(.conflictingAlias)
    )
    #expect(
        FinderToolbarSemanticVerifier.verify(
            plan: plan,
            observed: normalized,
            aliasResolution: .unresolvable
        ) == .rejected(.unresolvedAlias)
    )
}

@Test
func semanticVerifierRejectsEmptyAliasAndAnyOtherDifference() throws {
    let plan = try installPlan()
    let emptyAlias = try enrichedExpected(plan, alias: Data())
    #expect(
        FinderToolbarSemanticVerifier.verify(
            plan: plan,
            observed: emptyAlias,
            aliasResolution: .resolved(currentLauncherURL)
        ) == .rejected(.emptyAlias)
    )

    var changedFields = plan.expected.fields
    changedFields["unexpected"] = .string("value")
    let changed = FinderToolbarSnapshot(configurationWasPresent: true, fields: changedFields)
    #expect(
        FinderToolbarSemanticVerifier.verify(
            plan: plan,
            observed: changed,
            aliasResolution: .resolved(currentLauncherURL)
        ) == .rejected(.unexpectedDifference)
    )
}

@Test
func journalValidationFailsClosedForEveryIdentityField() throws {
    let plan = try installPlan()
    let context = FinderToolbarJournalValidationContext(
        profile: profile,
        launcherIdentity: launcherIdentity,
        beforeFingerprint: "before-hash",
        expectedFingerprint: "expected-hash"
    )
    #expect(
        FinderToolbarJournalValidator.validate(journal(plan: plan), context: context)
            == .valid(journal(plan: plan))
    )
    #expect(
        FinderToolbarJournalValidator.validate(journal(plan: plan, schemaVersion: 2), context: context)
            == .invalid(.schema)
    )
    let otherIdentity = FinderToolbarLauncherIdentity(
        url: otherLauncherURL,
        fingerprint: launcherIdentity.fingerprint,
        launcherBundleIdentifier: launcherIdentity.launcherBundleIdentifier,
        outerBundleIdentifier: launcherIdentity.outerBundleIdentifier
    )
    #expect(
        FinderToolbarJournalValidator.validate(journal(plan: plan, identity: otherIdentity), context: context)
            == .invalid(.launcherIdentity)
    )
    #expect(
        FinderToolbarJournalValidator.validate(journal(plan: plan, expectedFingerprint: "wrong"), context: context)
            == .invalid(.fingerprints)
    )
    #expect(
        FinderToolbarJournalValidator.validate(journal(plan: plan, semanticVerifierIdentifier: "unknown"), context: context)
            == .invalid(.semanticVerifier)
    )
}

@Test
func journalAndTypedSnapshotsAreCodable() throws {
    let original = journal(plan: try installPlan(), state: .restartIntentRecorded)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(FinderToolbarTransactionJournal.self, from: data)
    #expect(decoded == original)
}

@Test
func preMutationGateRequiresJournalBoundaryAndFreshConvergedRead() throws {
    let plan = try installPlan()
    let valid = FinderToolbarValidatedJournal.valid(journal(plan: plan))
    #expect(
        FinderToolbarPreMutationGate.decide(
            plan: plan,
            journal: valid,
            serializationBoundary: .established("validated-window-v1"),
            disk: plan.before,
            live: plan.before
        ) == .proceed
    )
    #expect(
        FinderToolbarPreMutationGate.decide(
            plan: plan,
            journal: valid,
            serializationBoundary: .experimentalBestEffort("user-confirmed-private-preferences-v1"),
            disk: plan.before,
            live: plan.before
        ) == .proceed
    )
    #expect(
        FinderToolbarPreMutationGate.decide(
            plan: plan,
            journal: valid,
            serializationBoundary: .unavailable,
            disk: plan.before,
            live: plan.before
        ) == .rejectSerializationBoundary
    )
    #expect(
        FinderToolbarPreMutationGate.decide(
            plan: plan,
            journal: valid,
            serializationBoundary: .established("validated-window-v1"),
            disk: plan.before,
            live: plan.expected
        ) == .rejectDiskLiveDivergence
    )
    #expect(
        FinderToolbarPreMutationGate.decide(
            plan: plan,
            journal: valid,
            serializationBoundary: .established("validated-window-v1"),
            disk: plan.expected,
            live: plan.expected
        ) == .rejectStalePlan
    )
}

@Test
func recoveryStateTableResumesEachDurableBoundaryDeterministically() throws {
    let plan = try installPlan()
    let expected = FinderToolbarRecoveryObservation(snapshot: plan.expected)
    let cases: [(FinderToolbarTransactionState, FinderToolbarFinderReplacementState, FinderToolbarRecoveryDecision)] = [
        (.prepared, .pending, .recordRestartIntent),
        (.preferenceSynchronized, .pending, .recordRestartIntent),
        (.restartIntentRecorded, .pending, .requestFinderRestart),
        (.restartRequested, .pending, .waitForFinderReplacement),
        (.restartRequested, .observed, .recordFinderReplacement),
        (.finderReplacementObserved, .observed, .resumeSemanticVerification),
        (.semanticConvergenceVerified, .observed, .commitReceipt),
        (.receiptCommitted, .observed, .markCompleted),
        (.completed, .observed, .alreadyCompleted),
    ]
    for (state, finderReplacement, decision) in cases {
        #expect(
            FinderToolbarRecoveryPlanner.decide(
                journal: .valid(journal(plan: plan, state: state)),
                disk: expected,
                live: expected,
                retryState: .mayRetry,
                finderReplacement: finderReplacement
            ) == decision
        )
    }
}

@Test
func recoveryUsesKnownBeforeButNeverGuessesUnknownOrTimedOutDivergence() throws {
    let plan = try installPlan()
    let before = FinderToolbarRecoveryObservation(snapshot: plan.before)
    let expected = FinderToolbarRecoveryObservation(snapshot: plan.expected)

    #expect(
        FinderToolbarRecoveryPlanner.decide(
            journal: .valid(journal(plan: plan, state: .restartRequested)),
            disk: before,
            live: before,
            retryState: .mayRetry
        ) == .resumePreferenceMutation
    )
    #expect(
        FinderToolbarRecoveryPlanner.decide(
            journal: .valid(journal(plan: plan, state: .finderReplacementObserved)),
            disk: before,
            live: before,
            retryState: .mayRetry
        ) == .manualSetupRequired(.unexpectedBeforeValue)
    )
    #expect(
        FinderToolbarRecoveryPlanner.decide(
            journal: .valid(journal(plan: plan)),
            disk: before,
            live: expected,
            retryState: .mayRetry
        ) == .waitForDiskLiveConvergence
    )
    #expect(
        FinderToolbarRecoveryPlanner.decide(
            journal: .valid(journal(plan: plan)),
            disk: before,
            live: expected,
            retryState: .timedOut
        ) == .manualSetupRequired(.convergenceTimedOut)
    )

    var unknownFields = plan.before.fields
    unknownFields["unknown"] = .string("change")
    let unknown = FinderToolbarRecoveryObservation(
        snapshot: FinderToolbarSnapshot(configurationWasPresent: true, fields: unknownFields)
    )
    #expect(
        FinderToolbarRecoveryPlanner.decide(
            journal: .valid(journal(plan: plan)),
            disk: unknown,
            live: unknown,
            retryState: .mayRetry
        ) == .manualSetupRequired(.unknownPreferenceValue)
    )
    #expect(
        FinderToolbarRecoveryPlanner.decide(
            journal: .invalid(.schema),
            disk: before,
            live: before,
            retryState: .mayRetry
        ) == .manualSetupRequired(.invalidJournal)
    )
}

@Test
func recoveryAcceptsAliasEnrichmentOnlyWithResolutionAndStillRequiresConvergence() throws {
    let plan = try installPlan()
    let enriched = try enrichedExpected(plan)
    let exact = FinderToolbarRecoveryObservation(snapshot: plan.expected)
    let normalized = FinderToolbarRecoveryObservation(
        snapshot: enriched,
        aliasResolution: .resolved(currentLauncherURL)
    )
    #expect(
        FinderToolbarRecoveryPlanner.decide(
            journal: .valid(journal(plan: plan, state: .finderReplacementObserved)),
            disk: normalized,
            live: normalized,
            retryState: .mayRetry
        ) == .resumeSemanticVerification
    )
    #expect(
        FinderToolbarRecoveryPlanner.decide(
            journal: .valid(journal(plan: plan, state: .finderReplacementObserved)),
            disk: exact,
            live: normalized,
            retryState: .mayRetry
        ) == .waitForDiskLiveConvergence
    )
    let conflict = FinderToolbarRecoveryObservation(
        snapshot: enriched,
        aliasResolution: .resolved(otherLauncherURL)
    )
    #expect(
        FinderToolbarRecoveryPlanner.decide(
            journal: .valid(journal(plan: plan)),
            disk: conflict,
            live: conflict,
            retryState: .mayRetry
        ) == .manualSetupRequired(.unknownPreferenceValue)
    )
}

@Test
func everyFaultBoundaryHasOneExplicitRecoveryPolicy() {
    #expect(Set(FinderToolbarFaultPoint.allCases).count == 12)
    #expect(FinderToolbarFaultPlanner.decide(at: .beforeJournalWrite) == .abortWithoutMutation)
    #expect(FinderToolbarFaultPlanner.decide(at: .duringJournalReplacement) == .discardIncompleteTemporaryJournal)
    #expect(FinderToolbarFaultPlanner.decide(at: .afterTerminalState) == .returnCompleted)

    let durableRecoveryPoints = FinderToolbarFaultPoint.allCases.filter {
        ![.beforeJournalWrite, .duringJournalReplacement, .afterTerminalState].contains($0)
    }
    #expect(durableRecoveryPoints.count == 9)
    for point in durableRecoveryPoints {
        #expect(FinderToolbarFaultPlanner.decide(at: point) == .recoverFromDurableJournal)
    }
}
