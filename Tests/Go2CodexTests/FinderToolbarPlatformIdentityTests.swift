import Foundation
import Go2CodexCore
import Testing

private let outerInfoPath = "Contents/Info.plist"
private let launcherRelativePath = "Contents/Applications/Go2CodexLauncher.app"
private let launcherInfoPath = "Contents/Applications/Go2CodexLauncher.app/Contents/Info.plist"
private let outerExecutablePath = "Contents/MacOS/Go2CodexFixture"
private let launcherExecutablePath = "Contents/Applications/Go2CodexLauncher.app/Contents/MacOS/Go2CodexLauncher"
private let outerBundleIdentifier = "io.github.czrzchao.go2codex.debug"
private let launcherBundleIdentifier = "io.github.czrzchao.go2codex.debug.launcher"
private let preferencesDomain = "io.github.czrzchao.go2codex.debug"

private enum IdentityFixtureError: Error {
    case missingTestExecutable
    case invalidBundle
    case invalidPropertyList
    case executableTooSmall
    case signingFailed(String)
}

enum IdentityBundlePart: CaseIterable, Sendable {
    case outer
    case launcher
}

enum IdentitySymlinkPart: CaseIterable, Sendable {
    case parent
    case leaf
}

private final class FinderToolbarIdentityTestAnchor: NSObject {}

private final class FinderToolbarIdentityFixture {
    let rootURL: URL
    let applicationURL: URL

    init() throws {
        let fileManager = FileManager.default
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        rootURL = projectURL
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("Go2CodexIdentityFixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        applicationURL = rootURL.appendingPathComponent("Go2Codex.app", isDirectory: true)
        do {
            try Self.assembleApplication(at: applicationURL, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: rootURL)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func bundle() throws -> Bundle {
        guard let bundle = Bundle(url: applicationURL) else {
            throw IdentityFixtureError.invalidBundle
        }
        return bundle
    }

    func launcherURL() -> URL {
        applicationURL.appendingPathComponent(launcherRelativePath, isDirectory: true)
    }

    func removeLauncher() throws {
        try FileManager.default.removeItem(at: launcherURL())
    }

    func removeLauncherAgentFlag() throws {
        try mutatePropertyList(at: applicationURL.appendingPathComponent(launcherInfoPath)) {
            $0.removeValue(forKey: "LSUIElement")
        }
    }

    func removeOuterBundleIdentifier() throws {
        try mutatePropertyList(at: applicationURL.appendingPathComponent(outerInfoPath)) {
            $0.removeValue(forKey: "CFBundleIdentifier")
        }
    }

    func replaceBundleIdentifier(in part: IdentityBundlePart) throws {
        let path = part == .outer ? outerInfoPath : launcherInfoPath
        try mutatePropertyList(at: applicationURL.appendingPathComponent(path)) {
            $0["CFBundleIdentifier"] = "invalid.example.\(part)"
        }
    }

    func damageExecutableHeader(in part: IdentityBundlePart) throws {
        try flipExecutableByte(in: part, offset: 0)
    }

    func tamperWithExecutable(in part: IdentityBundlePart) throws {
        try flipExecutableByte(in: part, offset: 4_096)
    }

    func replaceLauncherPathWithSymlink(_ part: IdentitySymlinkPart) throws {
        let fileManager = FileManager.default
        let applicationsURL = applicationURL.appendingPathComponent("Contents/Applications", isDirectory: true)
        switch part {
        case .parent:
            let realApplicationsURL = applicationURL.appendingPathComponent("Contents/RealApplications", isDirectory: true)
            try fileManager.moveItem(at: applicationsURL, to: realApplicationsURL)
            try fileManager.createSymbolicLink(at: applicationsURL, withDestinationURL: realApplicationsURL)
        case .leaf:
            let launcherURL = launcherURL()
            let realLauncherURL = applicationsURL.appendingPathComponent("RealGo2CodexLauncher.app", isDirectory: true)
            try fileManager.moveItem(at: launcherURL, to: realLauncherURL)
            try fileManager.createSymbolicLink(at: launcherURL, withDestinationURL: realLauncherURL)
        }
    }

    private static func assembleApplication(
        at applicationURL: URL,
        fileManager: FileManager
    ) throws {
        let launcherURL = applicationURL.appendingPathComponent(launcherRelativePath, isDirectory: true)
        let outerExecutableURL = applicationURL.appendingPathComponent(outerExecutablePath)
        let launcherExecutableURL = applicationURL.appendingPathComponent(launcherExecutablePath)

        try fileManager.createDirectory(
            at: outerExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: launcherExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let testExecutableURL = try currentTestExecutableURL()
        try fileManager.copyItem(at: testExecutableURL, to: outerExecutableURL)
        try fileManager.copyItem(at: testExecutableURL, to: launcherExecutableURL)

        try writePropertyList(
            [
                "CFBundleExecutable": outerExecutableURL.lastPathComponent,
                "CFBundleIdentifier": outerBundleIdentifier,
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "Go2CodexFixture",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "Go2CodexPreferencesDomain": preferencesDomain,
            ],
            to: applicationURL.appendingPathComponent(outerInfoPath)
        )
        try writePropertyList(
            [
                "CFBundleExecutable": launcherExecutableURL.lastPathComponent,
                "CFBundleIdentifier": launcherBundleIdentifier,
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "Go2CodexLauncher",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "Go2CodexPreferencesDomain": preferencesDomain,
                "LSUIElement": true,
            ],
            to: launcherURL.appendingPathComponent("Contents/Info.plist")
        )

        try signApplication(at: launcherURL, identifier: launcherBundleIdentifier)
        try signApplication(at: applicationURL, identifier: outerBundleIdentifier)
    }

    private static func currentTestExecutableURL() throws -> URL {
        let bundle = Bundle(for: FinderToolbarIdentityTestAnchor.self)
        guard let executableURL = bundle.executableURL,
              FileManager.default.fileExists(atPath: executableURL.path) else {
            throw IdentityFixtureError.missingTestExecutable
        }
        return executableURL
    }

    private static func writePropertyList(_ propertyList: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    private static func signApplication(at url: URL, identifier: String) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--force",
            "--sign", "-",
            "--identifier", identifier,
            url.path,
        ]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw IdentityFixtureError.signingFailed(detail)
        }
    }

    private func mutatePropertyList(
        at url: URL,
        mutation: (inout [String: Any]) -> Void
    ) throws {
        let data = try Data(contentsOf: url)
        guard var propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw IdentityFixtureError.invalidPropertyList
        }
        mutation(&propertyList)
        let updated = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        try updated.write(to: url, options: .atomic)
    }

    private func flipExecutableByte(in part: IdentityBundlePart, offset: UInt64) throws {
        let path = part == .outer ? outerExecutablePath : launcherExecutablePath
        let url = applicationURL.appendingPathComponent(path)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let byte = try handle.read(upToCount: 1)?.first else {
            throw IdentityFixtureError.executableTooSmall
        }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data([byte ^ 0x01]))
        try handle.synchronize()
    }
}

