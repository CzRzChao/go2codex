import Foundation
import Go2CodexCore

enum UserDefaultsPreferencesStoreError: Error, Equatable, Sendable, DiagnosticCodeProviding {
    case missingDomain
    case invalidDomain
    case suiteUnavailable
    case writeFailed

    var diagnosticCode: DiagnosticCode {
        switch self {
        case .missingDomain:
            DiagnosticCode(rawValue: "preferences-domain-missing")
        case .invalidDomain:
            DiagnosticCode(rawValue: "preferences-domain-invalid")
        case .suiteUnavailable:
            DiagnosticCode(rawValue: "preferences-domain-unavailable")
        case .writeFailed:
            DiagnosticCode(rawValue: "preferences-write-failed")
        }
    }
}

enum ApplicationUserDefaultsAccess: Equatable {
    case standard
    case suite(String)
}

enum ApplicationUserDefaultsPolicy {
    static func access(
        declaredDomain: String,
        runningBundleIdentifier: String?
    ) throws -> ApplicationUserDefaultsAccess {
        let normalizedDomain = declaredDomain.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedDomain.isEmpty,
              !normalizedDomain.contains("$(") else {
            throw UserDefaultsPreferencesStoreError.invalidDomain
        }
        if normalizedDomain == runningBundleIdentifier {
            return .standard
        }
        return .suite(normalizedDomain)
    }
}

@MainActor
enum ApplicationUserDefaultsResolver {
    static func defaults(
        declaredDomain: String,
        runningBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        standardDefaults: UserDefaults = .standard,
        suiteFactory: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) throws -> UserDefaults {
        switch try ApplicationUserDefaultsPolicy.access(
            declaredDomain: declaredDomain,
            runningBundleIdentifier: runningBundleIdentifier
        ) {
        case .standard:
            return standardDefaults
        case let .suite(domain):
            guard let defaults = suiteFactory(domain) else {
                throw UserDefaultsPreferencesStoreError.suiteUnavailable
            }
            return defaults
        }
    }
}

@MainActor
protocol PreferencesUserDefaultsBackend: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ data: Data, forKey key: String)
    func removeObject(forKey key: String)
    func synchronize() -> Bool
}

typealias PreferencesUserDefaultsBackendFactory =
    @MainActor (String) -> (any PreferencesUserDefaultsBackend)?

@MainActor
private final class FoundationPreferencesUserDefaultsBackend: PreferencesUserDefaultsBackend {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func object(forKey key: String) -> Any? {
        defaults.object(forKey: key)
    }

    func set(_ data: Data, forKey key: String) {
        defaults.set(data, forKey: key)
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }

    func synchronize() -> Bool {
        defaults.synchronize()
    }
}

@MainActor
final class UserDefaultsPreferencesStore: SettingsPreferencesServing {
    static let domainInfoKey = "Go2CodexPreferencesDomain"

    private let defaults: any PreferencesUserDefaultsBackend
    private let codec = PreferencesCodec()
    private var storageIntegrityIsUncertain = false

    private enum CanonicalRewriteError: Error {
        case snapshotChanged
        case invalidStoredType
    }

