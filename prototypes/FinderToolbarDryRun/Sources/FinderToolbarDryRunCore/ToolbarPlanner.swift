import Foundation

public enum ToolbarPreference {
    public static let domain = "com.apple.finder"
    public static let configurationKey = "NSToolbar Configuration Browser"
    public static let itemIdentifiersKey = "TB Item Identifiers"
    public static let defaultItemIdentifiersKey = "TB Default Item Identifiers"
    public static let itemPlistsKey = "TB Item Plists"
    public static let customItemIdentifier = "com.apple.finder.loc "
}

public struct CandidateEnvironment: Equatable {
    public let macOSBuild: String
    public let finderVersion: String
    public let finderBundleVersion: String

    public init(macOSBuild: String, finderVersion: String, finderBundleVersion: String) {
        self.macOSBuild = macOSBuild
        self.finderVersion = finderVersion
        self.finderBundleVersion = finderBundleVersion
    }

    public static let macOS146Finder146 = CandidateEnvironment(
        macOSBuild: "23G80",
        finderVersion: "14.6",
        finderBundleVersion: "1632.6.3"
    )
}

public struct CandidateProfile: Equatable {
    public let name: String
    public let itemIdentifiers: [String]
    public let defaultIdentifiers: [String]
    public let trailingReservedItemCount: Int
    public let verified: Bool
    public let environment: CandidateEnvironment?

    public static let go2ShellV25ModernUnverified = CandidateProfile(
        name: "go2shell-v2.5-modern-unverified",
        itemIdentifiers: [
            "com.apple.finder.BACK",
            "NSToolbarFlexibleSpaceItem",
            "com.apple.finder.SWCH",
            "com.apple.finder.ARNG",
            "com.apple.finder.ACTN",
            "com.apple.finder.SHAR",
            "com.apple.finder.LABL",
            "NSToolbarFlexibleSpaceItem",
            "NSToolbarFlexibleSpaceItem",
            "com.apple.finder.SRCH"
        ],
        defaultIdentifiers: [
            "com.apple.finder.BACK",
            "NSToolbarFlexibleSpaceItem",
            "com.apple.finder.SWCH",
            "com.apple.finder.ARNG",
            "com.apple.finder.ACTN",
            "com.apple.finder.SHAR",
            "com.apple.finder.LABL",
            "NSToolbarFlexibleSpaceItem",
            "NSToolbarFlexibleSpaceItem",
            "com.apple.finder.SRCH"
        ],
        trailingReservedItemCount: 2,
        verified: false,
        environment: nil
    )

    public static let finder146Verified = CandidateProfile(
        name: "finder-14.6-23G80-verified",
        itemIdentifiers: [
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
            "com.apple.finder.SRCH"
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
            "com.apple.finder.SRCH"
        ],
        trailingReservedItemCount: 2,
        verified: true,
        environment: .macOS146Finder146
    )
}

public enum PlanStatus: String, Codable {
    case blocked
    case candidateBlocked = "candidate_blocked"
    case candidateForReview = "candidate_for_review"
    case alreadyPresent = "already_present"
}

public enum IssueSeverity: String, Codable {
    case warning
    case blocker
}

public struct PlanningIssue: Codable, Equatable {
    public let code: String
    public let message: String
    public let severity: IssueSeverity

    public init(code: String, message: String, severity: IssueSeverity = .blocker) {
        self.code = code
        self.message = message
        self.severity = severity
    }
}

public struct ToolbarPlan {
    public let status: PlanStatus
    public let originalConfiguration: [String: Any]
    public let candidateConfiguration: [String: Any]?
    public let issues: [PlanningIssue]
    public let changes: [String]
    public let insertionIndex: Int?

