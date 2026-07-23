import Darwin
import Dispatch
import Foundation

public enum CLIExecutableProbeIssue: Equatable, Sendable {
    case loginShellUnavailable
    case loginShellUnsupported
    case loginShellNotExecutable
    case launchFailed
    case timedOut
    case cancelled
    case invalidResult
}

public enum CLIExecutableAvailability: Equatable, Sendable {
    case available
    case missing
    case unknown(CLIExecutableProbeIssue)
}

@MainActor
public protocol LoginShellPathLookingUp: Sendable {
    func loginShellPath() -> String?
}

@MainActor
public struct SystemLoginShellPathLookup: LoginShellPathLookingUp {
    public init() {}

    public func loginShellPath() -> String? {
        guard let passwordEntry = getpwuid(getuid()),
              let shell = passwordEntry.pointee.pw_shell else {
            return nil
        }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }
}

public struct LoginShellCommand: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

public enum LoginShellCommandRunResult: Equatable, Sendable {
    case completed(stdout: Data, exitStatus: Int32)
    case timedOut
    case cancelled
    case launchFailed
}

public protocol LoginShellCommandRunning: Sendable {
    func run(
        _ command: LoginShellCommand,
        timeout: Duration
    ) async -> LoginShellCommandRunResult
}

public protocol CLIExecutableAvailabilityProbing: Sendable {
    func availabilities(
        for executables: [CLIExecutable]
    ) async -> [CLIExecutableAvailability]

    func availability(
        for executable: CLIExecutable
    ) async -> CLIExecutableAvailability
}

public extension CLIExecutableAvailabilityProbing {
    func availability(
        for executable: CLIExecutable
    ) async -> CLIExecutableAvailability {
        await availabilities(for: [executable]).first
            ?? .unknown(.invalidResult)
    }
}

