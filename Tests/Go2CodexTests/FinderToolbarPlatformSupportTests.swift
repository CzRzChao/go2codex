import Foundation
import Go2CodexCore
import Testing

@Suite
struct FinderToolbarPlatformSupportTests {
    @Test
    func aliasRecordConversionSymbolIsAvailable() {
        #expect(FinderToolbarAliasRecordResolver.isAliasRecordConversionAvailable)
    }

    @Test
    func absentNonDataAndEmptyAliasValuesFailClosed() {
        #expect(FinderToolbarAliasRecordResolver.resolve(nil) == .absent)
        #expect(FinderToolbarAliasRecordResolver.resolve(.string("not-data")) == .invalid)
        #expect(FinderToolbarAliasRecordResolver.resolve(.data(Data())) == .invalid)
    }

    @Test
    func damagedAliasRecordsAreUnresolvable() {
        let aliasRecords = [
            Data([0]),
            Data([0, 0, 0, 0, 0, 64, 0, 2, 0, 0]),
            Data(repeating: 0, count: 512),
            Data((0..<257).map { UInt8(truncatingIfNeeded: $0 &* 73 &+ 19) }),
        ]
        for aliasRecord in aliasRecords {
            #expect(
                FinderToolbarAliasRecordResolver.resolve(.data(aliasRecord))
                    == .unresolvable
            )
        }
    }

    @Test
    func pathInspectionRejectsParentAndLeafSymlinksAndInvalidPaths() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("go2codex-platform-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let ordinaryDirectory = root.appendingPathComponent("ordinary", isDirectory: true)
        let ordinaryFile = ordinaryDirectory.appendingPathComponent("target", isDirectory: false)
        try fileManager.createDirectory(at: ordinaryDirectory, withIntermediateDirectories: true)
        try Data("target".utf8).write(to: ordinaryFile)

        #expect(FinderToolbarPathInspector.inspect(root) == .valid)
        #expect(FinderToolbarPathInspector.inspect(ordinaryDirectory) == .valid)
        #expect(FinderToolbarPathInspector.inspect(ordinaryFile) == .valid)

        let parentLink = root.appendingPathComponent("parent-link", isDirectory: true)
        try fileManager.createSymbolicLink(at: parentLink, withDestinationURL: ordinaryDirectory)
        #expect(
            FinderToolbarPathInspector.inspect(parentLink.appendingPathComponent("target"))
                == .symbolicLink
        )

        let leafLink = root.appendingPathComponent("leaf-link", isDirectory: false)
        try fileManager.createSymbolicLink(at: leafLink, withDestinationURL: ordinaryFile)
        #expect(FinderToolbarPathInspector.inspect(leafLink) == .symbolicLink)

        #expect(
            FinderToolbarPathInspector.inspect(root.appendingPathComponent("missing/target"))
                == .missingComponent
        )
        #expect(
            FinderToolbarPathInspector.inspect(URL(string: "file:relative/path")!)
                == .nonAbsolutePath
        )
        #expect(
            FinderToolbarPathInspector.inspect(URL(string: "file:///private/tmp/../target")!)
                == .nonCanonicalPath
        )
        #expect(
            FinderToolbarPathInspector.inspect(URL(string: "https://example.com/path")!)
                == .nonFileURL
        )
    }
}
