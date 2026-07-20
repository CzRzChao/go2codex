import Foundation

public enum ProductVariant: String, CaseIterable, Sendable {
    case debug
    case release

    public var preferencesSuiteName: String {
        switch self {
        case .debug:
            "io.github.czrzchao.go2codex.debug"
        case .release:
            "io.github.czrzchao.go2codex"
        }
    }
}

public enum PreferencesStorageKey {
    public static let envelope = "PreferencesEnvelope"
}

public enum FirstRunCompletionState: String, Codable, Sendable {
    case completed
}

public struct PreferencesEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let firstRunCompletion: FirstRunCompletionState
    public let defaultTarget: AgentTarget
    public let alternateTrigger: AlternateTrigger
    public let defaultTerminalHost: TerminalHost
    public let sessionPlacement: SessionPlacement

    public init(
        defaultTarget: AgentTarget,
        alternateTrigger: AlternateTrigger,
        defaultTerminalHost: TerminalHost,
        sessionPlacement: SessionPlacement
    ) {
        schemaVersion = Go2CodexCoreInfo.preferencesSchemaVersion
        firstRunCompletion = .completed
        self.defaultTarget = defaultTarget
        self.alternateTrigger = alternateTrigger
        self.defaultTerminalHost = defaultTerminalHost
        self.sessionPlacement = sessionPlacement
    }

    public func applying(_ change: PreferencesChange) -> PreferencesEnvelope {
        PreferencesEnvelope(
            defaultTarget: change.defaultTarget ?? defaultTarget,
            alternateTrigger: change.alternateTrigger ?? alternateTrigger,
            defaultTerminalHost: change.defaultTerminalHost ?? defaultTerminalHost,
            sessionPlacement: change.sessionPlacement ?? sessionPlacement
        )
    }
}

public struct PreferencesChange: Equatable, Sendable {
    public let defaultTarget: AgentTarget?
    public let alternateTrigger: AlternateTrigger?
    public let defaultTerminalHost: TerminalHost?
    public let sessionPlacement: SessionPlacement?

    public init(
        defaultTarget: AgentTarget? = nil,
        alternateTrigger: AlternateTrigger? = nil,
        defaultTerminalHost: TerminalHost? = nil,
        sessionPlacement: SessionPlacement? = nil
    ) {
        self.defaultTarget = defaultTarget
        self.alternateTrigger = alternateTrigger
        self.defaultTerminalHost = defaultTerminalHost
        self.sessionPlacement = sessionPlacement
    }
}

public struct FirstRunSelection: Equatable, Sendable {
    public var defaultTarget: AgentTarget?
    public var defaultTerminalHost: TerminalHost?
    public var alternateTrigger: AlternateTrigger
    public var sessionPlacement: SessionPlacement

    public init(
        defaultTarget: AgentTarget? = nil,
        defaultTerminalHost: TerminalHost? = nil,
        alternateTrigger: AlternateTrigger = .shiftClick,
        sessionPlacement: SessionPlacement = .newTab
    ) {
        self.defaultTarget = defaultTarget
        self.defaultTerminalHost = defaultTerminalHost
        self.alternateTrigger = alternateTrigger
        self.sessionPlacement = sessionPlacement
    }
}

public enum RequiredPreference: String, Hashable, Sendable {
    case defaultTarget
    case defaultTerminalHost
}

public enum PreferencesRecoveryReason: Equatable, Sendable {
    case corruptData
    case missingRequiredFields
    case unsupportedSchema(Int)
    case storageReadFailed
}

public enum PreferencesLoadState: Equatable, Sendable {
    case firstRun
    case configured(PreferencesEnvelope)
    case recoveryRequired(PreferencesRecoveryReason)
}

public enum PreferencesTransitionError: Error, Equatable, Sendable {
    case missingRequiredValues(Set<RequiredPreference>)
    case firstRunAlreadyCompleted
    case recoveryRequired(PreferencesRecoveryReason)
    case configurationRequired
}

public enum PreferencesCodecError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
}

public struct PreferencesDecodeOutcome: Equatable, Sendable {
    public let state: PreferencesLoadState
    public let requiresCanonicalRewrite: Bool

    public init(
        state: PreferencesLoadState,
        requiresCanonicalRewrite: Bool
    ) {
        self.state = state
        self.requiresCanonicalRewrite = requiresCanonicalRewrite
    }
}

public struct PreferencesCodec: Sendable {
    public init() {}

