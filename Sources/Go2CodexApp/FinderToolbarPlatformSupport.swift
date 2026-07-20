import CoreFoundation
import Darwin
import Foundation
import Go2CodexCore

enum FinderToolbarAliasRecordResolver {
    static func resolve(
        _ value: FinderToolbarPropertyListValue?
    ) -> FinderToolbarAliasResolution {
        guard let value else {
            return .absent
        }
        guard case let .data(aliasRecord) = value, !aliasRecord.isEmpty else {
            return .invalid
        }
        guard let unmanagedBookmark = CFURLCreateBookmarkDataFromAliasRecord(
            kCFAllocatorDefault,
            aliasRecord as CFData
        ) else {
            return .unresolvable
        }
        let bookmark = unmanagedBookmark.takeRetainedValue() as Data

        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ),
        resolved.isFileURL,
        resolved.path.hasPrefix("/") else {
            return .unresolvable
        }
        return .resolved(resolved.standardizedFileURL)
    }
}

enum FinderToolbarPathInspection: Equatable, Sendable {
    case valid
    case nonFileURL
    case nonAbsolutePath
    case nonCanonicalPath
    case missingComponent
    case symbolicLink
}

enum FinderToolbarPathInspector {
    static func inspect(_ url: URL) -> FinderToolbarPathInspection {
        guard url.isFileURL else {
            return .nonFileURL
        }
        let rawPath = url.path
        guard rawPath.hasPrefix("/") else {
            return .nonAbsolutePath
        }
        var current = "/"
        for component in (rawPath as NSString).pathComponents.dropFirst() {
            guard component != ".", component != ".." else {
                return .nonCanonicalPath
            }
            current = (current as NSString).appendingPathComponent(component)
            var metadata = stat()
            let status = current.withCString { pointer in
                lstat(pointer, &metadata)
            }
            guard status == 0 else {
                return .missingComponent
            }
            if metadata.st_mode & S_IFMT == S_IFLNK {
                return .symbolicLink
            }
        }
        return .valid
    }
}
