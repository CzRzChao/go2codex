import Foundation
import Testing
@testable import Go2CodexCore

@Suite("M3 Domain")
struct M3DomainTests {
    @Test
    func enumCasesAndFixedCatalogOrder() {
        #expect(AgentTarget.allCases == [
            .codexApp,
            .codexCLI,
            .claudeDesktopCode,
            .claudeCodeCLI,
        ])
        #expect(AgentTargetCatalog.targets == AgentTarget.allCases)
        #expect(TerminalHost.allCases == [.terminal, .iTerm2])
        #expect(SessionPlacement.allCases == [.newTab, .newWindow])
        #expect(AlternateTrigger.allCases == [.shiftClick, .disabled])
        #expect(CLIExecutable.allCases == [.codex, .claude])
        #expect(ProductVariant.allCases == [.debug, .release])
        #expect(DiagnosticPolicy.allCases == [.debug, .release])
        #expect(DiagnosticStage.allCases == [
            .preferencesRead,
            .preferencesWrite,
            .settingsOpen,
            .launcherInternal,
            .finderWorkspace,
            .targetAvailability,
            .desktopURL,
            .desktopHandoff,
            .terminalCommand,
            .terminalHandoff,
            .targetPicker,
            .finderToolbarStatus,
            .finderToolbarMutation,
            .transaction,
        ])
    }

    @Test
    func targetKindsAndNamesAreStable() {
        #expect(AgentTarget.codexApp.kind == .desktop)
        #expect(AgentTarget.codexCLI.kind == .cli)
        #expect(AgentTarget.claudeDesktopCode.kind == .desktop)
        #expect(AgentTarget.claudeCodeCLI.kind == .cli)
        #expect(AgentTargetCatalog.targets.map(\.displayName) == [
            "Codex App",
            "Codex CLI",
            "Claude Desktop Code",
            "Claude Code CLI",
        ])
        #expect(TerminalHost.terminal.bundleIdentifier == "com.apple.Terminal")
        #expect(TerminalHost.iTerm2.bundleIdentifier == "com.googlecode.iterm2")
    }

    @Test
    func catalogMarksWithoutReorderingAndFailsClosedWhenNotEvaluated() {
        let items = AgentTargetCatalog.items(
            defaultTarget: .claudeDesktopCode,
            availability: [
                .codexApp: .available,
                .codexCLI: .unavailable(.terminalHostMissing(.terminal)),
                .claudeDesktopCode: .available,
            ]
        )

        #expect(items.map(\.target) == AgentTargetCatalog.targets)
        #expect(items.map(\.isDefault) == [false, false, true, false])
        #expect(items.map(\.isEnabled) == [true, false, true, false])
        #expect(items[3].availability == .unavailable(.notEvaluated))
    }

    @Test
    func workspaceRequiresAnAbsoluteFilePath() throws {
        let workspace = try Workspace(absolutePath: "/Volumes/外置盘/项目 😀")
        #expect(workspace.path == "/Volumes/外置盘/项目 😀")
        #expect(try Workspace(absolutePath: "/").path == "/")
        let empty: WorkspaceValidationError? = capturedError {
            try Workspace(absolutePath: "")
        }
        let relative: WorkspaceValidationError? = capturedError {
            try Workspace(absolutePath: "relative")
        }
        let invalid: WorkspaceValidationError? = capturedError {
            try Workspace(absolutePath: "/bad\0path")
        }
        let nonFile: WorkspaceValidationError? = capturedError {
            try Workspace(fileURL: URL(string: "https://example.com")!)
        }
        #expect(empty == .emptyPath)
        #expect(relative == .nonAbsolutePath)
        #expect(invalid == .invalidPath)
        #expect(nonFile == .nonFileURL)
    }

    @Test
    func availabilityUsesOnlyMatchingEvidence() throws {
        #expect(try TargetAvailabilityClassifier.classify(
            target: .codexApp,
            evidence: .desktopURLHandler(isRegistered: true)
        ) == .available)
        #expect(try TargetAvailabilityClassifier.classify(
            target: .claudeDesktopCode,
            evidence: .desktopURLHandler(isRegistered: false)
        ) == .unavailable(.desktopHandlerMissing(.claudeDesktopCode)))
        #expect(try TargetAvailabilityClassifier.classify(
            target: .codexCLI,
            evidence: .terminalHost(.terminal, isRegistered: true)
        ) == .available)
        #expect(try TargetAvailabilityClassifier.classify(
            target: .claudeCodeCLI,
            evidence: .terminalHost(.iTerm2, isRegistered: false)
        ) == .unavailable(.terminalHostMissing(.iTerm2)))

        let error: AvailabilityClassificationError? = capturedError {
            try TargetAvailabilityClassifier.classify(
                target: .codexApp,
                evidence: .terminalHost(.terminal, isRegistered: true)
            )
        }
        #expect(error == .evidenceDoesNotMatchTarget(.codexApp))
    }

    @Test
    func launchRequestNeverFallsBack() throws {
        let workspace = try Workspace(absolutePath: "/tmp/project")
        let request = try LaunchRequest(
            workspace: workspace,
            target: .claudeCodeCLI,
            terminalHost: .iTerm2,
            sessionPlacement: .newWindow,
            availability: .available
        )
        #expect(request.target == .claudeCodeCLI)
        #expect(request.terminalHost == .iTerm2)

        let error: LaunchPlanningError? = capturedError {
            try LaunchRequest(
                workspace: workspace,
                target: .claudeCodeCLI,
                terminalHost: .iTerm2,
                sessionPlacement: .newWindow,
                availability: .unavailable(.terminalHostMissing(.iTerm2))
            )
        }
        #expect(error == .targetUnavailable(.claudeCodeCLI, .terminalHostMissing(.iTerm2)))
    }
}

