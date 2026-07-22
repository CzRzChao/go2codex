import AppKit
import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Go2CodexCore
import OSLog
import Security

@MainActor
protocol ToolbarAutomaticMutationCapability: AnyObject {
    var supportsAutomaticMutation: Bool { get }
}

@MainActor
protocol FinderToolbarMutationExecuting: AnyObject {
    func recoverIfNeeded(
        profile: FinderToolbarProfile,
        launcherIdentity: FinderToolbarLauncherIdentity
    ) async -> FinderToolbarMutationRecoveryResult

    func execute(
        plan: FinderToolbarMutationPlan,
        profile: FinderToolbarProfile,
        launcherIdentity: FinderToolbarLauncherIdentity
    ) async -> Bool
}

enum FinderToolbarMutationRecoveryResult: Equatable, Sendable {
    case none
    case recovered
    case manualInterventionRequired
}

@MainActor
final class FinderToolbarSettingsService: ToolbarSettingsServing, ToolbarAutomaticMutationCapability {
    private(set) var supportsAutomaticMutation = false

    private let inspector: FinderToolbarPlatformInspecting
    private let mutationExecutor: any FinderToolbarMutationExecuting
    private let automaticMutationConfirmation: ((ToolbarSettingsAction) -> Bool)?
    private let logger: Logger

    convenience init() {
        self.init(
            inspector: FinderToolbarPlatformInspector(),
            mutationExecutor: SystemFinderToolbarMutationExecutor(),
            automaticMutationConfirmation: nil
        )
    }

    convenience init(inspector: FinderToolbarPlatformInspecting) {
        self.init(
            inspector: inspector,
            mutationExecutor: SystemFinderToolbarMutationExecutor(),
            automaticMutationConfirmation: nil
        )
    }

    init(
        inspector: FinderToolbarPlatformInspecting,
        mutationExecutor: any FinderToolbarMutationExecuting,
        automaticMutationConfirmation: ((ToolbarSettingsAction) -> Bool)? = nil
    ) {
        self.inspector = inspector
        self.mutationExecutor = mutationExecutor
        self.automaticMutationConfirmation = automaticMutationConfirmation
        let subsystem = Bundle.main.object(
            forInfoDictionaryKey: "Go2CodexPreferencesDomain"
        ) as? String ?? "io.github.czrzchao.go2codex"
        logger = Logger(subsystem: subsystem, category: "FinderInstaller")
    }

    func currentStatus() async -> ToolbarSettingsStatus {
        var inspection = inspector.inspect()
        updateAutomaticMutationCapability(from: inspection)
        if case let .verified(context, _) = inspection,
           let profile = FinderToolbarProfileRegistry.profile(for: context.environment),
           case let .verified(identity) = context.launcherIdentity {
            switch await mutationExecutor.recoverIfNeeded(
                profile: profile,
                launcherIdentity: identity
            ) {
            case .none:
                break
            case .recovered:
                inspection = inspector.inspect()
                updateAutomaticMutationCapability(from: inspection)
            case .manualInterventionRequired:
                logger.error("Interrupted Finder toolbar transaction requires manual recovery")
                return .manualSetupRequired
            }
        }

        switch inspection {
        case let .verified(context, _):
            switch FinderToolbarDetector.detect(context) {
            case .installed:
                if !inspector.recordVerifiedInstalledReceipt(for: context) {
                    logger.error("Failed to persist verified Finder toolbar receipt")
                }
                return .installed
            case .notInstalled:
                return .notInstalled
            case .needsRepair:
                return .needsRepair
            case .manualSetupRequired:
                return .manualSetupRequired
            }
        case let .unavailable(reason):
            logger.notice("Read-only Finder toolbar inspection unavailable reason=\(String(describing: reason), privacy: .public)")
            return .manualSetupRequired
        }
    }

    private func updateAutomaticMutationCapability(
        from inspection: FinderToolbarPlatformInspection
    ) {
        guard case let .verified(_, automaticActionsLocationEligible) = inspection else {
            supportsAutomaticMutation = false
            return
        }
        supportsAutomaticMutation = automaticActionsLocationEligible
    }