@MainActor
private final class StubFinderToolbarPlatformContext: FinderToolbarPlatformContextAccessing {
    var environment: FinderToolbarEnvironment?
    var snapshotResult: Result<FinderToolbarSnapshot, FinderToolbarPlatformFailure>
    var receiptResult: Result<FinderToolbarReceiptEvidence, FinderToolbarPlatformFailure>
    var writeResult: Bool

    private(set) var environmentReadCount = 0
    private(set) var snapshotReadCount = 0
    private(set) var receiptReadCount = 0
    private(set) var writtenReceipts: [FinderToolbarInstallationReceipt] = []

    init(
        environment: FinderToolbarEnvironment? = FinderToolbarProfile.finder146Build23G80.environment,
        snapshotResult: Result<FinderToolbarSnapshot, FinderToolbarPlatformFailure> = .success(
            FinderToolbarSnapshot(
                configurationWasPresent: true,
                fields: FinderToolbarProfile.finder146Build23G80.scalarFields
            )
        ),
        receiptResult: Result<FinderToolbarReceiptEvidence, FinderToolbarPlatformFailure> = .success(.missing),
        writeResult: Bool = true
    ) {
        self.environment = environment
        self.snapshotResult = snapshotResult
        self.receiptResult = receiptResult
        self.writeResult = writeResult
    }

    func readEnvironment() -> FinderToolbarEnvironment? {
        environmentReadCount += 1
        return environment
    }

    func readSnapshot() -> Result<FinderToolbarSnapshot, FinderToolbarPlatformFailure> {
        snapshotReadCount += 1
        return snapshotResult
    }

    func readReceiptEvidence() -> Result<FinderToolbarReceiptEvidence, FinderToolbarPlatformFailure> {
        receiptReadCount += 1
        return receiptResult
    }