public actor SystemCLIExecutableAvailabilityProbe:
    CLIExecutableAvailabilityProbing {
    enum LoginShell: String {
        case bash
        case fish
        case zsh

        init?(path: String) {
            self.init(rawValue: URL(fileURLWithPath: path).lastPathComponent)
        }

        func lookupScript(
            for executables: [CLIExecutable],
            markerToken: String
        ) -> String {
            let checks = executables.map { executable in
                lookupCheck(
                    for: executable,
                    markerToken: markerToken
                )
            }.joined(separator: "\n")
            return checks
        }

        private func lookupCheck(
            for executable: CLIExecutable,
            markerToken: String
        ) -> String {
            let name = executable.rawValue
            let availableMarker =
                "__GO2CODEX_CLI_\(markerToken)_AVAILABLE__: \(name)"
            let missingMarker =
                "__GO2CODEX_CLI_\(markerToken)_MISSING__: \(name)"
            let inconclusiveMarker =
                "__GO2CODEX_CLI_\(markerToken)_INCONCLUSIVE__: \(name)"
            return switch self {
            case .bash:
                """
                go2codex_path_is_safe=1
                case ":${PATH-}:" in
                  *::*) go2codex_path_is_safe=0 ;;
                esac
                if [[ "$go2codex_path_is_safe" -eq 1 ]]; then
                  go2codex_old_ifs=$IFS
                  IFS=:
                  for go2codex_path_entry in $PATH; do
                    case "$go2codex_path_entry" in
                      /*) ;;
                      *) go2codex_path_is_safe=0; break ;;
                    esac
                  done
                  IFS=$go2codex_old_ifs
                fi
                if [[ "$go2codex_path_is_safe" -ne 1 ]]; then
                  builtin printf '\(inconclusiveMarker)\\n'
                else
                  go2codex_candidate="$(builtin type -P \(name))"
                  if [[ -z "$go2codex_candidate" || ! -x "$go2codex_candidate" || -d "$go2codex_candidate" ]]; then
                    builtin printf '\(missingMarker)\\n'
                  elif [[ "$go2codex_candidate" == /* ]]; then
                    builtin printf '\(availableMarker)\\n'
                  else
                    builtin printf '\(inconclusiveMarker)\\n'
                  fi
                fi
                """
            case .fish:
                """
                set -l go2codex_path_is_safe 1
                if builtin string match -qr '(^|:)(:|$)' -- "$PATH"
                  set go2codex_path_is_safe 0
                else
                  for go2codex_path_entry in (builtin string split : -- "$PATH")
                    if not builtin string match -q '/*' -- "$go2codex_path_entry"
                      set go2codex_path_is_safe 0
                      break
                    end
                  end
                end
                if builtin test "$go2codex_path_is_safe" -ne 1
                  builtin printf '\(inconclusiveMarker)\\n'
                else
                  set -l go2codex_candidate (builtin type -P \(name))[1]
                  if builtin test -z "$go2codex_candidate"; or not builtin test -x "$go2codex_candidate"; or builtin test -d "$go2codex_candidate"
                    builtin printf '\(missingMarker)\\n'
                  else if builtin string match -q '/*' -- "$go2codex_candidate"
                    builtin printf '\(availableMarker)\\n'
                  else
                    builtin printf '\(inconclusiveMarker)\\n'
                  end
                end
                """
            case .zsh:
                """
                go2codex_path_is_safe=1
                case ":${PATH-}:" in
                  *::*) go2codex_path_is_safe=0 ;;
                esac
                if [[ "$go2codex_path_is_safe" -eq 1 ]]; then
                  for go2codex_path_entry in ${(s/:/)PATH}; do
                    case "$go2codex_path_entry" in
                      /*) ;;
                      *) go2codex_path_is_safe=0; break ;;
                    esac
                  done
                fi
                if [[ "$go2codex_path_is_safe" -ne 1 ]]; then
                  builtin printf '\(inconclusiveMarker)\\n'
                else
                  go2codex_candidate="$(builtin whence -p \(name))"
                  if [[ -z "$go2codex_candidate" || ! -x "$go2codex_candidate" || -d "$go2codex_candidate" ]]; then
                    builtin printf '\(missingMarker)\\n'
                  elif [[ "$go2codex_candidate" == /* ]]; then
                    builtin printf '\(availableMarker)\\n'
                  else
                    builtin printf '\(inconclusiveMarker)\\n'
                  fi
                fi
                """
            }
        }
    }

    private let loginShellPathLookup: any LoginShellPathLookingUp
    private let runner: any LoginShellCommandRunning
    private let timeout: Duration

    public init(
        loginShellPathLookup: any LoginShellPathLookingUp,
        runner: any LoginShellCommandRunning,
        timeout: Duration = .seconds(2)
    ) {
        self.loginShellPathLookup = loginShellPathLookup
        self.runner = runner
        self.timeout = timeout
    }

    public func availabilities(
        for executables: [CLIExecutable]
    ) async -> [CLIExecutableAvailability] {
        guard !executables.isEmpty else {
            return []
        }
        guard let shellPath = await MainActor.run(body: {
            loginShellPathLookup.loginShellPath()
        }) else {
            return Self.unavailableResults(for: executables, issue: .loginShellUnavailable)
        }
        guard shellPath.hasPrefix("/"),
              let shell = LoginShell(path: shellPath) else {
            return Self.unavailableResults(for: executables, issue: .loginShellUnsupported)
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: shellPath,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: shellPath) else {
            return Self.unavailableResults(for: executables, issue: .loginShellNotExecutable)
        }

        var seen = Set<CLIExecutable>()
        let uniqueExecutables = executables.filter {
            seen.insert($0).inserted
        }
        let markerToken = UUID().uuidString
        let command = LoginShellCommand(
            executablePath: shellPath,
            arguments: [
                "-l",
                "-i",
                "-c",
                shell.lookupScript(
                    for: uniqueExecutables,
                    markerToken: markerToken
                ),
            ]
        )
        switch await runner.run(command, timeout: timeout) {
        case .timedOut:
            return Self.unavailableResults(for: executables, issue: .timedOut)
        case .cancelled:
            return Self.unavailableResults(for: executables, issue: .cancelled)
        case .launchFailed:
            return Self.unavailableResults(for: executables, issue: .launchFailed)
        case let .completed(stdout, exitStatus):
            guard exitStatus == 0 else {
                return Self.unavailableResults(for: executables, issue: .invalidResult)
            }
            return Self.parse(
                stdout: stdout,
                executables: executables,
                markerToken: markerToken
            )
        }
    }

    private static func parse(
        stdout: Data,
        executables: [CLIExecutable],
        markerToken: String
    ) -> [CLIExecutableAvailability] {
        guard let output = String(data: stdout, encoding: .utf8) else {
            return unavailableResults(for: executables, issue: .invalidResult)
        }
        return executables.map { executable in
            let availableMarker =
                "__GO2CODEX_CLI_\(markerToken)_AVAILABLE__: \(executable.rawValue)"
            let missingMarker =
                "__GO2CODEX_CLI_\(markerToken)_MISSING__: \(executable.rawValue)"
            let inconclusiveMarker =
                "__GO2CODEX_CLI_\(markerToken)_INCONCLUSIVE__: \(executable.rawValue)"
            let availableCount = output.occurrenceCount(of: availableMarker)
            let missingCount = output.occurrenceCount(of: missingMarker)
            let inconclusiveCount = output.occurrenceCount(
                of: inconclusiveMarker
            )
            guard availableCount + missingCount + inconclusiveCount == 1 else {
                return .unknown(.invalidResult)
            }
            if availableCount == 1 {
                return .available
            }
            return missingCount == 1
                ? .missing
                : .unknown(.invalidResult)
        }
    }

    private static func unavailableResults(
        for executables: [CLIExecutable],
        issue: CLIExecutableProbeIssue
    ) -> [CLIExecutableAvailability] {
        executables.map { _ in .unknown(issue) }
    }
}

