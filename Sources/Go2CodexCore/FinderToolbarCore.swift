import CoreFoundation
import Foundation

public enum FinderToolbarPreferenceKey {
    public static let domain = "com.apple.finder"
    public static let configuration = "NSToolbar Configuration Browser"
    public static let itemIdentifiers = "TB Item Identifiers"
    public static let defaultItemIdentifiers = "TB Default Item Identifiers"
    public static let itemPlists = "TB Item Plists"
    public static let customItemIdentifier = "com.apple.finder.loc "
    public static let urlString = "_CFURLString"
    public static let urlStringType = "_CFURLStringType"
    public static let aliasData = "_CFURLAliasData"
}

public indirect enum FinderToolbarPropertyListValue: Codable, Equatable, Sendable {
    case dictionary([String: FinderToolbarPropertyListValue])
    case array([FinderToolbarPropertyListValue])
    case string(String)
    case data(Data)
    case date(Date)
    case integer(Int64)
    case real(Double)
    case boolean(Bool)
}

public struct FinderToolbarSnapshot: Codable, Equatable, Sendable {
    public let configurationWasPresent: Bool
    public let fields: [String: FinderToolbarPropertyListValue]

    public init(
        configurationWasPresent: Bool,
        fields: [String: FinderToolbarPropertyListValue]
    ) {
        self.configurationWasPresent = configurationWasPresent
        self.fields = fields
    }
}

public enum FinderToolbarSnapshotDecodingError: Error, Codable, Equatable, Sendable {
    case presenceMismatch
    case rootIsNotDictionary
    case nonStringDictionaryKey
    case unsupportedValue
    case nonFiniteReal
}

public enum FinderToolbarSnapshotAdapter {
    public static func decode(
        _ rawConfiguration: Any?,
        configurationWasPresent: Bool
    ) -> Result<FinderToolbarSnapshot, FinderToolbarSnapshotDecodingError> {
        guard configurationWasPresent else {
            guard rawConfiguration == nil else {
                return .failure(.presenceMismatch)
            }
            return .success(FinderToolbarSnapshot(configurationWasPresent: false, fields: [:]))
        }

        guard let rawConfiguration else {
            return .failure(.presenceMismatch)
        }

        do {
            guard case let .dictionary(fields) = try decodeValue(rawConfiguration) else {
                return .failure(.rootIsNotDictionary)
            }
            return .success(FinderToolbarSnapshot(configurationWasPresent: true, fields: fields))
        } catch let error as FinderToolbarSnapshotDecodingError {
            return .failure(error)
        } catch {
            return .failure(.unsupportedValue)
        }
    }

    public static func encode(_ snapshot: FinderToolbarSnapshot) -> [String: Any]? {
        guard snapshot.configurationWasPresent else {
            return nil
        }
        return snapshot.fields.mapValues(encodeValue)
    }

    private static func decodeValue(_ rawValue: Any) throws -> FinderToolbarPropertyListValue {
        if let value = rawValue as? String {
            return .string(value)
        }
        if let value = rawValue as? Data {
            return .data(value)
        }
        if let value = rawValue as? Date {
            return .date(value)
        }
        if let value = rawValue as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .boolean(value.boolValue)
            }

            switch String(cString: value.objCType) {
            case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q":
                return .integer(value.int64Value)
            case "f", "d":
                guard value.doubleValue.isFinite else {
                    throw FinderToolbarSnapshotDecodingError.nonFiniteReal
                }
                return .real(value.doubleValue)
            default:
                throw FinderToolbarSnapshotDecodingError.unsupportedValue
            }
        }
        if let values = rawValue as? [Any] {
            return .array(try values.map(decodeValue))
        }
        if let values = rawValue as? [String: Any] {
            return .dictionary(try values.mapValues(decodeValue))
        }
        if let values = rawValue as? NSDictionary {
            var decoded: [String: FinderToolbarPropertyListValue] = [:]
            for (key, value) in values {
                guard let key = key as? String else {
                    throw FinderToolbarSnapshotDecodingError.nonStringDictionaryKey
                }
                decoded[key] = try decodeValue(value)
            }
            return .dictionary(decoded)
        }
        throw FinderToolbarSnapshotDecodingError.unsupportedValue
    }

    private static func encodeValue(_ value: FinderToolbarPropertyListValue) -> Any {
        switch value {
        case let .dictionary(dictionary):
            return dictionary.mapValues(encodeValue)
        case let .array(array):
            return array.map(encodeValue)
        case let .string(string):
            return string
        case let .data(data):
            return data
        case let .date(date):
            return date
        case let .integer(integer):
            return integer
        case let .real(real):
            return real
        case let .boolean(boolean):
            return boolean
        }
    }
}

public typealias FinderToolbarItemPayload = [String: FinderToolbarPropertyListValue]

public struct FinderToolbarLayout: Codable, Equatable, Sendable {
    public let identifiers: [String]
    public let defaultIdentifiers: [String]?
    public let itemPlists: [Int: FinderToolbarItemPayload]

    public init(
        identifiers: [String],
        defaultIdentifiers: [String]?,
        itemPlists: [Int: FinderToolbarItemPayload]
    ) {
        self.identifiers = identifiers
        self.defaultIdentifiers = defaultIdentifiers
        self.itemPlists = itemPlists
    }
}

public enum FinderToolbarLayoutProblem: Codable, Equatable, Sendable {
    case partialItemStructure
    case unexpectedIdentifiersType
    case unexpectedDefaultIdentifiersType
    case unexpectedItemPlistsType
    case nonCanonicalIndex(String)
    case indexOutOfRange(Int)
    case unexpectedItemPayloadType(Int)
}

public enum FinderToolbarLayoutClassification: Equatable, Sendable {
    case implicit
    case explicit(FinderToolbarLayout)
    case invalid(FinderToolbarLayoutProblem)
}