@Suite("M3 Preferences")
struct M3PreferencesTests {
    @Test
    func productVariantsUseIsolatedSuites() {
        #expect(ProductVariant.debug.preferencesSuiteName == "io.github.czrzchao.go2codex.debug")
        #expect(ProductVariant.release.preferencesSuiteName == "io.github.czrzchao.go2codex")
        #expect(ProductVariant.debug.preferencesSuiteName != ProductVariant.release.preferencesSuiteName)
        #expect(PreferencesStorageKey.envelope == "PreferencesEnvelope")
    }

    @Test
    func codecRoundTripsACompleteEnvelope() throws {
        let codec = PreferencesCodec()
        let envelope = PreferencesEnvelope(
            defaultTarget: .claudeDesktopCode,
            alternateTrigger: .shiftClick,
            defaultTerminalHost: .iTerm2,
            sessionPlacement: .newWindow
        )

        let data = try codec.encode(envelope)
        #expect(codec.decode(data) == .configured(envelope))
        #expect(!codec.decodeOutcome(data).requiresCanonicalRewrite)
        #expect(envelope.schemaVersion == 1)
        #expect(envelope.firstRunCompletion == .completed)
    }

    @Test
    func codecRejectsEncodingAnUnsupportedSchema() throws {
        let futureEnvelope = try JSONDecoder().decode(
            PreferencesEnvelope.self,
            from: Data("""
            {
              "schemaVersion": 2,
              "firstRunCompletion": "completed",
              "defaultTarget": "codex-app",
              "alternateTrigger": "shift-click",
              "defaultTerminalHost": "terminal-app",
              "sessionPlacement": "new-tab"
            }
            """.utf8)
        )

        let error: PreferencesCodecError? = capturedError {
            try PreferencesCodec().encode(futureEnvelope)
        }
        #expect(error == .unsupportedSchema(2))
    }

    @Test
    func codecMigratesLegacyOptionClickToShiftClick() throws {
        let legacyData = Data("""
        {
          "schemaVersion": 1,
          "firstRunCompletion": "completed",
          "defaultTarget": "codex-app",
          "alternateTrigger": "option-click",
          "defaultTerminalHost": "iterm2",
          "sessionPlacement": "new-tab"
        }
        """.utf8)

        let outcome = PreferencesCodec().decodeOutcome(legacyData)
        #expect(outcome.requiresCanonicalRewrite)
        guard case let .configured(envelope) = outcome.state else {
            Issue.record("Expected the legacy preference to migrate")
            return
        }
        #expect(envelope.alternateTrigger == .shiftClick)

        let canonicalData = try PreferencesCodec().encode(envelope)
        let canonicalText = try #require(String(data: canonicalData, encoding: .utf8))
        #expect(canonicalText.contains("\"alternateTrigger\":\"shift-click\""))
        #expect(!canonicalText.contains("option-click"))
    }

    @Test
    func codecClassifiesMissingCorruptIncompleteAndUnknownSchemas() throws {
        let codec = PreferencesCodec()
        #expect(codec.decode(nil) == .firstRun)
        #expect(codec.decode(Data("not-json".utf8)) == .recoveryRequired(.corruptData))
        #expect(codec.decode(Data("{}".utf8)) == .recoveryRequired(.missingRequiredFields))
        #expect(codec.decode(Data("{\"schemaVersion\":1}".utf8)) == .recoveryRequired(.missingRequiredFields))
        #expect(codec.decode(Data("{\"schemaVersion\":2}".utf8)) == .recoveryRequired(.unsupportedSchema(2)))
        #expect(codec.decode(Data("{\"schemaVersion\":0}".utf8)) == .recoveryRequired(.unsupportedSchema(0)))

        let nullRequiredValue = Data("""
        {
          "schemaVersion": 1,
          "firstRunCompletion": "completed",
          "defaultTarget": null,
          "alternateTrigger": "shift-click",
          "defaultTerminalHost": "terminal-app",
          "sessionPlacement": "new-tab"
        }
        """.utf8)
        #expect(codec.decode(nullRequiredValue) == .recoveryRequired(.missingRequiredFields))

        let unknownTarget = Data("""
        {
          "schemaVersion": 1,
          "firstRunCompletion": "completed",
          "defaultTarget": "future-target",
          "alternateTrigger": "shift-click",
          "defaultTerminalHost": "terminal-app",
          "sessionPlacement": "new-tab"
        }
        """.utf8)
        #expect(codec.decode(unknownTarget) == .recoveryRequired(.corruptData))
    }