    func perform(_ action: ToolbarSettingsAction) async -> ToolbarSettingsActionResult {
        switch action {
        case .showManualSetup:
            logger.info("Presenting manual Finder toolbar setup")
            switch showManualSetup() {
            case .shown, .handled:
                return .status(await currentStatus())
            case .failed:
                return .failed
            }
        case .install, .repair, .uninstall:
            return await performMutationOrFallback(action)
        }
    }

    private func performMutationOrFallback(
        _ action: ToolbarSettingsAction
    ) async -> ToolbarSettingsActionResult {
        guard case let .verified(context, automaticActionsLocationEligible) = inspector.inspect(),
              automaticActionsLocationEligible,
              let profile = FinderToolbarProfileRegistry.profile(for: context.environment),
              case let .verified(identity) = context.launcherIdentity else {
            return await performManualFallback(action)
        }

        let planned: FinderToolbarMutationResult
        switch action {
        case .install:
            planned = FinderToolbarMutationPlanner.install(context, profile: profile)
        case .repair:
            planned = FinderToolbarMutationPlanner.repair(context, profile: profile)
        case .uninstall:
            planned = FinderToolbarMutationPlanner.uninstall(context, profile: profile)
        case .showManualSetup:
            return .failed
        }

        switch planned {
        case .noChange:
            return .status(await currentStatus())
        case .blocked:
            return await performManualFallback(action)
        case let .mutation(plan):
            guard confirmAutomaticMutation(for: action) else {
                return .cancelled
            }
            guard await mutationExecutor.execute(
                plan: plan,
                profile: profile,
                launcherIdentity: identity
            ) else {
                logger.error("Experimental Finder toolbar mutation failed operation=\(action.debugName, privacy: .public)")
                return .failed
            }
            return .status(await currentStatus())
        }
    }

    private func performManualFallback(
        _ action: ToolbarSettingsAction
    ) async -> ToolbarSettingsActionResult {
        logger.info("Automatic Finder mutation unavailable; offering manual fallback")
        guard confirmManualFallback(for: action) else {
            return .cancelled
        }
        if action == .uninstall {
            showManualRemovalInstructions()
            return .status(await currentStatus())
        }
        switch showManualSetup() {
        case .shown, .handled:
            return .status(await currentStatus())
        case .failed:
            return .failed
        }
    }

