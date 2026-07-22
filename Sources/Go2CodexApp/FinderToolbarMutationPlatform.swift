import AppKit
import CryptoKit
import Foundation
import Go2CodexCore
import OSLog

protocol FinderToolbarTransactionJournalStoring: AnyObject {
    func loadActive() throws -> FinderToolbarTransactionJournal?
    func saveActive(_ journal: FinderToolbarTransactionJournal) throws
    func archiveCompleted(_ journal: FinderToolbarTransactionJournal) throws
}

enum FinderToolbarTransactionStoreError: Error, Equatable {
    case invalidJournal
    case writeFailed
    case cleanupFailed
}

final class SystemFinderToolbarTransactionJournalStore: FinderToolbarTransactionJournalStoring {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let activeURL: URL
    private let completedURL: URL

    convenience init(
        outerBundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
        let domain = outerBundle.object(
            forInfoDictionaryKey: "Go2CodexPreferencesDomain"
        ) as? String ?? "io.github.czrzchao.go2codex"
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.init(
            directoryURL: applicationSupport
                .appendingPathComponent(domain, isDirectory: true)
                .appendingPathComponent("FinderToolbarTransactions", isDirectory: true),
            fileManager: fileManager
        )
    }

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL.standardizedFileURL
        activeURL = self.directoryURL.appendingPathComponent("active-v1.json", isDirectory: false)
        completedURL = self.directoryURL.appendingPathComponent("last-completed-v1.json", isDirectory: false)
    }

    func loadActive() throws -> FinderToolbarTransactionJournal? {
        guard fileManager.fileExists(atPath: activeURL.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: activeURL),
              let journal = try? JSONDecoder().decode(FinderToolbarTransactionJournal.self, from: data) else {
            throw FinderToolbarTransactionStoreError.invalidJournal
        }
        return journal
    }

    func saveActive(_ journal: FinderToolbarTransactionJournal) throws {
        try write(journal, to: activeURL)
    }

    func archiveCompleted(_ journal: FinderToolbarTransactionJournal) throws {
        try write(journal, to: completedURL)
        if fileManager.fileExists(atPath: activeURL.path) {
            do {
                try fileManager.removeItem(at: activeURL)
            } catch {
                throw FinderToolbarTransactionStoreError.cleanupFailed
            }
        }
    }

    private func write(_ journal: FinderToolbarTransactionJournal, to url: URL) throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(journal)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw FinderToolbarTransactionStoreError.writeFailed
        }
    }
}

@MainActor
final class SystemFinderToolbarMutationExecutor: FinderToolbarMutationExecuting {
    private let platform: any FinderToolbarMutationPlatformAccessing
    private let journalStore: any FinderToolbarTransactionJournalStoring
    private let logger: Logger
    private var isExecuting = false

    convenience init(
        outerBundle: Bundle = .main,
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) {
        self.init(
            platform: SystemFinderToolbarPlatformContext(
                outerBundle: outerBundle,
                fileManager: fileManager,
                workspace: workspace
            ),
            journalStore: SystemFinderToolbarTransactionJournalStore(
                outerBundle: outerBundle,
                fileManager: fileManager
            ),
            subsystem: outerBundle.object(
                forInfoDictionaryKey: "Go2CodexPreferencesDomain"
            ) as? String ?? "io.github.czrzchao.go2codex"
        )
    }

    init(
        platform: any FinderToolbarMutationPlatformAccessing,
        journalStore: any FinderToolbarTransactionJournalStoring,
        subsystem: String = "io.github.czrzchao.go2codex"
    ) {
        self.platform = platform
        self.journalStore = journalStore
        logger = Logger(subsystem: subsystem, category: "FinderMutation")
    }