public extension FinderToolbarSnapshot {
    var layoutClassification: FinderToolbarLayoutClassification {
        let identifiersValue = fields[FinderToolbarPreferenceKey.itemIdentifiers]
        let itemPlistsValue = fields[FinderToolbarPreferenceKey.itemPlists]
        let defaultsValue = fields[FinderToolbarPreferenceKey.defaultItemIdentifiers]

        if identifiersValue == nil, itemPlistsValue == nil, defaultsValue == nil {
            return .implicit
        }
        guard identifiersValue != nil, itemPlistsValue != nil else {
            return .invalid(.partialItemStructure)
        }
        guard let identifiers = Self.stringArray(identifiersValue) else {
            return .invalid(.unexpectedIdentifiersType)
        }
        guard case let .dictionary(rawItemPlists) = itemPlistsValue else {
            return .invalid(.unexpectedItemPlistsType)
        }

        let defaults: [String]?
        if let defaultsValue {
            guard let parsed = Self.stringArray(defaultsValue) else {
                return .invalid(.unexpectedDefaultIdentifiersType)
            }
            defaults = parsed
        } else {
            defaults = nil
        }

        var itemPlists: [Int: FinderToolbarItemPayload] = [:]
        for (key, value) in rawItemPlists {
            guard let index = Int(key), String(index) == key else {
                return .invalid(.nonCanonicalIndex(key))
            }
            guard identifiers.indices.contains(index) else {
                return .invalid(.indexOutOfRange(index))
            }
            guard case let .dictionary(payload) = value else {
                return .invalid(.unexpectedItemPayloadType(index))
            }
            itemPlists[index] = payload
        }

        return .explicit(
            FinderToolbarLayout(
                identifiers: identifiers,
                defaultIdentifiers: defaults,
                itemPlists: itemPlists
            )
        )
    }

    func replacingLayout(_ layout: FinderToolbarLayout) -> FinderToolbarSnapshot {
        var updated = fields
        updated[FinderToolbarPreferenceKey.itemIdentifiers] = .array(layout.identifiers.map { .string($0) })
        updated[FinderToolbarPreferenceKey.itemPlists] = .dictionary(
            Dictionary(uniqueKeysWithValues: layout.itemPlists.map { (String($0.key), .dictionary($0.value)) })
        )
        if let defaults = layout.defaultIdentifiers {
            updated[FinderToolbarPreferenceKey.defaultItemIdentifiers] = .array(defaults.map { .string($0) })
        } else {
            updated.removeValue(forKey: FinderToolbarPreferenceKey.defaultItemIdentifiers)
        }
        return FinderToolbarSnapshot(configurationWasPresent: configurationWasPresent, fields: updated)
    }

    private static func stringArray(_ value: FinderToolbarPropertyListValue?) -> [String]? {
        guard case let .array(values) = value else {
            return nil
        }
        var strings: [String] = []
        for value in values {
            guard case let .string(string) = value else {
                return nil
            }
            strings.append(string)
        }
        return strings
    }
}

public struct FinderToolbarEnvironment: Codable, Equatable, Sendable {
    public let macOSBuild: String
    public let finderVersion: String
    public let finderBundleVersion: String

    public init(macOSBuild: String, finderVersion: String, finderBundleVersion: String) {
        self.macOSBuild = macOSBuild
        self.finderVersion = finderVersion
        self.finderBundleVersion = finderBundleVersion
    }
}

public struct FinderToolbarProfile: Codable, Equatable, Sendable {
    public let identifier: String
    public let environment: FinderToolbarEnvironment
    public let scalarFields: [String: FinderToolbarPropertyListValue]
    public let activeBaseline: [String]
    public let defaultIdentifiers: [String]
    public let trailingReservedItemCount: Int
    public let semanticVerifierIdentifier: String

    public static let finder146Build23G80 = FinderToolbarProfile(
        identifier: "finder-14.6-23G80-scalar-v1",
        environment: FinderToolbarEnvironment(
            macOSBuild: "23G80",
            finderVersion: "14.6",
            finderBundleVersion: "1632.6.3"
        ),
        scalarFields: [
            "TB Display Mode": .integer(2),
            "TB Icon Size Mode": .integer(1),
            "TB Is Shown": .boolean(true),
            "TB Size Mode": .integer(1),
        ],
        activeBaseline: [
            "com.apple.finder.BACK",
            "NSToolbarFlexibleSpaceItem",
            "com.apple.finder.SWCH",
            "NSToolbarSpaceItem",
            "com.apple.finder.ARNG",
            "com.apple.finder.ACTN",
            "NSToolbarSpaceItem",
            "com.apple.finder.SHAR",
            "com.apple.finder.LABL",
            "NSToolbarFlexibleSpaceItem",
            "NSToolbarFlexibleSpaceItem",
            "com.apple.finder.SRCH",
        ],
        defaultIdentifiers: [
            "com.apple.finder.BACK",
            "com.apple.finder.SWCH",
            "NSToolbarSpaceItem",
            "com.apple.finder.ARNG",
            "com.apple.finder.SHAR",
            "com.apple.finder.LABL",
            "com.apple.finder.ACTN",
            "NSToolbarSpaceItem",
            "com.apple.finder.SRCH",
        ],
        trailingReservedItemCount: 2,
        semanticVerifierIdentifier: "finder-14.6-alias-enrichment-v1"
    )

    public static let finder264Build25F84 = FinderToolbarProfile(
        identifier: "finder-26.4-25F84-explicit-v1",
        environment: FinderToolbarEnvironment(
            macOSBuild: "25F84",
            finderVersion: "26.4",
            finderBundleVersion: "1828.5.2"
        ),
        scalarFields: [
            "TB Display Mode": .integer(2),
            "TB Icon Size Mode": .integer(1),
            "TB Is Shown": .boolean(true),
            "TB Size Mode": .integer(1),
        ],
        activeBaseline: [
            "com.apple.finder.BACK",
            "com.apple.finder.SWCH",
            "NSToolbarSpaceItem",
            "com.apple.finder.ARNG",
            "NSToolbarSpaceItem",
            "com.apple.finder.SHAR",
            "com.apple.finder.LABL",
            "com.apple.finder.ACTN",
            "NSToolbarSpaceItem",
            "com.apple.finder.SRCH",
        ],
        defaultIdentifiers: [
            "com.apple.finder.BACK",
            "com.apple.finder.SWCH",
            "NSToolbarSpaceItem",
            "com.apple.finder.ARNG",
            "NSToolbarSpaceItem",
            "com.apple.finder.SHAR",
            "com.apple.finder.LABL",
            "com.apple.finder.ACTN",
            "NSToolbarSpaceItem",
            "com.apple.finder.SRCH",
        ],
        trailingReservedItemCount: 1,
        semanticVerifierIdentifier: "finder-26.4-alias-url-normalization-v1"
    )
}

public enum FinderToolbarProfileMismatch: Codable, Equatable, Sendable {
    case environment
    case configurationAbsent
    case beforeShape
    case explicitShape
    case malformed(FinderToolbarLayoutProblem)
}

public enum FinderToolbarProfileClassification: Equatable, Sendable {
    case exactBeforeShape(FinderToolbarProfile)
    case managedExplicitShape(FinderToolbarProfile, FinderToolbarLayout)
    case unsupported(FinderToolbarProfileMismatch)
}

public enum FinderToolbarProfileRegistry {
    public static let supportedProfiles: [FinderToolbarProfile] = [
        .finder146Build23G80,
        .finder264Build25F84,
    ]