    private func confirmAutomaticMutation(for action: ToolbarSettingsAction) -> Bool {
        if let automaticMutationConfirmation {
            return automaticMutationConfirmation(action)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = action.confirmationTitle
        alert.informativeText = action.confirmationMessage
        alert.addButton(withTitle: action.confirmationButtonTitle)
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel a Finder toolbar action"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmManualFallback(for action: ToolbarSettingsAction) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Manual Finder Action Required", comment: "Finder toolbar manual fallback confirmation title")
        switch action {
        case .install:
            alert.informativeText = NSLocalizedString(
                "Automatic Finder installation is unavailable. Go2Codex will not modify Finder preferences or restart Finder. Continue with manual setup?",
                comment: "Manual Finder installation confirmation"
            )
        case .repair:
            alert.informativeText = NSLocalizedString(
                "Automatic Finder repair is unavailable. Go2Codex will not modify Finder preferences or restart Finder. Continue with manual setup?",
                comment: "Manual Finder repair confirmation"
            )
        case .uninstall:
            alert.informativeText = NSLocalizedString(
                "Automatic Finder removal is unavailable. Go2Codex will not modify Finder preferences or restart Finder. Show the manual removal step?",
                comment: "Manual Finder removal confirmation"
            )
        case .showManualSetup:
            return true
        }
        alert.addButton(withTitle: NSLocalizedString("Continue Manually", comment: "Continue to Finder manual steps"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel a Finder toolbar action"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showManualSetup() -> ManualSetupPresentation {
        let launcherInspection = inspector.embeddedLauncherURL()
        if case .failure(.unstableReleaseLocation) = launcherInspection {
            showStableLocationInstructions()
            return .handled
        }
        guard case let .success(launcherURL) = launcherInspection else {
            return .failed
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Manual Finder Setup", comment: "Finder toolbar manual setup title")
        alert.informativeText = NSLocalizedString(
            "If an older Go2Codex button is already present, first hold Command (⌘) and drag it out of the toolbar. Then hold Command and drag the revealed Go2Codex into the toolbar.",
            comment: "Replace an old toolbar item and Command-drag the nested Launcher into Finder's toolbar"
        )
        alert.addButton(withTitle: NSLocalizedString("Show in Finder", comment: "Reveal the toolbar Launcher in Finder"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel manual Finder setup"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .handled
        }
        NSWorkspace.shared.activateFileViewerSelecting([launcherURL])
        return .shown
    }

    private func showStableLocationInstructions() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString(
            "Move Go2Codex to Applications",
            comment: "Stable application location requirement title"
        )
        alert.informativeText = NSLocalizedString(
            "Before adding the Finder toolbar button, move Go2Codex to Applications or your user Applications folder, then open it again.",
            comment: "Stable application location requirement"
        )
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Dismiss stable location instructions"))
        alert.runModal()
    }

    private func showManualRemovalInstructions() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Manual Finder Removal", comment: "Finder toolbar manual removal title")
        alert.informativeText = NSLocalizedString(
            "In Finder, hold Command (⌘) and drag the Go2Codex button out of the toolbar.",
            comment: "Command-drag Go2Codex out of Finder's toolbar"
        )
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Dismiss manual Finder removal instructions"))
        alert.runModal()
    }

    private enum ManualSetupPresentation {
        case shown
        case handled
        case failed
    }
}

private extension ToolbarSettingsAction {
    var debugName: String {
        switch self {
        case .install: "install"
        case .repair: "repair"
        case .uninstall: "uninstall"
        case .showManualSetup: "show-manual-setup"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .install:
            NSLocalizedString("Install Go2Codex in Finder?", comment: "Experimental Finder install confirmation title")
        case .repair:
            NSLocalizedString("Repair Go2Codex in Finder?", comment: "Experimental Finder repair confirmation title")
        case .uninstall:
            NSLocalizedString("Remove Go2Codex from Finder?", comment: "Experimental Finder uninstall confirmation title")
        case .showManualSetup:
            NSLocalizedString("Manual Finder Setup", comment: "Finder toolbar manual setup title")
        }
    }

    var confirmationMessage: String {
        switch self {
        case .install:
            NSLocalizedString(
                "Experimental setup will update your private Finder toolbar preferences and restart Finder. Go2Codex creates a recovery journal first and preserves unrelated toolbar items.",
                comment: "Experimental Finder install confirmation"
            )
        case .repair:
            NSLocalizedString(
                "Experimental repair will update the existing Go2Codex toolbar item and restart Finder. Go2Codex creates a recovery journal first and preserves unrelated toolbar items.",
                comment: "Experimental Finder repair confirmation"
            )
        case .uninstall:
            NSLocalizedString(
                "Experimental removal will remove only the verified Go2Codex toolbar item and restart Finder. Go2Codex creates a recovery journal first.",
                comment: "Experimental Finder uninstall confirmation"
            )
        case .showManualSetup:
            ""
        }
    }

    var confirmationButtonTitle: String {
        switch self {
        case .install:
            NSLocalizedString("Install and Restart Finder", comment: "Confirm experimental Finder install")
        case .repair:
            NSLocalizedString("Repair and Restart Finder", comment: "Confirm experimental Finder repair")
        case .uninstall:
            NSLocalizedString("Remove and Restart Finder", comment: "Confirm experimental Finder uninstall")
        case .showManualSetup:
            NSLocalizedString("Continue Manually", comment: "Continue to Finder manual steps")
        }
    }
}

@MainActor
protocol FinderToolbarPlatformInspecting: AnyObject {
    func inspect() -> FinderToolbarPlatformInspection
    func embeddedLauncherURL() -> Result<URL, FinderToolbarPlatformFailure>
    func recordVerifiedInstalledReceipt(for context: FinderToolbarDetectionContext) -> Bool
}

enum FinderToolbarPlatformInspection: Sendable {
    case verified(FinderToolbarDetectionContext, automaticActionsLocationEligible: Bool)
    case unavailable(FinderToolbarPlatformFailure)
}

enum FinderToolbarPlatformFailure: Error, Equatable, Sendable {
    case environmentUnavailable
    case finderPreferencesUnavailable
    case finderPreferencesDisagree
    case invalidFinderPreference
    case outerBundleInvalid
    case launcherMissing
    case launcherNotDirectlyNested
    case symbolicLinkOrPathEscape
    case invalidBundleIdentifiers
    case launcherIsNotAgent
    case invalidArchitecture
    case invalidCodeSignature
    case invalidSigningRelationship
    case invalidReceiptStore
    case unstableReleaseLocation
    case transactionJournalUnavailable
    case finderPreferenceWriteFailed
    case finderRestartFailed
    case semanticVerificationFailed
}

@MainActor
protocol FinderToolbarPlatformContextAccessing: AnyObject {
    func readEnvironment() -> FinderToolbarEnvironment?
    func readSnapshot() -> Result<FinderToolbarSnapshot, FinderToolbarPlatformFailure>
    func readReceiptEvidence() -> Result<FinderToolbarReceiptEvidence, FinderToolbarPlatformFailure>
    func writeReceipt(_ receipt: FinderToolbarInstallationReceipt) -> Bool
}

@MainActor
protocol FinderToolbarMutationPlatformAccessing: AnyObject {
    func readSnapshot() -> Result<FinderToolbarSnapshot, FinderToolbarPlatformFailure>
    func writeSnapshot(_ snapshot: FinderToolbarSnapshot) -> Bool
    func writeReceipt(_ receipt: FinderToolbarInstallationReceipt) -> Bool
    func clearReceipt() -> Bool
    func restartFinder() async -> Bool
    func resolveAlias(
        _ value: FinderToolbarPropertyListValue?
    ) -> FinderToolbarAliasResolution
}

@MainActor
final class SystemFinderToolbarPlatformContext: FinderToolbarPlatformContextAccessing, FinderToolbarMutationPlatformAccessing {
    private let outerBundle: Bundle
    private let fileManager: FileManager
    private let workspace: NSWorkspace
    private let receiptDefaultsResolver: @MainActor (String) -> UserDefaults?

    init(
        outerBundle: Bundle,
        fileManager: FileManager,
        workspace: NSWorkspace,
        receiptDefaultsResolver: @escaping @MainActor (String) -> UserDefaults? = {
            try? ApplicationUserDefaultsResolver.defaults(declaredDomain: $0)
        }
    ) {
        self.outerBundle = outerBundle
        self.fileManager = fileManager
        self.workspace = workspace
        self.receiptDefaultsResolver = receiptDefaultsResolver
    }

    func readEnvironment() -> FinderToolbarEnvironment? {
        guard let macOSBuild = systemBuildVersion(),
              let finderURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.finder"),
              let finderBundle = Bundle(url: finderURL),
              let finderVersion = finderBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let finderBundleVersion = finderBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !finderVersion.isEmpty,
              !finderBundleVersion.isEmpty else {
            return nil
        }
        return FinderToolbarEnvironment(
            macOSBuild: macOSBuild,
            finderVersion: finderVersion,
            finderBundleVersion: finderBundleVersion
        )
    }

    func readSnapshot() -> Result<FinderToolbarSnapshot, FinderToolbarPlatformFailure> {
        let domain = FinderToolbarPreferenceKey.domain as CFString
        guard CFPreferencesAppSynchronize(domain) else {
            return .failure(.finderPreferencesUnavailable)
        }
        let firstLiveValue = CFPreferencesCopyAppValue(
            FinderToolbarPreferenceKey.configuration as CFString,
            domain
        )
        let diskURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.finder.plist", isDirectory: false)
        guard let diskData = try? Data(contentsOf: diskURL),
              let diskRoot = try? PropertyListSerialization.propertyList(from: diskData, options: [], format: nil),
              let diskDictionary = stringDictionary(diskRoot) else {
            return .failure(.finderPreferencesUnavailable)
        }

        let diskPresent = diskDictionary.keys.contains(FinderToolbarPreferenceKey.configuration)
        let diskResult = FinderToolbarSnapshotAdapter.decode(
            diskDictionary[FinderToolbarPreferenceKey.configuration],
            configurationWasPresent: diskPresent
        )

        let secondLiveValue = CFPreferencesCopyAppValue(
            FinderToolbarPreferenceKey.configuration as CFString,
            domain
        )
        let firstLiveResult = FinderToolbarSnapshotAdapter.decode(
            firstLiveValue,
            configurationWasPresent: firstLiveValue != nil
        )
        let secondLiveResult = FinderToolbarSnapshotAdapter.decode(
            secondLiveValue,
            configurationWasPresent: secondLiveValue != nil
        )

        guard case let .success(diskSnapshot) = diskResult,
              case let .success(firstLiveSnapshot) = firstLiveResult,
              case let .success(secondLiveSnapshot) = secondLiveResult else {
            return .failure(.invalidFinderPreference)
        }
        guard FinderToolbarPlatformPolicy.snapshotsConverge(
            firstLive: firstLiveSnapshot,
            disk: diskSnapshot,
            secondLive: secondLiveSnapshot
        ) else {
            return .failure(.finderPreferencesDisagree)
        }
        return .success(diskSnapshot)
    }

    func readReceiptEvidence() -> Result<FinderToolbarReceiptEvidence, FinderToolbarPlatformFailure> {
        guard let defaults = receiptDefaults() else {
            return .failure(.invalidReceiptStore)
        }
        guard let stored = defaults.object(forKey: FinderToolbarPlatformInspector.receiptStorageKey) else {
            return .success(.missing)
        }
        guard let data = stored as? Data,
              let receipt = try? JSONDecoder().decode(FinderToolbarInstallationReceipt.self, from: data) else {
            return .success(.invalid)
        }
        return .success(.valid(receipt))
    }

    func writeReceipt(_ receipt: FinderToolbarInstallationReceipt) -> Bool {
        guard let defaults = receiptDefaults(),
              let data = try? JSONEncoder().encode(receipt) else {
            return false
        }
        if defaults.data(forKey: FinderToolbarPlatformInspector.receiptStorageKey) == data {
            return true
        }
        defaults.set(data, forKey: FinderToolbarPlatformInspector.receiptStorageKey)
        guard defaults.synchronize() else {
            return false
        }
        return defaults.data(forKey: FinderToolbarPlatformInspector.receiptStorageKey) == data
    }

    func clearReceipt() -> Bool {
        guard let defaults = receiptDefaults() else {
            return false
        }
        defaults.removeObject(forKey: FinderToolbarPlatformInspector.receiptStorageKey)
        guard defaults.synchronize() else {
            return false
        }
        return defaults.object(forKey: FinderToolbarPlatformInspector.receiptStorageKey) == nil
    }

    func writeSnapshot(_ snapshot: FinderToolbarSnapshot) -> Bool {
        let domain = FinderToolbarPreferenceKey.domain as CFString
        let key = FinderToolbarPreferenceKey.configuration as CFString
        if let encoded = FinderToolbarSnapshotAdapter.encode(snapshot) {
            CFPreferencesSetAppValue(key, encoded as CFPropertyList, domain)
        } else {
            CFPreferencesSetAppValue(key, nil, domain)
        }
        return CFPreferencesAppSynchronize(domain)
    }

    func restartFinder() async -> Bool {
        let finderIdentifier = FinderToolbarPreferenceKey.domain
        guard let currentFinder = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == finderIdentifier && !$0.isTerminated
        }) else {
            return false
        }
        let previousProcessIdentifier = currentFinder.processIdentifier
        if !currentFinder.terminate(), kill(previousProcessIdentifier, SIGTERM) != 0 {
            return false
        }

        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if workspace.runningApplications.contains(where: {
                $0.bundleIdentifier == finderIdentifier
                    && !$0.isTerminated
                    && $0.processIdentifier != previousProcessIdentifier
            }) {
                return true
            }
        }
        return false
    }

    func resolveAlias(
        _ value: FinderToolbarPropertyListValue?
    ) -> FinderToolbarAliasResolution {
        FinderToolbarAliasRecordResolver.resolve(value)
    }

    private func systemBuildVersion() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func stringDictionary(_ value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        guard let dictionary = value as? NSDictionary else {
            return nil
        }
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            guard let key = key as? String else {
                return nil
            }
            result[key] = value
        }
        return result
    }

    private func receiptDefaults() -> UserDefaults? {
        guard let domain = outerBundle.object(forInfoDictionaryKey: "Go2CodexPreferencesDomain") as? String,
              !domain.isEmpty else {
            return nil
        }
        return receiptDefaultsResolver(domain)
    }
}

