import Foundation
import Testing
@testable import Go2CodexCore

@MainActor
@Suite("Settings Preferences Store")
struct SettingsPreferencesStoreTests {
    @Test
    func runningApplicationDomainUsesStandardDefaultsWithoutOpeningASuite() throws {
        let domain = "io.github.czrzchao.go2codex.tests.standard.\(UUID().uuidString)"
        let standardDefaults = try #require(UserDefaults(suiteName: domain))
        defer { standardDefaults.removePersistentDomain(forName: domain) }
        var suiteRequests: [String] = []

        let resolved = try ApplicationUserDefaultsResolver.defaults(
            declaredDomain: "  io.github.czrzchao.go2codex  ",
            runningBundleIdentifier: "io.github.czrzchao.go2codex",
            standardDefaults: standardDefaults,
            suiteFactory: {
                suiteRequests.append($0)
                return nil
            }
        )

        #expect(resolved === standardDefaults)
        #expect(suiteRequests.isEmpty)
        #expect(resolved.object(forKey: PreferencesStorageKey.envelope) == nil)
    }

    @Test
    func foreignApplicationDomainUsesTheExactNamedSuite() throws {
        let suiteName = "io.github.czrzchao.go2codex.tests.foreign.\(UUID().uuidString)"
        let foreignDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { foreignDefaults.removePersistentDomain(forName: suiteName) }
        var suiteRequests: [String] = []

        let resolved = try ApplicationUserDefaultsResolver.defaults(
            declaredDomain: "  \(suiteName)  ",
            runningBundleIdentifier: "io.github.czrzchao.go2codex.launcher",
            standardDefaults: .standard,
            suiteFactory: {
                suiteRequests.append($0)
                return foreignDefaults
            }
        )

        #expect(resolved === foreignDefaults)
        #expect(suiteRequests == [suiteName])
    }

    @Test
    func applicationDefaultsPolicyRejectsInvalidAndUnavailableDomains() {
        for domain in ["", "  \n ", "$(GO2CODEX_PREFERENCES_DOMAIN)", "safe.$(unsafe)"] {
            let error: UserDefaultsPreferencesStoreError? = capturedError {
                _ = try ApplicationUserDefaultsResolver.defaults(
                    declaredDomain: domain,
                    runningBundleIdentifier: "io.github.czrzchao.go2codex"
                )
            }
            #expect(error == .invalidDomain)
        }

        let unavailable: UserDefaultsPreferencesStoreError? = capturedError {
            _ = try ApplicationUserDefaultsResolver.defaults(
                declaredDomain: "io.github.czrzchao.unavailable",
                runningBundleIdentifier: "io.github.czrzchao.go2codex",
                suiteFactory: { _ in nil }
            )
        }
        #expect(unavailable == .suiteUnavailable)
    }

    @Test
    func storeErrorsHaveStableSanitizedDiagnosticCodes() {
        #expect(UserDefaultsPreferencesStoreError.missingDomain.diagnosticCode.rawValue == "preferences-domain-missing")
        #expect(UserDefaultsPreferencesStoreError.invalidDomain.diagnosticCode.rawValue == "preferences-domain-invalid")
        #expect(UserDefaultsPreferencesStoreError.suiteUnavailable.diagnosticCode.rawValue == "preferences-domain-unavailable")
        #expect(UserDefaultsPreferencesStoreError.writeFailed.diagnosticCode.rawValue == "preferences-write-failed")
    }

