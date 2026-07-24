import AppKit
import ApplicationServices
import Darwin
import Foundation
import Go2CodexCore

typealias WorkspaceOpenCompletion = @Sendable (
    NSRunningApplication?,
    (any Error)?
) -> Void

@MainActor
func awaitWorkspaceOpen<Result: Sendable>(
    mapError: @escaping @Sendable ((any Error)?) -> Result,
    starting operation: (_ completion: @escaping WorkspaceOpenCompletion) -> Void
) async -> Result {
    await withCheckedContinuation { continuation in
        // LaunchServices invokes this completion on its own queue.
        let completion: WorkspaceOpenCompletion = { _, error in
            continuation.resume(returning: mapError(error))
        }
        operation(completion)
    }
}

struct DesktopHandlerRegistration: Equatable {
    let applicationURL: URL
    let bundleIdentifier: String?
}

@MainActor
protocol DesktopHandoffPlatform {
    func handler(toOpen url: URL) -> DesktopHandlerRegistration?
    func application(
        withBundleIdentifier bundleIdentifier: String
    ) -> DesktopHandlerRegistration?
    func open(
        _ url: URL,
        withApplicationAt applicationURL: URL
    ) async -> Int?
}

@MainActor
struct WorkspaceDesktopHandoffPlatform: DesktopHandoffPlatform {
    func handler(toOpen url: URL) -> DesktopHandlerRegistration? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            toOpen: url
        ) else {
            return nil
        }
        return DesktopHandlerRegistration(
            applicationURL: applicationURL,
            bundleIdentifier: Bundle(url: applicationURL)?.bundleIdentifier
        )
    }

    func application(
        withBundleIdentifier bundleIdentifier: String
    ) -> DesktopHandlerRegistration? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return nil
        }
        return DesktopHandlerRegistration(
            applicationURL: applicationURL,
            bundleIdentifier: Bundle(url: applicationURL)?.bundleIdentifier
        )
    }

    func open(
        _ url: URL,
        withApplicationAt applicationURL: URL
    ) async -> Int? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        return await awaitWorkspaceOpen(
            mapError: { error in
                error.map { ($0 as NSError).code }
            }
        ) { completion in
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration,
                completionHandler: completion
            )
        }
    }
}

@MainActor
struct DesktopOpenAdapter: DesktopHandoffPerforming {
    private let platform: any DesktopHandoffPlatform

    init(
        platform: any DesktopHandoffPlatform = WorkspaceDesktopHandoffPlatform()
    ) {
        self.platform = platform
    }

    func open(_ request: DesktopOpenRequest) async throws -> HandoffAcceptance {
        let handler: DesktopHandlerRegistration?
        switch request.applicationLookup {
        case .urlHandler:
            handler = platform.handler(toOpen: request.url)
        case let .bundleIdentifier(bundleIdentifier):
            handler = platform.application(
                withBundleIdentifier: bundleIdentifier
            )
        }

        guard let handler,
              let verifiedHandler = DesktopTargetHandlerPolicy.verify(
                  target: request.target,
                  applicationURL: handler.applicationURL,
                  handlerBundleIdentifier: handler.bundleIdentifier
              ) else {
            throw DesktopHandoffError.handlerUnavailable(request.target)
        }

        if let errorCode = await platform.open(
            request.url,
            withApplicationAt: verifiedHandler.applicationURL
        ) {
            throw DesktopHandoffError.openFailed(code: errorCode)
        }
        return .acceptedByLaunchServices
    }
}

@MainActor
protocol TerminalApplicationStateLookingUp {
    func applicationURL(bundleIdentifier: String) -> URL?
    func isRunning(bundleIdentifier: String) -> Bool
    func isFrontmost(bundleIdentifier: String) -> Bool
    func activate(bundleIdentifier: String) -> Bool
}

@MainActor
struct WorkspaceTerminalApplicationState: TerminalApplicationStateLookingUp {
    func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        )
    }

    func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
    }

    func isFrontmost(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == bundleIdentifier
    }

    func activate(bundleIdentifier: String) -> Bool {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else {
            return false
        }
        return application.activate(options: [.activateAllWindows])
    }
}

@MainActor
protocol TerminalServicePerforming {
    func performNewWindow(at directoryURL: URL) -> Bool
    func performNewTab(at directoryURL: URL) -> Bool
}

@MainActor
struct WorkspaceTerminalServicePerformer: TerminalServicePerforming {
    static let newWindowServiceName = "New Terminal at Folder"
    static let newTabServiceName = "New Terminal Tab at Folder"

    private let performService: @MainActor (String, NSPasteboard) -> Bool

    init(
        performService: @escaping @MainActor (
            String,
            NSPasteboard
        ) -> Bool = { name, pasteboard in
            NSPerformService(name, pasteboard)
        }
    ) {
        self.performService = performService
    }

    func performNewWindow(at directoryURL: URL) -> Bool {
        perform(
            Self.newWindowServiceName,
            at: directoryURL
        )
    }

    func performNewTab(at directoryURL: URL) -> Bool {
        perform(
            Self.newTabServiceName,
            at: directoryURL
        )
    }

    private func perform(_ serviceName: String, at directoryURL: URL) -> Bool {
        guard directoryURL.isFileURL,
              directoryURL.path(percentEncoded: false).hasPrefix("/") else {
            return false
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([directoryURL as NSURL]) else {
            return false
        }
        return performService(serviceName, pasteboard)
    }
}

struct TerminalApplicationOpenFailure: Equatable, Sendable {
    let code: Int
    let appleEventStatus: Int32?