public struct SystemLoginShellCommandRunner: LoginShellCommandRunning {
    public init() {}

    public func run(
        _ command: LoginShellCommand,
        timeout: Duration
    ) async -> LoginShellCommandRunResult {
        guard timeout > .zero else {
            return .timedOut
        }
        let execution = CLIProbeExecutionState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<LoginShellCommandRunResult, Never>) in
                execution.install(continuation)
                DispatchQueue.global(qos: .utility).async {
                    guard execution.beginWorker() else {
                        return
                    }

                    let collector = CLIProbeOutputCollector()
                    let standardOutputReader = CLIProbePipeReadCoordinator()
                    let standardErrorReader = CLIProbePipeReadCoordinator()
                    guard let process = Self.spawn(command) else {
                        execution.finishLaunchFailure()
                        return
                    }
                    process.standardOutput.readabilityHandler = { handle in
                        standardOutputReader.readAvailableData(
                            from: handle,
                            consume: collector.appendStandardOutput
                        )
                    }
                    process.standardError.readabilityHandler = { handle in
                        standardErrorReader.readAvailableData(
                            from: handle,
                            consume: collector.discardStandardError
                        )
                    }
                    execution.register(process.processID)
                    let timeoutTask = Task.detached(priority: .utility) {
                        do {
                            try await Task.sleep(for: timeout)
                        } catch {
                            return
                        }
                        execution.requestStop(.timedOut)
                    }
                    let exitStatus = Self.waitForProcess(process.processID)
                    timeoutTask.cancel()
                    standardOutputReader.stopAndWait(
                        fileHandle: process.standardOutput
                    )
                    standardErrorReader.stopAndWait(
                        fileHandle: process.standardError
                    )
                    collector.appendStandardOutput(
                        Self.drainAvailableData(from: process.standardOutput)
                    )
                    collector.discardStandardError(
                        Self.drainAvailableData(from: process.standardError)
                    )
                    execution.finishFromProcess(
                        stdout: collector.standardOutput,
                        exitStatus: exitStatus
                    )
                }
            }
        } onCancel: {
            execution.requestStop(.cancelled)
        }
    }

    private static func spawn(
        _ command: LoginShellCommand
    ) -> SpawnedCLIProbeProcess? {
        let argumentStrings = [command.executablePath] + command.arguments
        guard argumentStrings.allSatisfy({
            !$0.utf8.contains(0)
        }) else {
            return nil
        }

        guard let standardOutputPipe = makePipe() else {
            return nil
        }
        guard let standardErrorPipe = makePipe() else {
            close(standardOutputPipe)
            return nil
        }
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            close(standardOutputPipe)
            close(standardErrorPipe)
            return nil
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            close(standardOutputPipe)
            close(standardErrorPipe)
            return nil
        }
        defer {
            posix_spawnattr_destroy(&attributes)
        }

        let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawn_file_actions_addopen(
            &fileActions,
            STDIN_FILENO,
            "/dev/null",
            O_RDONLY,
            0
        ) == 0,
              posix_spawn_file_actions_adddup2(
                  &fileActions,
                  standardOutputPipe.writeDescriptor,
                  STDOUT_FILENO
              ) == 0,
              posix_spawn_file_actions_adddup2(
                  &fileActions,
                  standardErrorPipe.writeDescriptor,
                  STDERR_FILENO
              ) == 0,
              posix_spawn_file_actions_addclose(
                  &fileActions,
                  standardOutputPipe.readDescriptor
              ) == 0,
              posix_spawn_file_actions_addclose(
                  &fileActions,
                  standardOutputPipe.writeDescriptor
              ) == 0,
              posix_spawn_file_actions_addclose(
                  &fileActions,
                  standardErrorPipe.readDescriptor
              ) == 0,
              posix_spawn_file_actions_addclose(
                  &fileActions,
                  standardErrorPipe.writeDescriptor
              ) == 0,
              posix_spawnattr_setflags(
                  &attributes,
                  spawnFlags
              ) == 0,
              posix_spawnattr_setpgroup(
                  &attributes,
                  0
              ) == 0 else {
            close(standardOutputPipe)
            close(standardErrorPipe)
            return nil
        }

        let mutableArguments = argumentStrings.map { strdup($0) }
        guard mutableArguments.allSatisfy({ $0 != nil }) else {
            for case let pointer? in mutableArguments {
                free(pointer)
            }
            close(standardOutputPipe)
            close(standardErrorPipe)
            return nil
        }
        defer {
            for case let pointer? in mutableArguments {
                free(pointer)
            }
        }
        var arguments = mutableArguments
        arguments.append(nil)
        var processID = pid_t()
        let spawnResult = command.executablePath.withCString { executablePath in
            arguments.withUnsafeBufferPointer { buffer in
                posix_spawn(
                    &processID,
                    executablePath,
                    &fileActions,
                    &attributes,
                    buffer.baseAddress,
                    environ
                )
            }
        }
        _ = Darwin.close(standardOutputPipe.writeDescriptor)
        _ = Darwin.close(standardErrorPipe.writeDescriptor)
        guard spawnResult == 0 else {
            _ = Darwin.close(standardOutputPipe.readDescriptor)
            _ = Darwin.close(standardErrorPipe.readDescriptor)
            return nil
        }
        return SpawnedCLIProbeProcess(
            processID: processID,
            standardOutput: FileHandle(
                fileDescriptor: standardOutputPipe.readDescriptor,
                closeOnDealloc: true
            ),
            standardError: FileHandle(
                fileDescriptor: standardErrorPipe.readDescriptor,
                closeOnDealloc: true
            )
        )
    }

    private static func makePipe() -> CLIProbePipe? {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            return nil
        }
        guard let readDescriptor = normalizedPipeDescriptor(descriptors[0]) else {
            _ = Darwin.close(descriptors[1])
            return nil
        }
        guard let writeDescriptor = normalizedPipeDescriptor(descriptors[1]) else {
            _ = Darwin.close(readDescriptor)
            return nil
        }
        return CLIProbePipe(
            readDescriptor: readDescriptor,
            writeDescriptor: writeDescriptor
        )
    }

    private static func normalizedPipeDescriptor(
        _ descriptor: Int32
    ) -> Int32? {
        if descriptor < STDERR_FILENO + 1 {
            let duplicate = fcntl(
                descriptor,
                F_DUPFD_CLOEXEC,
                STDERR_FILENO + 1
            )
            _ = Darwin.close(descriptor)
            return duplicate >= 0 ? duplicate : nil
        }
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0,
              fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            _ = Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func close(_ pipe: CLIProbePipe) {
        _ = Darwin.close(pipe.readDescriptor)
        _ = Darwin.close(pipe.writeDescriptor)
    }

    private static func waitForProcess(_ processID: pid_t) -> Int32 {
        var status = Int32()
        while waitpid(processID, &status, 0) == -1 {
            guard errno == EINTR else {
                return -1
            }
        }
        let signal = status & 0x7f
        guard signal == 0 else {
            return 128 + signal
        }
        return (status >> 8) & 0xff
    }

    private static func drainAvailableData(from fileHandle: FileHandle) -> Data {
        let descriptor = fileHandle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            return Data()
        }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return Data()
        }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(Int(count)))
                continue
            }
            guard count < 0, errno == EINTR else {
                return result
            }
        }
    }
}