    func recoverIfNeeded(
        profile: FinderToolbarProfile,
        launcherIdentity: FinderToolbarLauncherIdentity
    ) async -> FinderToolbarMutationRecoveryResult {
        guard !isExecuting else {
            return .manualInterventionRequired
        }

        let active: FinderToolbarTransactionJournal
        do {
            guard let journal = try journalStore.loadActive() else {
                return .none
            }
            active = journal
        } catch {
            logger.error("Finder transaction journal could not be decoded")
            return .manualInterventionRequired
        }

        guard let beforeFingerprint = finderToolbarSnapshotFingerprint(active.plan.before),
              let expectedFingerprint = finderToolbarSnapshotFingerprint(active.plan.expected) else {
            return .manualInterventionRequired
        }
        let validation = FinderToolbarJournalValidator.validate(
            active,
            context: FinderToolbarJournalValidationContext(
                profile: profile,
                launcherIdentity: launcherIdentity,
                beforeFingerprint: beforeFingerprint,
                expectedFingerprint: expectedFingerprint
            )
        )
        guard case .valid = validation,
              case let .success(observed) = platform.readSnapshot() else {
            return .manualInterventionRequired
        }

        if observed == active.plan.before {
            do {
                try journalStore.archiveCompleted(active.updating(state: .completed))
                return .recovered
            } catch {
                return .manualInterventionRequired
            }
        }

        guard semanticResult(
            plan: active.plan,
            observed: observed
        ).isAccepted else {
            return .manualInterventionRequired
        }

        isExecuting = true
        defer { isExecuting = false }
        let finderAlreadyReplaced: Bool
        switch active.state {
        case .finderReplacementObserved, .semanticConvergenceVerified,
             .receiptCommitted, .completed:
            finderAlreadyReplaced = true
        case .prepared, .preferenceSynchronized, .restartIntentRecorded,
             .restartRequested:
            finderAlreadyReplaced = false
        }
        if !finderAlreadyReplaced, !(await platform.restartFinder()) {
            return .manualInterventionRequired
        }
        guard await waitForSemanticConvergence(plan: active.plan) != nil,
              commitReceipt(
                operation: active.plan.operation,
                profile: profile,
                launcherIdentity: launcherIdentity
              ) else {
            return .manualInterventionRequired
        }
        do {
            try journalStore.archiveCompleted(active.updating(state: .completed))
            return .recovered
        } catch {
            return .manualInterventionRequired
        }
    }

    func execute(
        plan: FinderToolbarMutationPlan,
        profile: FinderToolbarProfile,
        launcherIdentity: FinderToolbarLauncherIdentity
    ) async -> Bool {
        guard !isExecuting else {
            return false
        }
        isExecuting = true
        defer { isExecuting = false }

        var journal: FinderToolbarTransactionJournal?
        var receiptCommitted = false
        do {
            guard try journalStore.loadActive() == nil,
                  let beforeFingerprint = finderToolbarSnapshotFingerprint(plan.before),
                  let expectedFingerprint = finderToolbarSnapshotFingerprint(plan.expected) else {
                throw FinderToolbarPlatformFailure.transactionJournalUnavailable
            }
            var active = FinderToolbarTransactionJournal(
                operationIdentifier: UUID(),
                plan: plan,
                launcherIdentity: launcherIdentity,
                beforeFingerprint: beforeFingerprint,
                expectedFingerprint: expectedFingerprint,
                semanticVerifierIdentifier: profile.semanticVerifierIdentifier,
                state: .prepared
            )
            try journalStore.saveActive(active)
            journal = active

            guard case let .success(finalSnapshot) = platform.readSnapshot() else {
                throw FinderToolbarPlatformFailure.finderPreferencesUnavailable
            }
            let validated = FinderToolbarJournalValidator.validate(
                active,
                context: FinderToolbarJournalValidationContext(
                    profile: profile,
                    launcherIdentity: launcherIdentity,
                    beforeFingerprint: beforeFingerprint,
                    expectedFingerprint: expectedFingerprint
                )
            )
            guard FinderToolbarPreMutationGate.decide(
                plan: plan,
                journal: validated,
                serializationBoundary: .experimentalBestEffort(
                    "user-confirmed-private-preferences-v1"
                ),
                disk: finalSnapshot,
                live: finalSnapshot
            ) == .proceed else {
                throw FinderToolbarPlatformFailure.finderPreferencesDisagree
            }

            guard platform.writeSnapshot(plan.expected) else {
                throw FinderToolbarPlatformFailure.finderPreferenceWriteFailed
            }
            active = active.updating(state: .preferenceSynchronized)
            try journalStore.saveActive(active)
            journal = active

            active = active.updating(state: .restartIntentRecorded)
            try journalStore.saveActive(active)
            journal = active
            guard await platform.restartFinder() else {
                throw FinderToolbarPlatformFailure.finderRestartFailed
            }
            active = active.updating(state: .restartRequested)
            try journalStore.saveActive(active)
            active = active.updating(state: .finderReplacementObserved)
            try journalStore.saveActive(active)
            journal = active

            guard await waitForSemanticConvergence(plan: plan) != nil else {
                throw FinderToolbarPlatformFailure.semanticVerificationFailed
            }
            active = active.updating(state: .semanticConvergenceVerified)
            try journalStore.saveActive(active)
            journal = active

            guard commitReceipt(
                operation: plan.operation,
                profile: profile,
                launcherIdentity: launcherIdentity
            ) else {
                throw FinderToolbarPlatformFailure.invalidReceiptStore
            }
            receiptCommitted = true
            active = active.updating(state: .receiptCommitted)
            try journalStore.saveActive(active)
            active = active.updating(state: .completed)
            try journalStore.archiveCompleted(active)
            return true
        } catch {
            logger.error("Finder mutation transaction failed error=\(String(describing: error), privacy: .public)")
            if receiptCommitted {
                return true
            }
            if let journal {
                await rollbackIfSafe(journal)
            }
            return false
        }
    }