    init(error: any Error) {
        let outerError = error as NSError
        code = outerError.code

        var status: Int32?
        var current: NSError? = outerError
        for _ in 0..<8 {
            guard let inspected = current else {
                break
            }
            if inspected.domain == NSOSStatusErrorDomain,
               inspected.code == -600
                || (-1799 ... -1700).contains(inspected.code) {
                status = Int32(clamping: inspected.code)
                break
            }
            guard let underlying = inspected.userInfo[NSUnderlyingErrorKey]
                as? NSError,
                  underlying !== inspected else {
                break
            }
            current = underlying
        }
        appleEventStatus = status
    }

    init(code: Int, appleEventStatus: Int32? = nil) {
        self.code = code
        self.appleEventStatus = appleEventStatus
    }
}

@MainActor
protocol TerminalApplicationOpening {
    func openApplication(
        at applicationURL: URL,
        initialAppleEvent: NSAppleEventDescriptor?,
        activates: Bool
    ) async -> TerminalApplicationOpenFailure?
}

@MainActor
struct WorkspaceTerminalApplicationOpener: TerminalApplicationOpening {
    func openApplication(
        at applicationURL: URL,
        initialAppleEvent: NSAppleEventDescriptor?,
        activates: Bool
    ) async -> TerminalApplicationOpenFailure? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        configuration.addsToRecentItems = false
        configuration.appleEvent = initialAppleEvent

        return await awaitWorkspaceOpen(
            mapError: { error in
                error.map(TerminalApplicationOpenFailure.init(error:))
            }
        ) { completion in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration,
                completionHandler: completion
            )
        }
    }
}

struct AutomationPermissionRequest: Equatable, Sendable {
    static let allEvents: UInt32 = 0x2a2a2a2a

    let bundleIdentifier: String
    let eventClass: UInt32
    let eventID: UInt32
}

@MainActor
protocol NativeAppleEventSending {
    func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor

    func send(
        _ event: NSAppleEventDescriptor,
        timeout: TimeInterval
    ) throws -> NSAppleEventDescriptor

    func requestAutomationPermission(
        _ request: AutomationPermissionRequest
    ) async -> Int32
}

extension NativeAppleEventSending {
    func send(
        _ event: NSAppleEventDescriptor,
        timeout: TimeInterval
    ) throws -> NSAppleEventDescriptor {
        try send(event)
    }
}

@MainActor
struct SystemNativeAppleEventSender: NativeAppleEventSending {
    func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        try NativeAppleEvent.send(event)
    }

    func send(
        _ event: NSAppleEventDescriptor,
        timeout: TimeInterval
    ) throws -> NSAppleEventDescriptor {
        try NativeAppleEvent.send(event, timeout: timeout)
    }

    func requestAutomationPermission(
        _ request: AutomationPermissionRequest
    ) async -> Int32 {
        await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(
                bundleIdentifier: request.bundleIdentifier
            )
            guard let address = target.aeDesc else {
                return Int32(paramErr)
            }
            return AEDeterminePermissionToAutomateTarget(
                address,
                request.eventClass,
                request.eventID,
                true
            )
        }.value
    }

}

enum TerminalAdapterError: Error, Equatable, DiagnosticCodeProviding {
    case iTermScriptResourceMissing
    case iTermScriptLoadFailed
    case iTermScriptExecutionFailed
    case iTermHandoffOutcomeUnknown(Int32?)
    case iTermWindowQueryReplyInvalid(UInt32?)
    case iTermLoginShellUnavailable
    case applicationOpenFailed(Int)
    case terminalTabLockFailed(Int32)
    case terminalTabOperationBusy
    case terminalTabServiceFailed
    case terminalTabServiceLaunchTimedOut
    case terminalWindowServiceFailed
    case terminalWindowServiceLaunchTimedOut
    case terminalWindowListReplyInvalid(UInt32?)
    case terminalTabCountReplyInvalid(UInt32?)
    case terminalTabTTYListReplyInvalid(UInt32?)
    case terminalSnapshotReplyTimedOut
    case terminalSnapshotStabilityTimedOut
    case terminalBaselineTTYTimedOut
    case terminalTabCreationTimedOut(TerminalTabCreationEvidence)
    case terminalWindowCreationTimedOut(TerminalTabCreationEvidence)

    var diagnosticCode: DiagnosticCode {
        switch self {
        case .iTermScriptResourceMissing:
            DiagnosticCode(rawValue: "iterm-script-resource-missing")
        case .iTermScriptLoadFailed:
            DiagnosticCode(rawValue: "iterm-script-load-failed")
        case .iTermScriptExecutionFailed:
            DiagnosticCode(rawValue: "iterm-script-execution-failed")
        case .iTermHandoffOutcomeUnknown:
            DiagnosticCode(rawValue: "iterm-handoff-outcome-unknown")
        case .iTermWindowQueryReplyInvalid:
            DiagnosticCode(rawValue: "iterm-window-query-malformed")
        case .iTermLoginShellUnavailable:
            DiagnosticCode(rawValue: "iterm-login-shell-unavailable")
        case .applicationOpenFailed:
            DiagnosticCode(rawValue: "terminal-open-failed")
        case .terminalTabLockFailed:
            DiagnosticCode(rawValue: "terminal-tab-lock-failed")
        case .terminalTabOperationBusy:
            DiagnosticCode(rawValue: "terminal-tab-operation-busy")
        case .terminalTabServiceFailed:
            DiagnosticCode(rawValue: "terminal-tab-service-failed")
        case .terminalTabServiceLaunchTimedOut:
            DiagnosticCode(rawValue: "terminal-tab-service-launch-timeout")
        case .terminalWindowServiceFailed:
            DiagnosticCode(rawValue: "terminal-window-service-failed")
        case .terminalWindowServiceLaunchTimedOut:
            DiagnosticCode(rawValue: "terminal-window-service-launch-timeout")
        case .terminalWindowListReplyInvalid:
            DiagnosticCode(rawValue: "terminal-window-list-malformed")
        case .terminalTabCountReplyInvalid:
            DiagnosticCode(rawValue: "terminal-tab-count-malformed")
        case .terminalTabTTYListReplyInvalid:
            DiagnosticCode(rawValue: "terminal-tab-tty-list-malformed")
        case .terminalSnapshotReplyTimedOut:
            DiagnosticCode(rawValue: "terminal-snapshot-reply-timeout")
        case .terminalSnapshotStabilityTimedOut:
            DiagnosticCode(rawValue: "terminal-snapshot-stability-timeout")
        case .terminalBaselineTTYTimedOut:
            DiagnosticCode(rawValue: "terminal-baseline-tty-timeout")
        case .terminalTabCreationTimedOut(let evidence):
            Self.terminalCreationTimeoutDiagnosticCode(
                evidence: evidence,
                placement: "tab"
            )
        case .terminalWindowCreationTimedOut(let evidence):
            Self.terminalCreationTimeoutDiagnosticCode(
                evidence: evidence,
                placement: "window"
            )
        }
    }

