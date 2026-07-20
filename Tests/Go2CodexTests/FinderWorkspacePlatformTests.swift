import AppKit
import Foundation
import Go2CodexCore
import Testing

@Suite("Production Finder workspace platform")
@MainActor
struct FinderWorkspacePlatformTests {
    @Test
    func sendsOneExactFinderRequestAndBuildsWorkspace() throws {
        let sender = FinderWorkspaceEventSenderStub()
        sender.reply = workspaceReply(
            text: "file:///Users/example/Project%20With%20Space"
        )
        let inspector = FinderWorkspaceResourceInspectorStub()
        let resolver = FinderWorkspaceResolver(
            eventSender: sender,
            resourceInspector: inspector
        )

        let workspace = try resolver.resolveFrontmostWorkspace()

        #expect(workspace.path == "/Users/example/Project With Space")
        #expect(sender.events.count == 1)
        let event = try #require(sender.events.first)
        #expect(event.eventClass == workspaceCode("core"))
        #expect(event.eventID == workspaceCode("getd"))
        #expect(targetBundleIdentifier(of: event) == "com.apple.finder")
        #expect(event.paramDescriptor(
            forKeyword: workspaceCode("----")
        )?.descriptorType == workspaceCode("obj "))
        #expect(inspector.inspectedURLs.map(\.path) == [
            "/Users/example/Project With Space",
        ])
    }

    @Test(arguments: finderStatusCases)
    func mapsEveryRawFinderStatusWithoutInspectingResources(
        testCase: FinderStatusCase
    ) {
        let sender = FinderWorkspaceEventSenderStub()
        sender.status = testCase.status
        let inspector = FinderWorkspaceResourceInspectorStub()
        let resolver = FinderWorkspaceResolver(
            eventSender: sender,
            resourceInspector: inspector
        )

        let error = capturedFinderWorkspaceError {
            try resolver.resolveFrontmostWorkspace()
        }

        #expect(error == testCase.expectedError)
        #expect(sender.events.count == 1)
        #expect(inspector.inspectedURLs.isEmpty)
    }

    @Test(arguments: validWorkspaceURLCases)
    func acceptsAbsoluteFileURLShapes(
        testCase: ValidWorkspaceURLCase
    ) throws {
        let sender = FinderWorkspaceEventSenderStub()
        sender.reply = workspaceReply(text: testCase.replyText)
        let inspector = FinderWorkspaceResourceInspectorStub()
        let resolver = FinderWorkspaceResolver(
            eventSender: sender,
            resourceInspector: inspector
        )

        let workspace = try resolver.resolveFrontmostWorkspace()

        #expect(workspace.path == testCase.expectedPath)
        #expect(sender.events.count == 1)
        #expect(inspector.inspectedURLs.map(\.path) == [testCase.expectedPath])
    }

    @Test(arguments: InvalidWorkspaceReply.allCases)
    func malformedRepliesFailBeforeResourceInspection(
        testCase: InvalidWorkspaceReply
    ) {
        let sender = FinderWorkspaceEventSenderStub()
        sender.reply = testCase.reply
        let inspector = FinderWorkspaceResourceInspectorStub()
        let resolver = FinderWorkspaceResolver(
            eventSender: sender,
            resourceInspector: inspector
        )

        let error = capturedFinderWorkspaceError {
            try resolver.resolveFrontmostWorkspace()
        }

        #expect(error == .malformedReply)
        #expect(sender.events.count == 1)
        #expect(inspector.inspectedURLs.isEmpty)
    }

    @Test(arguments: unsupportedWorkspaceReplies)
    func relativeAndNonFileRepliesAreUnsupported(
        testCase: UnsupportedWorkspaceReply
    ) {
        let sender = FinderWorkspaceEventSenderStub()
        sender.reply = workspaceReply(text: testCase.replyText)
        let inspector = FinderWorkspaceResourceInspectorStub()
        let resolver = FinderWorkspaceResolver(
            eventSender: sender,
            resourceInspector: inspector
        )

        let error = capturedFinderWorkspaceError {
            try resolver.resolveFrontmostWorkspace()
        }

        #expect(error == .unsupportedLocation)
        #expect(sender.events.count == 1)
        #expect(inspector.inspectedURLs.isEmpty)
    }

    @Test
    func unreachableWorkspaceMapsToInaccessible() {
        let sender = FinderWorkspaceEventSenderStub()
        sender.reply = workspaceReply(text: "file:///Volumes/Missing/Project")
        let inspector = FinderWorkspaceResourceInspectorStub()
        inspector.result = .unreachable
        let resolver = FinderWorkspaceResolver(
            eventSender: sender,
            resourceInspector: inspector
        )

        let error = capturedFinderWorkspaceError {
            try resolver.resolveFrontmostWorkspace()
        }

        #expect(error == .inaccessibleWorkspace)
        #expect(inspector.inspectedURLs.map(\.path) == [
            "/Volumes/Missing/Project",
        ])
    }

    @Test
    func reachableNonDirectoryMapsToInvalidWorkspace() {
        let sender = FinderWorkspaceEventSenderStub()
        sender.reply = workspaceReply(text: "file:///Users/example/file.txt")
        let inspector = FinderWorkspaceResourceInspectorStub()
        inspector.result = .reachableNonDirectory
        let resolver = FinderWorkspaceResolver(
            eventSender: sender,
            resourceInspector: inspector
        )

        let error = capturedFinderWorkspaceError {
            try resolver.resolveFrontmostWorkspace()
        }

        #expect(error == .invalidWorkspace)
        #expect(inspector.inspectedURLs.map(\.path) == [
            "/Users/example/file.txt",
        ])
    }

    @Test
    func workspaceConstructionStandardizesTheValidatedFileURL() throws {
        let sender = FinderWorkspaceEventSenderStub()
        sender.reply = workspaceReply(
            text: "file:///Users/example/Parent/../Project"
        )
        let inspector = FinderWorkspaceResourceInspectorStub()
        let resolver = FinderWorkspaceResolver(
            eventSender: sender,
            resourceInspector: inspector
        )

        let workspace = try resolver.resolveFrontmostWorkspace()

        #expect(workspace.path == "/Users/example/Project")
        #expect(inspector.inspectedURLs.map(\.path) == [
            "/Users/example/Parent/../Project",
        ])
    }

    @Test
    func workspaceConstructionFailureMapsToInvalidWorkspace() {
        let sender = FinderWorkspaceEventSenderStub()
        sender.reply = workspaceReply(text: "file:///tmp/%00invalid")
        let inspector = FinderWorkspaceResourceInspectorStub()
        let resolver = FinderWorkspaceResolver(
            eventSender: sender,
            resourceInspector: inspector
        )

        let error = capturedFinderWorkspaceError {
            try resolver.resolveFrontmostWorkspace()
        }

        #expect(error == .invalidWorkspace)
        #expect(inspector.inspectedURLs.count == 1)
    }

    @Test
    func realURLInspectorDistinguishesDirectoryFileAndMissingPath() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "Go2Codex-FinderWorkspace-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? fileManager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        #expect(fileManager.createFile(
            atPath: file.path,
            contents: Data("test".utf8)
        ))
        let missing = directory.appendingPathComponent("missing")
        let inspector = URLFinderWorkspaceResourceInspector()

        #expect(inspector.inspect(directory) == .reachableDirectory)
        #expect(inspector.inspect(file) == .reachableNonDirectory)
        #expect(inspector.inspect(missing) == .unreachable)
    }
}