    func writeReceipt(_ receipt: FinderToolbarInstallationReceipt) -> Bool {
        writtenReceipts.append(receipt)
        return writeResult
    }
}

@MainActor
private final class StubFinderToolbarPlatformInspector: FinderToolbarPlatformInspecting {
    var inspection: FinderToolbarPlatformInspection
    var receiptWriteResult: Bool

    private(set) var recordedContexts: [FinderToolbarDetectionContext] = []

    init(
        inspection: FinderToolbarPlatformInspection,
        receiptWriteResult: Bool = true
    ) {
        self.inspection = inspection
        self.receiptWriteResult = receiptWriteResult
    }

    func inspect() -> FinderToolbarPlatformInspection {
        inspection
    }

    func embeddedLauncherURL() -> Result<URL, FinderToolbarPlatformFailure> {
        .failure(.launcherMissing)
    }

    func recordVerifiedInstalledReceipt(for context: FinderToolbarDetectionContext) -> Bool {
        recordedContexts.append(context)
        return receiptWriteResult
    }
}

private func explicitSnapshot(
    identifiers: [String],
    itemPlists: [Int: FinderToolbarItemPayload]
) -> FinderToolbarSnapshot {
    let profile = FinderToolbarProfile.finder146Build23G80
    var fields = profile.scalarFields
    fields[FinderToolbarPreferenceKey.itemIdentifiers] = .array(identifiers.map { .string($0) })
    fields[FinderToolbarPreferenceKey.defaultItemIdentifiers] = .array(
        profile.defaultIdentifiers.map { .string($0) }
    )
    fields[FinderToolbarPreferenceKey.itemPlists] = .dictionary(
        Dictionary(uniqueKeysWithValues: itemPlists.map { (String($0.key), .dictionary($0.value)) })
    )
    return FinderToolbarSnapshot(configurationWasPresent: true, fields: fields)
}

private func launcherIdentity(at url: URL) -> FinderToolbarLauncherIdentity {
    FinderToolbarLauncherIdentity(
        url: url.standardizedFileURL,
        fingerprint: "fixture-fingerprint",
        launcherBundleIdentifier: "io.github.czrzchao.go2codex.launcher.debug",
        outerBundleIdentifier: "io.github.czrzchao.go2codex.debug"
    )
}

private func installedContext(
    identity: FinderToolbarLauncherIdentity,
    receipt: FinderToolbarReceiptEvidence = .missing
) -> FinderToolbarDetectionContext {
    let profile = FinderToolbarProfile.finder146Build23G80
    let index = profile.activeBaseline.count - profile.trailingReservedItemCount
    var identifiers = profile.activeBaseline
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: index)
    let snapshot = explicitSnapshot(
        identifiers: identifiers,
        itemPlists: [
            index: [
                FinderToolbarPreferenceKey.urlString: .string(identity.url.standardizedFileURL.absoluteString),
                FinderToolbarPreferenceKey.urlStringType: .integer(15),
                FinderToolbarPreferenceKey.aliasData: .data(Data([0x01])),
            ],
        ]
    )
    return FinderToolbarDetectionContext(
        snapshot: snapshot,
        environment: profile.environment,
        launcherIdentity: .verified(identity),
        receipt: receipt,
        aliasResolutions: [index: .resolved(identity.url)]
    )
}

private func needsRepairContext(
    identity: FinderToolbarLauncherIdentity,
    staleURL: URL
) -> FinderToolbarDetectionContext {
    let profile = FinderToolbarProfile.finder146Build23G80
    let index = profile.activeBaseline.count - profile.trailingReservedItemCount
    var identifiers = profile.activeBaseline
    identifiers.insert(FinderToolbarPreferenceKey.customItemIdentifier, at: index)
    let snapshot = explicitSnapshot(
        identifiers: identifiers,
        itemPlists: [
            index: [
                FinderToolbarPreferenceKey.urlString: .string(staleURL.standardizedFileURL.absoluteString),
                FinderToolbarPreferenceKey.urlStringType: .integer(15),
                FinderToolbarPreferenceKey.aliasData: .data(Data([0x01])),
            ],
        ]
    )
    let receipt = FinderToolbarInstallationReceipt(
        profileIdentifier: profile.identifier,
        environment: profile.environment,
        lastVerifiedLauncherURL: staleURL,
        launcherIdentityFingerprint: identity.fingerprint,
        launcherBundleIdentifier: identity.launcherBundleIdentifier,
        outerBundleIdentifier: identity.outerBundleIdentifier
    )
    return FinderToolbarDetectionContext(
        snapshot: snapshot,
        environment: profile.environment,
        launcherIdentity: .verified(identity),
        receipt: .valid(receipt),
        aliasResolutions: [index: .resolved(identity.url)],
        storedPathStates: [staleURL.standardizedFileURL.absoluteString: .missing]
    )
}