    private static func terminalCreationTimeoutDiagnosticCode(
        evidence: TerminalTabCreationEvidence,
        placement: String
    ) -> DiagnosticCode {
        if evidence.sawUniqueNewTTY
            || evidence.windowSetChanged
            || evidence.oldTTYOwnerChanged
            || evidence.snapshotUnstableAfterService
            || evidence.latestTotalTabCount
                > evidence.initialTotalTabCount + 1 {
            return DiagnosticCode(
                rawValue: "terminal-\(placement)-identity-timeout"
            )
        }
        if evidence.sawPendingTTY
            || evidence.latestTotalTabCount
                == evidence.initialTotalTabCount + 1 {
            return DiagnosticCode(
                rawValue: "terminal-\(placement)-tty-timeout"
            )
        }
        return DiagnosticCode(rawValue: "terminal-\(placement)-creation-timeout")
    }
}

struct TerminalWindowTabEvidence: Equatable, Sendable {
    let windowID: Int32
    let tabCount: Int
    let readyTTYCount: Int
}

struct TerminalTabCreationEvidence: Equatable, Sendable {
    let initialWindows: [TerminalWindowTabEvidence]
    let latestWindows: [TerminalWindowTabEvidence]
    let sawGlobalTabIncrease: Bool
    let sawPendingTTY: Bool
    let sawUniqueNewTTY: Bool
    let windowSetChanged: Bool
    let oldTTYOwnerChanged: Bool
    let snapshotUnstableAfterService: Bool

    var initialTotalTabCount: Int {
        initialWindows.reduce(0) { $0 + $1.tabCount }
    }

    var latestTotalTabCount: Int {
        latestWindows.reduce(0) { $0 + $1.tabCount }
    }
}

struct TerminalWindowSnapshot: Equatable, Sendable {
    let windowID: Int32
    let tabTTYValues: [TerminalTabTTYValue]

    var tabCount: Int {
        tabTTYValues.count
    }

    var readyTTYCount: Int {
        tabTTYValues.reduce(0) { count, value in
            if case .ready = value {
                count + 1
            } else {
                count
            }
        }
    }
}

struct TerminalSnapshot: Equatable, Sendable {
    static let empty = TerminalSnapshot(windows: [])

    let windows: [TerminalWindowSnapshot]

    init(windows: [TerminalWindowSnapshot]) {
        self.windows = windows.sorted { $0.windowID < $1.windowID }
    }

    var totalTabCount: Int {
        windows.reduce(0) { $0 + $1.tabCount }
    }

    var notReadyTabCount: Int {
        windows.reduce(0) { count, window in
            count + window.tabTTYValues.reduce(0) { tabCount, value in
                if case .notReady = value {
                    tabCount + 1
                } else {
                    tabCount
                }
            }
        }
    }

    var readyTTYOwners: [String: Int32] {
        var result: [String: Int32] = [:]
        for window in windows {
            for case .ready(let tty) in window.tabTTYValues {
                result[tty] = window.windowID
            }
        }
        return result
    }

    var evidence: [TerminalWindowTabEvidence] {
        windows.map {
            TerminalWindowTabEvidence(
                windowID: $0.windowID,
                tabCount: $0.tabCount,
                readyTTYCount: $0.readyTTYCount
            )
        }
    }
}

@MainActor
protocol TerminalSnapshotReading {
    func coherentSnapshot() throws -> TerminalSnapshot?
}

@MainActor
struct AppleEventTerminalSnapshotReader: TerminalSnapshotReading {
    static let queryTimeout: TimeInterval = 2

    private let eventSender: any NativeAppleEventSending

    init(eventSender: any NativeAppleEventSending) {
        self.eventSender = eventSender
    }