@MainActor
private final class FinderWorkspaceEventSenderStub:
    FinderWorkspaceAppleEventSending {
    var reply = workspaceReply(text: "file:///")
    var status: Int32?
    private(set) var events: [NSAppleEventDescriptor] = []

    func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        events.append(event)
        if let status {
            throw RawAppleEventError.status(status)
        }
        return reply
    }
}

@MainActor
private final class FinderWorkspaceResourceInspectorStub:
    FinderWorkspaceResourceInspecting {
    var result = FinderWorkspaceResourceInspection.reachableDirectory
    private(set) var inspectedURLs: [URL] = []

    func inspect(_ url: URL) -> FinderWorkspaceResourceInspection {
        inspectedURLs.append(url)
        return result
    }
}

struct FinderStatusCase: Sendable, CustomTestStringConvertible {
    let status: Int32
    let expectedError: FinderWorkspaceError

    var testDescription: String {
        String(status)
    }
}

struct ValidWorkspaceURLCase: Sendable, CustomTestStringConvertible {
    let replyText: String
    let expectedPath: String

    var testDescription: String {
        expectedPath
    }
}

enum InvalidWorkspaceReply: CaseIterable, Sendable,
    CustomTestStringConvertible {
    case missingDirectObject
    case nonTextDirectObject
    case emptyText
    case malformedURL

    @MainActor
    var reply: NSAppleEventDescriptor {
        switch self {
        case .missingDirectObject:
            workspaceReply()
        case .nonTextDirectObject:
            workspaceReply(directObject: .record())
        case .emptyText:
            workspaceReply(text: "")
        case .malformedURL:
            workspaceReply(text: "file://[")
        }
    }

    var testDescription: String {
        switch self {
        case .missingDirectObject: "missing-direct-object"
        case .nonTextDirectObject: "non-text-direct-object"
        case .emptyText: "empty-text"
        case .malformedURL: "malformed-url"
        }
    }
}