    public static func profile(
        for environment: FinderToolbarEnvironment
    ) -> FinderToolbarProfile? {
        supportedProfiles.first { $0.environment == environment }
    }

    public static func classify(
        environment: FinderToolbarEnvironment,
        snapshot: FinderToolbarSnapshot,
        profile: FinderToolbarProfile = .finder146Build23G80
    ) -> FinderToolbarProfileClassification {
        guard environment == profile.environment else {
            return .unsupported(.environment)
        }
        guard snapshot.configurationWasPresent else {
            return .unsupported(.configurationAbsent)
        }
        if snapshot.fields == profile.scalarFields {
            return .exactBeforeShape(profile)
        }

        switch snapshot.layoutClassification {
        case .implicit:
            return .unsupported(.beforeShape)
        case let .invalid(problem):
            return .unsupported(.malformed(problem))
        case let .explicit(layout):
            let expectedKeys = Set(profile.scalarFields.keys).union([
                FinderToolbarPreferenceKey.itemIdentifiers,
                FinderToolbarPreferenceKey.defaultItemIdentifiers,
                FinderToolbarPreferenceKey.itemPlists,
            ])
            guard Set(snapshot.fields.keys) == expectedKeys,
                  profile.scalarFields.allSatisfy({ snapshot.fields[$0.key] == $0.value }),
                  layout.defaultIdentifiers == profile.defaultIdentifiers else {
                return .unsupported(.explicitShape)
            }
            return .managedExplicitShape(profile, layout)
        }
    }
}

public struct FinderToolbarLauncherIdentity: Codable, Equatable, Sendable {
    public let url: URL
    public let fingerprint: String
    public let launcherBundleIdentifier: String
    public let outerBundleIdentifier: String

    public init(
        url: URL,
        fingerprint: String,
        launcherBundleIdentifier: String,
        outerBundleIdentifier: String
    ) {
        self.url = url
        self.fingerprint = fingerprint
        self.launcherBundleIdentifier = launcherBundleIdentifier
        self.outerBundleIdentifier = outerBundleIdentifier
    }
}

public enum FinderToolbarLauncherIdentityEvidence: Equatable, Sendable {
    case verified(FinderToolbarLauncherIdentity)
    case invalid
}

public struct FinderToolbarInstallationReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let profileIdentifier: String
    public let environment: FinderToolbarEnvironment
    public let lastVerifiedLauncherURL: URL
    public let launcherIdentityFingerprint: String
    public let launcherBundleIdentifier: String
    public let outerBundleIdentifier: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        profileIdentifier: String,
        environment: FinderToolbarEnvironment,
        lastVerifiedLauncherURL: URL,
        launcherIdentityFingerprint: String,
        launcherBundleIdentifier: String,
        outerBundleIdentifier: String
    ) {
        self.schemaVersion = schemaVersion
        self.profileIdentifier = profileIdentifier
        self.environment = environment
        self.lastVerifiedLauncherURL = lastVerifiedLauncherURL
        self.launcherIdentityFingerprint = launcherIdentityFingerprint
        self.launcherBundleIdentifier = launcherBundleIdentifier
        self.outerBundleIdentifier = outerBundleIdentifier
    }
}

public enum FinderToolbarReceiptEvidence: Equatable, Sendable {
    case missing
    case valid(FinderToolbarInstallationReceipt)
    case invalid
}

public enum FinderToolbarAliasResolution: Equatable, Sendable {
    case absent
    case resolved(URL)
    case unresolvable
    case invalid
}

public enum FinderToolbarStoredPathState: Codable, Equatable, Sendable {
    case present
    case missing
    case unknown
}

public struct FinderToolbarDetectionContext: Equatable, Sendable {
    public let snapshot: FinderToolbarSnapshot
    public let environment: FinderToolbarEnvironment
    public let launcherIdentity: FinderToolbarLauncherIdentityEvidence
    public let receipt: FinderToolbarReceiptEvidence
    public let aliasResolutions: [Int: FinderToolbarAliasResolution]
    public let storedPathStates: [String: FinderToolbarStoredPathState]
    public let legacyLauncherURLs: [URL]

    public init(
        snapshot: FinderToolbarSnapshot,
        environment: FinderToolbarEnvironment,
        launcherIdentity: FinderToolbarLauncherIdentityEvidence,
        receipt: FinderToolbarReceiptEvidence = .missing,
        aliasResolutions: [Int: FinderToolbarAliasResolution] = [:],
        storedPathStates: [String: FinderToolbarStoredPathState] = [:],
        legacyLauncherURLs: [URL] = []
    ) {
        self.snapshot = snapshot
        self.environment = environment
        self.launcherIdentity = launcherIdentity
        self.receipt = receipt
        self.aliasResolutions = aliasResolutions
        self.storedPathStates = storedPathStates
        self.legacyLauncherURLs = legacyLauncherURLs
    }
}

public enum FinderToolbarManualReason: Codable, Equatable, Sendable {
    case unsupportedProfile(FinderToolbarProfileMismatch)
    case invalidLauncherIdentity
    case invalidReceipt
    case unmanagedExplicitShape
    case orphanCustomIdentifier(Int)
    case duplicateOwnership
    case invalidURL(Int)
    case wrongURLType(Int)
    case missingAlias(Int)
    case emptyAlias(Int)
    case unresolvedAlias(Int)
    case conflictingAlias(Int)
    case stalePathNotMissing
}

public enum FinderToolbarDetectionStatus: Equatable, Sendable {
    case installed(index: Int)
    case notInstalled
    case needsRepair(index: Int, staleURL: URL)
    case manualSetupRequired(FinderToolbarManualReason)
}

public enum FinderToolbarDetector {
    public static func detect(
        _ context: FinderToolbarDetectionContext
    ) -> FinderToolbarDetectionStatus {
        guard let profile = FinderToolbarProfileRegistry.profile(for: context.environment) else {
            return .manualSetupRequired(.unsupportedProfile(.environment))
        }
        return detect(context, profile: profile)
    }