    func coherentSnapshot() throws -> TerminalSnapshot? {
        do {
            guard let windowIDsBefore = try terminalWindowIDs() else {
                return nil
            }
            var windows: [TerminalWindowSnapshot] = []
            windows.reserveCapacity(windowIDsBefore.count)
            for windowID in windowIDsBefore.sorted() {
                guard let countBefore = try terminalTabCount(
                    windowID: windowID
                ), let ttyValues = try terminalTabTTYValues(
                    windowID: windowID
                ), let countAfter = try terminalTabCount(
                    windowID: windowID
                ), countBefore == countAfter,
                   countBefore == ttyValues.count else {
                    return nil
                }
                windows.append(
                    TerminalWindowSnapshot(
                        windowID: windowID,
                        tabTTYValues: ttyValues
                    )
                )
            }
            guard let windowIDsAfter = try terminalWindowIDs(),
                  Set(windowIDsBefore) == Set(windowIDsAfter) else {
                return nil
            }
            let snapshot = TerminalSnapshot(windows: windows)
            let readyTTYCount = windows.reduce(0) {
                $0 + $1.readyTTYCount
            }
            guard snapshot.readyTTYOwners.count == readyTTYCount else {
                return nil
            }
            return snapshot
        } catch RawAppleEventError.status(-1728),
                RawAppleEventError.status(-1719) {
            return nil
        } catch RawAppleEventError.status(-1712) {
            throw TerminalAdapterError.terminalSnapshotReplyTimedOut
        } catch let RawAppleEventError.status(status) {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: .terminal
            )
        }
    }

    private func terminalWindowIDs() throws -> [Int32]? {
        let reply = try eventSender.send(
            try NativeAppleEvent.terminalWindowIDsQuery(),
            timeout: Self.queryTimeout
        )
        if let windowIDs = NativeAppleEvent.terminalWindowIDs(from: reply) {
            return windowIDs
        }
        guard NativeAppleEvent.directObjectContainsMissingValue(reply) else {
            throw TerminalAdapterError.terminalWindowListReplyInvalid(
                reply.paramDescriptor(
                    forKeyword: NativeAppleEvent.directObjectKeyword
                )?.descriptorType
            )
        }
        return nil
    }

    private func terminalTabCount(windowID: Int32) throws -> Int? {
        let reply = try eventSender.send(
            try NativeAppleEvent.terminalTabCountQuery(windowID: windowID),
            timeout: Self.queryTimeout
        )
        if let count = NativeAppleEvent.terminalTabCount(from: reply) {
            return count
        }
        guard NativeAppleEvent.directObjectContainsMissingValue(reply) else {
            throw TerminalAdapterError.terminalTabCountReplyInvalid(
                reply.paramDescriptor(
                    forKeyword: NativeAppleEvent.directObjectKeyword
                )?.descriptorType
            )
        }
        return nil
    }

    private func terminalTabTTYValues(
        windowID: Int32
    ) throws -> [TerminalTabTTYValue]? {
        let reply = try eventSender.send(
            try NativeAppleEvent.terminalTabTTYsQuery(windowID: windowID),
            timeout: Self.queryTimeout
        )
        if let values = NativeAppleEvent.terminalTabTTYValues(from: reply) {
            return values
        }
        guard NativeAppleEvent.directObjectContainsMissingValue(reply) else {
            throw TerminalAdapterError.terminalTabTTYListReplyInvalid(
                reply.paramDescriptor(
                    forKeyword: NativeAppleEvent.directObjectKeyword
                )?.descriptorType
            )
        }
        return nil
    }
}

struct TerminalTabCandidate: Equatable, Sendable {
    let windowID: Int32
    let tty: String
    let tabIndex: Int32
}

enum TerminalTabObservation: Equatable, Sendable {
    case unchanged
    case pending
    case candidate(TerminalTabCandidate)
    case ambiguous
}

struct TerminalTabDelta: Equatable, Sendable {
    let observation: TerminalTabObservation
    let sawGlobalTabIncrease: Bool
    let sawPendingTTY: Bool
    let sawUniqueNewTTY: Bool
    let windowSetChanged: Bool
    let oldTTYOwnerChanged: Bool
}

func terminalTabDelta(
    from baseline: TerminalSnapshot,
    to current: TerminalSnapshot
) -> TerminalTabDelta {
    let baselineOwners = baseline.readyTTYOwners
    let currentOwners = current.readyTTYOwners
    let baselineWindowIDs = Set(baseline.windows.map(\.windowID))
    let currentWindowIDs = Set(current.windows.map(\.windowID))
    let windowSetChanged: Bool
    if baseline.windows.isEmpty {
        windowSetChanged = current.windows.count > 1
    } else {
        windowSetChanged = baselineWindowIDs != currentWindowIDs
    }
    let oldTTYOwnerChanged = baselineOwners.contains { tty, windowID in
        currentOwners[tty] != windowID
    }
    let newTTYs = currentOwners.keys.filter { baselineOwners[$0] == nil }
    let sawGlobalTabIncrease = current.totalTabCount > baseline.totalTabCount
    let sawPendingTTY = current.totalTabCount
        == baseline.totalTabCount + 1 && current.notReadyTabCount == 1
    let sawUniqueNewTTY = newTTYs.count == 1
    let changedWindowID = windowSetChanged
        ? terminalNewWindowFallbackID(from: baseline, to: current)
        : terminalChangedWindowID(from: baseline, to: current)

    let observation: TerminalTabObservation
    if current == baseline {
        observation = .unchanged
    } else if !oldTTYOwnerChanged,
              current.totalTabCount == baseline.totalTabCount + 1,
              let changedWindowID {
        if newTTYs.isEmpty, current.notReadyTabCount == 1 {
            observation = .pending
        } else if newTTYs.count == 1,
                  current.notReadyTabCount == 0,
                  let tty = newTTYs.first,
                  currentOwners[tty] == changedWindowID,
                  let changedWindow = current.windows.first(
                    where: { $0.windowID == changedWindowID }
                  ),
                  let zeroBasedTabIndex = changedWindow.tabTTYValues.firstIndex(
                    where: { $0 == .ready(tty) }
                  ),
                  zeroBasedTabIndex < Int(Int32.max),
                  let tabIndex = Int32(exactly: zeroBasedTabIndex + 1),
                  tabIndex > 0 {
            observation = .candidate(
                TerminalTabCandidate(
                    windowID: changedWindowID,
                    tty: tty,
                    tabIndex: tabIndex
                )
            )
        } else {
            observation = .ambiguous
        }
    } else {
        observation = .ambiguous
    }

    return TerminalTabDelta(
        observation: observation,
        sawGlobalTabIncrease: sawGlobalTabIncrease,
        sawPendingTTY: sawPendingTTY,
        sawUniqueNewTTY: sawUniqueNewTTY,
        windowSetChanged: windowSetChanged,
        oldTTYOwnerChanged: oldTTYOwnerChanged
    )
}

