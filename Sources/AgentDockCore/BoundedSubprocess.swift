import Darwin
import Foundation

struct BoundedSubprocessResult: Sendable {
    var output: Data
    var terminationStatus: Int32
    var exceededOutputLimit: Bool
}

enum BoundedSubprocess {
    /// Blocks the calling thread until the process finishes. Async callers get
    /// the overload below, which suspends instead.
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        captureStandardError: Bool = false,
        environmentOverrides: [String: String] = [:]
    ) throws -> BoundedSubprocessResult {
        try spawn(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            captureStandardError: captureStandardError,
            environmentOverrides: environmentOverrides
        ).wait()
    }

    /// Suspends until the process finishes without occupying a cooperative
    /// thread. Task cancellation terminates the process group.
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        captureStandardError: Bool = false,
        environmentOverrides: [String: String] = [:]
    ) async throws -> BoundedSubprocessResult {
        try await spawn(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            captureStandardError: captureStandardError,
            environmentOverrides: environmentOverrides
        ).value()
    }

    private static func spawn(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        captureStandardError: Bool,
        environmentOverrides: [String: String]
    ) throws -> BoundedSubprocessExecution {
        var pipeDescriptors: [Int32] = [0, 0]
        guard pipe(&pipeDescriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let readDescriptor = pipeDescriptors[0]
        let writeDescriptor = pipeDescriptors[1]

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO)
        if captureStandardError {
            posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDERR_FILENO)
        } else {
            posix_spawn_file_actions_addopen(
                &actions,
                STDERR_FILENO,
                "/dev/null",
                O_WRONLY,
                0
            )
        }
        posix_spawn_file_actions_addclose(&actions, readDescriptor)
        posix_spawn_file_actions_addclose(&actions, writeDescriptor)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let command = [executableURL.path] + arguments
        let cArguments = command.map { strdup($0) }
        defer { cArguments.forEach { free($0) } }
        var argv = cArguments + [nil]
        let environment = ProcessInfo.processInfo.environment
            .merging(environmentOverrides) { _, override in override }
            .map { "\($0.key)=\($0.value)" }
        let cEnvironment = environment.map { strdup($0) }
        defer { cEnvironment.forEach { free($0) } }
        var environmentPointer = cEnvironment + [nil]
        var processID: pid_t = 0
        let spawnResult = posix_spawn(
            &processID,
            executableURL.path,
            &actions,
            &attributes,
            &argv,
            &environmentPointer
        )
        close(writeDescriptor)
        guard spawnResult == 0 else {
            close(readDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .EIO)
        }

        let capture = BoundedDataCapture(maximumBytes: maximumOutputBytes)
        return BoundedSubprocessExecution(
            processID: processID,
            outputDescriptor: readDescriptor,
            capture: capture,
            timeout: timeout
        )
    }
}

enum BoundedSubprocessError: Error, Equatable {
    case timedOut
}

/// Drives one spawned process from dispatch sources on a private serial queue:
/// root exit, pipe output, the deadline, and termination escalation. All
/// mutable state below is confined to `queue`.
private final class BoundedSubprocessExecution: @unchecked Sendable {
    private let queue = DispatchQueue(label: "AgentDock.BoundedSubprocess", qos: .utility)
    private let processID: pid_t
    private let capture: BoundedDataCapture
    private var exitSource: DispatchSourceProcess?
    private var outputSource: DispatchSourceRead?
    private var deadlineTimer: DispatchSourceTimer?
    private var terminationTimer: DispatchSourceTimer?
    private var waitStatus: Int32 = 0
    private var rootReaped = false
    private var rootUnavailable = false
    private var outputClosed = false
    private var terminating = false
    private var escalated = false
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
    private var outcome: Result<BoundedSubprocessResult, any Error>?
    private var observer: (@Sendable (Result<BoundedSubprocessResult, any Error>) -> Void)?

    init(processID: pid_t, outputDescriptor: Int32, capture: BoundedDataCapture, timeout: TimeInterval) {
        self.processID = processID
        self.capture = capture
        queue.sync {
            startSources(outputDescriptor: outputDescriptor, timeout: timeout)
        }
    }

    func wait() throws -> BoundedSubprocessResult {
        let finished = DispatchSemaphore(value: 0)
        observe { _ in finished.signal() }
        if withUnsafeCurrentTask(body: { $0 != nil }) {
            // Synchronous code cannot register a cancellation handler.
            var cancelled = false
            while finished.wait(timeout: .now() + 0.05) == .timedOut {
                if !cancelled, Task.isCancelled {
                    cancelled = true
                    cancel()
                }
            }
        } else {
            finished.wait()
        }
        guard let outcome = queue.sync(execute: { outcome }) else {
            throw BoundedSubprocessError.timedOut
        }
        return try outcome.get()
    }