@MainActor
final class FinderToolbarPlatformInspector: FinderToolbarPlatformInspecting {
    static let receiptStorageKey = "FinderToolbarInstallationReceipt.v1"

    private let outerBundle: Bundle
    private let fileManager: FileManager
    private let platformContext: any FinderToolbarPlatformContextAccessing

    convenience init(
        outerBundle: Bundle = .main,
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) {
        self.init(
            outerBundle: outerBundle,
            fileManager: fileManager,
            platformContext: SystemFinderToolbarPlatformContext(
                outerBundle: outerBundle,
                fileManager: fileManager,
                workspace: workspace
            )
        )
    }

    init(
        outerBundle: Bundle,
        fileManager: FileManager = .default,
        platformContext: any FinderToolbarPlatformContextAccessing
    ) {
        self.outerBundle = outerBundle
        self.fileManager = fileManager
        self.platformContext = platformContext
    }

    func inspect() -> FinderToolbarPlatformInspection {
        guard let environment = platformContext.readEnvironment() else {
            return .unavailable(.environmentUnavailable)
        }
        let identityInspection = launcherIdentity()
        guard case let .success(identityResult) = identityInspection else {
            return .unavailable(identityInspection.failure ?? .invalidCodeSignature)
        }
        let snapshotInspection = platformContext.readSnapshot()
        guard case let .success(snapshot) = snapshotInspection else {
            return .unavailable(snapshotInspection.failure ?? .finderPreferencesUnavailable)
        }
        guard case let .success(receipt) = platformContext.readReceiptEvidence() else {
            return .unavailable(.invalidReceiptStore)
        }

        var aliasResolutions: [Int: FinderToolbarAliasResolution] = [:]
        var storedPathStates: [String: FinderToolbarStoredPathState] = [:]
        if case let .explicit(layout) = snapshot.layoutClassification {
            for (index, payload) in layout.itemPlists {
                aliasResolutions[index] = FinderToolbarAliasRecordResolver.resolve(
                    payload[FinderToolbarPreferenceKey.aliasData]
                )
                if case let .string(rawURL)? = payload[FinderToolbarPreferenceKey.urlString],
                   let url = URL(string: rawURL),
                   url.isFileURL,
                   url.path.hasPrefix("/") {
                    let canonical = url.standardizedFileURL
                    storedPathStates[canonical.absoluteString] = fileManager.fileExists(atPath: canonical.path)
                        ? .present
                        : .missing
                }
            }
        }
        let legacyLauncherURL = outerBundle.bundleURL.standardizedFileURL
            .appendingPathComponent(
                "Contents/Applications/Go2CodexLauncher.app",
                isDirectory: true
            )
            .standardizedFileURL
        storedPathStates[legacyLauncherURL.absoluteString] = fileManager.fileExists(
            atPath: legacyLauncherURL.path
        ) ? .present : .missing

        let context = FinderToolbarDetectionContext(
            snapshot: snapshot,
            environment: environment,
            launcherIdentity: .verified(identityResult.identity),
            receipt: receipt,
            aliasResolutions: aliasResolutions,
            storedPathStates: storedPathStates,
            legacyLauncherURLs: [legacyLauncherURL]
        )
        return .verified(
            context,
            automaticActionsLocationEligible: identityResult.automaticActionsLocationEligible
        )
    }