    @Test
    func firstRunRequiresBothExplicitValuesAtOnce() {
        let missingBoth: PreferencesTransitionError? = capturedError {
            try PreferencesStateMachine.completeFirstRun(
                from: .firstRun,
                selection: FirstRunSelection()
            )
        }
        #expect(missingBoth == .missingRequiredValues([.defaultTarget, .defaultTerminalHost]))

        let missingHost: PreferencesTransitionError? = capturedError {
            try PreferencesStateMachine.completeFirstRun(
                from: .firstRun,
                selection: FirstRunSelection(defaultTarget: .codexApp)
            )
        }
        #expect(missingHost == .missingRequiredValues([.defaultTerminalHost]))

        let missingTarget: PreferencesTransitionError? = capturedError {
            try PreferencesStateMachine.completeFirstRun(
                from: .firstRun,
                selection: FirstRunSelection(defaultTerminalHost: .iTerm2)
            )
        }
        #expect(missingTarget == .missingRequiredValues([.defaultTarget]))
    }

    @Test
    func firstRunCompletionAndEveryLaterEditAreDeterministic() throws {
        let envelope = try PreferencesStateMachine.completeFirstRun(
            from: .firstRun,
            selection: FirstRunSelection(
                defaultTarget: .codexCLI,
                defaultTerminalHost: .terminal
            )
        )
        #expect(envelope.defaultTarget == .codexCLI)
        #expect(envelope.defaultTerminalHost == .terminal)
        #expect(envelope.alternateTrigger == .shiftClick)
        #expect(envelope.sessionPlacement == .newTab)

        var state = PreferencesLoadState.configured(envelope)
        let edits: [PreferencesChange] = [
            PreferencesChange(defaultTarget: .claudeCodeCLI),
            PreferencesChange(alternateTrigger: .shiftClick),
            PreferencesChange(defaultTerminalHost: .iTerm2),
            PreferencesChange(sessionPlacement: .newWindow),
        ]
        for edit in edits {
            state = .configured(try PreferencesStateMachine.apply(edit, to: state))
        }

        guard case let .configured(updated) = state else {
            Issue.record("Expected configured preferences")
            return
        }
        #expect(updated.defaultTarget == .claudeCodeCLI)
        #expect(updated.alternateTrigger == .shiftClick)
        #expect(updated.defaultTerminalHost == .iTerm2)
        #expect(updated.sessionPlacement == .newWindow)
    }

    @Test
    func invalidStateTransitionsFailClosed() {
        let configured = PreferencesEnvelope(
            defaultTarget: .codexApp,
            alternateTrigger: .shiftClick,
            defaultTerminalHost: .terminal,
            sessionPlacement: .newTab
        )
        let alreadyCompleted: PreferencesTransitionError? = capturedError {
            try PreferencesStateMachine.completeFirstRun(
                from: .configured(configured),
                selection: FirstRunSelection(
                    defaultTarget: .codexApp,
                    defaultTerminalHost: .terminal
                )
            )
        }
        #expect(alreadyCompleted == .firstRunAlreadyCompleted)

        let editBeforeCompletion: PreferencesTransitionError? = capturedError {
            try PreferencesStateMachine.apply(PreferencesChange(defaultTarget: .codexCLI), to: .firstRun)
        }
        #expect(editBeforeCompletion == .configurationRequired)

        let recoveryCompletion: PreferencesTransitionError? = capturedError {
            try PreferencesStateMachine.completeFirstRun(
                from: .recoveryRequired(.unsupportedSchema(3)),
                selection: FirstRunSelection(
                    defaultTarget: .codexApp,
                    defaultTerminalHost: .terminal
                )
            )
        }
        #expect(recoveryCompletion == .recoveryRequired(.unsupportedSchema(3)))

        let recoveryEdit: PreferencesTransitionError? = capturedError {
            try PreferencesStateMachine.apply(
                PreferencesChange(sessionPlacement: .newWindow),
                to: .recoveryRequired(.corruptData)
            )
        }
        #expect(recoveryEdit == .recoveryRequired(.corruptData))
    }