private func terminalChangedWindowID(
    from baseline: TerminalSnapshot,
    to current: TerminalSnapshot
) -> Int32? {
    if baseline.windows.isEmpty {
        guard current.windows.count == 1,
              current.windows[0].tabCount == 1 else {
            return nil
        }
        return current.windows[0].windowID
    }
    let baselineCounts = Dictionary(
        uniqueKeysWithValues: baseline.windows.map {
            ($0.windowID, $0.tabCount)
        }
    )
    let changed = current.windows.filter { window in
        guard let previous = baselineCounts[window.windowID] else {
            return true
        }
        return window.tabCount != previous
    }
    guard changed.count == 1,
          let previous = baselineCounts[changed[0].windowID],
          changed[0].tabCount == previous + 1 else {
        return nil
    }
    return changed[0].windowID
}

private func terminalNewWindowFallbackID(
    from baseline: TerminalSnapshot,
    to current: TerminalSnapshot
) -> Int32? {
    guard !baseline.windows.isEmpty,
          current.totalTabCount == baseline.totalTabCount + 1 else {
        return nil
    }

    let currentWindowsByID = Dictionary(
        current.windows.map { ($0.windowID, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    guard currentWindowsByID.count == current.windows.count,
          baseline.windows.allSatisfy({ window in
        currentWindowsByID[window.windowID]?.tabTTYValues
            == window.tabTTYValues
    }) else {
        return nil
    }

    let baselineWindowIDs = Set(baseline.windows.map(\.windowID))
    let newWindows = current.windows.filter {
        !baselineWindowIDs.contains($0.windowID)
    }
    guard newWindows.count == 1,
          newWindows[0].tabCount == 1 else {
        return nil
    }
    return newWindows[0].windowID
}

protocol TerminalTabOperationLock: AnyObject {
    func release()
}

@MainActor
protocol TerminalTabOperationLocking {
    func tryAcquire() throws -> (any TerminalTabOperationLock)?
}

final class POSIXTerminalTabOperationLock: TerminalTabOperationLock {
    private var fileDescriptor: Int32?

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func release() {
        guard let fileDescriptor else {
            return
        }
        self.fileDescriptor = nil
        close(fileDescriptor)
    }

    deinit {
        if let fileDescriptor {
            close(fileDescriptor)
        }
    }
}

@MainActor
struct WorkspaceTerminalTabOperationLocker: TerminalTabOperationLocking {
    private let lockURL: URL

    init(lockURL: URL? = nil) {
        if let lockURL {
            self.lockURL = lockURL
            return
        }
        let applicationSupportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        self.lockURL = applicationSupportURL
            .appendingPathComponent(
                "io.github.czrzchao.go2codex",
                isDirectory: true
            )
            .appendingPathComponent(
                "terminal-tab.lock",
                isDirectory: false
            )
    }

    func tryAcquire() throws -> (any TerminalTabOperationLock)? {
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw TerminalAdapterError.terminalTabLockFailed(
                Int32(clamping: (error as NSError).code)
            )
        }
        let fileDescriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_EXLOCK,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                return nil
            }
            throw TerminalAdapterError.terminalTabLockFailed(errno)
        }
        var fileStatus = stat()
        guard fstat(fileDescriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_uid == geteuid(),
              fileStatus.st_nlink == 1,
              fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            close(fileDescriptor)
            throw TerminalAdapterError.terminalTabLockFailed(EPERM)
        }
        return POSIXTerminalTabOperationLock(
            fileDescriptor: fileDescriptor
        )
    }
}

typealias TerminalTabPollDelay = @MainActor () async -> Void

private enum TerminalFrontWindowState {
    case notRunning
    case noWindow
    case hasWindow
}

@MainActor
struct TerminalOpenAdapter: TerminalHandoffPerforming {
    private let applicationState: any TerminalApplicationStateLookingUp
    private let applicationOpener: any TerminalApplicationOpening
    private let eventSender: any NativeAppleEventSending
    private let iTermScriptExecutor: any ITermHandoffScriptExecuting
    private let loginShellPathLookup: any LoginShellPathLookingUp
    private let terminalService: any TerminalServicePerforming
    private let terminalSnapshotReader: any TerminalSnapshotReading
    private let terminalTabOperationLocker: any TerminalTabOperationLocking
    private let terminalTabPollAttempts: Int
    private let terminalTabPollDelay: TerminalTabPollDelay

    init(
        applicationState: any TerminalApplicationStateLookingUp =
            WorkspaceTerminalApplicationState(),
        applicationOpener: any TerminalApplicationOpening =
            WorkspaceTerminalApplicationOpener(),
        eventSender: any NativeAppleEventSending = SystemNativeAppleEventSender(),
        iTermScriptExecutor: any ITermHandoffScriptExecuting =
            BundledITermHandoffScriptExecutor(),
        loginShellPathLookup: any LoginShellPathLookingUp =
            SystemLoginShellPathLookup(),
        terminalService: any TerminalServicePerforming =
            WorkspaceTerminalServicePerformer(),
        terminalSnapshotReader: (any TerminalSnapshotReading)? = nil,
        terminalTabOperationLocker: any TerminalTabOperationLocking =
            WorkspaceTerminalTabOperationLocker(),
        terminalTabPollAttempts: Int = 50,
        terminalTabPollDelay: @escaping TerminalTabPollDelay = {
            try? await Task.sleep(for: .milliseconds(50))
        }
    ) {
        self.applicationState = applicationState
        self.applicationOpener = applicationOpener
        self.eventSender = eventSender
        self.iTermScriptExecutor = iTermScriptExecutor
        self.loginShellPathLookup = loginShellPathLookup
        self.terminalService = terminalService
        self.terminalSnapshotReader = terminalSnapshotReader
            ?? AppleEventTerminalSnapshotReader(eventSender: eventSender)
        self.terminalTabOperationLocker = terminalTabOperationLocker
        self.terminalTabPollAttempts = max(1, terminalTabPollAttempts)
        self.terminalTabPollDelay = terminalTabPollDelay
    }