    convenience init(domain: String) throws {
        try self.init(domain: domain) { suiteName in
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                return nil
            }
            return FoundationPreferencesUserDefaultsBackend(defaults: defaults)
        }
    }

    init(
        domain: String,
        backendFactory: PreferencesUserDefaultsBackendFactory
    ) throws {
        let normalizedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDomain.isEmpty, !normalizedDomain.contains("$(") else {
            throw UserDefaultsPreferencesStoreError.invalidDomain
        }
        guard let defaults = backendFactory(normalizedDomain) else {
            throw UserDefaultsPreferencesStoreError.suiteUnavailable
        }
        self.defaults = defaults
    }

    static func fromMainBundle() throws -> UserDefaultsPreferencesStore {
        guard let domain = Bundle.main.object(
            forInfoDictionaryKey: domainInfoKey
        ) as? String else {
            throw UserDefaultsPreferencesStoreError.missingDomain
        }
        let defaults = try ApplicationUserDefaultsResolver.defaults(
            declaredDomain: domain
        )
        return try UserDefaultsPreferencesStore(domain: domain) { _ in
            FoundationPreferencesUserDefaultsBackend(defaults: defaults)
        }
    }

    func load() -> PreferencesLoadState {
        guard !storageIntegrityIsUncertain else {
            return .recoveryRequired(.storageReadFailed)
        }
        guard let stored = defaults.object(forKey: PreferencesStorageKey.envelope) else {
            return .firstRun
        }
        guard let data = stored as? Data else {
            return .recoveryRequired(.corruptData)
        }
        let outcome = codec.decodeOutcome(data)
        guard outcome.requiresCanonicalRewrite,
              case let .configured(envelope) = outcome.state else {
            return outcome.state
        }

        do {
            try replaceEnvelopeDataSynchronously(
                with: codec.encode(envelope),
                ifCurrentDataEquals: data
            )
            return .configured(envelope)
        } catch CanonicalRewriteError.snapshotChanged {
            return .recoveryRequired(.storageReadFailed)
        } catch CanonicalRewriteError.invalidStoredType {
            return .recoveryRequired(.corruptData)
        } catch {
            if storageIntegrityIsUncertain {
                return .recoveryRequired(.storageReadFailed)
            }
            return .configured(envelope)
        }
    }

    func completeFirstRun(selection: FirstRunSelection) throws -> PreferencesEnvelope {
        let envelope = try PreferencesStateMachine.completeFirstRun(
            from: load(),
            selection: selection
        )
        try replaceEnvelopeDataSynchronously(with: codec.encode(envelope))
        return envelope
    }

    func update(_ change: PreferencesChange) throws -> PreferencesEnvelope {
        let envelope = try PreferencesStateMachine.apply(
            change,
            to: load()
        )
        try replaceEnvelopeDataSynchronously(with: codec.encode(envelope))
        return envelope
    }

    func reset() throws {
        guard restoreEnvelopeData(nil) else {
            throw UserDefaultsPreferencesStoreError.writeFailed
        }
        storageIntegrityIsUncertain = false
    }

    private func replaceEnvelopeDataSynchronously(with data: Data) throws {
        let previousObject = defaults.object(forKey: PreferencesStorageKey.envelope)
        guard previousObject == nil || previousObject is Data else {
            throw UserDefaultsPreferencesStoreError.writeFailed
        }
        try commitEnvelopeDataSynchronously(
            data,
            replacing: previousObject as? Data
        )
    }

    private func replaceEnvelopeDataSynchronously(
        with data: Data,
        ifCurrentDataEquals expectedData: Data
    ) throws {
        let currentObject = defaults.object(forKey: PreferencesStorageKey.envelope)
        guard let currentData = currentObject as? Data else {
            if currentObject == nil {
                throw CanonicalRewriteError.snapshotChanged
            }
            throw CanonicalRewriteError.invalidStoredType
        }
        guard currentData == expectedData else {
            throw CanonicalRewriteError.snapshotChanged
        }
        try commitEnvelopeDataSynchronously(data, replacing: currentData)
    }

    private func commitEnvelopeDataSynchronously(
        _ data: Data,
        replacing previousData: Data?
    ) throws {
        defaults.set(data, forKey: PreferencesStorageKey.envelope)
        let synchronizationSucceeded = defaults.synchronize()
        let readbackData = synchronizationSucceeded
            ? defaults.object(forKey: PreferencesStorageKey.envelope) as? Data
            : nil
        do {
            try PreferencesWriteVerifier.verify(
                synchronizationSucceeded: synchronizationSucceeded,
                expectedData: data,
                readbackData: readbackData
            )
        } catch {
            if !restoreEnvelopeData(previousData) {
                storageIntegrityIsUncertain = true
            }
            throw UserDefaultsPreferencesStoreError.writeFailed
        }
    }

    private func restoreEnvelopeData(_ data: Data?) -> Bool {
        if let data {
            defaults.set(data, forKey: PreferencesStorageKey.envelope)
        } else {
            defaults.removeObject(forKey: PreferencesStorageKey.envelope)
        }
        let synchronizationSucceeded = defaults.synchronize()
        let readbackObject = defaults.object(forKey: PreferencesStorageKey.envelope)
        return PreferencesWriteVerifier.restorationSucceeded(
            synchronizationSucceeded: synchronizationSucceeded,
            expectedData: data,
            readbackData: readbackObject as? Data,
            keyIsPresent: readbackObject != nil
        )
    }
}

@MainActor
final class UnavailableSettingsPreferencesService: SettingsPreferencesServing {
    func load() -> PreferencesLoadState {
        .recoveryRequired(.storageReadFailed)
    }

    func completeFirstRun(selection: FirstRunSelection) throws -> PreferencesEnvelope {
        throw PreferencesStoreError.writeFailed
    }

    func update(_ change: PreferencesChange) throws -> PreferencesEnvelope {
        throw PreferencesStoreError.writeFailed
    }

    func reset() throws {
        throw PreferencesStoreError.writeFailed
    }
}