    @Test
    func repositoryCommitsOneCompleteEnvelopeAndReplacesOnEdit() async throws {
        let store = PreferencesStoreFake()
        let repository = PreferencesRepository(store: store)

        do {
            _ = try await repository.completeFirstRun(
                selection: FirstRunSelection(defaultTarget: .codexApp)
            )
            Issue.record("Expected incomplete First Run to fail")
        } catch let error as PreferencesTransitionError {
            #expect(error == .missingRequiredValues([.defaultTerminalHost]))
        }
        #expect(await store.writeCount == 0)

        let envelope = try await repository.completeFirstRun(
            selection: FirstRunSelection(
                defaultTarget: .codexApp,
                defaultTerminalHost: .terminal
            )
        )
        #expect(await store.writeCount == 1)
        #expect(await repository.load() == .configured(envelope))

        let updated = try await repository.update(
            PreferencesChange(
                defaultTarget: .claudeDesktopCode,
                alternateTrigger: .disabled,
                defaultTerminalHost: .iTerm2,
                sessionPlacement: .newWindow
            )
        )
        #expect(await store.writeCount == 2)
        #expect(await repository.load() == .configured(updated))
    }

    @Test
    func repositoryMapsReadFailureToRecovery() async {
        let store = PreferencesStoreFake(failReads: true)
        let repository = PreferencesRepository(store: store)
        #expect(await repository.load() == .recoveryRequired(.storageReadFailed))
    }

    @Test
    func repositoryPropagatesStoreWriteFailureWithoutCommitting() async {
        let store = PreferencesStoreFake(failWrites: true)
        let repository = PreferencesRepository(store: store)

        do {
            _ = try await repository.completeFirstRun(
                selection: FirstRunSelection(
                    defaultTarget: .codexApp,
                    defaultTerminalHost: .terminal
                )
            )
            Issue.record("Expected store write to fail")
        } catch let error as PreferencesStoreError {
            #expect(error == .writeFailed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await store.writeCount == 0)
        #expect(await repository.load() == .firstRun)
    }

    @Test
    func synchronousWriteVerificationFailsClosedOnSynchronizationAndReadback() throws {
        let expected = Data("complete-envelope".utf8)

        try PreferencesWriteVerifier.verify(
            synchronizationSucceeded: true,
            expectedData: expected,
            readbackData: expected
        )

        let synchronizationFailure: PreferencesStoreError? = capturedError {
            try PreferencesWriteVerifier.verify(
                synchronizationSucceeded: false,
                expectedData: expected,
                readbackData: expected
            )
        }
        let missingReadback: PreferencesStoreError? = capturedError {
            try PreferencesWriteVerifier.verify(
                synchronizationSucceeded: true,
                expectedData: expected,
                readbackData: nil
            )
        }
        let mismatchedReadback: PreferencesStoreError? = capturedError {
            try PreferencesWriteVerifier.verify(
                synchronizationSucceeded: true,
                expectedData: expected,
                readbackData: Data("partial-envelope".utf8)
            )
        }

        #expect(synchronizationFailure == .writeFailed)
        #expect(missingReadback == .writeFailed)
        #expect(mismatchedReadback == .writeFailed)
        #expect(PreferencesWriteVerifier.restorationSucceeded(
            synchronizationSucceeded: true,
            expectedData: expected,
            readbackData: expected,
            keyIsPresent: true
        ))
        #expect(PreferencesWriteVerifier.restorationSucceeded(
            synchronizationSucceeded: true,
            expectedData: nil,
            readbackData: nil,
            keyIsPresent: false
        ))
        #expect(!PreferencesWriteVerifier.restorationSucceeded(
            synchronizationSucceeded: false,
            expectedData: expected,
            readbackData: expected,
            keyIsPresent: true
        ))
        #expect(!PreferencesWriteVerifier.restorationSucceeded(
            synchronizationSucceeded: true,
            expectedData: nil,
            readbackData: nil,
            keyIsPresent: true
        ))
    }
}