    func open(
        _ command: TerminalCommand,
        in host: TerminalHost,
        placement: SessionPlacement
    ) async throws -> HandoffAcceptance {
        guard let applicationURL = applicationState.applicationURL(
            bundleIdentifier: host.bundleIdentifier
        ), applicationURL.isFileURL, applicationURL.path.hasPrefix("/") else {
            throw TerminalHandoffError.hostUnavailable(host)
        }

        switch host {
        case .terminal:
            try await openTerminal(
                command: command,
                placement: placement,
                applicationURL: applicationURL
            )
        case .iTerm2:
            try await openITerm(
                command: command,
                placement: placement,
                applicationURL: applicationURL,
                host: host
            )
        }
        return .acceptedByTerminalHost
    }

    private func openTerminal(
        command: TerminalCommand,
        placement: SessionPlacement,
        applicationURL: URL
    ) async throws {
        let host = TerminalHost.terminal
        switch placement {
        case .newTab:
            try await sendTerminalNewTab(command: command)
        case .newWindow:
            let wasRunning = applicationState.isRunning(
                bundleIdentifier: host.bundleIdentifier
            )
            if wasRunning {
                try await requestHostAutomationPermission(host)
                try await sendTerminal(
                    command: command.line,
                    host: host,
                    applicationURL: applicationURL,
                    isRunning: true
                )
            } else {
                try await sendTerminalNewWindow(command: command)
            }
        }
    }

    private func openITerm(
        command: TerminalCommand,
        placement: SessionPlacement,
        applicationURL: URL,
        host: TerminalHost
    ) async throws {
        let scriptCommand = try iTermScriptCommand(for: command)
        let wasRunning = applicationState.isRunning(
            bundleIdentifier: host.bundleIdentifier
        )
        if !wasRunning {
            // AEDeterminePermission requires a running target. This bootstrap
            // event suppresses window restoration without stealing focus.
            try await openHost(
                applicationURL: applicationURL,
                event: NativeAppleEvent.iTermQuietLaunch(),
                host: host,
                activates: false
            )
        }
        try await requestHostAutomationPermission(host)
        let windowState = placement == .newTab
            ? try frontWindowState(for: host, assumesRunning: true)
            : .noWindow
        let placementPlan = TerminalPlacementPlanner.plan(
            for: host,
            placement: placement,
            hasWindow: windowState == .hasWindow
        )
        switch placementPlan {
        case .createTabInFrontWindow:
            try sendITerm(
                command: scriptCommand,
                targetFrontWindow: true
            )
            // Creation is the acceptance boundary. Activation only reveals
            // the accepted session and must not turn success into a retryable
            // failure that could create a duplicate session.
            _ = applicationState.activate(
                bundleIdentifier: host.bundleIdentifier
            )
        case .createWindow:
            try sendITerm(
                command: scriptCommand,
                targetFrontWindow: false
            )
        case .unsupported:
            throw TerminalHandoffError.unsupportedPlacement(host, placement)
        }
    }

    private func iTermScriptCommand(
        for command: TerminalCommand
    ) throws -> String {
        guard let shellPath = loginShellPathLookup.loginShellPath() else {
            throw TerminalAdapterError.iTermLoginShellUnavailable
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: shellPath,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: shellPath) else {
            throw TerminalAdapterError.iTermLoginShellUnavailable
        }
        return try ITermCustomCommandBuilder.command(
            for: command,
            loginShellPath: shellPath
        )
    }

