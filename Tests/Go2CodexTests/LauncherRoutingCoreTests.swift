import Testing
@testable import Go2CodexCore

@Suite("Launcher modifier routing")
struct LauncherModifierRoutingTests {
    @Test
    func modifierFlagsAreDistinctAndComposable() {
        let flags: [InvocationModifierFlags] = [
            .option,
            .shift,
            .capsLock,
            .function,
            .command,
            .control,
        ]

        #expect(Set(flags.map(\.rawValue)).count == flags.count)
        #expect(flags.reduce(into: InvocationModifierFlags()) { $0.formUnion($1) }.rawValue == 0b11_1111)
    }

    @Test
    func shiftUsesContainmentWithUnrelatedNonOptionFlags() {
        let unrelated: InvocationModifierFlags = [
            .capsLock,
            .function,
            .command,
            .control,
        ]

        #expect(AlternateTriggerMatcher.matches(.shiftClick, modifiers: [.shift]))
        #expect(AlternateTriggerMatcher.matches(.shiftClick, modifiers: unrelated.union(.shift)))
        #expect(!AlternateTriggerMatcher.matches(.shiftClick, modifiers: unrelated.union(.option)))
        #expect(!AlternateTriggerMatcher.matches(.shiftClick, modifiers: [.option, .shift]))
    }

    @Test
    func disabledNeverMatches() {
        let everyFlag: InvocationModifierFlags = [
            .option,
            .shift,
            .capsLock,
            .function,
            .command,
            .control,
        ]

        #expect(!AlternateTriggerMatcher.matches(.disabled, modifiers: []))
        #expect(!AlternateTriggerMatcher.matches(.disabled, modifiers: everyFlag))
    }
}

@Suite("Launcher invocation gate")
struct LauncherInvocationGateTests {
    @Test
    func onlyTheLifecycleTransitionsAreAccepted() {
        var gate = InvocationGateStateMachine()

        #expect(gate.state == .idle)
        let finishWhileIdle = gate.beginFinishing()
        #expect(!finishWhileIdle)
        #expect(gate.state == .idle)

        let beginWhileIdle = gate.begin()
        #expect(beginWhileIdle)
        #expect(gate.state == .active)
        let beginWhileActive = gate.begin()
        #expect(!beginWhileActive)
        #expect(gate.state == .active)

        let finishWhileActive = gate.beginFinishing()
        #expect(finishWhileActive)
        #expect(gate.state == .finishing)
        let beginWhileFinishing = gate.begin()
        let finishWhileFinishing = gate.beginFinishing()
        #expect(!beginWhileFinishing)
        #expect(!finishWhileFinishing)
        #expect(gate.state == .finishing)
    }

    @Test
    func gateStateCasesRemainCompleteAndStable() {
        #expect(InvocationGateState.allCases == [.idle, .active, .finishing])
    }

    @Test
    func debugInvocationDelayIsDisabledOrBounded() {
        #expect(DebugInvocationDelayPolicy.boundedMilliseconds(Int.min) == nil)
        #expect(DebugInvocationDelayPolicy.boundedMilliseconds(-1) == nil)
        #expect(DebugInvocationDelayPolicy.boundedMilliseconds(0) == nil)
        #expect(DebugInvocationDelayPolicy.boundedMilliseconds(1) == 1)
        #expect(DebugInvocationDelayPolicy.boundedMilliseconds(2_000) == 2_000)
        #expect(
            DebugInvocationDelayPolicy.boundedMilliseconds(Int.max)
                == DebugInvocationDelayPolicy.maximumMilliseconds
        )
    }
}

@Suite("Picker screen point clamping")
struct PickerScreenPointClampingTests {
    @Test
    func pointOnOneScreenIsUnchanged() throws {
        let point = ScreenPoint(x: 40, y: 70)
        let resolved = try ScreenPointClamper.resolve(
            point,
            in: [ScreenRect(x: 0, y: 0, width: 100, height: 100)]
        )

        #expect(resolved == point)
    }