struct UnsupportedWorkspaceReply: Sendable, CustomTestStringConvertible {
    let replyText: String
    let name: String

    var testDescription: String {
        name
    }
}

private let finderStatusCases = [
    FinderStatusCase(
        status: -1743,
        expectedError: .automationPermissionDenied
    ),
    FinderStatusCase(status: -1744, expectedError: .consentRequired),
    FinderStatusCase(status: -1712, expectedError: .replyTimeout),
    FinderStatusCase(status: -600, expectedError: .finderUnavailable),
    FinderStatusCase(status: -1728, expectedError: .objectUnavailable),
    FinderStatusCase(
        status: -1708,
        expectedError: .appleEventFailure(status: -1708)
    ),
]

private let validWorkspaceURLCases = [
    ValidWorkspaceURLCase(
        replyText: "file:///Users/example/Project%20With%20Space",
        expectedPath: "/Users/example/Project With Space"
    ),
    ValidWorkspaceURLCase(
        replyText: "file:///Users/example/%E6%B5%8B%E8%AF%95%20Folder",
        expectedPath: "/Users/example/测试 Folder"
    ),
    ValidWorkspaceURLCase(replyText: "file:///", expectedPath: "/"),
    ValidWorkspaceURLCase(
        replyText: "file:///Volumes/External%20Disk/Project",
        expectedPath: "/Volumes/External Disk/Project"
    ),
]

private let unsupportedWorkspaceReplies = [
    UnsupportedWorkspaceReply(
        replyText: "file:relative/path",
        name: "relative-file-url"
    ),
    UnsupportedWorkspaceReply(
        replyText: "relative/path",
        name: "relative-url"
    ),
    UnsupportedWorkspaceReply(
        replyText: "https://example.com/path",
        name: "non-file-url"
    ),
]

@MainActor
private func workspaceReply(
    text: String? = nil,
    directObject: NSAppleEventDescriptor? = nil
) -> NSAppleEventDescriptor {
    let reply = NSAppleEventDescriptor(
        eventClass: workspaceCode("aevt"),
        eventID: workspaceCode("ansr"),
        targetDescriptor: .null(),
        returnID: -1,
        transactionID: 0
    )
    if let text {
        reply.setParam(
            .init(string: text),
            forKeyword: workspaceCode("----")
        )
    } else if let directObject {
        reply.setParam(
            directObject,
            forKeyword: workspaceCode("----")
        )
    }
    return reply
}

@MainActor
private func capturedFinderWorkspaceError(
    _ operation: @MainActor () throws -> Workspace
) -> FinderWorkspaceError? {
    do {
        _ = try operation()
        return nil
    } catch let error as FinderWorkspaceError {
        return error
    } catch {
        return nil
    }
}

private func workspaceCode(_ value: String) -> UInt32 {
    precondition(value.utf8.count == 4)
    return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

private func targetBundleIdentifier(
    of event: NSAppleEventDescriptor
) -> String? {
    guard let address = event.attributeDescriptor(
        forKeyword: workspaceCode("addr")
    ) else {
        return nil
    }
    return String(data: address.data, encoding: .utf8)
}