@Suite("M3 Handoff Encoding")
struct M3HandoffEncodingTests {
    @Test
    func desktopContractsAreExact() throws {
        #expect(try DesktopURLBuilder.contract(for: .codexApp) == DesktopURLContract(
            scheme: "codex",
            host: "new",
            path: "",
            workspaceQueryName: "path"
        ))
        #expect(try DesktopURLBuilder.contract(for: .claudeDesktopCode) == DesktopURLContract(
            scheme: "claude",
            host: "code",
            path: "/new",
            workspaceQueryName: "folder"
        ))

        let codexError: DesktopURLBuildError? = capturedError {
            try DesktopURLBuilder.contract(for: .codexCLI)
        }
        let claudeError: DesktopURLBuildError? = capturedError {
            try DesktopURLBuilder.contract(for: .claudeCodeCLI)
        }
        #expect(codexError == .unsupportedTarget(.codexCLI))
        #expect(claudeError == .unsupportedTarget(.claudeCodeCLI))
    }

    @Test
    func desktopURLsRoundTripEverySensitivePathCharacterOnce() throws {
        let workspace = try Workspace(
            absolutePath: "/tmp/space apostrophe' plus+ hash# percent% ampersand& question? 中文 😀"
        )
        for target in [AgentTarget.codexApp, .claudeDesktopCode] {
            let contract = try DesktopURLBuilder.contract(for: target)
            let url = try DesktopURLBuilder.url(for: target, workspace: workspace)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let items = try #require(components.queryItems)
            #expect(components.scheme == contract.scheme)
            #expect(components.host == contract.host)
            #expect(components.path == contract.path)
            #expect(items.count == 1)
            #expect(items[0].name == contract.workspaceQueryName)
            #expect(items[0].value == workspace.path)
            #expect(!items.contains(where: { ["prompt", "q", "file", "originUrl"].contains($0.name) }))
        }
    }

    @Test
    func POSIXSingleQuotingCoversInjectionShapedPaths() {
        let cases: [(String, String)] = [
            ("", "''"),
            ("/tmp/simple", "'/tmp/simple'"),
            ("/tmp/O'Brien", "'/tmp/O'\\''Brien'"),
            ("/tmp/$(touch nope); echo hi", "'/tmp/$(touch nope); echo hi'"),
            ("/tmp/line\nbreak\\!中文", "'/tmp/line\nbreak\\!中文'"),
        ]
        for (input, expected) in cases {
            #expect(POSIXShellQuoting.singleQuote(input) == expected)
        }
    }

    @Test
    func POSIXSingleQuotingRoundTripsThroughBinShWithoutEvaluation() throws {
        let cases = [
            "",
            "/tmp/simple",
            "/tmp/O'Brien",
            "/tmp/$(printf injected >&2); `printf injected >&2`",
            "/tmp/' ; printf injected >&2; #",
            "/tmp/line\nbreak\\! 中文 😀",
        ]

        for input in cases {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                "printf '%s' \(POSIXShellQuoting.singleQuote(input))",
            ]
            process.standardOutput = standardOutput
            process.standardError = standardError

            try process.run()
            process.waitUntilExit()

            let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let error = standardError.fileHandleForReading.readDataToEndOfFile()
            #expect(process.terminationStatus == 0)
            #expect(output == Data(input.utf8))
            #expect(error.isEmpty)
        }
    }

    @Test
    func terminalCommandsUseOnlyAClosedExecutableWithoutArguments() throws {
        let workspace = try Workspace(absolutePath: "/tmp/O'Brien; $(touch never)")
        let codex = try TerminalCommandBuilder.command(for: .codexCLI, workspace: workspace)
        let claude = try TerminalCommandBuilder.command(for: .claudeCodeCLI, workspace: workspace)
        #expect(codex == TerminalCommand(
            executable: .codex,
            line: "cd '/tmp/O'\\''Brien; $(touch never)' && codex"
        ))
        #expect(claude.line == "cd '/tmp/O'\\''Brien; $(touch never)' && claude")
        #expect(!codex.line.hasSuffix("codex "))
        #expect(!claude.line.hasSuffix("claude "))

        for desktopTarget in [AgentTarget.codexApp, .claudeDesktopCode] {
            let error: TerminalCommandBuildError? = capturedError {
                try TerminalCommandBuilder.command(for: desktopTarget, workspace: workspace)
            }
            #expect(error == .unsupportedTarget(desktopTarget))
        }
    }

    @Test
    func verifiedAppleEventConstantsStayExact() {
        #expect(FinderAppleEventContract.targetBundleIdentifier == "com.apple.finder")
        #expect(FinderAppleEventContract.eventClass.ascii == "core")
        #expect(FinderAppleEventContract.eventID.ascii == "getd")
        #expect(FinderAppleEventContract.directObjectKeyword.ascii == "----")
        #expect(FinderAppleEventContract.urlProperty.ascii == "pURL")
        #expect(FinderAppleEventContract.targetProperty.ascii == "fvtg")
        #expect(FinderAppleEventContract.browserWindowClass.ascii == "brow")
        #expect(FinderAppleEventContract.absoluteIndex == 1)
        #expect(TerminalAppleEventContract.terminalDoScriptClass.ascii == "core")
        #expect(TerminalAppleEventContract.terminalDoScriptID.ascii == "dosc")
        #expect(TerminalAppleEventContract.terminalTargetKeyword.ascii == "kfil")
        #expect(TerminalAppleEventContract.iTermClass.ascii == "Itrm")
        #expect(TerminalAppleEventContract.iTermCreateWindowID.ascii == "nwwn")
        #expect(TerminalAppleEventContract.iTermCreateTabID.ascii == "ntwn")
        #expect(TerminalAppleEventContract.iTermWriteTextID.ascii == "sntx")
        #expect(TerminalAppleEventContract.iTermCurrentWindowProperty.ascii == "Crwn")
        #expect(TerminalAppleEventContract.subjectAttribute.ascii == "subj")
        #expect(TerminalAppleEventContract.iTermTextKeyword.ascii == "Text")
        #expect(TerminalAppleEventContract.iTermNewlineKeyword.ascii == "Wtnl")
        #expect(FourCharacterCode(ascii: "abc") == nil)
        #expect(FourCharacterCode(ascii: "中文ab") == nil)
    }
}