    func value() async throws -> BoundedSubprocessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                observe { continuation.resume(with: $0) }
            }
        } onCancel: {
            cancel()
        }
    }

    /// Cancellation is reported as a timeout, matching the deadline path.
    func cancel() {
        queue.async { self.beginTermination() }
    }

    private func observe(_ handler: @escaping @Sendable (Result<BoundedSubprocessResult, any Error>) -> Void) {
        queue.async {
            if let outcome = self.outcome {
                handler(outcome)
            } else {
                self.observer = handler
            }
        }
    }

    private func startSources(outputDescriptor: Int32, timeout: TimeInterval) {
        _ = fcntl(outputDescriptor, F_SETFL, fcntl(outputDescriptor, F_GETFL) | O_NONBLOCK)
        let output = DispatchSource.makeReadSource(fileDescriptor: outputDescriptor, queue: queue)
        output.setEventHandler { self.readOutput(from: outputDescriptor) }
        output.setCancelHandler { close(outputDescriptor) }
        outputSource = output
        output.resume()

        let exit = DispatchSource.makeProcessSource(identifier: processID, eventMask: .exit, queue: queue)
        exit.setEventHandler {
            self.reapRoot(exited: true)
            self.completeIfFinished()
        }
        exitSource = exit
        exit.resume()
        // The root may have exited before its source was registered.
        reapRoot()

        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + max(0, timeout))
        deadline.setEventHandler { self.beginTermination() }
        deadlineTimer = deadline
        deadline.resume()
    }

    private func readOutput(from descriptor: Int32) {
        let count = readBuffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
            capture.append(Data(readBuffer[0..<count]))
            return
        }
        if count < 0, errno == EAGAIN || errno == EINTR {
            return
        }
        outputClosed = true
        outputSource?.cancel()
        outputSource = nil
        completeIfFinished()
    }

    /// The exit event can arrive just before the root becomes a zombie, when
    /// `WNOHANG` still reports it running. After that event a blocking reap on
    /// this private queue returns promptly.
    private func reapRoot(exited: Bool = false) {
        guard !rootReaped, !rootUnavailable else { return }
        var result: pid_t
        repeat {
            result = waitpid(processID, &waitStatus, exited ? 0 : WNOHANG)
        } while result == -1 && errno == EINTR
        if result == processID {
            rootReaped = true
        } else if result == -1, errno == ECHILD {
            // No status to report; only termination may treat this as finished.
            rootUnavailable = true
        }
    }

    private func completeIfFinished() {
        guard !terminating, rootReaped, outputClosed else { return }
        finish(.success(BoundedSubprocessResult(
            output: capture.data,
            terminationStatus: Self.terminationStatus(from: waitStatus),
            exceededOutputLimit: capture.exceededLimit
        )))
    }

    private func beginTermination() {
        guard outcome == nil, !terminating else { return }
        terminating = true
        deadlineTimer?.cancel()
        deadlineTimer = nil
        outputSource?.cancel()
        outputSource = nil
        _ = kill(-processID, SIGTERM)

        let graceDeadline = DispatchTime.now() + 1
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(5))
        timer.setEventHandler { self.escalateTermination(graceDeadline: graceDeadline) }
        terminationTimer = timer
        timer.resume()
    }

    private func escalateTermination(graceDeadline: DispatchTime) {
        reapRoot()
        let rootFinished = rootReaped || rootUnavailable
        if !escalated {
            guard DispatchTime.now() >= graceDeadline || (!groupExists() && rootFinished) else { return }
            if groupExists() {
                _ = kill(-processID, SIGKILL)
            }
            if !rootFinished {
                // The root may have left its group; its PID is ours until reaped.
                _ = kill(processID, SIGKILL)
            }
            escalated = true
        }
        if rootFinished {
            finish(.failure(BoundedSubprocessError.timedOut))
        }
    }

    private func finish(_ result: Result<BoundedSubprocessResult, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        // Cancelling releases each handler and with it the reference to self.
        exitSource?.cancel()
        outputSource?.cancel()
        deadlineTimer?.cancel()
        terminationTimer?.cancel()
        exitSource = nil
        outputSource = nil
        deadlineTimer = nil
        terminationTimer = nil
        if let observer {
            self.observer = nil
            observer(result)
        }
    }

    private func groupExists() -> Bool {
        if kill(-processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func terminationStatus(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + signal
    }
}

private final class BoundedDataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var storage = Data()
    private var overflowed = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var data: Data {
        lock.withLock { storage }
    }

    var exceededLimit: Bool {
        lock.withLock { overflowed }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            guard !overflowed else { return }
            guard storage.count + data.count <= maximumBytes else {
                overflowed = true
                storage.removeAll(keepingCapacity: false)
                return
            }
            storage.append(data)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
