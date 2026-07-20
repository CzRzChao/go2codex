import Foundation
import Testing
@testable import Go2CodexCore

@Suite
struct FinderToolbarPlatformPolicyTests {
    @Test
    func bundleIdentifierPairsAreClosedAndVariantSpecific() {
        #expect(
            FinderToolbarPlatformPolicy.applicationVariant(
                outerBundleIdentifier: "io.github.czrzchao.go2codex",
                launcherBundleIdentifier: "io.github.czrzchao.go2codex.launcher"
            ) == .release
        )
        #expect(
            FinderToolbarPlatformPolicy.applicationVariant(
                outerBundleIdentifier: "io.github.czrzchao.go2codex.debug",
                launcherBundleIdentifier: "io.github.czrzchao.go2codex.debug.launcher"
            ) == .debug
        )
        #expect(
            FinderToolbarPlatformPolicy.applicationVariant(
                outerBundleIdentifier: "io.github.czrzchao.go2codex",
                launcherBundleIdentifier: "io.github.czrzchao.go2codex.debug.launcher"
            ) == nil
        )
        #expect(
            FinderToolbarPlatformPolicy.applicationVariant(
                outerBundleIdentifier: "io.github.czrzchao.other",
                launcherBundleIdentifier: "io.github.czrzchao.go2codex.launcher"
            ) == nil
        )
    }

    @Test
    func releaseRequiresAnExactApplicationsParentWhileDebugIsExempt() {
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let userApplications = URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true)
        let eligibleURLs = [
            systemApplications.appendingPathComponent("Go2Codex.app", isDirectory: true),
            userApplications.appendingPathComponent("Go2Codex.app", isDirectory: true),
        ]
        for url in eligibleURLs {
            #expect(
                FinderToolbarPlatformPolicy.isStableLocationEligible(
                    outerURL: url,
                    systemApplicationsURL: systemApplications,
                    userApplicationsURL: userApplications,
                    variant: .release
                )
            )
        }

        let ineligible = [
            URL(fileURLWithPath: "/Downloads/Go2Codex.app", isDirectory: true),
            systemApplications
                .appendingPathComponent("Tools", isDirectory: true)
                .appendingPathComponent("Go2Codex.app", isDirectory: true),
            URL(fileURLWithPath: "/Users/other/Applications/Go2Codex.app", isDirectory: true),
        ]
        for url in ineligible {
            #expect(
                !FinderToolbarPlatformPolicy.isStableLocationEligible(
                    outerURL: url,
                    systemApplicationsURL: systemApplications,
                    userApplicationsURL: userApplications,
                    variant: .release
                )
            )
            #expect(
                FinderToolbarPlatformPolicy.isStableLocationEligible(
                    outerURL: url,
                    systemApplicationsURL: systemApplications,
                    userApplicationsURL: userApplications,
                    variant: .debug
                )
            )
        }
    }

    @Test
    func executableContainmentRequiresTheDirectMacOSDirectory() {
        let bundle = URL(fileURLWithPath: "/Applications/Go2Codex.app", isDirectory: true)
        #expect(
            FinderToolbarPlatformPolicy.executableIsDirectlyContained(
                bundle.appendingPathComponent("Contents/MacOS/Go2Codex"),
                in: bundle
            )
        )
        #expect(
            !FinderToolbarPlatformPolicy.executableIsDirectlyContained(
                bundle.appendingPathComponent("Contents/Helpers/Go2Codex"),
                in: bundle
            )
        )
        #expect(
            !FinderToolbarPlatformPolicy.executableIsDirectlyContained(
                URL(fileURLWithPath: "/Applications/Other.app/Contents/MacOS/Go2Codex"),
                in: bundle
            )
        )
    }

    @Test
    func onlyAThinLittleEndianArm64MachOHeaderIsAccepted() {
        let valid = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01])
        #expect(FinderToolbarPlatformPolicy.isThinArm64MachO(header: valid))
        #expect(!FinderToolbarPlatformPolicy.isThinArm64MachO(header: Data(valid.dropLast())))
        #expect(
            !FinderToolbarPlatformPolicy.isThinArm64MachO(
                header: Data([0xCA, 0xFE, 0xBA, 0xBE, 0x0C, 0x00, 0x00, 0x01])
            )
        )
        #expect(
            !FinderToolbarPlatformPolicy.isThinArm64MachO(
                header: Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01])
            )
        )
        #expect(
            !FinderToolbarPlatformPolicy.isThinArm64MachO(
                header: Data([0xFE, 0xED, 0xFA, 0xCF, 0x01, 0x00, 0x00, 0x0C])
            )
        )
    }

    @Test
    func signingRelationshipRequiresBothCleanAdHocOrTheSameTeamAndCertificate() {
        let adHoc = FinderToolbarSigningRelationshipEvidence(
            teamIdentifier: nil,
            leafCertificate: nil,
            isAdHoc: true
        )
        let signed = FinderToolbarSigningRelationshipEvidence(
            teamIdentifier: "TEAM",
            leafCertificate: Data([1, 2, 3]),
            isAdHoc: false
        )
        #expect(FinderToolbarPlatformPolicy.signingRelationshipIsValid(outer: adHoc, launcher: adHoc))
        #expect(!FinderToolbarPlatformPolicy.signingRelationshipIsValid(outer: adHoc, launcher: signed))
        #expect(FinderToolbarPlatformPolicy.signingRelationshipIsValid(outer: signed, launcher: signed))
        #expect(
            !FinderToolbarPlatformPolicy.signingRelationshipIsValid(
                outer: signed,
                launcher: FinderToolbarSigningRelationshipEvidence(
                    teamIdentifier: "OTHER",
                    leafCertificate: Data([1, 2, 3]),
                    isAdHoc: false
                )
            )
        )
        #expect(
            !FinderToolbarPlatformPolicy.signingRelationshipIsValid(
                outer: signed,
                launcher: FinderToolbarSigningRelationshipEvidence(
                    teamIdentifier: "TEAM",
                    leafCertificate: Data([9]),
                    isAdHoc: false
                )
            )
        )
        #expect(
            !FinderToolbarPlatformPolicy.signingRelationshipIsValid(
                outer: adHoc,
                launcher: FinderToolbarSigningRelationshipEvidence(
                    teamIdentifier: "TEAM",
                    leafCertificate: nil,
                    isAdHoc: true
                )
            )
        )
        #expect(
            !FinderToolbarPlatformPolicy.signingRelationshipIsValid(
                outer: adHoc,
                launcher: FinderToolbarSigningRelationshipEvidence(
                    teamIdentifier: nil,
                    leafCertificate: Data([1]),
                    isAdHoc: true
                )
            )
        )
        #expect(
            !FinderToolbarPlatformPolicy.signingRelationshipIsValid(
                outer: signed,
                launcher: FinderToolbarSigningRelationshipEvidence(
                    teamIdentifier: nil,
                    leafCertificate: nil,
                    isAdHoc: false
                )
            )
        )
    }

    @Test
    func liveDiskLiveConvergenceRejectsEveryMismatchPosition() {
        let first = FinderToolbarSnapshot(configurationWasPresent: true, fields: ["value": .integer(1)])
        let second = FinderToolbarSnapshot(configurationWasPresent: true, fields: ["value": .integer(2)])
        #expect(FinderToolbarPlatformPolicy.snapshotsConverge(firstLive: first, disk: first, secondLive: first))
        #expect(!FinderToolbarPlatformPolicy.snapshotsConverge(firstLive: second, disk: first, secondLive: first))
        #expect(!FinderToolbarPlatformPolicy.snapshotsConverge(firstLive: first, disk: second, secondLive: first))
        #expect(!FinderToolbarPlatformPolicy.snapshotsConverge(firstLive: first, disk: first, secondLive: second))
    }
}
