import Darwin
import Foundation

struct BoundedSubprocessResult {
    var output: Data
    var terminationStatus: Int32
    var exceededOutputLimit: Bool
}

enum BoundedSubprocess {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        captureStandardError: Bool = false,
        environmentOverrides: [String: String] = [:]
    ) throws -> BoundedSubprocessResult {
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
        let output = FileHandle(fileDescriptor: readDescriptor, closeOnDealloc: true)
        let pipeClosed = DispatchSemaphore(value: 0)
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                pipeClosed.signal()
            } else {
                capture.append(data)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var waitStatus: Int32 = 0
        var rootExited = false
        var outputClosed = false
        while !Task.isCancelled, Date() < deadline {
            if !rootExited {
                let waitResult = waitpid(processID, &waitStatus, WNOHANG)
                rootExited = waitResult == processID
            }
            if !outputClosed {
                outputClosed = pipeClosed.wait(timeout: .now()) == .success
            }
            if rootExited && outputClosed {
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        output.readabilityHandler = nil
        if !rootExited || !outputClosed {
            terminateProcessGroup(processID, rootExited: rootExited, waitStatus: &waitStatus)
            try? output.close()
            throw BoundedSubprocessError.timedOut
        }
        try? output.close()
        return BoundedSubprocessResult(
            output: capture.data,
            terminationStatus: terminationStatus(from: waitStatus),
            exceededOutputLimit: capture.exceededLimit
        )
    }

    private static func terminateProcessGroup(
        _ processID: pid_t,
        rootExited: Bool,
        waitStatus: inout Int32
    ) {
        _ = kill(-processID, SIGTERM)
        let deadline = Date().addingTimeInterval(1)
        while groupExists(processID), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if groupExists(processID) {
            _ = kill(-processID, SIGKILL)
        }
        if !rootExited {
            _ = waitpid(processID, &waitStatus, 0)
        }
    }

    private static func groupExists(_ processGroupID: pid_t) -> Bool {
        if kill(-processGroupID, 0) == 0 {
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

enum BoundedSubprocessError: Error, Equatable {
    case timedOut
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
