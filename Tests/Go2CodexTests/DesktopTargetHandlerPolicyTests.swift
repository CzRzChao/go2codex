import Foundation
import Testing
@testable import Go2CodexCore

@Suite
struct DesktopTargetHandlerPolicyTests {
    @Test
    func onlyTheExpectedDesktopApplicationCanOwnEachHandoff() throws {
        #expect(
            try DesktopTargetHandlerPolicy.expectedBundleIdentifier(for: .codexApp)
                == "com.openai.codex"
        )
        #expect(
            try DesktopTargetHandlerPolicy.expectedBundleIdentifier(for: .claudeDesktopCode)
                == "com.anthropic.claudefordesktop"
        )
        #expect(
            try DesktopTargetHandlerPolicy.expectedBundleIdentifier(for: .cursorApp)
                == "com.todesktop.230313mzl4w4u92"
        )
        #expect(
            DesktopTargetHandlerPolicy.accepts(
                target: .codexApp,
                handlerBundleIdentifier: "com.openai.codex"
            )
        )
        #expect(
            DesktopTargetHandlerPolicy.accepts(
                target: .claudeDesktopCode,
                handlerBundleIdentifier: "com.anthropic.claudefordesktop"
            )
        )
        #expect(
            DesktopTargetHandlerPolicy.accepts(
                target: .cursorApp,
                handlerBundleIdentifier: "com.todesktop.230313mzl4w4u92"
            )
        )
        #expect(
            !DesktopTargetHandlerPolicy.accepts(
                target: .codexApp,
                handlerBundleIdentifier: "com.example.codex-handler"
            )
        )
        #expect(
            !DesktopTargetHandlerPolicy.accepts(
                target: .claudeDesktopCode,
                handlerBundleIdentifier: nil
            )
        )
        #expect(
            !DesktopTargetHandlerPolicy.accepts(
                target: .cursorApp,
                handlerBundleIdentifier: "com.todesktop.cursor-nightly"
            )
        )
    }

    @Test
    func cliTargetsCanNeverPassTheDesktopHandlerPolicy() {
        for target in [AgentTarget.codexCLI, .claudeCodeCLI, .cursorCLI] {
            #expect(throws: DesktopURLBuildError.unsupportedTarget(target)) {
                try DesktopTargetHandlerPolicy.expectedBundleIdentifier(for: target)
            }
            #expect(
                !DesktopTargetHandlerPolicy.accepts(
                    target: target,
                    handlerBundleIdentifier: "com.openai.codex"
                )
            )
        }
    }

    @Test
    func verifiedHandlerBindsTheExactLookupURLForSubmission() {
        let codexURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let verified = DesktopTargetHandlerPolicy.verify(
            target: .codexApp,
            applicationURL: codexURL,
            handlerBundleIdentifier: "com.openai.codex"
        )

        #expect(verified?.applicationURL == codexURL)
        #expect(DesktopTargetHandlerPolicy.verify(
            target: .codexApp,
            applicationURL: codexURL,
            handlerBundleIdentifier: "com.example.scheme-claimant"
        ) == nil)
        #expect(DesktopTargetHandlerPolicy.verify(
            target: .codexApp,
            applicationURL: URL(string: "https://example.com/Codex.app"),
            handlerBundleIdentifier: "com.openai.codex"
        ) == nil)
        #expect(DesktopTargetHandlerPolicy.verify(
            target: .codexApp,
            applicationURL: nil,
            handlerBundleIdentifier: "com.openai.codex"
        ) == nil)

        let cursorURL = URL(fileURLWithPath: "/Applications/Cursor.app")
        #expect(DesktopTargetHandlerPolicy.verify(
            target: .cursorApp,
            applicationURL: cursorURL,
            handlerBundleIdentifier: "com.todesktop.230313mzl4w4u92"
        )?.applicationURL == cursorURL)
        #expect(DesktopTargetHandlerPolicy.verify(
            target: .cursorApp,
            applicationURL: cursorURL,
            handlerBundleIdentifier: "com.todesktop.cursor-nightly"
        ) == nil)
    }
}