    func embeddedLauncherURL() -> Result<URL, FinderToolbarPlatformFailure> {
        if let outerIdentifier = outerBundle.bundleIdentifier,
           let variant = FinderToolbarPlatformPolicy.applicationVariant(
               outerBundleIdentifier: outerIdentifier
           ),
           !automaticActionsLocationEligible(
               outerURL: outerBundle.bundleURL.standardizedFileURL,
               variant: variant
           ) {
            return .failure(.unstableReleaseLocation)
        }
        return launcherIdentity().flatMap { inspection in
            guard inspection.automaticActionsLocationEligible else {
                return .failure(.unstableReleaseLocation)
            }
            return .success(inspection.identity.url)
        }
    }

    func recordVerifiedInstalledReceipt(for context: FinderToolbarDetectionContext) -> Bool {
        guard case let .installed(index) = FinderToolbarDetector.detect(context),
              index >= 0,
              let profile = FinderToolbarProfileRegistry.profile(for: context.environment),
              case let .verified(identity) = context.launcherIdentity else {
            return false
        }
        let receipt = FinderToolbarInstallationReceipt(
            profileIdentifier: profile.identifier,
            environment: context.environment,
            lastVerifiedLauncherURL: identity.url,
            launcherIdentityFingerprint: identity.fingerprint,
            launcherBundleIdentifier: identity.launcherBundleIdentifier,
            outerBundleIdentifier: identity.outerBundleIdentifier
        )
        return platformContext.writeReceipt(receipt)
    }