    @Test
    func completeFirstRunAndImmediateUpdatePersistCompleteEnvelopes() throws {
        let backend = PreferencesUserDefaultsBackendFake()
        var requestedDomains: [String] = []
        let store = try UserDefaultsPreferencesStore(
            domain: "  io.github.czrzchao.go2codex.tests  ",
            backendFactory: { domain in
                requestedDomains.append(domain)
                return backend
            }
        )

        let initial = try store.completeFirstRun(
            selection: FirstRunSelection(
                defaultTarget: .codexCLI,
                defaultTerminalHost: .terminal,
                alternateTrigger: .shiftClick,
                sessionPlacement: .newTab
            )
        )
        let updated = try store.update(
            PreferencesChange(
                defaultTarget: .claudeDesktopCode,
                alternateTrigger: .shiftClick,
                defaultTerminalHost: .iTerm2,
                sessionPlacement: .newWindow
            )
        )

        #expect(requestedDomains == ["io.github.czrzchao.go2codex.tests"])
        #expect(backend.synchronizeCalls == 2)
        #expect(backend.setValues.count == 2)
        #expect(PreferencesCodec().decode(backend.setValues[0]) == .configured(initial))
        #expect(PreferencesCodec().decode(backend.setValues[1]) == .configured(updated))
        #expect(store.load() == .configured(updated))
    }