private struct CLIProbePipe {
    let readDescriptor: Int32
    let writeDescriptor: Int32
}

private struct SpawnedCLIProbeProcess {
    let processID: pid_t
    let standardOutput: FileHandle
    let standardError: FileHandle
}

private final class CLIProbePipeReadCoordinator: @unchecked Sendable {
    private let condition = NSCondition()
    private var acceptsReads = true
    private var activeReadCount = 0

    func readAvailableData(
        from fileHandle: FileHandle,
        consume: @Sendable (Data) -> Void
    ) {
        condition.lock()
        guard acceptsReads else {
            condition.unlock()
            return
        }
        activeReadCount += 1
        condition.unlock()
        defer {
            condition.lock()
            activeReadCount -= 1
            if activeReadCount == 0 {
                condition.broadcast()
            }
            condition.unlock()
        }
        consume(fileHandle.availableData)
    }

    func stopAndWait(fileHandle: FileHandle) {
        condition.lock()
        acceptsReads = false
        condition.unlock()
        fileHandle.readabilityHandler = nil
        condition.lock()
        while activeReadCount > 0 {
            condition.wait()
        }
        condition.unlock()
    }
}

private final class CLIProbeOutputCollector: @unchecked Sendable {
    private static let outputLimit = 64 * 1024
    private let lock = NSLock()
    private var output = Data()