    public static func detect(
        _ context: FinderToolbarDetectionContext,
        profile: FinderToolbarProfile
    ) -> FinderToolbarDetectionStatus {
        guard case let .verified(identity) = context.launcherIdentity,
              canonicalFileURL(identity.url) != nil,
              !identity.fingerprint.isEmpty,
              !identity.launcherBundleIdentifier.isEmpty,
              !identity.outerBundleIdentifier.isEmpty else {
            return .manualSetupRequired(.invalidLauncherIdentity)
        }

        let validReceipt: FinderToolbarInstallationReceipt?
        let receiptIsInvalid: Bool
        switch context.receipt {
        case .missing:
            validReceipt = nil
            receiptIsInvalid = false
        case .invalid:
            validReceipt = nil
            receiptIsInvalid = true
        case let .valid(receipt):
            if receipt.schemaVersion == FinderToolbarInstallationReceipt.currentSchemaVersion,
               receipt.profileIdentifier == profile.identifier,
               receipt.environment == profile.environment,
               canonicalFileURL(receipt.lastVerifiedLauncherURL) != nil,
               receipt.launcherIdentityFingerprint == identity.fingerprint,
               receipt.launcherBundleIdentifier == identity.launcherBundleIdentifier,
               receipt.outerBundleIdentifier == identity.outerBundleIdentifier {
                validReceipt = receipt
                receiptIsInvalid = false
            } else {
                validReceipt = nil
                receiptIsInvalid = true
            }
        }

        switch FinderToolbarProfileRegistry.classify(
            environment: context.environment,
            snapshot: context.snapshot,
            profile: profile
        ) {
        case let .unsupported(reason):
            return .manualSetupRequired(.unsupportedProfile(reason))
        case .exactBeforeShape:
            return receiptIsInvalid ? .manualSetupRequired(.invalidReceipt) : .notInstalled
        case let .managedExplicitShape(_, layout):
            var customEntries: [FinderToolbarDetectedCustomEntry] = []
            for index in layout.identifiers.indices
            where layout.identifiers[index] == FinderToolbarPreferenceKey.customItemIdentifier {
                guard let payload = layout.itemPlists[index] else {
                    return .manualSetupRequired(.orphanCustomIdentifier(index))
                }
                guard let url = payloadFileURL(payload) else {
                    return .manualSetupRequired(.invalidURL(index))
                }
                guard payload[FinderToolbarPreferenceKey.urlStringType] == .integer(15) else {
                    return .manualSetupRequired(.wrongURLType(index))
                }
                customEntries.append(
                    FinderToolbarDetectedCustomEntry(
                        index: index,
                        url: url,
                        payload: payload,
                        usesFinderFileReference: payloadUsesFinderFileReference(payload)
                    )
                )
            }

            let currentMatches = customEntries.filter {
                $0.usesFinderFileReference
                    ? aliasURLsEqual(
                        context.aliasResolutions[$0.index] ?? .absent,
                        identity.url
                    )
                    : fileURLsEqual($0.url, identity.url)
            }
            guard currentMatches.count <= 1 else {
                return .manualSetupRequired(.duplicateOwnership)
            }
            if let current = currentMatches.first {
                let otherLegacyMatches = customEntries.filter { entry in
                    entry.index != current.index
                        && context.legacyLauncherURLs.contains(where: { legacyURL in
                            entry.usesFinderFileReference
                                ? aliasURLsEqual(
                                    context.aliasResolutions[entry.index] ?? .absent,
                                    legacyURL
                                )
                                : fileURLsEqual(entry.url, legacyURL)
                        })
                }
                guard otherLegacyMatches.isEmpty else {
                    return .manualSetupRequired(.duplicateOwnership)
                }
                if let receipt = validReceipt,
                   !fileURLsEqual(receipt.lastVerifiedLauncherURL, identity.url) {
                    let receiptMatches = customEntries.filter {
                        $0.usesFinderFileReference
                            ? aliasURLsEqual(
                                context.aliasResolutions[$0.index] ?? .absent,
                                receipt.lastVerifiedLauncherURL
                            )
                            : fileURLsEqual($0.url, receipt.lastVerifiedLauncherURL)
                    }
                    guard receiptMatches.isEmpty else {
                        return .manualSetupRequired(.duplicateOwnership)
                    }
                }
                if let reason = aliasFailure(
                    payload: current.payload,
                    resolution: context.aliasResolutions[current.index] ?? .absent,
                    expectedURL: identity.url,
                    index: current.index
                ) {
                    return .manualSetupRequired(reason)
                }
                return .installed(index: current.index)
            }

            if customEntries.isEmpty {
                return .notInstalled
            }

            let legacyMatches = customEntries.compactMap { entry -> (Int, URL)? in
                guard let legacyURL = context.legacyLauncherURLs.first(where: {
                    entry.usesFinderFileReference
                        ? aliasURLsEqual(
                            context.aliasResolutions[entry.index] ?? .absent,
                            $0
                        )
                        : fileURLsEqual(entry.url, $0)
                }) else {
                    return nil
                }
                return (entry.index, legacyURL)
            }
            guard legacyMatches.count <= 1 else {
                return .manualSetupRequired(.duplicateOwnership)
            }
            if let legacy = legacyMatches.first {
                guard context.storedPathStates[canonicalFileURL(legacy.1) ?? ""] == .missing else {
                    return .manualSetupRequired(.stalePathNotMissing)
                }
                return .needsRepair(index: legacy.0, staleURL: legacy.1)
            }
            guard !receiptIsInvalid else {
                return .manualSetupRequired(.invalidReceipt)
            }
            guard let receipt = validReceipt else {
                return .manualSetupRequired(.unmanagedExplicitShape)
            }
            let receiptMatches = customEntries.filter {
                $0.usesFinderFileReference
                    ? aliasURLsEqual(
                        context.aliasResolutions[$0.index] ?? .absent,
                        receipt.lastVerifiedLauncherURL
                    )
                    : fileURLsEqual($0.url, receipt.lastVerifiedLauncherURL)
            }
            guard receiptMatches.count <= 1 else {
                return .manualSetupRequired(.duplicateOwnership)
            }
            guard let stale = receiptMatches.first else {
                return .notInstalled
            }
            guard !fileURLsEqual(receipt.lastVerifiedLauncherURL, identity.url) else {
                return .manualSetupRequired(.invalidReceipt)
            }
            guard context.storedPathStates[canonicalFileURL(receipt.lastVerifiedLauncherURL) ?? ""] == .missing else {
                return .manualSetupRequired(.stalePathNotMissing)
            }
            if let reason = aliasFailure(
                payload: stale.payload,
                resolution: context.aliasResolutions[stale.index] ?? .absent,
                expectedURL: identity.url,
                index: stale.index
            ) {
                return .manualSetupRequired(reason)
            }
            return .needsRepair(index: stale.index, staleURL: receipt.lastVerifiedLauncherURL)
        }
    }