private func platformFailure(
    in inspection: FinderToolbarPlatformInspection
) -> FinderToolbarPlatformFailure? {
    guard case let .unavailable(failure) = inspection else {
        return nil
    }
    return failure
}

@MainActor
@Test
func signedDebugApplicationReturnsItsExactNestedLauncherURL() throws {
    let fixture = try FinderToolbarIdentityFixture()
    let result = FinderToolbarPlatformInspector(outerBundle: try fixture.bundle()).embeddedLauncherURL()
    #expect(result == .success(fixture.launcherURL().standardizedFileURL))
}

@MainActor
@Test
func missingNestedLauncherFailsBeforeIdentityInspection() throws {
    let fixture = try FinderToolbarIdentityFixture()
    try fixture.removeLauncher()
    let result = FinderToolbarPlatformInspector(outerBundle: try fixture.bundle()).embeddedLauncherURL()
    #expect(result == .failure(.launcherMissing))
}

@MainActor
@Test
func missingLauncherAgentFlagHasItsOwnFailure() throws {
    let fixture = try FinderToolbarIdentityFixture()
    try fixture.removeLauncherAgentFlag()
    let result = FinderToolbarPlatformInspector(outerBundle: try fixture.bundle()).embeddedLauncherURL()
    #expect(result == .failure(.launcherIsNotAgent))
}

@MainActor
@Test(arguments: IdentityBundlePart.allCases)
func wrongOuterOrLauncherBundleIdentifierFailsClosed(_ part: IdentityBundlePart) throws {
    let fixture = try FinderToolbarIdentityFixture()
    try fixture.replaceBundleIdentifier(in: part)
    let result = FinderToolbarPlatformInspector(outerBundle: try fixture.bundle()).embeddedLauncherURL()
    #expect(result == .failure(.invalidBundleIdentifiers))
}

@MainActor
@Test
func missingOuterBundleIdentifierHasItsOwnFailure() throws {
    let fixture = try FinderToolbarIdentityFixture()
    try fixture.removeOuterBundleIdentifier()
    let result = FinderToolbarPlatformInspector(outerBundle: try fixture.bundle()).embeddedLauncherURL()
    #expect(result == .failure(.outerBundleInvalid))
}

@MainActor
@Test(arguments: IdentityBundlePart.allCases)
func damagedOuterOrLauncherMachOHeaderFailsArchitectureInspection(_ part: IdentityBundlePart) throws {
    let fixture = try FinderToolbarIdentityFixture()
    try fixture.damageExecutableHeader(in: part)
    let result = FinderToolbarPlatformInspector(outerBundle: try fixture.bundle()).embeddedLauncherURL()
    #expect(result == .failure(.invalidArchitecture))
}

@MainActor
@Test(arguments: IdentityBundlePart.allCases)
func codeTamperingAfterTheMachOHeaderFailsStaticCodeValidation(_ part: IdentityBundlePart) throws {
    let fixture = try FinderToolbarIdentityFixture()
    try fixture.tamperWithExecutable(in: part)
    let result = FinderToolbarPlatformInspector(outerBundle: try fixture.bundle()).embeddedLauncherURL()
    #expect(result == .failure(.invalidCodeSignature))
}

@MainActor
@Test(arguments: IdentitySymlinkPart.allCases)
func launcherParentOrLeafSymlinkFailsBeforeBundleInspection(_ part: IdentitySymlinkPart) throws {
    let fixture = try FinderToolbarIdentityFixture()
    try fixture.replaceLauncherPathWithSymlink(part)
    let result = FinderToolbarPlatformInspector(outerBundle: try fixture.bundle()).embeddedLauncherURL()
    #expect(result == .failure(.symbolicLinkOrPathEscape))
}