    func appendStandardOutput(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        let remaining = Self.outputLimit - output.count
        guard remaining > 0 else {
            return
        }
        output.append(data.prefix(remaining))
    }

    func discardStandardError(_ data: Data) {}

    var standardOutput: Data {
        lock.lock()
        defer { lock.unlock() }
        return output
    }
}

private final class CLIProbeExecutionState: @unchecked Sendable {
    enum StopReason: Equatable {
        case timedOut
        case cancelled

        var result: LoginShellCommandRunResult {
            switch self {
            case .timedOut:
                .timedOut
            case .cancelled:
                .cancelled
            }
        }
    }

    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<LoginShellCommandRunResult, Never>?
    private var finalResult: LoginShellCommandRunResult?
    private var workerStarted = false
    private var stopReason: StopReason?
    private var stopSignalScheduled = false
    private var processGroupID: pid_t?
    private var processExitResult: LoginShellCommandRunResult?

    func install(
        _ continuation:
            CheckedContinuation<LoginShellCommandRunResult, Never>
    ) {
        let completedResult: LoginShellCommandRunResult?
        lock.lock()
        if let finalResult {
            completedResult = finalResult
        } else {
            self.continuation = continuation
            completedResult = nil
        }
        lock.unlock()
        if let completedResult {
            continuation.resume(returning: completedResult)
        }
    }