    private func frontWindowState(
        for host: TerminalHost,
        assumesRunning: Bool = false
    ) throws -> TerminalFrontWindowState {
        guard assumesRunning || applicationState.isRunning(
            bundleIdentifier: host.bundleIdentifier
        ) else {
            return .notRunning
        }

        do {
            let reply = try eventSender.send(
                host == .iTerm2
                    ? try NativeAppleEvent.iTermCurrentWindowQuery()
                    : try NativeAppleEvent.frontWindowQuery(
                        bundleIdentifier: host.bundleIdentifier
                    )
            )
            if host == .iTerm2 {
                return try iTermWindowState(from: reply)
            }
            return .hasWindow
        } catch RawAppleEventError.status(-1728),
                RawAppleEventError.status(-1719) {
            return .noWindow
        } catch RawAppleEventError.status(-600) where host == .terminal {
            return .notRunning
        } catch let RawAppleEventError.status(status) {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: host
            )
        }
    }

    private func iTermWindowState(
        from reply: NSAppleEventDescriptor
    ) throws -> TerminalFrontWindowState {
        switch NativeAppleEvent.classifyITermCurrentWindowReply(reply) {
        case .window:
            return .hasWindow
        case .noWindow:
            return .noWindow
        case .invalid(let descriptorType):
            throw TerminalAdapterError.iTermWindowQueryReplyInvalid(
                descriptorType
            )
        }
    }

    private func sendTerminal(
        command: String,
        host: TerminalHost,
        applicationURL: URL,
        isRunning: Bool,
        targetFrontWindow: Bool = false,
        fallbackToNewWindowIfTargetMissing: Bool = false
    ) async throws {
        let event = try NativeAppleEvent.terminalCommand(
            command: command,
            targetFrontWindow: targetFrontWindow
        )
        guard isRunning else {
            try await openHost(
                applicationURL: applicationURL,
                event: event,
                host: host
            )
            return
        }

        do {
            _ = try eventSender.send(event)
        } catch RawAppleEventError.status(-1728)
            where targetFrontWindow && fallbackToNewWindowIfTargetMissing {
            _ = try sendTerminalEvent(
                NativeAppleEvent.terminalNewWindow(command: command),
                host: host
            )
        } catch RawAppleEventError.status(-1719)
            where targetFrontWindow && fallbackToNewWindowIfTargetMissing {
            _ = try sendTerminalEvent(
                NativeAppleEvent.terminalNewWindow(command: command),
                host: host
            )
        } catch RawAppleEventError.status(-600) {
            try await openHost(
                applicationURL: applicationURL,
                event: event,
                host: host
            )
        } catch let RawAppleEventError.status(status) {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: host
            )
        }
    }

    private func sendTerminalNewTab(
        command: TerminalCommand
    ) async throws {
        let operationLock = try await acquireTerminalTabOperationLock()
        defer { operationLock.release() }

        let wasRunning = applicationState.isRunning(
            bundleIdentifier: TerminalHost.terminal.bundleIdentifier
        )
        let baseline: TerminalSnapshot
        if wasRunning {
            try await requestHostAutomationPermission(.terminal)
            baseline = try await readyTerminalBaseline()
        } else {
            baseline = .empty
        }

        guard terminalService.performNewTab(
            at: command.workspace.fileURL
        ) else {
            throw TerminalAdapterError.terminalTabServiceFailed
        }

        if !wasRunning {
            try await waitForTerminalServiceLaunch(placement: .newTab)
            try await requestHostAutomationPermission(.terminal)
        }
        try await submitTerminalCommand(
            command.line,
            intoTabCreatedAfter: baseline,
            placement: .newTab
        )
        _ = applicationState.activate(
            bundleIdentifier: TerminalHost.terminal.bundleIdentifier
        )
    }

    private func sendTerminalNewWindow(
        command: TerminalCommand
    ) async throws {
        let operationLock = try await acquireTerminalTabOperationLock()
        defer { operationLock.release() }

        guard terminalService.performNewWindow(
            at: command.workspace.fileURL
        ) else {
            throw TerminalAdapterError.terminalWindowServiceFailed
        }

        try await waitForTerminalServiceLaunch(placement: .newWindow)
        try await requestHostAutomationPermission(.terminal)
        try await submitTerminalCommand(
            command.line,
            intoTabCreatedAfter: .empty,
            placement: .newWindow
        )
        _ = applicationState.activate(
            bundleIdentifier: TerminalHost.terminal.bundleIdentifier
        )
    }

    private func acquireTerminalTabOperationLock() async throws
        -> any TerminalTabOperationLock {
        for attempt in 0..<terminalTabPollAttempts {
            if let operationLock = try terminalTabOperationLocker
                .tryAcquire() {
                return operationLock
            }
            if attempt + 1 < terminalTabPollAttempts {
                await terminalTabPollDelay()
            }
        }
        throw TerminalAdapterError.terminalTabOperationBusy
    }

    private func readyTerminalBaseline() async throws -> TerminalSnapshot {
        var previous: TerminalSnapshot?
        var sawNotReadyTTY = false
        for attempt in 0..<terminalTabPollAttempts {
            if attempt > 0 {
                await terminalTabPollDelay()
            }
            guard let current = try terminalSnapshotReader
                .coherentSnapshot() else {
                previous = nil
                continue
            }
            sawNotReadyTTY = sawNotReadyTTY
                || current.notReadyTabCount > 0
            if current == previous, current.notReadyTabCount == 0 {
                return current
            }
            previous = current
        }
        if sawNotReadyTTY {
            throw TerminalAdapterError.terminalBaselineTTYTimedOut
        }
        throw TerminalAdapterError.terminalSnapshotStabilityTimedOut
    }

    private func waitForTerminalServiceLaunch(
        placement: SessionPlacement
    ) async throws {
        let bundleIdentifier = TerminalHost.terminal.bundleIdentifier
        for attempt in 0..<terminalTabPollAttempts {
            if applicationState.isRunning(
                bundleIdentifier: bundleIdentifier
            ) {
                return
            }
            if attempt + 1 < terminalTabPollAttempts {
                await terminalTabPollDelay()
            }
        }
        switch placement {
        case .newTab:
            throw TerminalAdapterError.terminalTabServiceLaunchTimedOut
        case .newWindow:
            throw TerminalAdapterError.terminalWindowServiceLaunchTimedOut
        }
    }

    private func submitTerminalCommand(
        _ command: String,
        intoTabCreatedAfter baseline: TerminalSnapshot,
        placement: SessionPlacement
    ) async throws {
        var previous: TerminalSnapshot?
        var latest = baseline
        var sawGlobalTabIncrease = false
        var sawPendingTTY = false
        var sawUniqueNewTTY = false
        var windowSetChanged = false
        var oldTTYOwnerChanged = false
        var snapshotUnstableAfterService = false

        for attempt in 0..<terminalTabPollAttempts {
            if attempt > 0 {
                await terminalTabPollDelay()
            }
            let current: TerminalSnapshot?
            do {
                current = try terminalSnapshotReader.coherentSnapshot()
            } catch let error as TerminalHandoffError {
                guard error == .appleEventFailure(
                    .terminal,
                    status: NativeAppleEvent.transportFailureStatus
                ) || error == .appleEventFailure(.terminal, status: -10000) else {
                    throw error
                }
                // Snapshots are read-only and can retry after a launch race.
                // Terminal scripting model settling can surface errAEEventFailed;
                // the later targeted command remains intentionally unretried.
                previous = nil
                snapshotUnstableAfterService = true
                continue
            }
            guard let current else {
                previous = nil
                snapshotUnstableAfterService = true
                continue
            }
            latest = current
            let delta = terminalTabDelta(from: baseline, to: current)
            sawGlobalTabIncrease = sawGlobalTabIncrease
                || delta.sawGlobalTabIncrease
            sawPendingTTY = sawPendingTTY || delta.sawPendingTTY
            sawUniqueNewTTY = sawUniqueNewTTY || delta.sawUniqueNewTTY
            windowSetChanged = windowSetChanged || delta.windowSetChanged
            oldTTYOwnerChanged = oldTTYOwnerChanged
                || delta.oldTTYOwnerChanged

            guard current == previous else {
                previous = current
                continue
            }
            switch delta.observation {
            case .unchanged, .pending:
                continue
            case .candidate(let candidate):
                _ = try sendTerminalEvent(
                    try NativeAppleEvent.terminalCommand(
                        command: command,
                        targetTabIndex: candidate.tabIndex,
                        inWindowID: candidate.windowID
                    ),
                    host: .terminal
                )
                return
            case .ambiguous:
                throw terminalCreationError(
                    baseline: baseline,
                    latest: latest,
                    sawGlobalTabIncrease: sawGlobalTabIncrease,
                    sawPendingTTY: sawPendingTTY,
                    sawUniqueNewTTY: sawUniqueNewTTY,
                    windowSetChanged: windowSetChanged,
                    oldTTYOwnerChanged: oldTTYOwnerChanged,
                    snapshotUnstableAfterService:
                        snapshotUnstableAfterService,
                    placement: placement
                )
            }
        }
        throw terminalCreationError(
            baseline: baseline,
            latest: latest,
            sawGlobalTabIncrease: sawGlobalTabIncrease,
            sawPendingTTY: sawPendingTTY,
            sawUniqueNewTTY: sawUniqueNewTTY,
            windowSetChanged: windowSetChanged,
            oldTTYOwnerChanged: oldTTYOwnerChanged,
            snapshotUnstableAfterService: snapshotUnstableAfterService,
            placement: placement
        )
    }

    private func terminalCreationError(
        baseline: TerminalSnapshot,
        latest: TerminalSnapshot,
        sawGlobalTabIncrease: Bool,
        sawPendingTTY: Bool,
        sawUniqueNewTTY: Bool,
        windowSetChanged: Bool,
        oldTTYOwnerChanged: Bool,
        snapshotUnstableAfterService: Bool,
        placement: SessionPlacement
    ) -> TerminalAdapterError {
        let evidence = TerminalTabCreationEvidence(
            initialWindows: baseline.evidence,
            latestWindows: latest.evidence,
            sawGlobalTabIncrease: sawGlobalTabIncrease,
            sawPendingTTY: sawPendingTTY,
            sawUniqueNewTTY: sawUniqueNewTTY,
            windowSetChanged: windowSetChanged,
            oldTTYOwnerChanged: oldTTYOwnerChanged,
            snapshotUnstableAfterService: snapshotUnstableAfterService
        )
        switch placement {
        case .newTab:
            return .terminalTabCreationTimedOut(evidence)
        case .newWindow:
            return .terminalWindowCreationTimedOut(evidence)
        }
    }

    private func sendTerminalEvent(
        _ event: NSAppleEventDescriptor,
        host: TerminalHost
    ) throws -> NSAppleEventDescriptor {
        do {
            return try eventSender.send(event)
        } catch let RawAppleEventError.status(status) {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: host
            )
        }
    }

    private func requestHostAutomationPermission(
        _ host: TerminalHost
    ) async throws {
        let eventClass: UInt32
        let eventID: UInt32
        switch host {
        case .terminal:
            eventClass = TerminalAppleEventContract.terminalDoScriptClass.rawValue
            eventID = TerminalAppleEventContract.terminalDoScriptID.rawValue
        case .iTerm2:
            eventClass = AutomationPermissionRequest.allEvents
            eventID = AutomationPermissionRequest.allEvents
        }
        let status = await eventSender.requestAutomationPermission(
            AutomationPermissionRequest(
                bundleIdentifier: host.bundleIdentifier,
                eventClass: eventClass,
                eventID: eventID
            )
        )
        guard status == noErr else {
            throw TerminalHandoffError.mapAppleEventStatus(status, host: host)
        }
    }

    private func openHost(
        applicationURL: URL,
        event: NSAppleEventDescriptor?,
        host: TerminalHost,
        activates: Bool = true
    ) async throws {
        guard let failure = await applicationOpener.openApplication(
            at: applicationURL,
            initialAppleEvent: event,
            activates: activates
        ) else {
            return
        }
        if let status = failure.appleEventStatus {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: host
            )
        }
        throw TerminalAdapterError.applicationOpenFailed(failure.code)
    }

    private func sendITerm(
        command: String,
        targetFrontWindow: Bool
    ) throws {
        let result: NSAppleEventDescriptor
        do {
            result = try iTermScriptExecutor.execute(
                ITermHandoffScript.invocation(
                    command: command,
                    targetFrontWindow: targetFrontWindow
                )
            )
        } catch let error as TerminalAdapterError {
            switch error {
            case .iTermScriptResourceMissing, .iTermScriptLoadFailed:
                throw error
            default:
                throw TerminalAdapterError.iTermHandoffOutcomeUnknown(nil)
            }
        } catch let RawAppleEventError.status(status)
            where [-1743, -1744].contains(status) {
            throw TerminalHandoffError.mapAppleEventStatus(
                status,
                host: .iTerm2
            )
        } catch let RawAppleEventError.status(status) {
            throw TerminalAdapterError.iTermHandoffOutcomeUnknown(status)
        } catch {
            throw TerminalAdapterError.iTermHandoffOutcomeUnknown(nil)
        }
        guard ITermHandoffScript.isSuccessfulResult(result) else {
            throw TerminalAdapterError.iTermHandoffOutcomeUnknown(nil)
        }
    }
}