    private static func aliasFailure(
        payload: FinderToolbarItemPayload,
        resolution: FinderToolbarAliasResolution,
        expectedURL: URL,
        index: Int
    ) -> FinderToolbarManualReason? {
        guard let value = payload[FinderToolbarPreferenceKey.aliasData] else {
            return .missingAlias(index)
        }
        guard case let .data(data) = value else {
            return .unresolvedAlias(index)
        }
        guard !data.isEmpty else {
            return .emptyAlias(index)
        }
        switch resolution {
        case let .resolved(url):
            return fileURLsEqual(url, expectedURL) ? nil : .conflictingAlias(index)
        case .absent, .unresolvable, .invalid:
            return .unresolvedAlias(index)
        }
    }
}

public enum FinderToolbarLayoutMutationError: Error, Codable, Equatable, Sendable {
    case invalidIndex
    case malformedLayout
    case missingPayload
}

public enum FinderToolbarLayoutMutation {
    public static func insert(
        identifier: String,
        payload: FinderToolbarItemPayload,
        at index: Int,
        into layout: FinderToolbarLayout
    ) -> Result<FinderToolbarLayout, FinderToolbarLayoutMutationError> {
        guard validate(layout), index >= 0, index <= layout.identifiers.count else {
            return .failure(index < 0 || index > layout.identifiers.count ? .invalidIndex : .malformedLayout)
        }
        var identifiers = layout.identifiers
        identifiers.insert(identifier, at: index)
        var itemPlists: [Int: FinderToolbarItemPayload] = [:]
        for (existingIndex, existingPayload) in layout.itemPlists {
            itemPlists[existingIndex >= index ? existingIndex + 1 : existingIndex] = existingPayload
        }
        itemPlists[index] = payload
        return .success(
            FinderToolbarLayout(
                identifiers: identifiers,
                defaultIdentifiers: layout.defaultIdentifiers,
                itemPlists: itemPlists
            )
        )
    }

    public static func remove(
        at index: Int,
        from layout: FinderToolbarLayout
    ) -> Result<FinderToolbarLayout, FinderToolbarLayoutMutationError> {
        guard validate(layout) else {
            return .failure(.malformedLayout)
        }
        guard layout.identifiers.indices.contains(index) else {
            return .failure(.invalidIndex)
        }
        var identifiers = layout.identifiers
        identifiers.remove(at: index)
        var itemPlists: [Int: FinderToolbarItemPayload] = [:]
        for (existingIndex, payload) in layout.itemPlists where existingIndex != index {
            itemPlists[existingIndex > index ? existingIndex - 1 : existingIndex] = payload
        }
        return .success(
            FinderToolbarLayout(
                identifiers: identifiers,
                defaultIdentifiers: layout.defaultIdentifiers,
                itemPlists: itemPlists
            )
        )
    }

    public static func replacePayload(
        at index: Int,
        in layout: FinderToolbarLayout,
        transform: (FinderToolbarItemPayload) -> FinderToolbarItemPayload
    ) -> Result<FinderToolbarLayout, FinderToolbarLayoutMutationError> {
        guard validate(layout) else {
            return .failure(.malformedLayout)
        }
        guard let payload = layout.itemPlists[index] else {
            return .failure(.missingPayload)
        }
        var itemPlists = layout.itemPlists
        itemPlists[index] = transform(payload)
        return .success(
            FinderToolbarLayout(
                identifiers: layout.identifiers,
                defaultIdentifiers: layout.defaultIdentifiers,
                itemPlists: itemPlists
            )
        )
    }

    private static func validate(_ layout: FinderToolbarLayout) -> Bool {
        layout.itemPlists.keys.allSatisfy(layout.identifiers.indices.contains)
    }
}

public enum FinderToolbarMutationOperation: String, Codable, Equatable, Sendable {
    case install
    case repair
    case uninstall
}

public enum FinderToolbarOwnership: Codable, Equatable, Sendable {
    case newEntry
    case currentLauncherURL
    case receipt(URL)
    case legacy(URL)
}

public struct FinderToolbarMutationPlan: Codable, Equatable, Sendable {
    public let operation: FinderToolbarMutationOperation
    public let profileIdentifier: String
    public let environment: FinderToolbarEnvironment
    public let before: FinderToolbarSnapshot
    public let expected: FinderToolbarSnapshot
    public let affectedIndex: Int
    public let ownership: FinderToolbarOwnership

    public init(
        operation: FinderToolbarMutationOperation,
        profileIdentifier: String,
        environment: FinderToolbarEnvironment,
        before: FinderToolbarSnapshot,
        expected: FinderToolbarSnapshot,
        affectedIndex: Int,
        ownership: FinderToolbarOwnership
    ) {
        self.operation = operation
        self.profileIdentifier = profileIdentifier
        self.environment = environment
        self.before = before
        self.expected = expected
        self.affectedIndex = affectedIndex
        self.ownership = ownership
    }
}

public enum FinderToolbarNoChangeReason: Codable, Equatable, Sendable {
    case alreadyInstalled
    case alreadyNotInstalled
}

public enum FinderToolbarMutationBlockReason: Equatable, Sendable {
    case unsafe(FinderToolbarManualReason)
    case repairRequired
    case notInstalled
    case invalidMutation
}

public enum FinderToolbarMutationResult: Equatable, Sendable {
    case mutation(FinderToolbarMutationPlan)
    case noChange(FinderToolbarNoChangeReason)
    case blocked(FinderToolbarMutationBlockReason)
}

public enum FinderToolbarMutationPlanner {
    public static func install(
        _ context: FinderToolbarDetectionContext
    ) -> FinderToolbarMutationResult {
        guard let profile = FinderToolbarProfileRegistry.profile(for: context.environment) else {
            return .blocked(.unsafe(.unsupportedProfile(.environment)))
        }
        return install(context, profile: profile)
    }

    public static func install(
        _ context: FinderToolbarDetectionContext,
        profile: FinderToolbarProfile
    ) -> FinderToolbarMutationResult {
        switch FinderToolbarDetector.detect(context, profile: profile) {
        case .installed:
            return .noChange(.alreadyInstalled)
        case .needsRepair:
            return .blocked(.repairRequired)
        case let .manualSetupRequired(reason):
            return .blocked(.unsafe(reason))
        case .notInstalled:
            let layout: FinderToolbarLayout
            switch FinderToolbarProfileRegistry.classify(
                environment: context.environment,
                snapshot: context.snapshot,
                profile: profile
            ) {
            case .exactBeforeShape:
                layout = FinderToolbarLayout(
                    identifiers: profile.activeBaseline,
                    defaultIdentifiers: profile.defaultIdentifiers,
                    itemPlists: [:]
                )
            case let .managedExplicitShape(_, currentLayout):
                layout = currentLayout
            case let .unsupported(reason):
                return .blocked(.unsafe(.unsupportedProfile(reason)))
            }

            guard case let .verified(identity) = context.launcherIdentity else {
                return .blocked(.unsafe(.invalidLauncherIdentity))
            }
            let insertionIndex = max(layout.identifiers.count - profile.trailingReservedItemCount, 0)
            let payload: FinderToolbarItemPayload = [
                FinderToolbarPreferenceKey.urlString: .string(identity.url.standardizedFileURL.absoluteString),
                FinderToolbarPreferenceKey.urlStringType: .integer(15),
            ]
            guard case let .success(updated) = FinderToolbarLayoutMutation.insert(
                identifier: FinderToolbarPreferenceKey.customItemIdentifier,
                payload: payload,
                at: insertionIndex,
                into: layout
            ) else {
                return .blocked(.invalidMutation)
            }
            return .mutation(
                FinderToolbarMutationPlan(
                    operation: .install,
                    profileIdentifier: profile.identifier,
                    environment: context.environment,
                    before: context.snapshot,
                    expected: context.snapshot.replacingLayout(updated),
                    affectedIndex: insertionIndex,
                    ownership: .newEntry
                )
            )
        }
    }