    func beginWorker() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard finalResult == nil else {
            return false
        }
        workerStarted = true
        return true
    }

    func register(_ processID: pid_t) {
        let shouldStop: Bool
        lock.lock()
        if finalResult == nil {
            processGroupID = processID
            shouldStop = stopReason != nil && !stopSignalScheduled
            if shouldStop {
                stopSignalScheduled = true
            }
        } else {
            shouldStop = false
        }
        lock.unlock()

        if shouldStop {
            stop(processGroupID: processID)
        }
    }

    func requestStop(_ reason: StopReason) {
        var processGroupToStop: pid_t?
        var immediateResult: LoginShellCommandRunResult?
        lock.lock()
        guard finalResult == nil else {
            lock.unlock()
            return
        }
        if stopReason == nil || reason == .cancelled {
            stopReason = reason
        }
        if !workerStarted {
            immediateResult = stopReason?.result
        } else if let processGroupID, !stopSignalScheduled {
            stopSignalScheduled = true
            processGroupToStop = processGroupID
        }
        lock.unlock()

        if let immediateResult {
            finish(immediateResult)
        } else if let processGroupToStop {
            stop(processGroupID: processGroupToStop)
        }
    }

    func finishLaunchFailure() {
        let result: LoginShellCommandRunResult
        lock.lock()
        result = stopReason?.result ?? .launchFailed
        lock.unlock()
        finish(result)
    }

    func finishFromProcess(stdout: Data, exitStatus: Int32) {
        let result: LoginShellCommandRunResult
        let processGroupID: pid_t?
        var shouldStopRemainingGroup = false
        lock.lock()
        result = stopReason?.result ?? .completed(
            stdout: stdout,
            exitStatus: exitStatus
        )
        processExitResult = result
        processGroupID = self.processGroupID
        if let processGroupID,
           Self.processGroupExists(processGroupID) {
            shouldStopRemainingGroup = !stopSignalScheduled
            stopSignalScheduled = true
        }
        lock.unlock()

        if let processGroupID,
           Self.processGroupExists(processGroupID) {
            if shouldStopRemainingGroup {
                stop(processGroupID: processGroupID)
            }
            return
        }
        finish(result)
    }

    private func stop(processGroupID: pid_t) {
        _ = kill(-processGroupID, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(200)
        ) { [self] in
            guard shouldForceStop(processGroupID) else {
                return
            }
            _ = kill(-processGroupID, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(500)
        ) { [self] in
            finishStoppedProcessIfNeeded()
        }
    }

    private func shouldForceStop(_ processGroupID: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finalResult == nil
            && self.processGroupID == processGroupID
            && Self.processGroupExists(processGroupID)
    }

    private func finishStoppedProcessIfNeeded() {
        let result: LoginShellCommandRunResult?
        let processGroupID: pid_t?
        lock.lock()
        result = finalResult == nil
            ? stopReason?.result ?? processExitResult
            : nil
        processGroupID = finalResult == nil ? self.processGroupID : nil
        lock.unlock()
        if let processGroupID,
           Self.processGroupExists(processGroupID) {
            _ = kill(-processGroupID, SIGKILL)
        }
        if let result {
            finish(result)
        }
    }

    private func finish(_ result: LoginShellCommandRunResult) {
        let continuation:
            CheckedContinuation<LoginShellCommandRunResult, Never>?
        lock.lock()
        guard finalResult == nil else {
            lock.unlock()
            return
        }
        finalResult = result
        processGroupID = nil
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        if kill(-processGroupID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}

private extension String {
    func occurrenceCount(of substring: String) -> Int {
        guard !substring.isEmpty else {
            return 0
        }
        var count = 0
        var searchRange = startIndex ..< endIndex
        while let match = range(
            of: substring,
            options: [],
            range: searchRange
        ) {
            count += 1
            searchRange = match.upperBound ..< endIndex
        }
        return count
    }
}
