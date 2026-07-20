import CoreFoundation
import CryptoKit
import FinderToolbarDryRunCore
import Foundation

private struct Options {
    let sourceURL: URL
    let usesDefaultSource: Bool
    let launcherURL: URL
    let outputURL: URL
    let profile: CandidateProfile?
}

private struct Report: Codable {
    let schemaVersion: Int
    let mode: String
    let generatedAt: String
    let macOSVersion: String
    let macOSBuild: String?
    let finderVersion: String?
    let finderBundleVersion: String?
    let preferenceDomain: String
    let preferenceKey: String
    let sourcePath: String
    let sourceMatchesLivePreferences: Bool?
    let toolbarConfigurationWasPresent: Bool
    let launcherURL: String
    let launcherExists: Bool
    let candidateProfile: String?
    let status: PlanStatus
    let writeEligible: Bool
    let insertionIndex: Int?
    let issues: [PlanningIssue]
    let changes: [String]
    let recoverySHA256: String
    let artifacts: [String: String]
}

private enum DryRunError: LocalizedError {
    case usage(String)
    case invalidPlist(String)
    case outputNotEmpty(String)
    case artifactFailure(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message),
             .invalidPlist(let message),
             .outputNotEmpty(let message),
             .artifactFailure(let message):
            return message
        }
    }
}

private let help = """
Usage:
  finder-toolbar-dry-run --launcher <app-path> --output <directory> [options]

Options:
  --source <plist>             Read a fixture instead of the current Finder plist.
  --candidate-profile <name>   Supported: go2shell-v2.5-modern-unverified,
                               finder-14.6-23G80-verified
  --help                       Show this help.

This program never writes Finder preferences or restarts Finder.
"""

private func expandedURL(_ path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded).standardizedFileURL
}

private func parseOptions() throws -> Options {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") {
        print(help)
        exit(0)
    }

    var sourcePath: String?
    var launcherPath: String?
    var outputPath: String?
    var profile: CandidateProfile?
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        guard index + 1 < arguments.count else {
            throw DryRunError.usage("Missing value for \(argument).\n\n\(help)")
        }
        let value = arguments[index + 1]

        switch argument {
        case "--source":
            sourcePath = value
        case "--launcher":
            launcherPath = value
        case "--output":
            outputPath = value
        case "--candidate-profile":
            switch value {
            case CandidateProfile.go2ShellV25ModernUnverified.name:
                profile = .go2ShellV25ModernUnverified
            case CandidateProfile.finder146Verified.name:
                profile = .finder146Verified
            default:
                throw DryRunError.usage("Unknown candidate profile: \(value)")
            }
        default:
            throw DryRunError.usage("Unknown option: \(argument)\n\n\(help)")
        }
        index += 2
    }

    guard let launcherPath else {
        throw DryRunError.usage("--launcher is required.\n\n\(help)")
    }
    guard let outputPath else {
        throw DryRunError.usage("--output is required.\n\n\(help)")
    }

    let defaultSource = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.finder.plist")

    return Options(
        sourceURL: sourcePath.map(expandedURL) ?? defaultSource,
        usesDefaultSource: sourcePath == nil,
        launcherURL: expandedURL(launcherPath),
        outputURL: expandedURL(outputPath),
        profile: profile
    )
}

private func loadTopLevelPlist(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let dictionary = value as? [String: Any] else {
        throw DryRunError.invalidPlist("The source plist is not a string-keyed dictionary: \(url.path)")
    }
    return dictionary
}

private func toolbarDictionary(_ value: Any?) throws -> [String: Any]? {
    guard let value else {
        return nil
    }
    if let dictionary = value as? [String: Any] {
        return dictionary
    }
    if let dictionary = value as? NSDictionary {
        var result: [String: Any] = [:]
        for (key, item) in dictionary {
            guard let key = key as? String else {
                throw DryRunError.invalidPlist("The toolbar dictionary contains a non-string key.")
            }
            result[key] = item
        }
        return result
    }
    throw DryRunError.invalidPlist("The Finder toolbar preference is not a dictionary.")
}

private func liveToolbarDictionary() throws -> [String: Any]? {
    let value = CFPreferencesCopyAppValue(
        ToolbarPreference.configurationKey as CFString,
        ToolbarPreference.domain as CFString
    )
    return try toolbarDictionary(value)
}

private func propertyListsEqual(_ lhs: [String: Any]?, _ rhs: [String: Any]?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (lhs?, rhs?):
        return NSDictionary(dictionary: lhs).isEqual(to: rhs)
    default:
        return false
    }
}

private func xmlPlistData(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func prepareOutputDirectory(_ url: URL) throws {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw DryRunError.outputNotEmpty("Output path exists and is not a directory: \(url.path)")
        }
        let contents = try manager.contentsOfDirectory(atPath: url.path)
        guard contents.isEmpty else {
            throw DryRunError.outputNotEmpty("Output directory must be empty: \(url.path)")
        }
    } else {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private func unifiedDiff(original: URL, candidate: URL) throws -> Data {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
    process.arguments = ["-u", original.path, candidate.path]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
        throw DryRunError.artifactFailure("diff failed with status \(process.terminationStatus).")
    }
    return data
}

