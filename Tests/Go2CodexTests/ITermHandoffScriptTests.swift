import Foundation
import Testing

@Suite("iTerm handoff script contracts")
@MainActor
struct ITermHandoffScriptTests {
    @Test(arguments: scriptInvocationCases)
    func invocationUsesOneExactTextArgument(
        testCase: ScriptInvocationCase
    ) throws {
        let event = ITermHandoffScript.invocation(
            command: adversarialCommand,
            targetFrontWindow: testCase.targetFrontWindow
        )

        #expect(event.eventClass == code("ascr"))
        #expect(event.eventID == code("psbr"))
        #expect(event.paramDescriptor(
            forKeyword: ITermHandoffScript.subroutineNameKeyword
        )?.stringValue == testCase.expectedHandler)

        let arguments = try #require(event.paramDescriptor(
            forKeyword: ITermHandoffScript.directObjectKeyword
        ))
        #expect(arguments.descriptorType == code("list"))
        #expect(arguments.numberOfItems == 1)
        let command = try #require(arguments.atIndex(1))
        #expect(command.descriptorType == code("utxt"))
        #expect(command.stringValue == adversarialCommand)
    }

    @Test
    func resultMustBeExplicitBooleanTrue() throws {
        #expect(ITermHandoffScript.isSuccessfulResult(
            .init(boolean: true)
        ))
        let appleScriptTrue = try #require(NSAppleEventDescriptor(
            descriptorType: code("true"),
            data: Data()
        ))
        #expect(ITermHandoffScript.isSuccessfulResult(
            appleScriptTrue
        ))
        #expect(!ITermHandoffScript.isSuccessfulResult(
            .init(boolean: false)
        ))
        #expect(!ITermHandoffScript.isSuccessfulResult(
            .init(string: "true")
        ))
    }

    @Test
    func bundledCompiledScriptIsPresentAndLoadable() throws {
        let bundle = Bundle(for: ITermHandoffScriptTestBundleMarker.self)
        let executor = BundledITermHandoffScriptExecutor(bundle: bundle)

        let script = try executor.loadScript()

        #expect(script.isCompiled)
    }

    @Test
    func missingAndInvalidResourcesFailBeforeExecution() {
        #expect(capturedAdapterError {
            try BundledITermHandoffScriptExecutor(
                resourceURL: nil
            ).loadScript()
        } == .iTermScriptResourceMissing)
        #expect(capturedAdapterError {
            try BundledITermHandoffScriptExecutor(
                resourceURL: URL(fileURLWithPath: #filePath)
            ).loadScript()
        } == .iTermScriptLoadFailed)
    }
}

private final class ITermHandoffScriptTestBundleMarker: NSObject {}

struct ScriptInvocationCase: Sendable, CustomTestStringConvertible {
    let targetFrontWindow: Bool
    let expectedHandler: String

    var testDescription: String {
        expectedHandler
    }
}

private let scriptInvocationCases = [
    ScriptInvocationCase(
        targetFrontWindow: false,
        expectedHandler: "go2codexNewWindow"
    ),
    ScriptInvocationCase(
        targetFrontWindow: true,
        expectedHandler: "go2codexNewTab"
    ),
]

private let adversarialCommand = """
cd '/tmp/quote' && printf "a\\nb"; error number -999 -- $HOME `whoami`
"""

private func code(_ value: String) -> UInt32 {
    precondition(value.utf8.count == 4)
    return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

@MainActor
private func capturedAdapterError<T>(
    _ operation: @MainActor () throws -> T
) -> TerminalAdapterError? {
    do {
        _ = try operation()
        return nil
    } catch let error as TerminalAdapterError {
        return error
    } catch {
        return nil
    }
}