    private func launcherIdentity() -> Result<LauncherIdentityInspection, FinderToolbarPlatformFailure> {
        guard let outerIdentifier = outerBundle.bundleIdentifier else {
            return .failure(.outerBundleInvalid)
        }
        let outerURL = outerBundle.bundleURL.standardizedFileURL
        let launcherURL = outerURL
            .appendingPathComponent("Contents/Helpers/Go2CodexLauncher.app", isDirectory: true)
            .standardizedFileURL
        guard fileManager.fileExists(atPath: launcherURL.path) else {
            return .failure(.launcherMissing)
        }

        let expectedParent = outerURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .standardizedFileURL
        guard launcherURL.deletingLastPathComponent().standardizedFileURL == expectedParent,
              launcherURL == expectedParent
                .appendingPathComponent("Go2CodexLauncher.app", isDirectory: true)
                .standardizedFileURL else {
            return .failure(.launcherNotDirectlyNested)
        }
        guard FinderToolbarPathInspector.inspect(outerURL) == .valid,
              FinderToolbarPathInspector.inspect(launcherURL) == .valid else {
            return .failure(.symbolicLinkOrPathEscape)
        }

        guard let launcherBundle = Bundle(url: launcherURL),
              let launcherIdentifier = launcherBundle.bundleIdentifier,
              let variant = FinderToolbarPlatformPolicy.applicationVariant(
                outerBundleIdentifier: outerIdentifier,
                launcherBundleIdentifier: launcherIdentifier
              ) else {
            return .failure(.invalidBundleIdentifiers)
        }
        let agentValue = launcherBundle.object(forInfoDictionaryKey: "LSUIElement")
        guard (agentValue as? NSNumber)?.boolValue == true else {
            return .failure(.launcherIsNotAgent)
        }
        guard let outerExecutableURL = outerBundle.executableURL,
              let launcherExecutableURL = launcherBundle.executableURL,
              executableIsDirectlyContained(outerExecutableURL, in: outerURL),
              executableIsDirectlyContained(launcherExecutableURL, in: launcherURL),
              FinderToolbarPathInspector.inspect(outerExecutableURL) == .valid,
              FinderToolbarPathInspector.inspect(launcherExecutableURL) == .valid,
              isThinArm64MachO(at: outerExecutableURL),
              isThinArm64MachO(at: launcherExecutableURL) else {
            return .failure(.invalidArchitecture)
        }

        guard let outerSigning = signingEvidence(
            at: outerURL,
            expectedIdentifier: outerIdentifier,
            checksNestedCode: true
        ),
        let launcherSigning = signingEvidence(
            at: launcherURL,
            expectedIdentifier: launcherIdentifier,
            checksNestedCode: false
        ) else {
            return .failure(.invalidCodeSignature)
        }
        guard FinderToolbarPlatformPolicy.signingRelationshipIsValid(
            outer: outerSigning.relationshipEvidence,
            launcher: launcherSigning.relationshipEvidence
        ) else {
            return .failure(.invalidSigningRelationship)
        }

        let fingerprint = identityFingerprint(
            outerIdentifier: outerIdentifier,
            launcherIdentifier: launcherIdentifier,
            outerSigning: outerSigning,
            launcherSigning: launcherSigning
        )
        let identity = FinderToolbarLauncherIdentity(
            url: launcherURL,
            fingerprint: fingerprint,
            launcherBundleIdentifier: launcherIdentifier,
            outerBundleIdentifier: outerIdentifier
        )
        return .success(
            LauncherIdentityInspection(
                identity: identity,
                automaticActionsLocationEligible: automaticActionsLocationEligible(
                    outerURL: outerURL,
                    variant: variant
                )
            )
        )
    }

