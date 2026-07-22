import FinderToolbarDryRunCore
import Foundation

private struct TestFailure: Error {
    let message: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure(message: message)
    }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw TestFailure(message: message)
    }
    return value
}

private let launcherURL = URL(
    fileURLWithPath: "/Applications/Go2Codex.app/Contents/Helpers/Go2CodexLauncher.app"
)

private let tests: [(String, () throws -> Void)] = [
    ("blocks implicit defaults without a profile", {
        let plan = ToolbarPlanner.planInstall(
            configuration: ["TB Display Mode": 2],
            configurationWasPresent: true,
            launcherURL: launcherURL,
            profile: nil
        )
        try expect(plan.status == .blocked, "expected blocked status")
        try expect(plan.candidateConfiguration == nil, "expected no candidate")
        try expect(plan.issues.map(\.code) == ["implicit_default_order"], "unexpected blocker")
    }),
    ("builds a blocked legacy candidate", {
        let profile = CandidateProfile.go2ShellV25ModernUnverified
        let plan = ToolbarPlanner.planInstall(
            configuration: ["TB Display Mode": 2],
            configurationWasPresent: true,
            launcherURL: launcherURL,
            profile: profile,
            environment: .macOS146Finder146
        )
        try expect(plan.status == .candidateBlocked, "expected candidate_blocked status")
        try expect(plan.insertionIndex == 8, "expected insertion index 8")
        try expect(
            plan.issues.map(\.code) == ["private_finder_schema", "unverified_candidate_profile"],
            "unexpected candidate blockers"
        )
        try expect(plan.issues.map(\.severity) == [.warning, .blocker], "unexpected issue severity")

        let candidate = try require(plan.candidateConfiguration, "candidate is missing")
        let identifiers = try require(
            candidate[ToolbarPreference.itemIdentifiersKey] as? [String],
            "identifiers are missing"
        )
        try expect(identifiers.count == 11, "expected 11 identifiers")
        try expect(identifiers[8] == ToolbarPreference.customItemIdentifier, "custom item is misplaced")
        try expect(
            candidate[ToolbarPreference.defaultItemIdentifiersKey] as? [String] == profile.defaultIdentifiers,
            "default identifiers differ"
        )

        let itemPlists = try require(
            candidate[ToolbarPreference.itemPlistsKey] as? [String: Any],
            "item plists are missing"
        )
        let launcher = try require(itemPlists["8"] as? [String: Any], "launcher plist is missing")
        try expect(launcher["_CFURLString"] as? String == launcherURL.absoluteString, "launcher URL differs")
        try expect(launcher["_CFURLStringType"] as? Int == 15, "launcher URL type differs")
    }),
    ("blocks a verified profile on another build", {
        let environment = CandidateEnvironment(
            macOSBuild: "different",
            finderVersion: "14.6",
            finderBundleVersion: "1632.6.3"
        )
        let plan = ToolbarPlanner.planInstall(
            configuration: ["TB Display Mode": 2],
            configurationWasPresent: true,
            launcherURL: launcherURL,
            profile: .finder146Verified,
            environment: environment
        )
        try expect(plan.status == .blocked, "expected blocked status")
        try expect(
            plan.issues.map(\.code) == ["candidate_profile_environment_mismatch"],
            "unexpected environment blocker"
        )
    }),
    ("builds a reviewable verified Finder 14.6 candidate", {
        let profile = CandidateProfile.finder146Verified
        let plan = ToolbarPlanner.planInstall(
            configuration: ["TB Display Mode": 2],
            configurationWasPresent: true,
            launcherURL: launcherURL,
            profile: profile,
            environment: .macOS146Finder146
        )
        try expect(plan.status == .candidateForReview, "expected candidate_for_review status")
        try expect(plan.insertionIndex == 10, "expected insertion index 10")
        try expect(plan.issues.map(\.code) == ["private_finder_schema"], "unexpected verified-profile issues")

        let candidate = try require(plan.candidateConfiguration, "candidate is missing")
        let identifiers = try require(
            candidate[ToolbarPreference.itemIdentifiersKey] as? [String],
            "identifiers are missing"
        )
        try expect(identifiers.count == 13, "expected 13 identifiers")
        try expect(identifiers[10] == ToolbarPreference.customItemIdentifier, "custom item is misplaced")
        try expect(
            candidate[ToolbarPreference.defaultItemIdentifiersKey] as? [String] == profile.defaultIdentifiers,
            "default identifiers differ"
        )

        let itemPlists = try require(
            candidate[ToolbarPreference.itemPlistsKey] as? [String: Any],
            "item plists are missing"
        )
        let launcher = try require(itemPlists["10"] as? [String: Any], "launcher plist is missing")
        try expect(launcher["_CFURLString"] as? String == launcherURL.absoluteString, "launcher URL differs")
        try expect(launcher["_CFURLStringType"] as? Int == 15, "launcher URL type differs")
    }),
    ("shifts an existing indexed item", {
        let configuration: [String: Any] = [
            ToolbarPreference.itemIdentifiersKey: ["0", "1", "2", "3", "4"],
            ToolbarPreference.itemPlistsKey: ["3": ["value": "existing"]]
        ]
        let plan = ToolbarPlanner.planInstall(
            configuration: configuration,
            configurationWasPresent: true,
            launcherURL: launcherURL,
            profile: .go2ShellV25ModernUnverified
        )
        try expect(plan.insertionIndex == 3, "expected insertion index 3")
        let candidate = try require(plan.candidateConfiguration, "candidate is missing")
        let itemPlists = try require(
            candidate[ToolbarPreference.itemPlistsKey] as? [String: Any],
            "item plists are missing"
        )
        try expect(itemPlists["3"] != nil, "new item is missing")
        try expect(
            (itemPlists["4"] as? [String: String])?["value"] == "existing",
            "existing item was not shifted"
        )
    }),
    ("blocks a partial item structure", {
        let plan = ToolbarPlanner.planInstall(
            configuration: [ToolbarPreference.itemIdentifiersKey: ["one"]],
            configurationWasPresent: true,
            launcherURL: launcherURL,
            profile: .go2ShellV25ModernUnverified
        )
        try expect(plan.status == .blocked, "expected blocked status")
        try expect(plan.issues.map(\.code) == ["partial_item_structure"], "unexpected blocker")
    }),
    ("recognizes an existing launcher", {
        let configuration: [String: Any] = [
            ToolbarPreference.itemIdentifiersKey: [ToolbarPreference.customItemIdentifier, "tail-a", "tail-b"],
            ToolbarPreference.itemPlistsKey: [
                "0": [
                    "_CFURLString": launcherURL.absoluteString,
                    "_CFURLStringType": 15
                ]
            ]
        ]
        let plan = ToolbarPlanner.planInstall(
            configuration: configuration,
            configurationWasPresent: true,
            launcherURL: launcherURL,
            profile: .go2ShellV25ModernUnverified
        )
        try expect(plan.status == .alreadyPresent, "expected already_present status")
        try expect(plan.insertionIndex == 0, "expected existing index 0")
        try expect(plan.candidateConfiguration == nil, "expected no candidate")
    }),
    ("blocks an existing launcher with the wrong URL type", {
        let configuration: [String: Any] = [
            ToolbarPreference.itemIdentifiersKey: [ToolbarPreference.customItemIdentifier, "tail-a", "tail-b"],
            ToolbarPreference.itemPlistsKey: [
                "0": [
                    "_CFURLString": launcherURL.absoluteString,
                    "_CFURLStringType": 14
                ]
            ]
        ]
        let plan = ToolbarPlanner.planInstall(
            configuration: configuration,
            configurationWasPresent: true,
            launcherURL: launcherURL,
            profile: .go2ShellV25ModernUnverified
        )
        try expect(plan.status == .blocked, "expected blocked status")
        try expect(plan.issues.map(\.code) == ["invalid_launcher_url_type"], "unexpected URL type blocker")
    })
]

var failureCount = 0
for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch let failure as TestFailure {
        failureCount += 1
        print("FAIL \(name): \(failure.message)")
    } catch {
        failureCount += 1
        print("FAIL \(name): \(error.localizedDescription)")
    }
}

if failureCount > 0 {
    print("\(failureCount) self-test(s) failed")
    exit(1)
}

print("All \(tests.count) self-tests passed")