private func finderVersion() -> String? {
    Bundle(path: "/System/Library/CoreServices/Finder.app")?
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
}

private func finderBundleVersion() -> String? {
    Bundle(path: "/System/Library/CoreServices/Finder.app")?
        .object(forInfoDictionaryKey: "CFBundleVersion") as? String
}

private func macOSBuild() -> String? {
    let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
    return (try? loadTopLevelPlist(url))?["ProductBuildVersion"] as? String
}

private func candidateEnvironment() -> CandidateEnvironment? {
    guard let macOSBuild = macOSBuild(),
          let finderVersion = finderVersion(),
          let finderBundleVersion = finderBundleVersion() else {
        return nil
    }
    return CandidateEnvironment(
        macOSBuild: macOSBuild,
        finderVersion: finderVersion,
        finderBundleVersion: finderBundleVersion
    )
}

do {
    let options = try parseOptions()
    let topLevel = try loadTopLevelPlist(options.sourceURL)
    let diskToolbar = try toolbarDictionary(topLevel[ToolbarPreference.configurationKey])
    let configurationWasPresent = diskToolbar != nil
    let environment = candidateEnvironment()
    let sourceMatchesLive: Bool?
    var plan: ToolbarPlan

    if options.usesDefaultSource {
        let liveToolbar = try liveToolbarDictionary()
        sourceMatchesLive = propertyListsEqual(diskToolbar, liveToolbar)
        if sourceMatchesLive == false {
            plan = ToolbarPlanner.blocked(
                configuration: diskToolbar ?? [:],
                issues: [
                    PlanningIssue(
                        code: "disk_live_preference_mismatch",
                        message: "The Finder plist and live CFPreferences toolbar values differ."
                    )
                ]
            )
        } else {
            plan = ToolbarPlanner.planInstall(
                configuration: diskToolbar ?? [:],
                configurationWasPresent: configurationWasPresent,
                launcherURL: options.launcherURL,
                profile: options.profile,
                environment: environment
            )
        }
    } else {
        sourceMatchesLive = nil
        plan = ToolbarPlanner.planInstall(
            configuration: diskToolbar ?? [:],
            configurationWasPresent: configurationWasPresent,
            launcherURL: options.launcherURL,
            profile: options.profile,
            environment: environment
        )
    }

    var issues = plan.issues
    let launcherExists = FileManager.default.fileExists(atPath: options.launcherURL.path)
    if !launcherExists {
        issues.append(
            PlanningIssue(
                code: "launcher_missing",
                message: "The requested launcher path does not exist; the URL is illustrative only."
            )
        )
    }

    try prepareOutputDirectory(options.outputURL)
    let recoveryURL = options.outputURL.appendingPathComponent("recovery-toolbar.plist")
    let candidateURL = options.outputURL.appendingPathComponent("candidate-toolbar.plist")
    let diffURL = options.outputURL.appendingPathComponent("candidate.diff")
    let reportURL = options.outputURL.appendingPathComponent("report.json")
    let recoveryData = try xmlPlistData(plan.originalConfiguration)
    try recoveryData.write(to: recoveryURL, options: .atomic)

    var artifacts = ["recovery": recoveryURL.lastPathComponent]
    if let candidate = plan.candidateConfiguration {
        let candidateData = try xmlPlistData(candidate)
        try candidateData.write(to: candidateURL, options: .atomic)
        try unifiedDiff(original: recoveryURL, candidate: candidateURL)
            .write(to: diffURL, options: .atomic)
        artifacts["candidate"] = candidateURL.lastPathComponent
        artifacts["diff"] = diffURL.lastPathComponent
    }

    let reportedStatus: PlanStatus
    if issues.contains(where: { $0.severity == .blocker }) {
        reportedStatus = plan.candidateConfiguration == nil ? .blocked : .candidateBlocked
    } else {
        reportedStatus = plan.status
    }

    let report = Report(
        schemaVersion: 2,
        mode: "read-only",
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        macOSBuild: environment?.macOSBuild,
        finderVersion: finderVersion(),
        finderBundleVersion: finderBundleVersion(),
        preferenceDomain: ToolbarPreference.domain,
        preferenceKey: ToolbarPreference.configurationKey,
        sourcePath: options.sourceURL.path,
        sourceMatchesLivePreferences: sourceMatchesLive,
        toolbarConfigurationWasPresent: configurationWasPresent,
        launcherURL: options.launcherURL.absoluteString,
        launcherExists: launcherExists,
        candidateProfile: options.profile?.name,
        status: reportedStatus,
        writeEligible: false,
        insertionIndex: plan.insertionIndex,
        issues: issues,
        changes: plan.changes,
        recoverySHA256: sha256(recoveryData),
        artifacts: artifacts
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: reportURL, options: .atomic)

    print("Status: \(reportedStatus.rawValue)")
    print("Write eligible: false")
    print("Artifacts: \(options.outputURL.path)")
    if !issues.isEmpty {
        print("Issues:")
        for issue in issues {
            print("- [\(issue.severity.rawValue)] \(issue.code): \(issue.message)")
        }
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