    @Test
    func pointOnASecondScreenIsUnchanged() throws {
        let point = ScreenPoint(x: 260, y: 45)
        let resolved = try ScreenPointClamper.resolve(
            point,
            in: [
                ScreenRect(x: 0, y: 0, width: 100, height: 100),
                ScreenRect(x: 200, y: 0, width: 100, height: 100),
            ]
        )

        #expect(resolved == point)
    }

    @Test
    func negativeCoordinateScreenIsSupported() throws {
        let point = ScreenPoint(x: -500, y: 600)
        let resolved = try ScreenPointClamper.resolve(
            point,
            in: [ScreenRect(x: -1920, y: 0, width: 1920, height: 1080)]
        )

        #expect(resolved == point)
    }

    @Test
    func offscreenPointClampsToTheNearestScreen() throws {
        let frames = [
            ScreenRect(x: -200, y: 0, width: 100, height: 100),
            ScreenRect(x: 100, y: 0, width: 100, height: 100),
        ]

        #expect(try ScreenPointClamper.resolve(
            ScreenPoint(x: 70, y: 140),
            in: frames
        ) == ScreenPoint(x: 100, y: 100))

        #expect(try ScreenPointClamper.resolve(
            ScreenPoint(x: -250, y: -10),
            in: frames
        ) == ScreenPoint(x: -200, y: 0))
    }

    @Test
    func unusableFramesFailClosed() {
        let frames = [
            ScreenRect(x: 0, y: 0, width: 0, height: 100),
            ScreenRect(x: 0, y: 0, width: 100, height: -1),
            ScreenRect(x: .infinity, y: 0, width: 100, height: 100),
        ]

        #expect(capturedRoutingError {
            try ScreenPointClamper.resolve(ScreenPoint(x: 0, y: 0), in: frames)
        } == ScreenPointResolutionError.noUsableScreen)
        #expect(capturedRoutingError {
            try ScreenPointClamper.resolve(ScreenPoint(x: 0, y: 0), in: [])
        } == ScreenPointResolutionError.noUsableScreen)
    }

    @Test
    func nonFinitePointerFailsClosed() {
        let frame = ScreenRect(x: 0, y: 0, width: 100, height: 100)

        #expect(capturedRoutingError {
            try ScreenPointClamper.resolve(ScreenPoint(x: .nan, y: 0), in: [frame])
        } == ScreenPointResolutionError.nonFinitePoint)
    }
}

@Suite("Target picker routing")
struct TargetPickerRoutingTests {
    @Test
    func planKeepsFixedOrderAndMarksDefaultWithoutMovingIt() {
        let plan = TargetPickerPlan(
            defaultTarget: .claudeDesktopCode,
            availability: allTargetsAvailable
        )

        #expect(plan.items.map(\.target) == AgentTargetCatalog.targets)
        #expect(plan.items.map(\.isDefault) == [false, false, true, false])
        #expect(plan.items.map(\.isEnabled) == [true, true, true, true])
    }

    @Test
    func knownAndUnevaluatedUnavailableTargetsStayVisibleAndDisabled() {
        let plan = TargetPickerPlan(
            defaultTarget: .claudeCodeCLI,
            availability: [
                .codexApp: .available,
                .codexCLI: .unavailable(.terminalHostMissing(.terminal)),
                .claudeDesktopCode: .available,
            ]
        )

        #expect(plan.items.map(\.target) == AgentTargetCatalog.targets)
        #expect(plan.items.map(\.isEnabled) == [true, false, true, false])
        #expect(plan.items[1].availability == .unavailable(.terminalHostMissing(.terminal)))
        #expect(plan.items[3].availability == .unavailable(.notEvaluated))
        #expect(plan.items[3].isDefault)
    }