    public func encode(_ envelope: PreferencesEnvelope) throws -> Data {
        guard envelope.schemaVersion == Go2CodexCoreInfo.preferencesSchemaVersion else {
            throw PreferencesCodecError.unsupportedSchema(envelope.schemaVersion)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    public func decode(_ data: Data?) -> PreferencesLoadState {
        decodeOutcome(data).state
    }

    public func decodeOutcome(_ data: Data?) -> PreferencesDecodeOutcome {
        guard let data else {
            return PreferencesDecodeOutcome(
                state: .firstRun,
                requiresCanonicalRewrite: false
            )
        }

        let decoder = JSONDecoder()
        let version: Int

        do {
            version = try decoder.decode(VersionProbe.self, from: data).schemaVersion
        } catch let DecodingError.keyNotFound(key, _) where key.stringValue == "schemaVersion" {
            return outcome(.recoveryRequired(.missingRequiredFields))
        } catch {
            return outcome(.recoveryRequired(.corruptData))
        }

        guard version == Go2CodexCoreInfo.preferencesSchemaVersion else {
            return outcome(.recoveryRequired(.unsupportedSchema(version)))
        }

        do {
            let envelope = try decoder.decode(PreferencesEnvelope.self, from: data)
            let trigger = try decoder.decode(
                AlternateTriggerProbe.self,
                from: data
            ).alternateTrigger
            return PreferencesDecodeOutcome(
                state: .configured(envelope),
                requiresCanonicalRewrite: trigger == "option-click"
            )
        } catch DecodingError.keyNotFound {
            return outcome(.recoveryRequired(.missingRequiredFields))
        } catch DecodingError.valueNotFound {
            return outcome(.recoveryRequired(.missingRequiredFields))
        } catch {
            return outcome(.recoveryRequired(.corruptData))
        }
    }

    private func outcome(_ state: PreferencesLoadState) -> PreferencesDecodeOutcome {
        PreferencesDecodeOutcome(
            state: state,
            requiresCanonicalRewrite: false
        )
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }

    private struct AlternateTriggerProbe: Decodable {
        let alternateTrigger: String
    }
}

public enum PreferencesWriteVerifier {
    public static func verify(
        synchronizationSucceeded: Bool,
        expectedData: Data,
        readbackData: Data?
    ) throws {
        guard synchronizationSucceeded,
              readbackData == expectedData else {
            throw PreferencesStoreError.writeFailed
        }
    }

    public static func restorationSucceeded(
        synchronizationSucceeded: Bool,
        expectedData: Data?,
        readbackData: Data?,
        keyIsPresent: Bool
    ) -> Bool {
        guard synchronizationSucceeded else {
            return false
        }
        if let expectedData {
            return keyIsPresent && readbackData == expectedData
        }
        return !keyIsPresent
    }
}

public enum PreferencesStateMachine {
    public static func completeFirstRun(
        from state: PreferencesLoadState,
        selection: FirstRunSelection
    ) throws -> PreferencesEnvelope {
        switch state {
        case .firstRun:
            break
        case .configured:
            throw PreferencesTransitionError.firstRunAlreadyCompleted
        case let .recoveryRequired(reason):
            throw PreferencesTransitionError.recoveryRequired(reason)
        }

        var missing: Set<RequiredPreference> = []
        if selection.defaultTarget == nil {
            missing.insert(.defaultTarget)
        }
        if selection.defaultTerminalHost == nil {
            missing.insert(.defaultTerminalHost)
        }
        guard missing.isEmpty,
              let defaultTarget = selection.defaultTarget,
              let terminalHost = selection.defaultTerminalHost else {
            throw PreferencesTransitionError.missingRequiredValues(missing)
        }

        return PreferencesEnvelope(
            defaultTarget: defaultTarget,
            alternateTrigger: selection.alternateTrigger,
            defaultTerminalHost: terminalHost,
            sessionPlacement: selection.sessionPlacement
        )
    }

    public static func apply(
        _ change: PreferencesChange,
        to state: PreferencesLoadState
    ) throws -> PreferencesEnvelope {
        switch state {
        case .firstRun:
            throw PreferencesTransitionError.configurationRequired
        case let .configured(envelope):
            return envelope.applying(change)
        case let .recoveryRequired(reason):
            throw PreferencesTransitionError.recoveryRequired(reason)
        }
    }
}

public struct PreferencesRepository: Sendable {
    private let store: any PreferencesEnvelopeStoring
    private let codec: PreferencesCodec

    public init(
        store: any PreferencesEnvelopeStoring,
        codec: PreferencesCodec = PreferencesCodec()
    ) {
        self.store = store
        self.codec = codec
    }

    public func load() async -> PreferencesLoadState {
        do {
            return codec.decode(try await store.readEnvelopeData())
        } catch {
            return .recoveryRequired(.storageReadFailed)
        }
    }

    @discardableResult
    public func completeFirstRun(
        selection: FirstRunSelection
    ) async throws -> PreferencesEnvelope {
        let envelope = try PreferencesStateMachine.completeFirstRun(
            from: await load(),
            selection: selection
        )
        try await replace(with: envelope)
        return envelope
    }

    @discardableResult
    public func update(_ change: PreferencesChange) async throws -> PreferencesEnvelope {
        let envelope = try PreferencesStateMachine.apply(change, to: await load())
        try await replace(with: envelope)
        return envelope
    }

    private func replace(with envelope: PreferencesEnvelope) async throws {
        let data = try codec.encode(envelope)
        try await store.replaceEnvelopeData(with: data)
    }
}