@MainActor
@Test
func productionInspectorAssemblesInjectedEnvironmentSnapshotReceiptAndPathEvidence() throws {
    let fixture = try FinderToolbarIdentityFixture()
    let profile = FinderToolbarProfile.finder146Build23G80
    let presentURL = fixture.launcherURL().standardizedFileURL
    let missingURL = fixture.rootURL
        .appendingPathComponent("MissingLauncher.app", isDirectory: true)
        .standardizedFileURL
    let snapshot = explicitSnapshot(
        identifiers: [
            FinderToolbarPreferenceKey.customItemIdentifier,
            FinderToolbarPreferenceKey.customItemIdentifier,
        ],
        itemPlists: [
            0: [
                FinderToolbarPreferenceKey.urlString: .string(presentURL.absoluteString),
                FinderToolbarPreferenceKey.urlStringType: .integer(15),
            ],
            1: [
                FinderToolbarPreferenceKey.urlString: .string(missingURL.absoluteString),
                FinderToolbarPreferenceKey.urlStringType: .integer(15),
            ],
        ]
    )
    let receipt = FinderToolbarInstallationReceipt(
        profileIdentifier: profile.identifier,
        environment: profile.environment,
        lastVerifiedLauncherURL: presentURL,
        launcherIdentityFingerprint: "receipt-fingerprint",
        launcherBundleIdentifier: "receipt-launcher",
        outerBundleIdentifier: "receipt-outer"
    )
    let platformContext = StubFinderToolbarPlatformContext(
        snapshotResult: .success(snapshot),
        receiptResult: .success(.valid(receipt))
    )
    let inspector = FinderToolbarPlatformInspector(
        outerBundle: try fixture.bundle(),
        platformContext: platformContext
    )

    guard case let .verified(context, locationEligible) = inspector.inspect() else {
        Issue.record("Expected a verified platform inspection")
        return
    }

    #expect(locationEligible)
    #expect(context.environment == profile.environment)
    #expect(context.snapshot == snapshot)
    #expect(context.receipt == .valid(receipt))
    #expect(context.aliasResolutions == [0: .absent, 1: .absent])
    #expect(context.storedPathStates == [
        presentURL.absoluteString: .present,
        missingURL.absoluteString: .missing,
    ])
    guard case let .verified(identity) = context.launcherIdentity else {
        Issue.record("Expected the signed nested launcher identity")
        return
    }
    #expect(identity.url == presentURL)
    #expect(platformContext.environmentReadCount == 1)
    #expect(platformContext.snapshotReadCount == 1)
    #expect(platformContext.receiptReadCount == 1)
}

@MainActor
@Test
func productionInspectorFailsClosedAtInjectedContextBoundaries() throws {
    let fixture = try FinderToolbarIdentityFixture()
    let bundle = try fixture.bundle()

    let missingEnvironment = StubFinderToolbarPlatformContext(environment: nil)
    let environmentInspection = FinderToolbarPlatformInspector(
        outerBundle: bundle,
        platformContext: missingEnvironment
    ).inspect()
    #expect(platformFailure(in: environmentInspection) == .environmentUnavailable)
    #expect(missingEnvironment.snapshotReadCount == 0)
    #expect(missingEnvironment.receiptReadCount == 0)

    let disagreeingSnapshot = StubFinderToolbarPlatformContext(
        snapshotResult: .failure(.finderPreferencesDisagree)
    )
    let snapshotInspection = FinderToolbarPlatformInspector(
        outerBundle: bundle,
        platformContext: disagreeingSnapshot
    ).inspect()
    #expect(platformFailure(in: snapshotInspection) == .finderPreferencesDisagree)
    #expect(disagreeingSnapshot.snapshotReadCount == 1)
    #expect(disagreeingSnapshot.receiptReadCount == 0)

    let invalidReceiptStore = StubFinderToolbarPlatformContext(
        receiptResult: .failure(.invalidReceiptStore)
    )
    let receiptInspection = FinderToolbarPlatformInspector(
        outerBundle: bundle,
        platformContext: invalidReceiptStore
    ).inspect()
    #expect(platformFailure(in: receiptInspection) == .invalidReceiptStore)
    #expect(invalidReceiptStore.snapshotReadCount == 1)
    #expect(invalidReceiptStore.receiptReadCount == 1)
}