    @Test
    func everyEnabledTargetCanBeSelectedExactlyOnce() throws {
        let plan = TargetPickerPlan(
            defaultTarget: .codexApp,
            availability: allTargetsAvailable
        )

        for (index, target) in AgentTargetCatalog.targets.enumerated() {
            var selection = TargetPickerSelectionStateMachine(plan: plan)
            #expect(try selection.resolve(.select(index: index)) == .selected(target))
            #expect(selection.state == .selected(target))
            #expect(capturedRoutingError {
                try selection.resolve(.select(index: index))
            } == TargetPickerSelectionError.alreadyResolved)
            #expect(selection.state == .selected(target))
        }
    }

    @Test
    func cancellationIsAOneShotResolutionWithoutSelection() throws {
        let plan = TargetPickerPlan(
            defaultTarget: .codexApp,
            availability: allTargetsAvailable
        )
        var selection = TargetPickerSelectionStateMachine(plan: plan)

        #expect(try selection.resolve(.cancel) == .cancelled)
        #expect(selection.state == .cancelled)
        #expect(capturedRoutingError {
            try selection.resolve(.select(index: 0))
        } == TargetPickerSelectionError.alreadyResolved)
        #expect(selection.state == .cancelled)
    }

    @Test
    func invalidIndexConsumesTheSelectionFailClosed() {
        let plan = TargetPickerPlan(
            defaultTarget: .codexApp,
            availability: allTargetsAvailable
        )
        var selection = TargetPickerSelectionStateMachine(plan: plan)

        #expect(capturedRoutingError {
            try selection.resolve(.select(index: -1))
        } == TargetPickerSelectionError.invalidIndex(-1))
        #expect(selection.state == .rejected(.invalidIndex(-1)))
        #expect(capturedRoutingError {
            try selection.resolve(.select(index: plan.items.count))
        } == TargetPickerSelectionError.alreadyResolved)
    }

    @Test
    func disabledTargetConsumesTheSelectionFailClosed() {
        let plan = TargetPickerPlan(
            defaultTarget: .codexApp,
            availability: [
                .codexApp: .available,
                .codexCLI: .unavailable(.terminalHostMissing(.terminal)),
                .claudeDesktopCode: .available,
                .claudeCodeCLI: .available,
            ]
        )
        var selection = TargetPickerSelectionStateMachine(plan: plan)

        #expect(capturedRoutingError {
            try selection.resolve(.select(index: 1))
        } == TargetPickerSelectionError.unavailableTarget(.codexCLI))
        #expect(selection.state == .rejected(.unavailableTarget(.codexCLI)))
        #expect(capturedRoutingError {
            try selection.resolve(.select(index: 0))
        } == TargetPickerSelectionError.alreadyResolved)
    }
}

@Suite("Terminal placement routing")
struct TerminalPlacementRoutingTests {
    @Test
    func everyHostPlacementAndWindowStateHasAnExplicitPlan() {
        #expect(TerminalPlacementPlanner.plan(
            for: .terminal,
            placement: .newTab,
            hasWindow: true
        ) == .createWindow)
        #expect(TerminalPlacementPlanner.plan(
            for: .terminal,
            placement: .newTab,
            hasWindow: false
        ) == .createWindow)
        #expect(TerminalPlacementPlanner.plan(
            for: .terminal,
            placement: .newWindow,
            hasWindow: true
        ) == .createWindow)
        #expect(TerminalPlacementPlanner.plan(
            for: .terminal,
            placement: .newWindow,
            hasWindow: false
        ) == .createWindow)

        #expect(TerminalPlacementPlanner.plan(
            for: .iTerm2,
            placement: .newTab,
            hasWindow: true
        ) == .createTabInFrontWindow)
        #expect(TerminalPlacementPlanner.plan(
            for: .iTerm2,
            placement: .newTab,
            hasWindow: false
        ) == .createWindow)
        #expect(TerminalPlacementPlanner.plan(
            for: .iTerm2,
            placement: .newWindow,
            hasWindow: true
        ) == .createWindow)
        #expect(TerminalPlacementPlanner.plan(
            for: .iTerm2,
            placement: .newWindow,
            hasWindow: false
        ) == .createWindow)
    }
}

private let allTargetsAvailable = Dictionary(
    uniqueKeysWithValues: AgentTargetCatalog.targets.map { ($0, TargetAvailability.available) }
)

private func capturedRoutingError<T, E: Error & Equatable>(
    _ operation: () throws -> T
) -> E? {
    do {
        _ = try operation()
        return nil
    } catch let error as E {
        return error
    } catch {
        return nil
    }
}