    private func rollbackIfSafe(_ journal: FinderToolbarTransactionJournal) async {
        guard case let .success(observed) = platform.readSnapshot() else {
            return
        }
        if observed == journal.plan.before {
            try? journalStore.archiveCompleted(journal.updating(state: .completed))
            return
        }
        guard semanticResult(plan: journal.plan, observed: observed).isAccepted,
              platform.writeSnapshot(journal.plan.before),
              await platform.restartFinder(),
              await waitForExactConvergence(journal.plan.before) else {
            return
        }
        try? journalStore.archiveCompleted(journal.updating(state: .completed))
    }

    private func waitForSemanticConvergence(
        plan: FinderToolbarMutationPlan
    ) async -> FinderToolbarSnapshot? {
        for _ in 0..<40 {
            if case let .success(snapshot) = platform.readSnapshot() {
                let result = semanticResult(plan: plan, observed: snapshot)
                if result.isAcceptedAfterFinderRestart(for: plan.operation) {
                    return snapshot
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    private func waitForExactConvergence(_ expected: FinderToolbarSnapshot) async -> Bool {
        for _ in 0..<40 {
            if case let .success(snapshot) = platform.readSnapshot(), snapshot == expected {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func semanticResult(
        plan: FinderToolbarMutationPlan,
        observed: FinderToolbarSnapshot
    ) -> FinderToolbarSemanticResult {
        let aliasResolution: FinderToolbarAliasResolution
        if plan.operation == .uninstall {
            aliasResolution = .absent
        } else if case let .explicit(layout) = observed.layoutClassification,
                  let payload = layout.itemPlists[plan.affectedIndex] {
            aliasResolution = platform.resolveAlias(
                payload[FinderToolbarPreferenceKey.aliasData]
            )
        } else {
            aliasResolution = .invalid
        }
        return FinderToolbarSemanticVerifier.verify(
            plan: plan,
            observed: observed,
            aliasResolution: aliasResolution
        )
    }

    private func commitReceipt(
        operation: FinderToolbarMutationOperation,
        profile: FinderToolbarProfile,
        launcherIdentity: FinderToolbarLauncherIdentity
    ) -> Bool {
        if operation == .uninstall {
            return platform.clearReceipt()
        }
        return platform.writeReceipt(
            FinderToolbarInstallationReceipt(
                profileIdentifier: profile.identifier,
                environment: profile.environment,
                lastVerifiedLauncherURL: launcherIdentity.url,
                launcherIdentityFingerprint: launcherIdentity.fingerprint,
                launcherBundleIdentifier: launcherIdentity.launcherBundleIdentifier,
                outerBundleIdentifier: launcherIdentity.outerBundleIdentifier
            )
        )
    }
}

private extension FinderToolbarTransactionJournal {
    func updating(state: FinderToolbarTransactionState) -> FinderToolbarTransactionJournal {
        FinderToolbarTransactionJournal(
            schemaVersion: schemaVersion,
            operationIdentifier: operationIdentifier,
            plan: plan,
            launcherIdentity: launcherIdentity,
            beforeFingerprint: beforeFingerprint,
            expectedFingerprint: expectedFingerprint,
            semanticVerifierIdentifier: semanticVerifierIdentifier,
            state: state
        )
    }
}

private extension FinderToolbarSemanticResult {
    var isAccepted: Bool {
        switch self {
        case .exactExpected, .acceptedAliasEnrichment:
            true
        case .rejected:
            false
        }
    }

    func isAcceptedAfterFinderRestart(
        for operation: FinderToolbarMutationOperation
    ) -> Bool {
        switch (operation, self) {
        case (.uninstall, .exactExpected),
             (.install, .acceptedAliasEnrichment),
             (.repair, .acceptedAliasEnrichment):
            true
        case (.uninstall, .acceptedAliasEnrichment),
             (_, .exactExpected),
             (_, .rejected):
            false
        }
    }
}

func finderToolbarSnapshotFingerprint(_ snapshot: FinderToolbarSnapshot) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(snapshot) else {
        return nil
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