@Suite("M3 Diagnostics and Errors")
struct M3DiagnosticsTests {
    @Test
    func debugDiagnosticsRetainLocalContext() throws {
        let workspace = try Workspace(absolutePath: "/Users/me/Secret Project")
        let command = "cd '/Users/me/Secret Project' && codex"
        let input = DiagnosticInput(
            applicationVersion: "0.1.0 (1)",
            systemVersion: "macOS 14.6 (23G80)",
            stage: .terminalHandoff,
            target: .codexCLI,
            terminalHost: .terminal,
            errorCode: DiagnosticCode(rawValue: "terminal-open-failed"),
            errorDetail: "Could not run \(command) in \(workspace.path)",
            workspace: workspace,
            generatedCommand: command
        )

        let record = DiagnosticSanitizer.sanitize(input, policy: .debug)
        #expect(record.workspacePath == workspace.path)
        #expect(record.generatedCommand == command)
        #expect(record.detail?.contains(workspace.path) == true)
        #expect(record.rendered.contains(command))
    }

    @Test
    func releaseDiagnosticsRemovePlainURLPercentEncodedAndCommandForms() throws {
        let workspace = try Workspace(absolutePath: "/Users/me/秘密 Project#1")
        let command = try TerminalCommandBuilder.command(for: .codexCLI, workspace: workspace).line
        let encoded = try #require(workspace.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        let input = DiagnosticInput(
            applicationVersion: "0.1.0 (1)",
            systemVersion: "macOS 14.6 (23G80)",
            stage: .desktopHandoff,
            target: .codexApp,
            errorCode: DiagnosticCode(rawValue: "desktop-open-failed"),
            errorDetail: "path=\(workspace.path) url=\(workspace.fileURL.absoluteString) encoded=\(encoded) command=\(command)",
            workspace: workspace,
            generatedCommand: command
        )