    public init(
        status: PlanStatus,
        originalConfiguration: [String: Any],
        candidateConfiguration: [String: Any]?,
        issues: [PlanningIssue],
        changes: [String],
        insertionIndex: Int?
    ) {
        self.status = status
        self.originalConfiguration = originalConfiguration
        self.candidateConfiguration = candidateConfiguration
        self.issues = issues
        self.changes = changes
        self.insertionIndex = insertionIndex
    }
}

public enum ToolbarPlanner {
    public static func planInstall(
        configuration: [String: Any],
        configurationWasPresent: Bool,
        launcherURL: URL,
        profile: CandidateProfile?,
        environment: CandidateEnvironment? = nil
    ) -> ToolbarPlan {
        let identifiersValue = configuration[ToolbarPreference.itemIdentifiersKey]
        let itemPlistsValue = configuration[ToolbarPreference.itemPlistsKey]

        if (identifiersValue == nil) != (itemPlistsValue == nil) {
            return blocked(
                configuration,
                code: "partial_item_structure",
                message: "Only one of TB Item Identifiers and TB Item Plists is present."
            )
        }

        var identifiers: [String]
        var itemPlists: [String: Any]
        var materializesImplicitDefault = false

        if identifiersValue == nil {
            guard let profile else {
                return blocked(
                    configuration,
                    code: "implicit_default_order",
                    message: "Finder has no explicit item arrays and no candidate profile was selected."
                )
            }

            identifiers = profile.itemIdentifiers
            itemPlists = [:]
            materializesImplicitDefault = true
        } else {
            guard let parsedIdentifiers = identifiersValue as? [String],
                  let parsedItemPlists = dictionary(itemPlistsValue) else {
                return blocked(
                    configuration,
                    code: "invalid_item_structure",
                    message: "Finder item identifiers or item plists have an unexpected type."
                )
            }

            identifiers = parsedIdentifiers
            itemPlists = parsedItemPlists
        }

        guard let profile else {
            return blocked(
                configuration,
                code: "missing_placement_profile",
                message: "No reviewed insertion rule is available for this Finder configuration."
            )
        }

        if let expectedEnvironment = profile.environment,
           environment != expectedEnvironment {
            return blocked(
                configuration,
                code: "candidate_profile_environment_mismatch",
                message: "The selected candidate profile is not verified for this macOS and Finder build."
            )
        }

        if let defaultValue = configuration[ToolbarPreference.defaultItemIdentifiersKey] {
            guard let defaults = defaultValue as? [String] else {
                return blocked(
                    configuration,
                    code: "invalid_default_identifiers",
                    message: "TB Default Item Identifiers has an unexpected type."
                )
            }

            if materializesImplicitDefault && defaults != profile.defaultIdentifiers {
                return blocked(
                    configuration,
                    code: "default_profile_mismatch",
                    message: "The stored default identifiers do not match the selected candidate profile."
                )
            }
        }

        guard validateItemPlistIndexes(itemPlists, identifierCount: identifiers.count) else {
            return blocked(
                configuration,
                code: "invalid_item_plist_indexes",
                message: "TB Item Plists contains a non-canonical or out-of-range index."
            )
        }

        let launcherString = launcherURL.standardizedFileURL.absoluteString
        let launcherURLIndexes = identifiers.indices.filter { index in
            guard identifiers[index] == ToolbarPreference.customItemIdentifier,
                  let item = dictionary(itemPlists[String(index)]),
                  let storedURLString = item["_CFURLString"] as? String,
                  let storedURL = URL(string: storedURLString) else {
                return false
            }
            return storedURL.standardizedFileURL == launcherURL.standardizedFileURL
        }

        if launcherURLIndexes.count > 1 {
            return blocked(
                configuration,
                code: "duplicate_launcher_entries",
                message: "More than one toolbar item already points to the requested launcher."
            )
        }

        if launcherURLIndexes.count == 1 {
            let index = launcherURLIndexes[0]
            guard let item = dictionary(itemPlists[String(index)]),
                  let storedType = item["_CFURLStringType"] as? NSNumber,
                  storedType.intValue == 15 else {
                return blocked(
                    configuration,
                    code: "invalid_launcher_url_type",
                    message: "The existing launcher entry has an unexpected file URL type."
                )
            }
            return ToolbarPlan(
                status: .alreadyPresent,
                originalConfiguration: configuration,
                candidateConfiguration: nil,
                issues: [],
                changes: [],
                insertionIndex: index
            )
        }

        let insertionIndex = max(identifiers.count - profile.trailingReservedItemCount, 0)
        var shiftedItemPlists: [String: Any] = [:]

        for (key, value) in itemPlists {
            let index = Int(key)!
            shiftedItemPlists[String(index >= insertionIndex ? index + 1 : index)] = value
        }

        identifiers.insert(ToolbarPreference.customItemIdentifier, at: insertionIndex)
        shiftedItemPlists[String(insertionIndex)] = [
            "_CFURLString": launcherString,
            "_CFURLStringType": 15
        ]

        var candidate = configuration
        candidate[ToolbarPreference.itemIdentifiersKey] = identifiers
        candidate[ToolbarPreference.itemPlistsKey] = shiftedItemPlists

        if materializesImplicitDefault && candidate[ToolbarPreference.defaultItemIdentifiersKey] == nil {
            candidate[ToolbarPreference.defaultItemIdentifiersKey] = profile.defaultIdentifiers
        }

        var issues: [PlanningIssue] = [
            PlanningIssue(
                code: "private_finder_schema",
                message: "The candidate uses an undocumented Finder preference structure.",
                severity: .warning
            )
        ]

        if !profile.verified {
            issues.append(
                PlanningIssue(
                code: "unverified_candidate_profile",
                message: "The selected default and placement rules are not verified for this Finder version."
                )
            )
        }

        var changes: [String] = []
        if materializesImplicitDefault {
            if configurationWasPresent {
                changes.append("Materialize missing item arrays in the existing toolbar configuration from candidate profile \(profile.name).")
            } else {
                changes.append("Materialize Finder's implicit item order from candidate profile \(profile.name).")
            }
            changes.append("Add TB Default Item Identifiers with \(profile.defaultIdentifiers.count) identifiers.")
        }
        changes.append("Insert \(ToolbarPreference.customItemIdentifier.debugDescription) at toolbar index \(insertionIndex).")
        changes.append("Add the launcher file URL at TB Item Plists index \(insertionIndex).")

        return ToolbarPlan(
            status: issues.contains(where: { $0.severity == .blocker }) ? .candidateBlocked : .candidateForReview,
            originalConfiguration: configuration,
            candidateConfiguration: candidate,
            issues: issues,
            changes: changes,
            insertionIndex: insertionIndex
        )
    }

    public static func blocked(
        configuration: [String: Any],
        issues: [PlanningIssue]
    ) -> ToolbarPlan {
        ToolbarPlan(
            status: .blocked,
            originalConfiguration: configuration,
            candidateConfiguration: nil,
            issues: issues,
            changes: [],
            insertionIndex: nil
        )
    }

    private static func blocked(
        _ configuration: [String: Any],
        code: String,
        message: String
    ) -> ToolbarPlan {
        blocked(
            configuration: configuration,
            issues: [PlanningIssue(code: code, message: message)]
        )
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] {
            return value
        }

        guard let value = value as? NSDictionary else {
            return nil
        }

        var result: [String: Any] = [:]
        for (key, item) in value {
            guard let key = key as? String else {
                return nil
            }
            result[key] = item
        }
        return result
    }

    private static func validateItemPlistIndexes(
        _ itemPlists: [String: Any],
        identifierCount: Int
    ) -> Bool {
        itemPlists.keys.allSatisfy { key in
            guard let index = Int(key),
                  String(index) == key else {
                return false
            }
            return index >= 0 && index < identifierCount
        }
    }
}