    public static func repair(
        _ context: FinderToolbarDetectionContext
    ) -> FinderToolbarMutationResult {
        guard let profile = FinderToolbarProfileRegistry.profile(for: context.environment) else {
            return .blocked(.unsafe(.unsupportedProfile(.environment)))
        }
        return repair(context, profile: profile)
    }

    public static func repair(
        _ context: FinderToolbarDetectionContext,
        profile: FinderToolbarProfile
    ) -> FinderToolbarMutationResult {
        let status = FinderToolbarDetector.detect(context, profile: profile)
        switch status {
        case .installed:
            return .noChange(.alreadyInstalled)
        case .notInstalled:
            return .blocked(.notInstalled)
        case let .manualSetupRequired(reason):
            return .blocked(.unsafe(reason))
        case let .needsRepair(index, staleURL):
            guard case let .verified(identity) = context.launcherIdentity,
                  case let .explicit(layout) = context.snapshot.layoutClassification,
                  case let .success(updated) = FinderToolbarLayoutMutation.replacePayload(
                    at: index,
                    in: layout,
                    transform: { payload in
                        var payload = payload
                        payload[FinderToolbarPreferenceKey.urlString] = .string(identity.url.standardizedFileURL.absoluteString)
                        payload[FinderToolbarPreferenceKey.urlStringType] = .integer(15)
                        payload.removeValue(forKey: FinderToolbarPreferenceKey.aliasData)
                        return payload
                    }
                  ) else {
                return .blocked(.invalidMutation)
            }
            return .mutation(
                FinderToolbarMutationPlan(
                    operation: .repair,
                    profileIdentifier: profile.identifier,
                    environment: context.environment,
                    before: context.snapshot,
                    expected: context.snapshot.replacingLayout(updated),
                    affectedIndex: index,
                    ownership: context.legacyLauncherURLs.contains(where: {
                        fileURLsEqual($0, staleURL)
                    }) ? .legacy(staleURL) : .receipt(staleURL)
                )
            )
        }
    }

    public static func uninstall(
        _ context: FinderToolbarDetectionContext
    ) -> FinderToolbarMutationResult {
        guard let profile = FinderToolbarProfileRegistry.profile(for: context.environment) else {
            return .blocked(.unsafe(.unsupportedProfile(.environment)))
        }
        return uninstall(context, profile: profile)
    }

    public static func uninstall(
        _ context: FinderToolbarDetectionContext,
        profile: FinderToolbarProfile
    ) -> FinderToolbarMutationResult {
        let status = FinderToolbarDetector.detect(context, profile: profile)
        let index: Int
        let ownership: FinderToolbarOwnership
        switch status {
        case let .installed(installedIndex):
            index = installedIndex
            ownership = .currentLauncherURL
        case let .needsRepair(staleIndex, staleURL):
            index = staleIndex
            ownership = context.legacyLauncherURLs.contains(where: {
                fileURLsEqual($0, staleURL)
            }) ? .legacy(staleURL) : .receipt(staleURL)
        case .notInstalled:
            return .noChange(.alreadyNotInstalled)
        case let .manualSetupRequired(reason):
            return .blocked(.unsafe(reason))
        }
        guard case let .explicit(layout) = context.snapshot.layoutClassification,
              case let .success(updated) = FinderToolbarLayoutMutation.remove(at: index, from: layout) else {
            return .blocked(.invalidMutation)
        }
        return .mutation(
            FinderToolbarMutationPlan(
                operation: .uninstall,
                profileIdentifier: profile.identifier,
                environment: context.environment,
                before: context.snapshot,
                expected: context.snapshot.replacingLayout(updated),
                affectedIndex: index,
                ownership: ownership
            )
        )
    }
}

public enum FinderToolbarSemanticMismatch: Codable, Equatable, Sendable {
    case unsupportedOperation
    case unexpectedDifference
    case missingAlias
    case emptyAlias
    case unresolvedAlias
    case conflictingAlias
}

public enum FinderToolbarSemanticResult: Equatable, Sendable {
    case exactExpected
    case acceptedAliasEnrichment
    case rejected(FinderToolbarSemanticMismatch)
}

public enum FinderToolbarSemanticVerifier {
    public static func verify(
        plan: FinderToolbarMutationPlan,
        observed: FinderToolbarSnapshot,
        aliasResolution: FinderToolbarAliasResolution = .absent
    ) -> FinderToolbarSemanticResult {
        if observed == plan.expected {
            return .exactExpected
        }
        guard plan.operation != .uninstall,
              Set(observed.fields.keys) == Set(plan.expected.fields.keys),
              plan.expected.fields.allSatisfy({ key, value in
                  key == FinderToolbarPreferenceKey.itemPlists || observed.fields[key] == value
              }),
              case let .explicit(expectedLayout) = plan.expected.layoutClassification,
              case let .explicit(observedLayout) = observed.layoutClassification,
              expectedLayout.identifiers.indices.contains(plan.affectedIndex),
              expectedLayout.identifiers[plan.affectedIndex] == FinderToolbarPreferenceKey.customItemIdentifier,
              let expectedPayload = expectedLayout.itemPlists[plan.affectedIndex],
              let observedPayload = observedLayout.itemPlists[plan.affectedIndex],
              expectedPayload[FinderToolbarPreferenceKey.aliasData] == nil else {
            return .rejected(.unexpectedDifference)
        }
        guard case let .data(aliasData)? = observedPayload[FinderToolbarPreferenceKey.aliasData] else {
            return .rejected(.missingAlias)
        }
        guard !aliasData.isEmpty else {
            return .rejected(.emptyAlias)
        }
        var normalizedPayload = observedPayload
        normalizedPayload.removeValue(forKey: FinderToolbarPreferenceKey.aliasData)
        guard let expectedURL = payloadFileURL(expectedPayload) else {
            return .rejected(.unexpectedDifference)
        }

        if normalizedPayload != expectedPayload {
            guard payloadFileURL(normalizedPayload) != nil,
                  payloadUsesFinderFileReference(normalizedPayload) else {
                return .rejected(.unexpectedDifference)
            }
            normalizedPayload[FinderToolbarPreferenceKey.urlString] = expectedPayload[
                FinderToolbarPreferenceKey.urlString
            ]
            guard normalizedPayload == expectedPayload else {
                return .rejected(.unexpectedDifference)
            }
        }
        var normalizedItemPlists = observedLayout.itemPlists
        normalizedItemPlists[plan.affectedIndex] = normalizedPayload
        let normalizedLayout = FinderToolbarLayout(
            identifiers: observedLayout.identifiers,
            defaultIdentifiers: observedLayout.defaultIdentifiers,
            itemPlists: normalizedItemPlists
        )
        guard observed.replacingLayout(normalizedLayout) == plan.expected else {
            return .rejected(.unexpectedDifference)
        }
        switch aliasResolution {
        case let .resolved(url):
            return fileURLsEqual(url, expectedURL)
                ? .acceptedAliasEnrichment
                : .rejected(.conflictingAlias)
        case .absent, .unresolvable, .invalid:
            return .rejected(.unresolvedAlias)
        }
    }
}