    @Test
    func legacyOptionTriggerIsCanonicalizedAsOneCompleteShiftEnvelope() throws {
        let legacyData = legacyOptionEnvelopeData()
        let backend = PreferencesUserDefaultsBackendFake(storedObject: legacyData)
        let store = try makeStore(backend)

        guard case let .configured(envelope) = store.load() else {
            Issue.record("Expected migrated preferences")
            return
        }

        #expect(envelope.alternateTrigger == .shiftClick)
        #expect(backend.setValues.count == 1)
        #expect(backend.synchronizeCalls == 1)
        #expect(PreferencesCodec().decode(backend.setValues[0]) == .configured(envelope))
        let canonicalText = try #require(
            String(data: backend.setValues[0], encoding: .utf8)
        )
        #expect(!canonicalText.contains("option-click"))
        #expect(canonicalText.contains("shift-click"))
    }

    @Test
    func canonicalShiftEnvelopeDoesNotWriteDuringLoad() throws {
        let envelope = configuredEnvelope()
        let backend = PreferencesUserDefaultsBackendFake(
            storedObject: try PreferencesCodec().encode(envelope)
        )
        let store = try makeStore(backend)

        #expect(store.load() == .configured(envelope))
        #expect(backend.setValues.isEmpty)
        #expect(backend.synchronizeCalls == 0)
    }

    @Test
    func failedLegacyCanonicalizationRestoresOldDataAndUsesShiftInMemory() throws {
        let legacyData = legacyOptionEnvelopeData()
        let backend = PreferencesUserDefaultsBackendFake(
            storedObject: legacyData,
            synchronizeResults: [false, true]
        )
        let store = try makeStore(backend)

        guard case let .configured(envelope) = store.load() else {
            Issue.record("Expected safe in-memory migration")
            return
        }

        #expect(envelope.alternateTrigger == .shiftClick)
        #expect(backend.storedObject as? Data == legacyData)
        #expect(backend.setValues.count == 2)
        #expect(backend.setValues.last == legacyData)
        #expect(backend.synchronizeCalls == 2)
    }

    @Test
    func failedLegacyCanonicalizationAndRollbackRequiresRecovery() throws {
        let backend = PreferencesUserDefaultsBackendFake(
            storedObject: legacyOptionEnvelopeData(),
            synchronizeResults: [false, false]
        )
        let store = try makeStore(backend)

        #expect(store.load() == .recoveryRequired(.storageReadFailed))
        let writesAfterFailure = backend.setValues.count
        #expect(store.load() == .recoveryRequired(.storageReadFailed))
        #expect(backend.setValues.count == writesAfterFailure)
    }

    @Test
    func legacyCanonicalizationDoesNotOverwriteAChangedEnvelope() throws {
        let newerEnvelope = PreferencesEnvelope(
            defaultTarget: .claudeDesktopCode,
            alternateTrigger: .disabled,
            defaultTerminalHost: .iTerm2,
            sessionPlacement: .newWindow
        )
        let newerData = try PreferencesCodec().encode(newerEnvelope)
        let backend = PreferencesUserDefaultsBackendFake(
            storedObject: newerData,
            objectReads: [.value(legacyOptionEnvelopeData())]
        )
        let store = try makeStore(backend)

        #expect(store.load() == .recoveryRequired(.storageReadFailed))
        #expect(backend.storedObject as? Data == newerData)
        #expect(backend.setValues.isEmpty)
        #expect(backend.removeCalls == 0)
        #expect(backend.synchronizeCalls == 0)
        #expect(store.load() == .configured(newerEnvelope))
    }

    @Test
    func legacyCanonicalizationDoesNotRecreateADeletedEnvelope() throws {
        let backend = PreferencesUserDefaultsBackendFake(
            objectReads: [.value(legacyOptionEnvelopeData())]
        )
        let store = try makeStore(backend)

        #expect(store.load() == .recoveryRequired(.storageReadFailed))
        #expect(backend.storedObject == nil)
        #expect(backend.setValues.isEmpty)
        #expect(backend.removeCalls == 0)
        #expect(backend.synchronizeCalls == 0)
        #expect(store.load() == .firstRun)
    }

    @Test
    func legacyCanonicalizationDoesNotOverwriteANewInvalidType() throws {
        let backend = PreferencesUserDefaultsBackendFake(
            storedObject: "foreign-value",
            objectReads: [.value(legacyOptionEnvelopeData())]
        )
        let store = try makeStore(backend)

        #expect(store.load() == .recoveryRequired(.corruptData))
        #expect(backend.storedObject as? String == "foreign-value")
        #expect(backend.setValues.isEmpty)
        #expect(backend.removeCalls == 0)
        #expect(backend.synchronizeCalls == 0)
        #expect(store.load() == .recoveryRequired(.corruptData))
    }

    @Test
    func emptyInvalidAndUnavailableSuitesFailBeforeUse() {
        var factoryCalls: [String] = []
        for domain in ["", "  \n ", "$(GO2CODEX_PREFERENCES_DOMAIN)", "safe.$(unsafe)"] {
            let error: UserDefaultsPreferencesStoreError? = capturedError {
                _ = try UserDefaultsPreferencesStore(
                    domain: domain,
                    backendFactory: { requestedDomain in
                        factoryCalls.append(requestedDomain)
                        return PreferencesUserDefaultsBackendFake()
                    }
                )
            }
            #expect(error == .invalidDomain)
        }
        #expect(factoryCalls.isEmpty)

        let unavailable: UserDefaultsPreferencesStoreError? = capturedError {
            _ = try UserDefaultsPreferencesStore(
                domain: "  io.github.czrzchao.unavailable  ",
                backendFactory: { requestedDomain in
                    factoryCalls.append(requestedDomain)
                    return nil
                }
            )
        }
        #expect(unavailable == .suiteUnavailable)
        #expect(factoryCalls == ["io.github.czrzchao.unavailable"])
    }

    @Test
    func invalidStoredTypeRequiresRecoveryWithoutWriting() throws {
        let backend = PreferencesUserDefaultsBackendFake(storedObject: "not-data")
        let store = try makeStore(backend)

        #expect(store.load() == .recoveryRequired(.corruptData))
        #expect(backend.setValues.isEmpty)
        #expect(backend.removeCalls == 0)
        #expect(backend.synchronizeCalls == 0)
    }

    @Test
    func synchronizationFailureRestoresAnAbsentEnvelope() throws {
        let backend = PreferencesUserDefaultsBackendFake(
            synchronizeResults: [false, true]
        )
        let store = try makeStore(backend)

        let error: UserDefaultsPreferencesStoreError? = capturedError {
            _ = try store.completeFirstRun(selection: completeSelection())
        }

        #expect(error == .writeFailed)
        #expect(backend.storedObject == nil)
        #expect(backend.setValues.count == 1)
        #expect(backend.removeCalls == 1)
        #expect(backend.synchronizeCalls == 2)
        #expect(store.load() == .firstRun)
    }

    @Test
    func synchronizationFailureRestoresThePreviousEnvelope() throws {
        let previous = configuredEnvelope()
        let previousData = try PreferencesCodec().encode(previous)
        let backend = PreferencesUserDefaultsBackendFake(
            storedObject: previousData,
            synchronizeResults: [false, true]
        )
        let store = try makeStore(backend)

        let error: UserDefaultsPreferencesStoreError? = capturedError {
            _ = try store.update(PreferencesChange(defaultTarget: .claudeCodeCLI))
        }

        #expect(error == .writeFailed)
        #expect(backend.storedObject as? Data == previousData)
        #expect(backend.setValues.count == 2)
        #expect(backend.setValues.last == previousData)
        #expect(backend.removeCalls == 0)
        #expect(store.load() == .configured(previous))
    }

    @Test
    func mismatchedReadbackRestoresThePreviousState() throws {
        let mismatch = Data("mismatched-envelope".utf8)
        let backend = PreferencesUserDefaultsBackendFake(
            synchronizeResults: [true, true],
            synchronizationEffects: [.replace(mismatch), .none]
        )
        let store = try makeStore(backend)

        let error: UserDefaultsPreferencesStoreError? = capturedError {
            _ = try store.completeFirstRun(selection: completeSelection())
        }

        #expect(error == .writeFailed)
        #expect(backend.storedObject == nil)
        #expect(backend.removeCalls == 1)
        #expect(backend.synchronizeCalls == 2)
        #expect(store.load() == .firstRun)
    }

    @Test
    func failedRestorationSynchronizationMakesIntegrityUncertain() throws {
        let backend = PreferencesUserDefaultsBackendFake(
            synchronizeResults: [false, false]
        )
        let store = try makeStore(backend)

        let firstError: UserDefaultsPreferencesStoreError? = capturedError {
            _ = try store.completeFirstRun(selection: completeSelection())
        }
        let readsAfterFailure = backend.objectReadCalls
        let writesAfterFailure = backend.setValues.count + backend.removeCalls

        #expect(firstError == .writeFailed)
        #expect(store.load() == .recoveryRequired(.storageReadFailed))
        let laterError: PreferencesTransitionError? = capturedError {
            _ = try store.completeFirstRun(selection: completeSelection())
        }
        #expect(laterError == .recoveryRequired(.storageReadFailed))
        #expect(backend.objectReadCalls == readsAfterFailure)
        #expect(backend.setValues.count + backend.removeCalls == writesAfterFailure)
    }

    @Test
    func failedRestorationReadbackMakesIntegrityUncertain() throws {
        let previous = configuredEnvelope()
        let previousData = try PreferencesCodec().encode(previous)
        let unrestored = Data("not-the-previous-envelope".utf8)
        let backend = PreferencesUserDefaultsBackendFake(
            storedObject: previousData,
            synchronizeResults: [false, true],
            synchronizationEffects: [.none, .replace(unrestored)]
        )
        let store = try makeStore(backend)

        let firstError: UserDefaultsPreferencesStoreError? = capturedError {
            _ = try store.update(PreferencesChange(sessionPlacement: .newWindow))
        }
        let setCallsAfterFailure = backend.setValues.count

        #expect(firstError == .writeFailed)
        #expect(backend.storedObject as? Data == unrestored)
        #expect(store.load() == .recoveryRequired(.storageReadFailed))
        let laterError: PreferencesTransitionError? = capturedError {
            _ = try store.update(PreferencesChange(defaultTarget: .claudeCodeCLI))
        }
        #expect(laterError == .recoveryRequired(.storageReadFailed))
        #expect(backend.setValues.count == setCallsAfterFailure)
    }

    @Test
    func nonDataValueObservedBeforeReplacementIsNeverOverwritten() throws {
        let configuredData = try PreferencesCodec().encode(configuredEnvelope())
        let backend = PreferencesUserDefaultsBackendFake(
            storedObject: "foreign-value",
            objectReads: [.value(configuredData)]
        )
        let store = try makeStore(backend)

        let error: UserDefaultsPreferencesStoreError? = capturedError {
            _ = try store.update(PreferencesChange(defaultTarget: .claudeCodeCLI))
        }

        #expect(error == .writeFailed)
        #expect(backend.storedObject as? String == "foreign-value")
        #expect(backend.setValues.isEmpty)
        #expect(backend.removeCalls == 0)
        #expect(backend.synchronizeCalls == 0)
    }

    @Test
    func unavailableServiceAlwaysFailsClosed() {
        let service = UnavailableSettingsPreferencesService()

        #expect(service.load() == .recoveryRequired(.storageReadFailed))
        let completionError: PreferencesStoreError? = capturedError {
            _ = try service.completeFirstRun(selection: completeSelection())
        }
        let updateError: PreferencesStoreError? = capturedError {
            _ = try service.update(PreferencesChange(defaultTarget: .codexCLI))
        }
        #expect(completionError == .writeFailed)
        #expect(updateError == .writeFailed)
    }

    private func makeStore(
        _ backend: PreferencesUserDefaultsBackendFake
    ) throws -> UserDefaultsPreferencesStore {
        try UserDefaultsPreferencesStore(
            domain: "io.github.czrzchao.go2codex.tests",
            backendFactory: { _ in backend }
        )
    }

    private func completeSelection() -> FirstRunSelection {
        FirstRunSelection(
            defaultTarget: .codexApp,
            defaultTerminalHost: .terminal
        )
    }

    private func configuredEnvelope() -> PreferencesEnvelope {
        PreferencesEnvelope(
            defaultTarget: .codexApp,
            alternateTrigger: .shiftClick,
            defaultTerminalHost: .terminal,
            sessionPlacement: .newTab
        )
    }

    private func legacyOptionEnvelopeData() -> Data {
        Data("""
        {
          "schemaVersion": 1,
          "firstRunCompletion": "completed",
          "defaultTarget": "codex-app",
          "alternateTrigger": "option-click",
          "defaultTerminalHost": "terminal-app",
          "sessionPlacement": "new-tab"
        }
        """.utf8)
    }
}

