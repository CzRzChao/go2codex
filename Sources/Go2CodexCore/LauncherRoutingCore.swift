public struct InvocationModifierFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let option = InvocationModifierFlags(rawValue: 1 << 0)
    public static let shift = InvocationModifierFlags(rawValue: 1 << 1)
    public static let capsLock = InvocationModifierFlags(rawValue: 1 << 2)
    public static let function = InvocationModifierFlags(rawValue: 1 << 3)
    public static let command = InvocationModifierFlags(rawValue: 1 << 4)
    public static let control = InvocationModifierFlags(rawValue: 1 << 5)
}

public enum AlternateTriggerMatcher {
    public static func matches(
        _ trigger: AlternateTrigger,
        modifiers: InvocationModifierFlags
    ) -> Bool {
        guard !modifiers.contains(.option) else {
            return false
        }
        return switch trigger {
        case .shiftClick:
            modifiers.contains(.shift)
        case .disabled:
            false
        }
    }
}

public enum InvocationGateState: String, CaseIterable, Equatable, Sendable {
    case idle
    case active
    case finishing
}

public struct InvocationGateStateMachine: Equatable, Sendable {
    public private(set) var state: InvocationGateState

    public init() {
        state = .idle
    }

    @discardableResult
    public mutating func begin() -> Bool {
        guard state == .idle else {
            return false
        }
        state = .active
        return true
    }

    @discardableResult
    public mutating func beginFinishing() -> Bool {
        guard state == .active else {
            return false
        }
        state = .finishing
        return true
    }
}

public enum DebugInvocationDelayPolicy {
    public static let maximumMilliseconds = 5_000

    public static func boundedMilliseconds(_ value: Int) -> Int? {
        guard value > 0 else {
            return nil
        }
        return min(value, maximumMilliseconds)
    }
}

public struct ScreenPoint: Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}

public struct ScreenRect: Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public var isUsable: Bool {
        x.isFinite
            && y.isFinite
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
            && maxX.isFinite
            && maxY.isFinite
    }

    public func contains(_ point: ScreenPoint) -> Bool {
        isUsable
            && point.x >= minX
            && point.x <= maxX
            && point.y >= minY
            && point.y <= maxY
    }

    public func clamped(_ point: ScreenPoint) -> ScreenPoint {
        ScreenPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }
}

public enum ScreenPointResolutionError: Error, Equatable, Sendable {
    case nonFinitePoint
    case noUsableScreen
}

public enum ScreenPointClamper {
    public static func resolve(
        _ point: ScreenPoint,
        in visibleFrames: [ScreenRect]
    ) throws -> ScreenPoint {
        guard point.isFinite else {
            throw ScreenPointResolutionError.nonFinitePoint
        }

        let usableFrames = visibleFrames.filter(\.isUsable)
        guard !usableFrames.isEmpty else {
            throw ScreenPointResolutionError.noUsableScreen
        }

        if usableFrames.contains(where: { $0.contains(point) }) {
            return point
        }

        let firstPoint = usableFrames[0].clamped(point)
        let firstDeltaX = firstPoint.x - point.x
        let firstDeltaY = firstPoint.y - point.y
        var nearestPoint = firstPoint
        var nearestSquaredDistance = firstDeltaX * firstDeltaX + firstDeltaY * firstDeltaY
        for frame in usableFrames.dropFirst() {
            let candidate = frame.clamped(point)
            let deltaX = candidate.x - point.x
            let deltaY = candidate.y - point.y
            let squaredDistance = deltaX * deltaX + deltaY * deltaY
            if squaredDistance < nearestSquaredDistance {
                nearestPoint = candidate
                nearestSquaredDistance = squaredDistance
            }
        }

        return nearestPoint
    }
}

public struct TargetPickerPlan: Equatable, Sendable {
    public let items: [TargetCatalogItem]

    public init(
        defaultTarget: AgentTarget,
        availability: [AgentTarget: TargetAvailability]
    ) {
        items = AgentTargetCatalog.items(
            defaultTarget: defaultTarget,
            availability: availability
        )
    }
}

public enum TargetPickerAction: Equatable, Sendable {
    case select(index: Int)
    case cancel
}

public enum TargetPickerSelectionResult: Equatable, Sendable {
    case selected(AgentTarget)
    case cancelled
}

public enum TargetPickerSelectionError: Error, Equatable, Sendable,
    DiagnosticCodeProviding {
    case invalidIndex(Int)
    case unavailableTarget(AgentTarget)
    case alreadyResolved

    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .invalidIndex:
            DiagnosticCode(rawValue: "target-picker-invalid-selection")
        case .unavailableTarget:
            DiagnosticCode(rawValue: "target-picker-unavailable-selection")
        case .alreadyResolved:
            DiagnosticCode(rawValue: "target-picker-already-resolved")
        }
    }
}

public enum TargetPickerSelectionState: Equatable, Sendable {
    case awaitingSelection
    case selected(AgentTarget)
    case cancelled
    case rejected(TargetPickerSelectionError)
}

public struct TargetPickerSelectionStateMachine: Equatable, Sendable {
    public let plan: TargetPickerPlan
    public private(set) var state: TargetPickerSelectionState

    public init(plan: TargetPickerPlan) {
        self.plan = plan
        state = .awaitingSelection
    }

    public mutating func resolve(
        _ action: TargetPickerAction
    ) throws -> TargetPickerSelectionResult {
        guard state == .awaitingSelection else {
            throw TargetPickerSelectionError.alreadyResolved
        }

        switch action {
        case .cancel:
            state = .cancelled
            return .cancelled
        case .select(let index):
            guard plan.items.indices.contains(index) else {
                let error = TargetPickerSelectionError.invalidIndex(index)
                state = .rejected(error)
                throw error
            }

            let item = plan.items[index]
            guard item.isEnabled else {
                let error = TargetPickerSelectionError.unavailableTarget(item.target)
                state = .rejected(error)
                throw error
            }

            state = .selected(item.target)
            return .selected(item.target)
        }
    }
}

public enum TerminalPlacementPlan: Equatable, Sendable {
    case createTabInFrontWindow
    case createWindow
    case unsupported(host: TerminalHost, placement: SessionPlacement)
}

public enum TerminalPlacementPlanner {
    public static func plan(
        for host: TerminalHost,
        placement: SessionPlacement,
        hasWindow: Bool
    ) -> TerminalPlacementPlan {
        switch (host, placement, hasWindow) {
        case (.iTerm2, .newTab, true):
            .createTabInFrontWindow
        default:
            .createWindow
        }
    }
}