public enum FinderToolbarTransactionState: String, Codable, CaseIterable, Equatable, Sendable {
    case prepared
    case preferenceSynchronized
    case restartIntentRecorded
    case restartRequested
    case finderReplacementObserved
    case semanticConvergenceVerified
    case receiptCommitted
    case completed
}

public struct FinderToolbarTransactionJournal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let operationIdentifier: UUID
    public let plan: FinderToolbarMutationPlan
    public let launcherIdentity: FinderToolbarLauncherIdentity
    public let beforeFingerprint: String
    public let expectedFingerprint: String
    public let semanticVerifierIdentifier: String
    public let state: FinderToolbarTransactionState

    public init(
        schemaVersion: Int = currentSchemaVersion,
        operationIdentifier: UUID,
        plan: FinderToolbarMutationPlan,
        launcherIdentity: FinderToolbarLauncherIdentity,
        beforeFingerprint: String,
        expectedFingerprint: String,
        semanticVerifierIdentifier: String,
        state: FinderToolbarTransactionState
    ) {
        self.schemaVersion = schemaVersion
        self.operationIdentifier = operationIdentifier
        self.plan = plan
        self.launcherIdentity = launcherIdentity
        self.beforeFingerprint = beforeFingerprint
        self.expectedFingerprint = expectedFingerprint
        self.semanticVerifierIdentifier = semanticVerifierIdentifier
        self.state = state
    }
}

public struct FinderToolbarJournalValidationContext: Equatable, Sendable {
    public let profile: FinderToolbarProfile
    public let launcherIdentity: FinderToolbarLauncherIdentity
    public let beforeFingerprint: String
    public let expectedFingerprint: String

    public init(
        profile: FinderToolbarProfile,
        launcherIdentity: FinderToolbarLauncherIdentity,
        beforeFingerprint: String,
        expectedFingerprint: String
    ) {
        self.profile = profile
        self.launcherIdentity = launcherIdentity
        self.beforeFingerprint = beforeFingerprint
        self.expectedFingerprint = expectedFingerprint
    }
}

public enum FinderToolbarJournalInvalidReason: Codable, Equatable, Sendable {
    case schema
    case profile
    case environment
    case launcherIdentity
    case fingerprints
    case semanticVerifier
    case noMutation
}

public enum FinderToolbarValidatedJournal: Equatable, Sendable {
    case missing
    case invalid(FinderToolbarJournalInvalidReason)
    case valid(FinderToolbarTransactionJournal)
}

public enum FinderToolbarJournalValidator {
    public static func validate(
        _ journal: FinderToolbarTransactionJournal,
        context: FinderToolbarJournalValidationContext
    ) -> FinderToolbarValidatedJournal {
        guard journal.schemaVersion == FinderToolbarTransactionJournal.currentSchemaVersion else {
            return .invalid(.schema)
        }
        guard journal.plan.profileIdentifier == context.profile.identifier else {
            return .invalid(.profile)
        }
        guard journal.plan.environment == context.profile.environment else {
            return .invalid(.environment)
        }
        guard journal.launcherIdentity == context.launcherIdentity else {
            return .invalid(.launcherIdentity)
        }
        guard journal.beforeFingerprint == context.beforeFingerprint,
              journal.expectedFingerprint == context.expectedFingerprint,
              !journal.beforeFingerprint.isEmpty,
              !journal.expectedFingerprint.isEmpty else {
            return .invalid(.fingerprints)
        }
        guard journal.semanticVerifierIdentifier == context.profile.semanticVerifierIdentifier else {
            return .invalid(.semanticVerifier)
        }
        guard journal.plan.before != journal.plan.expected else {
            return .invalid(.noMutation)
        }
        return .valid(journal)
    }
}

public enum FinderToolbarSerializationBoundary: Equatable, Sendable {
    case established(String)
    case experimentalBestEffort(String)
    case unavailable
}

public enum FinderToolbarPreMutationDecision: Equatable, Sendable {
    case proceed
    case rejectJournal
    case rejectSerializationBoundary
    case rejectDiskLiveDivergence
    case rejectStalePlan
}

public enum FinderToolbarPreMutationGate {
    public static func decide(
        plan: FinderToolbarMutationPlan,
        journal: FinderToolbarValidatedJournal,
        serializationBoundary: FinderToolbarSerializationBoundary,
        disk: FinderToolbarSnapshot,
        live: FinderToolbarSnapshot
    ) -> FinderToolbarPreMutationDecision {
        guard case let .valid(validJournal) = journal, validJournal.plan == plan else {
            return .rejectJournal
        }
        let boundaryIdentifier: String?
        switch serializationBoundary {
        case let .established(identifier), let .experimentalBestEffort(identifier):
            boundaryIdentifier = identifier
        case .unavailable:
            boundaryIdentifier = nil
        }
        guard let boundaryIdentifier, !boundaryIdentifier.isEmpty else {
            return .rejectSerializationBoundary
        }
        guard disk == live else {
            return .rejectDiskLiveDivergence
        }
        guard disk == plan.before else {
            return .rejectStalePlan
        }
        return .proceed
    }
}

public enum FinderToolbarRecoveryRetryState: Equatable, Sendable {
    case mayRetry
    case timedOut
}