    private func automaticActionsLocationEligible(
        outerURL: URL,
        variant: FinderToolbarApplicationVariant
    ) -> Bool {
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL
        let userApplications = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL
        return FinderToolbarPlatformPolicy.isStableLocationEligible(
            outerURL: outerURL,
            systemApplicationsURL: systemApplications,
            userApplicationsURL: userApplications,
            variant: variant
        )
    }

    private func executableIsDirectlyContained(_ executableURL: URL, in bundleURL: URL) -> Bool {
        FinderToolbarPlatformPolicy.executableIsDirectlyContained(executableURL, in: bundleURL)
    }

    private func isThinArm64MachO(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8), data.count == 8 else {
            return false
        }
        return FinderToolbarPlatformPolicy.isThinArm64MachO(header: data)
    }

    private func signingEvidence(
        at url: URL,
        expectedIdentifier: String,
        checksNestedCode: Bool
    ) -> SigningEvidence? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var validationFlagValue = kSecCSStrictValidate
            | kSecCSCheckAllArchitectures
            | kSecCSRestrictSymlinks
        if checksNestedCode {
            validationFlagValue |= kSecCSCheckNestedCode
        }
        let validationFlags = SecCSFlags(rawValue: validationFlagValue)
        guard SecStaticCodeCheckValidity(staticCode, validationFlags, nil) == errSecSuccess else {
            return nil
        }

        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        ) == errSecSuccess,
        let information = rawInformation as? [String: Any],
        information[kSecCodeInfoIdentifier as String] as? String == expectedIdentifier,
        let flags = information[kSecCodeInfoFlags as String] as? NSNumber,
        let uniqueHash = information[kSecCodeInfoUnique as String] as? Data,
        !uniqueHash.isEmpty else {
            return nil
        }

        let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let leafCertificate = certificates.first.map { SecCertificateCopyData($0) as Data }
        return SigningEvidence(
            teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String,
            leafCertificate: leafCertificate,
            uniqueHash: uniqueHash,
            isAdHoc: flags.uint32Value & 0x0002 != 0
        )
    }

    private func identityFingerprint(
        outerIdentifier: String,
        launcherIdentifier: String,
        outerSigning: SigningEvidence,
        launcherSigning: SigningEvidence
    ) -> String {
        var hasher = SHA256()
        for data in [
            Data("go2codex-launcher-identity-v1".utf8),
            Data(outerIdentifier.utf8),
            Data(launcherIdentifier.utf8),
            outerSigning.uniqueHash,
            launcherSigning.uniqueHash,
            Data(outerSigning.teamIdentifier?.utf8 ?? "ad-hoc".utf8),
        ] {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct LauncherIdentityInspection {
    let identity: FinderToolbarLauncherIdentity
    let automaticActionsLocationEligible: Bool
}

private struct SigningEvidence {
    let teamIdentifier: String?
    let leafCertificate: Data?
    let uniqueHash: Data
    let isAdHoc: Bool

    var relationshipEvidence: FinderToolbarSigningRelationshipEvidence {
        FinderToolbarSigningRelationshipEvidence(
            teamIdentifier: teamIdentifier,
            leafCertificate: leafCertificate,
            isAdHoc: isAdHoc
        )
    }
}

private extension Result where Failure == FinderToolbarPlatformFailure {
    var failure: FinderToolbarPlatformFailure? {
        guard case let .failure(error) = self else {
            return nil
        }
        return error
    }
}