@MainActor
private final class PreferencesUserDefaultsBackendFake: PreferencesUserDefaultsBackend {
    enum ObjectRead {
        case stored
        case value(Any?)
    }

    enum SynchronizationEffect {
        case none
        case replace(Any?)
    }

    var storedObject: Any?
    private var objectReads: [ObjectRead]
    private var synchronizeResults: [Bool]
    private var synchronizationEffects: [SynchronizationEffect]
    private(set) var objectReadCalls = 0
    private(set) var setValues: [Data] = []
    private(set) var removeCalls = 0
    private(set) var synchronizeCalls = 0

    init(
        storedObject: Any? = nil,
        objectReads: [ObjectRead] = [],
        synchronizeResults: [Bool] = [],
        synchronizationEffects: [SynchronizationEffect] = []
    ) {
        self.storedObject = storedObject
        self.objectReads = objectReads
        self.synchronizeResults = synchronizeResults
        self.synchronizationEffects = synchronizationEffects
    }

    func object(forKey key: String) -> Any? {
        objectReadCalls += 1
        guard !objectReads.isEmpty else {
            return storedObject
        }
        switch objectReads.removeFirst() {
        case .stored:
            return storedObject
        case let .value(value):
            return value
        }
    }

    func set(_ data: Data, forKey key: String) {
        setValues.append(data)
        storedObject = data
    }

    func removeObject(forKey key: String) {
        removeCalls += 1
        storedObject = nil
    }

    func synchronize() -> Bool {
        synchronizeCalls += 1
        let result = synchronizeResults.isEmpty
            ? true
            : synchronizeResults.removeFirst()
        let effect = synchronizationEffects.isEmpty
            ? SynchronizationEffect.none
            : synchronizationEffects.removeFirst()
        if case let .replace(value) = effect {
            storedObject = value
        }
        return result
    }
}

private func capturedError<E: Error & Equatable>(
    _ operation: () throws -> Void
) -> E? {
    do {
        try operation()
        return nil
    } catch let error as E {
        return error
    } catch {
        return nil
    }
}