public enum FinderToolbarFinderReplacementState: Equatable, Sendable {
    case pending
    case observed
}

public enum FinderToolbarRecoveryManualReason: Codable, Equatable, Sendable {
    case invalidJournal
    case unknownPreferenceValue
    case convergenceTimedOut
    case unexpectedBeforeValue
}

public enum FinderToolbarRecoveryDecision: Equatable, Sendable {
    case noRecoveryNeeded
    case resumePreferenceMutation
    case recordRestartIntent
    case requestFinderRestart
    case waitForFinderReplacement
    case recordFinderReplacement
    case resumeSemanticVerification
    case commitReceipt
    case markCompleted
    case alreadyCompleted
    case waitForDiskLiveConvergence
    case manualSetupRequired(FinderToolbarRecoveryManualReason)
}

public struct FinderToolbarRecoveryObservation: Equatable, Sendable {
    public let snapshot: FinderToolbarSnapshot
    public let aliasResolution: FinderToolbarAliasResolution

    public init(
        snapshot: FinderToolbarSnapshot,
        aliasResolution: FinderToolbarAliasResolution = .absent
    ) {
        self.snapshot = snapshot
        self.aliasResolution = aliasResolution
    }
}

public enum FinderToolbarRecoveryPlanner {
    public static func decide(
        journal evidence: FinderToolbarValidatedJournal,
        disk: FinderToolbarRecoveryObservation,
        live: FinderToolbarRecoveryObservation,
        retryState: FinderToolbarRecoveryRetryState,
        finderReplacement: FinderToolbarFinderReplacementState = .pending
    ) -> FinderToolbarRecoveryDecision {
        switch evidence {
        case .missing:
            return .noRecoveryNeeded
        case .invalid:
            return .manualSetupRequired(.invalidJournal)
        case let .valid(journal):
            let diskClass = classify(disk, plan: journal.plan)
            let liveClass = classify(live, plan: journal.plan)
            guard diskClass != .unknown, liveClass != .unknown else {
                return .manualSetupRequired(.unknownPreferenceValue)
            }
            guard disk.snapshot == live.snapshot else {
                return retryState == .mayRetry
                    ? .waitForDiskLiveConvergence
                    : .manualSetupRequired(.convergenceTimedOut)
            }

            if diskClass == .before, liveClass == .before {
                switch journal.state {
                case .prepared, .preferenceSynchronized, .restartIntentRecorded, .restartRequested:
                    return .resumePreferenceMutation
                case .finderReplacementObserved, .semanticConvergenceVerified, .receiptCommitted, .completed:
                    return .manualSetupRequired(.unexpectedBeforeValue)
                }
            }

            switch journal.state {
            case .prepared, .preferenceSynchronized:
                return .recordRestartIntent
            case .restartIntentRecorded:
                return .requestFinderRestart
            case .restartRequested:
                return finderReplacement == .observed
                    ? .recordFinderReplacement
                    : .waitForFinderReplacement
            case .finderReplacementObserved:
                return .resumeSemanticVerification
            case .semanticConvergenceVerified:
                return .commitReceipt
            case .receiptCommitted:
                return .markCompleted
            case .completed:
                return .alreadyCompleted
            }
        }
    }

    private enum ObservedClass: Equatable {
        case before
        case accepted
        case unknown
    }

    private static func classify(
        _ observation: FinderToolbarRecoveryObservation,
        plan: FinderToolbarMutationPlan
    ) -> ObservedClass {
        if observation.snapshot == plan.before {
            return .before
        }
        switch FinderToolbarSemanticVerifier.verify(
            plan: plan,
            observed: observation.snapshot,
            aliasResolution: observation.aliasResolution
        ) {
        case .exactExpected, .acceptedAliasEnrichment:
            return .accepted
        case .rejected:
            return .unknown
        }
    }
}

public enum FinderToolbarFaultPoint: String, CaseIterable, Codable, Equatable, Sendable {
    case beforeJournalWrite
    case duringJournalReplacement
    case afterJournalDurable
    case duringPreferenceWrite
    case afterPreferenceSynchronization
    case afterRestartIntent
    case afterRestartRequest
    case afterFinderReplacement
    case duringSemanticVerification
    case afterSemanticVerification
    case afterReceiptCommit
    case afterTerminalState
}

public enum FinderToolbarFaultDecision: Equatable, Sendable {
    case abortWithoutMutation
    case discardIncompleteTemporaryJournal
    case recoverFromDurableJournal
    case returnCompleted
}

public enum FinderToolbarFaultPlanner {
    public static func decide(at point: FinderToolbarFaultPoint) -> FinderToolbarFaultDecision {
        switch point {
        case .beforeJournalWrite:
            return .abortWithoutMutation
        case .duringJournalReplacement:
            return .discardIncompleteTemporaryJournal
        case .afterJournalDurable,
             .duringPreferenceWrite,
             .afterPreferenceSynchronization,
             .afterRestartIntent,
             .afterRestartRequest,
             .afterFinderReplacement,
             .duringSemanticVerification,
             .afterSemanticVerification,
             .afterReceiptCommit:
            return .recoverFromDurableJournal
        case .afterTerminalState:
            return .returnCompleted
        }
    }
}

private struct FinderToolbarDetectedCustomEntry {
    let index: Int
    let url: URL
    let payload: FinderToolbarItemPayload
    let usesFinderFileReference: Bool
}

private func payloadFileURL(_ payload: FinderToolbarItemPayload) -> URL? {
    guard case let .string(string)? = payload[FinderToolbarPreferenceKey.urlString],
          let url = URL(string: string),
          canonicalFileURL(url) != nil else {
        return nil
    }
    return url
}

private func payloadUsesFinderFileReference(
    _ payload: FinderToolbarItemPayload
) -> Bool {
    guard case let .string(string)? = payload[FinderToolbarPreferenceKey.urlString] else {
        return false
    }
    return string.hasPrefix("file:///.file/id=")
}

private func canonicalFileURL(_ url: URL) -> String? {
    guard url.isFileURL, url.path.hasPrefix("/") else {
        return nil
    }
    return url.standardizedFileURL.absoluteString
}

private func fileURLsEqual(_ lhs: URL, _ rhs: URL) -> Bool {
    guard let left = canonicalFileURL(lhs), let right = canonicalFileURL(rhs) else {
        return false
    }
    return left == right
}

private func aliasURLsEqual(
    _ resolution: FinderToolbarAliasResolution,
    _ expectedURL: URL
) -> Bool {
    guard case let .resolved(url) = resolution else {
        return false
    }
    return fileURLsEqual(url, expectedURL)
}