        let record = DiagnosticSanitizer.sanitize(input, policy: .release)
        #expect(record.workspacePath == nil)
        #expect(record.generatedCommand == nil)
        #expect(record.detail?.contains(workspace.path) == false)
        #expect(record.detail?.contains(workspace.fileURL.absoluteString) == false)
        #expect(record.detail?.contains(encoded) == false)
        #expect(record.detail?.contains(command) == false)
        #expect(!record.rendered.contains(workspace.path))
        #expect(!record.rendered.contains(command))
        #expect(record.rendered.contains("stage=desktop.handoff"))
        #expect(record.rendered.contains("target=codex-app"))
    }

    @Test
    func releaseDiagnosticsRedactShellQuotedAndDesktopURLRepresentations() throws {
        let workspace = try Workspace(absolutePath: "/Users/me/O'Brien 秘密 Project#1")
        let fileComponents = try #require(URLComponents(
            url: workspace.fileURL,
            resolvingAgainstBaseURL: false
        ))
        let encoded = try #require(
            workspace.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        )
        let desktopTargets = AgentTargetCatalog.targets.filter { $0.kind == .desktop }
        let desktopURLs = try desktopTargets.map { target in
            try DesktopURLBuilder.url(for: target, workspace: workspace)
        }
        let queryValues = try desktopURLs.map { url in
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = try #require(components.percentEncodedQuery)
            let separator = try #require(query.firstIndex(of: "="))
            return String(query[query.index(after: separator)...])
        }
        let sensitiveValues = [
            workspace.path,
            workspace.fileURL.absoluteString,
            POSIXShellQuoting.singleQuote(workspace.path),
            encoded,
            fileComponents.percentEncodedPath,
        ] + desktopURLs.map(\.absoluteString) + queryValues
        let detail = sensitiveValues.enumerated()
            .map { "value\($0.offset)=\($0.element)" }
            .joined(separator: " ")
        let input = DiagnosticInput(
            applicationVersion: "1",
            systemVersion: "14.6",
            stage: .desktopHandoff,
            errorCode: DiagnosticCode(rawValue: "desktop-open-failed"),
            errorDetail: detail,
            workspace: workspace
        )

        let record = DiagnosticSanitizer.sanitize(input, policy: .release)
        let sanitizedDetail = try #require(record.detail)
        for sensitiveValue in Set(sensitiveValues) where !sensitiveValue.isEmpty {
            #expect(!sanitizedDetail.contains(sensitiveValue))
        }
        #expect(sanitizedDetail.contains("<redacted>"))
    }

    @Test
    func releaseDiagnosticsKeepSafeDetailForAbsentWorkspaceAndEmptyCommand() {
        let safeDetail = "The target rejected the request"
        let withEmptyCommand = DiagnosticInput(
            applicationVersion: "1",
            systemVersion: "14.6",
            stage: .terminalHandoff,
            errorCode: DiagnosticCode(rawValue: "terminal-open-failed"),
            errorDetail: safeDetail,
            generatedCommand: ""
        )
        let withoutDetail = DiagnosticInput(
            applicationVersion: "1",
            systemVersion: "14.6",
            stage: .terminalHandoff,
            errorCode: DiagnosticCode(rawValue: "terminal-open-failed")
        )

        #expect(DiagnosticSanitizer.sanitize(
            withEmptyCommand,
            policy: .release
        ).detail == safeDetail)
        #expect(DiagnosticSanitizer.sanitize(
            withoutDetail,
            policy: .release
        ).detail == nil)
    }

    @Test
    func releaseDropsRootDetailAndInvalidCodesAreConstrained() throws {
        let root = try Workspace(absolutePath: "/")
        let input = DiagnosticInput(
            applicationVersion: "1",
            systemVersion: "14.6",
            stage: .finderWorkspace,
            errorCode: DiagnosticCode(rawValue: "/private/path leaked"),
            errorDetail: "Failure under /",
            workspace: root
        )
        let record = DiagnosticSanitizer.sanitize(input, policy: .release)
        #expect(record.detail == nil)
        #expect(record.errorCode.rawValue == "invalid-diagnostic-code")
    }

    @Test
    func AppleEventStatusesMapToTypedErrors() {
        #expect(FinderWorkspaceError.mapAppleEventStatus(-1743) == .automationPermissionDenied)
        #expect(FinderWorkspaceError.mapAppleEventStatus(-1744) == .consentRequired)
        #expect(FinderWorkspaceError.mapAppleEventStatus(-1712) == .replyTimeout)
        #expect(FinderWorkspaceError.mapAppleEventStatus(-600) == .finderUnavailable)
        #expect(FinderWorkspaceError.mapAppleEventStatus(-1728) == .objectUnavailable)
        #expect(FinderWorkspaceError.mapAppleEventStatus(-1719) == .objectUnavailable)
        #expect(FinderWorkspaceError.mapAppleEventStatus(-999) == .appleEventFailure(status: -999))

        for host in TerminalHost.allCases {
            #expect(TerminalHandoffError.mapAppleEventStatus(-1743, host: host) == .automationPermissionDenied(host))
            #expect(TerminalHandoffError.mapAppleEventStatus(-1744, host: host) == .consentRequired(host))
            #expect(TerminalHandoffError.mapAppleEventStatus(-1712, host: host) == .replyTimeout(host))
            #expect(TerminalHandoffError.mapAppleEventStatus(-600, host: host) == .terminalUnavailable(host))
            #expect(TerminalHandoffError.mapAppleEventStatus(-1719, host: host) == .appleEventFailure(host, status: -1719))
            #expect(TerminalHandoffError.mapAppleEventStatus(-999, host: host) == .appleEventFailure(host, status: -999))
        }
    }

    @Test
    func everyTypedPlatformErrorCaseMapsToItsStableDiagnosticCode() {
        let mappings: [(error: any DiagnosticCodeProviding, code: String)] = [
            (PreferencesStoreError.readFailed, "preferences-read-failed"),
            (PreferencesStoreError.writeFailed, "preferences-write-failed"),
            (FinderWorkspaceError.automationPermissionDenied, "finder-automation-denied"),
            (FinderWorkspaceError.consentRequired, "finder-consent-required"),
            (FinderWorkspaceError.replyTimeout, "finder-reply-timeout"),
            (FinderWorkspaceError.finderUnavailable, "finder-unavailable"),
            (FinderWorkspaceError.objectUnavailable, "finder-object-unavailable"),
            (FinderWorkspaceError.malformedReply, "finder-malformed-reply"),
            (FinderWorkspaceError.unsupportedLocation, "finder-unsupported-location"),
            (FinderWorkspaceError.inaccessibleWorkspace, "workspace-inaccessible"),
            (FinderWorkspaceError.invalidWorkspace, "workspace-invalid"),
            (FinderWorkspaceError.appleEventFailure(status: -1), "finder-apple-event-failed"),
            (AvailabilityLookupError.lookupFailed(.codexApp), "availability-lookup-failed"),
            (AvailabilityLookupError.inconsistentEvidence(.codexCLI), "availability-evidence-mismatch"),
            (DesktopHandoffError.unsupportedTarget(.codexCLI), "desktop-target-unsupported"),
            (DesktopHandoffError.handlerUnavailable(.codexApp), "desktop-handler-unavailable"),
            (DesktopHandoffError.malformedURL(.claudeDesktopCode), "desktop-url-malformed"),
            (DesktopHandoffError.openFailed(code: 1), "desktop-open-failed"),
            (TerminalHandoffError.unsupportedTarget(.codexApp), "terminal-target-unsupported"),
            (TerminalHandoffError.hostUnavailable(.terminal), "terminal-host-unavailable"),
            (TerminalHandoffError.unsupportedPlacement(.terminal, .newTab), "terminal-placement-unsupported"),
            (TerminalHandoffError.automationPermissionDenied(.terminal), "terminal-automation-denied"),
            (TerminalHandoffError.consentRequired(.iTerm2), "terminal-consent-required"),
            (TerminalHandoffError.replyTimeout(.terminal), "terminal-reply-timeout"),
            (TerminalHandoffError.terminalUnavailable(.iTerm2), "terminal-unavailable"),
            (TerminalHandoffError.appleEventFailure(.terminal, status: -1), "terminal-apple-event-failed"),
            (AliasResolutionError.emptyAliasRecord, "alias-empty"),
            (AliasResolutionError.conversionFailed, "alias-conversion-failed"),
            (AliasResolutionError.bookmarkResolutionFailed, "alias-bookmark-resolution-failed"),
            (AliasResolutionError.nonFileURL, "alias-non-file-url"),
            (AliasResolutionError.targetMissing, "alias-target-missing"),
            (AliasResolutionError.storedURLConflict, "alias-stored-url-conflict"),
            (AliasResolutionError.expectedLauncherConflict, "alias-expected-launcher-conflict"),
        ]
        #expect(mappings.count == 33)
        for mapping in mappings {
            #expect(mapping.error.diagnosticCode.rawValue == mapping.code)
            #expect(mapping.error.diagnosticCode.rawValue != "invalid-diagnostic-code")
        }
    }

    @Test
    func aliasAgreementAllowsStaleMatchingAndRejectsAmbiguity() throws {
        let expected = URL(fileURLWithPath: "/Applications/Go2Codex.app/Contents/Applications/Go2CodexLauncher.app")
        let equivalent = URL(fileURLWithPath: "/Applications/Go2Codex.app/Contents/Applications/./Go2CodexLauncher.app")
        let resolution = AliasResolution(fileURL: equivalent, bookmarkDataWasStale: true)
        #expect(try FinderAliasAgreement.validate(
            resolution: resolution,
            storedURL: expected,
            expectedLauncherURL: expected
        ) == expected.standardizedFileURL)

        let storedConflict: AliasResolutionError? = capturedError {
            try FinderAliasAgreement.validate(
                resolution: resolution,
                storedURL: URL(fileURLWithPath: "/tmp/Other.app"),
                expectedLauncherURL: expected
            )
        }
        #expect(storedConflict == .storedURLConflict)

        let expectedConflict: AliasResolutionError? = capturedError {
            try FinderAliasAgreement.validate(
                resolution: resolution,
                storedURL: expected,
                expectedLauncherURL: URL(fileURLWithPath: "/tmp/Other.app")
            )
        }
        #expect(expectedConflict == .expectedLauncherConflict)

        let nonFile: AliasResolutionError? = capturedError {
            try FinderAliasAgreement.validate(
                resolution: AliasResolution(
                    fileURL: URL(string: "https://example.com/launcher")!,
                    bookmarkDataWasStale: false
                ),
                storedURL: expected,
                expectedLauncherURL: expected
            )
        }
        #expect(nonFile == .nonFileURL)
    }
}

private actor PreferencesStoreFake: PreferencesEnvelopeStoring {
    private var data: Data?
    private let failReads: Bool
    private let failWrites: Bool
    private(set) var writeCount = 0

    init(
        data: Data? = nil,
        failReads: Bool = false,
        failWrites: Bool = false
    ) {
        self.data = data
        self.failReads = failReads
        self.failWrites = failWrites
    }

    func readEnvelopeData() async throws -> Data? {
        if failReads {
            throw PreferencesStoreError.readFailed
        }
        return data
    }

    func replaceEnvelopeData(with data: Data) async throws {
        if failWrites {
            throw PreferencesStoreError.writeFailed
        }
        self.data = data
        writeCount += 1
    }
}

private func capturedError<T, E: Error & Equatable>(
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
