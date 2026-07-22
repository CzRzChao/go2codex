import Foundation

public enum FinderToolbarApplicationVariant: Codable, Equatable, Sendable {
    case release
    case debug
}

public struct FinderToolbarSigningRelationshipEvidence: Equatable, Sendable {
    public let teamIdentifier: String?
    public let leafCertificate: Data?
    public let isAdHoc: Bool

    public init(
        teamIdentifier: String?,
        leafCertificate: Data?,
        isAdHoc: Bool
    ) {
        self.teamIdentifier = teamIdentifier
        self.leafCertificate = leafCertificate
        self.isAdHoc = isAdHoc
    }
}

public enum FinderToolbarPlatformPolicy {
    public static func applicationVariant(
        outerBundleIdentifier: String
    ) -> FinderToolbarApplicationVariant? {
        switch outerBundleIdentifier {
        case "io.github.czrzchao.go2codex":
            .release
        case "io.github.czrzchao.go2codex.debug":
            .debug
        default:
            nil
        }
    }

    public static func applicationVariant(
        outerBundleIdentifier: String,
        launcherBundleIdentifier: String
    ) -> FinderToolbarApplicationVariant? {
        guard launcherBundleIdentifier == "\(outerBundleIdentifier).launcher" else {
            return nil
        }
        return applicationVariant(outerBundleIdentifier: outerBundleIdentifier)
    }

    public static func isStableLocationEligible(
        outerURL: URL,
        systemApplicationsURL: URL,
        userApplicationsURL: URL,
        variant: FinderToolbarApplicationVariant
    ) -> Bool {
        if variant == .debug {
            return true
        }
        let parent = outerURL.standardizedFileURL.deletingLastPathComponent()
        return parent == systemApplicationsURL.standardizedFileURL
            || parent == userApplicationsURL.standardizedFileURL
    }

    public static func executableIsDirectlyContained(
        _ executableURL: URL,
        in bundleURL: URL
    ) -> Bool {
        let expectedDirectory = bundleURL.standardizedFileURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .standardizedFileURL
        return executableURL.standardizedFileURL
            .deletingLastPathComponent()
            .standardizedFileURL == expectedDirectory
    }

    public static func isThinArm64MachO(header: Data) -> Bool {
        guard header.count == 8 else {
            return false
        }
        let bytes = [UInt8](header)
        let magic = UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
        let cpuType = UInt32(bytes[4])
            | UInt32(bytes[5]) << 8
            | UInt32(bytes[6]) << 16
            | UInt32(bytes[7]) << 24
        return magic == 0xFEED_FACF && cpuType == 0x0100_000C
    }

    public static func signingRelationshipIsValid(
        outer: FinderToolbarSigningRelationshipEvidence,
        launcher: FinderToolbarSigningRelationshipEvidence
    ) -> Bool {
        if outer.isAdHoc || launcher.isAdHoc {
            return outer.isAdHoc
                && launcher.isAdHoc
                && outer.teamIdentifier == nil
                && launcher.teamIdentifier == nil
                && outer.leafCertificate == nil
                && launcher.leafCertificate == nil
        }
        guard let outerTeam = outer.teamIdentifier,
              let launcherTeam = launcher.teamIdentifier,
              let outerCertificate = outer.leafCertificate,
              let launcherCertificate = launcher.leafCertificate else {
            return false
        }
        return outerTeam == launcherTeam && outerCertificate == launcherCertificate
    }

    public static func snapshotsConverge(
        firstLive: FinderToolbarSnapshot,
        disk: FinderToolbarSnapshot,
        secondLive: FinderToolbarSnapshot
    ) -> Bool {
        firstLive == disk && disk == secondLive
    }
}