@MainActor
@Test
func readOnlySettingsServiceMapsStatusesAndRecordsOnlyInstalledContext() async {
    let profile = FinderToolbarProfile.finder146Build23G80
    let identity = launcherIdentity(
        at: URL(fileURLWithPath: "/Applications/Go2Codex.app/Contents/Applications/Go2CodexLauncher.app")
    )
    let scalarSnapshot = FinderToolbarSnapshot(
        configurationWasPresent: true,
        fields: profile.scalarFields
    )
    let installed = installedContext(identity: identity)
    let notInstalled = FinderToolbarDetectionContext(
        snapshot: scalarSnapshot,
        environment: profile.environment,
        launcherIdentity: .verified(identity)
    )
    let needsRepair = needsRepairContext(
        identity: identity,
        staleURL: URL(fileURLWithPath: "/Applications/OldGo2Codex.app/Contents/Applications/Go2CodexLauncher.app")
    )
    let manual = FinderToolbarDetectionContext(
        snapshot: scalarSnapshot,
        environment: profile.environment,
        launcherIdentity: .invalid
    )

    let cases: [(FinderToolbarPlatformInspection, ToolbarSettingsStatus, FinderToolbarDetectionContext?)] = [
        (.verified(installed, automaticActionsLocationEligible: true), .installed, installed),
        (.verified(notInstalled, automaticActionsLocationEligible: true), .notInstalled, nil),
        (.verified(needsRepair, automaticActionsLocationEligible: true), .needsRepair, nil),
        (.verified(manual, automaticActionsLocationEligible: true), .manualSetupRequired, nil),
        (.unavailable(.finderPreferencesUnavailable), .manualSetupRequired, nil),
    ]

    for (inspection, expectedStatus, recordedContext) in cases {
        let inspector = StubFinderToolbarPlatformInspector(
            inspection: inspection,
            receiptWriteResult: false
        )
        let service = ReadOnlyFinderToolbarSettingsService(inspector: inspector)
        let status = await service.currentStatus()
        #expect(status == expectedStatus)
        if let recordedContext {
            #expect(inspector.recordedContexts == [recordedContext])
        } else {
            #expect(inspector.recordedContexts.isEmpty)
        }
    }
}

@MainActor
@Test
func productionInspectorWritesExactReceiptForVerifiedInstalledContext() throws {
    let fixture = try FinderToolbarIdentityFixture()
    let platformContext = StubFinderToolbarPlatformContext()
    let inspector = FinderToolbarPlatformInspector(
        outerBundle: try fixture.bundle(),
        platformContext: platformContext
    )
    guard case let .verified(initialContext, _) = inspector.inspect(),
          case let .verified(identity) = initialContext.launcherIdentity else {
        Issue.record("Expected a verified signed launcher identity")
        return
    }
    let context = installedContext(identity: identity)

    #expect(inspector.recordVerifiedInstalledReceipt(for: context))
    #expect(platformContext.writtenReceipts == [
        FinderToolbarInstallationReceipt(
            profileIdentifier: FinderToolbarProfile.finder146Build23G80.identifier,
            environment: context.environment,
            lastVerifiedLauncherURL: identity.url,
            launcherIdentityFingerprint: identity.fingerprint,
            launcherBundleIdentifier: identity.launcherBundleIdentifier,
            outerBundleIdentifier: identity.outerBundleIdentifier
        ),
    ])
}

@MainActor
@Test
func systemPlatformContextReadsAndWritesReceiptsThroughTheApplicationDomainResolver() throws {
    let fixture = try FinderToolbarIdentityFixture()
    let bundle = try fixture.bundle()
    let expectedDomain = try #require(
        bundle.object(forInfoDictionaryKey: "Go2CodexPreferencesDomain") as? String
    )
    let suiteName = "io.github.czrzchao.go2codex.tests.receipt.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.removeObject(forKey: FinderToolbarPlatformInspector.receiptStorageKey)
    var requestedDomains: [String] = []
    let context = SystemFinderToolbarPlatformContext(
        outerBundle: bundle,
        fileManager: .default,
        workspace: .shared,
        receiptDefaultsResolver: {
            requestedDomains.append($0)
            return defaults
        }
    )

    #expect(context.readReceiptEvidence() == .success(.missing))
    let receipt = FinderToolbarInstallationReceipt(
        profileIdentifier: FinderToolbarProfile.finder146Build23G80.identifier,
        environment: FinderToolbarProfile.finder146Build23G80.environment,
        lastVerifiedLauncherURL: fixture.launcherURL(),
        launcherIdentityFingerprint: "receipt-test-fingerprint",
        launcherBundleIdentifier: "io.github.czrzchao.go2codex.debug.launcher",
        outerBundleIdentifier: "io.github.czrzchao.go2codex.debug"
    )
    #expect(context.writeReceipt(receipt))
    #expect(context.readReceiptEvidence() == .success(.valid(receipt)))
    #expect(requestedDomains == [expectedDomain, expectedDomain, expectedDomain])
}
