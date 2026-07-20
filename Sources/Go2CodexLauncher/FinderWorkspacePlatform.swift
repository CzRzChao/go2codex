import AppKit
import Foundation
import Go2CodexCore

@MainActor
protocol FinderWorkspaceAppleEventSending {
    func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor
}

@MainActor
struct NativeFinderWorkspaceAppleEventSender:
    FinderWorkspaceAppleEventSending {
    func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        try NativeAppleEvent.send(event)
    }
}

enum FinderWorkspaceResourceInspection: Equatable {
    case unreachable
    case reachableNonDirectory
    case reachableDirectory
}

@MainActor
protocol FinderWorkspaceResourceInspecting {
    func inspect(_ url: URL) -> FinderWorkspaceResourceInspection
}

@MainActor
struct URLFinderWorkspaceResourceInspector:
    FinderWorkspaceResourceInspecting {
    func inspect(_ url: URL) -> FinderWorkspaceResourceInspection {
        guard (try? url.checkResourceIsReachable()) == true else {
            return .unreachable
        }
        guard (try? url.resourceValues(
            forKeys: [.isDirectoryKey]
        ).isDirectory) == true else {
            return .reachableNonDirectory
        }
        return .reachableDirectory
    }
}

@MainActor
struct FinderWorkspaceResolver: FinderWorkspaceResolving {
    private let eventSender: any FinderWorkspaceAppleEventSending
    private let resourceInspector: any FinderWorkspaceResourceInspecting

    init(
        eventSender: any FinderWorkspaceAppleEventSending =
            NativeFinderWorkspaceAppleEventSender(),
        resourceInspector: any FinderWorkspaceResourceInspecting =
            URLFinderWorkspaceResourceInspector()
    ) {
        self.eventSender = eventSender
        self.resourceInspector = resourceInspector
    }

    func resolveFrontmostWorkspace() throws -> Workspace {
        let reply: NSAppleEventDescriptor
        do {
            reply = try eventSender.send(
                try NativeAppleEvent.finderWorkspace()
            )
        } catch let RawAppleEventError.status(status) {
            throw FinderWorkspaceError.mapAppleEventStatus(status)
        }

        guard let text = reply.paramDescriptor(
            forKeyword: NativeAppleEvent.directObjectKeyword
        )?.stringValue,
              !text.isEmpty,
              let url = URL(string: text) else {
            throw FinderWorkspaceError.malformedReply
        }
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw FinderWorkspaceError.unsupportedLocation
        }

        switch resourceInspector.inspect(url) {
        case .unreachable:
            throw FinderWorkspaceError.inaccessibleWorkspace
        case .reachableNonDirectory:
            throw FinderWorkspaceError.invalidWorkspace
        case .reachableDirectory:
            break
        }

        do {
            return try Workspace(fileURL: url)
        } catch {
            throw FinderWorkspaceError.invalidWorkspace
        }
    }
}
