import Foundation
import Darwin

public final class AppServerRateLimitClient: @unchecked Sendable {
    private let executableOverride: URL?
    private let appValidator: any CodexAppValidating
    private let timeoutSeconds: TimeInterval
    private let maximumResponseBytes: Int
    private let clientVersion: String

    public init(
        codexExecutable: URL? = nil,
        appValidator: any CodexAppValidating = OfficialCodexAppValidator(),
        timeoutSeconds: TimeInterval = 8,
        maximumResponseBytes: Int = 1_048_576,
        clientVersion: String? = nil
    ) {
        executableOverride = codexExecutable
        self.appValidator = appValidator
        self.timeoutSeconds = timeoutSeconds
        self.maximumResponseBytes = maximumResponseBytes
        self.clientVersion = clientVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.1.1"
    }

    public func fetchRateLimits(for profile: CodexProfile, codexAppURL: URL) async -> ProfileRateLimits {
        await fetchRateLimits(codexHomeURL: profile.codexHomePath, codexAppURL: codexAppURL)
    }

    public func fetchRateLimits(codexHomeURL: URL, codexAppURL: URL) async -> ProfileRateLimits {
        await fetchRateLimits(codexHomeURL: codexHomeURL, codexAppURL: codexAppURL, includeAccountDetails: false)
    }

    public func fetchRateLimits(codexHomeURL: URL, codexAppURL: URL,
                               includeAccountDetails: Bool) async -> ProfileRateLimits {
        await fetchRateLimitsBatch(codexHomeURLs: [codexHomeURL], codexAppURL: codexAppURL,
            includeAccountDetails: includeAccountDetails)[codexHomeURL]
            ?? ProfileRateLimits(errorMessage: "Usage-limit refresh was cancelled.")
    }

    /// The validated executable is scoped to this bounded batch, never cached as trust.
    public func fetchRateLimitsBatch(codexHomeURLs: [URL], codexAppURL: URL,
                                    includeAccountDetails: Bool = true) async -> [URL: ProfileRateLimits] {
        guard !Task.isCancelled else { return [:] }
        let homes = Array(Set(codexHomeURLs)).sorted { $0.path < $1.path }
        guard !homes.isEmpty else { return [:] }
        let executable = executableOverride ?? CodexBundledCLI.executableURL(for: codexAppURL)
        let identity = executableOverride == nil ? batchIdentity(app: codexAppURL, executable: executable) : nil
        if executableOverride == nil {
            do { try appValidator.validateCodexApp(at: codexAppURL) }
            catch {
                let failure = ProfileRateLimits(errorMessage:
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return Dictionary(uniqueKeysWithValues: homes.map { ($0, failure) })
            }
        }
        guard identity == nil || identity == batchIdentity(app: codexAppURL, executable: executable) else {
            return Dictionary(uniqueKeysWithValues: homes.map {
                ($0, ProfileRateLimits(errorMessage: "The installed app changed during validation."))
            })
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return Dictionary(uniqueKeysWithValues: homes.map {
                ($0, ProfileRateLimits(errorMessage: "Codex app-server executable was not found."))
            })
        }
        var results: [URL: ProfileRateLimits] = [:]
        for home in homes {
            guard !Task.isCancelled else { break }
            guard identity == nil || identity == batchIdentity(app: codexAppURL, executable: executable) else {
                results[home] = ProfileRateLimits(errorMessage: "The installed app changed during the refresh.")
                continue
            }
            let value = await fetchValidatedRateLimits(codexHomeURL: home,
                executable: executable, includeAccountDetails: includeAccountDetails)
            results[home] = Task.isCancelled || identity == nil || identity == batchIdentity(app: codexAppURL, executable: executable)
                ? value : ProfileRateLimits(errorMessage: "The installed app changed during the refresh.")
        }
        return results
    }

    private func batchIdentity(app: URL, executable: URL) -> [String] {
        var paths = [app, app.appendingPathComponent("Contents"), app.appendingPathComponent("Contents/Resources"),
            app.appendingPathComponent("Contents/MacOS/Codex"),
            app.appendingPathComponent("Contents/_CodeSignature/CodeResources"),
            app.appendingPathComponent("Contents/Resources/app.asar"), executable,
            executable.deletingLastPathComponent(), executable.deletingLastPathComponent().deletingLastPathComponent(),
            executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("_CodeSignature/CodeResources")]
        var parent = executable.deletingLastPathComponent()
        while parent.path.hasPrefix(app.path + "/"), parent != app {
            paths.append(parent)
            parent.deleteLastPathComponent()
        }
        return paths.map { path in
            var value = stat()
            guard lstat(path.path, &value) == 0 else { return "missing:\(errno)" }
            return "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
        }
    }

    private func fetchValidatedRateLimits(codexHomeURL: URL, executable codexExecutable: URL,
                                         includeAccountDetails: Bool) async -> ProfileRateLimits {
        let environment = Self.launchEnvironment(
            codexHomeURL: codexHomeURL,
            codexExecutable: codexExecutable,
            inherited: ProcessInfo.processInfo.environment
        )

        let progress = AppServerProgress()
        let responseState = ResponseState(maximumBytes: maximumResponseBytes,
            includesAccountDetails: includeAccountDetails)

        let process: GroupedSubprocess
        do {
            process = try GroupedSubprocess(
                executableURL: codexExecutable,
                arguments: ["app-server", "--listen", "stdio://"],
                environment: environment
            )
        } catch {
            return ProfileRateLimits(errorMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        process.standardOutput.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                progress.mark(.outputClosed)
                return
            }
            responseState.consume(data)
            if responseState.hasInitializeResponse || responseState.errorMessage != nil {
                progress.mark(.initialized)
            }
            if responseState.isComplete || responseState.errorMessage != nil {
                progress.mark(.completed)
            }
        }
        let exitObservation = process.observeExit(on: .global(qos: .utility)) {
            progress.mark(.processExited)
        }
        // The root may have exited before its source was registered.
        if !process.isRunning {
            progress.mark(.processExited)
        }

        let limits = await exchangeRequests(
            with: process,
            progress: progress,
            responseState: responseState,
            includeAccountDetails: includeAccountDetails
        )
        process.standardOutput.readabilityHandler = nil
        exitObservation.cancel()
        await process.terminate()
        return limits
    }

    private func exchangeRequests(
        with process: GroupedSubprocess,
        progress: AppServerProgress,
        responseState: ResponseState,
        includeAccountDetails: Bool
    ) async -> ProfileRateLimits {
        do {
            try writeInitializeRequest(to: process.standardInput)
            let initializeWait = await waitForCompletion(.initialized, progress: progress)
            if let errorMessage = responseState.errorMessage {
                return ProfileRateLimits(errorMessage: errorMessage)
            }
            if Task.isCancelled {
                return ProfileRateLimits(errorMessage: "Usage-limit refresh was cancelled.")
            }
            guard responseState.hasInitializeResponse else {
                if initializeWait == .timedOut {
                    return ProfileRateLimits(errorMessage: "Timed out reading Codex usage limits.")
                }
                return ProfileRateLimits(errorMessage: "Codex app-server exited before returning usage limits.")
            }

            try writeRateLimitRequest(to: process.standardInput, includeAccountDetails: includeAccountDetails)

            let waitResult = await waitForCompletion(.completed, progress: progress)
            if progress.hasReached(.processExited) || !process.isRunning,
               responseState.responseData == nil,
               responseState.errorMessage == nil
            {
                // Process termination can race the readability callback that
                // delivers the final response. Give that bounded callback a
                // chance to consume EOF before deciding the response is absent.
                _ = await progress.wait(forAnyOf: [.outputClosed], timeout: 0.1)
            }
            if let responseData = responseState.responseData {
                var limits = try RateLimitParser.parseResponse(responseData)
                if let data = responseState.accountData {
                    limits.accountEmail = CodexAccountDisplayParser.email(from: data)
                }
                return limits
            }
            if let errorMessage = responseState.errorMessage {
                return ProfileRateLimits(errorMessage: errorMessage)
            }
            if Task.isCancelled {
                return ProfileRateLimits(errorMessage: "Usage-limit refresh was cancelled.")
            }
            guard waitResult == .success else {
                return ProfileRateLimits(errorMessage: "Timed out reading Codex usage limits.")
            }
            return ProfileRateLimits(errorMessage: "Codex app-server exited before returning usage limits.")
        } catch {
            return ProfileRateLimits(errorMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    static func launchEnvironment(
        codexHomeURL: URL,
        codexExecutable: URL,
        inherited: [String: String]
    ) -> [String: String] {
        var environment = DesktopLaunchEnvironment.sanitized(inherited)
        // Native account limits must use this home's login. Custom-provider
        // credentials and endpoints are handled by CodexRateLimitClient instead.
        for key in [
            "OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL",
            "OPENAI_ORG_ID", "OPENAI_ORGANIZATION", "OPENAI_PROJECT_ID",
            "CODEX_APP_SERVER_CHATGPT_BASE_URL", "CODEX_APP_SERVER_OPENAI_BASE_URL",
            "CODEX_APP_SERVER_LOGIN_ISSUER", "CODEX_API_BASE_URL", "CODEX_API_ENDPOINT"
        ] {
            environment.removeValue(forKey: key)
        }
        environment["CODEX_HOME"] = codexHomeURL.path
        environment["CODEX_CLI_PATH"] = codexExecutable.path
        return environment
    }

    /// Suspends until `milestone` or root exit, the timeout, or cancellation.
    private func waitForCompletion(
        _ milestone: AppServerProgress.Milestone,
        progress: AppServerProgress
    ) async -> DispatchTimeoutResult {
        await progress.wait(forAnyOf: [milestone, .processExited], timeout: timeoutSeconds)
            ? .success : .timedOut
    }

    private func writeInitializeRequest(to fileHandle: FileHandle) throws {
        let initialize: [String: Any] = [
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "AgentDock",
                    "version": clientVersion
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        ]
        var data = try JSONSerialization.data(withJSONObject: initialize)
        data.append(0x0A)
        try fileHandle.write(contentsOf: data)
    }

    private func writeRateLimitRequest(to fileHandle: FileHandle, includeAccountDetails: Bool) throws {
        let initialized = """
        {"method":"initialized","params":{}}

        """
        let readRateLimits = """
        {"id":2,"method":"account/rateLimits/read"}

        """
        try fileHandle.write(contentsOf: Data(initialized.utf8))
        if includeAccountDetails {
            // Display metadata from the same isolated app-server; never refresh credentials.
            try fileHandle.write(contentsOf: Data("{\"id\":3,\"method\":\"account/read\",\"params\":{\"refreshToken\":false}}\n".utf8))
        }
        try fileHandle.write(contentsOf: Data(readRateLimits.utf8))
    }

}

/// Milestones reported by the readability and process-exit callbacks. Waiting
/// suspends the task instead of holding a cooperative thread.
private final class AppServerProgress: @unchecked Sendable {
    enum Milestone: Hashable {
        case initialized
        case completed
        case outputClosed
        case processExited
    }

    private struct Waiter {
        var milestones: Set<Milestone>
        var continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var reached: Set<Milestone> = []
    private var waiters: [UUID: Waiter] = [:]

    func mark(_ milestone: Milestone) {
        let ready = lock.withLock {
            reached.insert(milestone)
            let identifiers = waiters.filter { $0.value.milestones.contains(milestone) }.map(\.key)
            return identifiers.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        }
        ready.forEach { $0.resume(returning: true) }
    }

    func hasReached(_ milestone: Milestone) -> Bool {
        lock.withLock { reached.contains(milestone) }
    }

    /// Returns false on timeout or cancellation.
    func wait(forAnyOf milestones: Set<Milestone>, timeout: TimeInterval) async -> Bool {
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Bool? = lock.withLock {
                    if !reached.isDisjoint(with: milestones) { return true }
                    if Task.isCancelled { return false }
                    waiters[identifier] = Waiter(milestones: milestones, continuation: continuation)
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
                    self.resume(identifier, returning: false)
                }
            }
        } onCancel: {
            resume(identifier, returning: false)
        }
    }

    private func resume(_ identifier: UUID, returning value: Bool) {
        lock.withLock { waiters.removeValue(forKey: identifier) }?
            .continuation.resume(returning: value)
    }
}

private final class ResponseState: @unchecked Sendable {
    private struct Envelope: Decodable {
        var id: Int?
    }

    private let lock = NSLock()
    private let maximumBytes: Int
    private let includesAccountDetails: Bool
    private var buffer = Data()
    private var readOffset = 0
    private var storedResponse: Data?
    private var storedAccount: Data?
    private var storedError: String?
    private var receivedInitializeResponse = false

    init(maximumBytes: Int, includesAccountDetails: Bool) {
        self.maximumBytes = maximumBytes
        self.includesAccountDetails = includesAccountDetails
    }

    var isComplete: Bool {
        lock.withLock { storedResponse != nil && (!includesAccountDetails || storedAccount != nil) }
    }

    var accountData: Data? { lock.withLock { storedAccount } }

    var responseData: Data? {
        lock.withLock { storedResponse }
    }

    var errorMessage: String? {
        lock.withLock { storedError }
    }

    var hasInitializeResponse: Bool {
        lock.withLock { receivedInitializeResponse }
    }

    func consume(_ data: Data) {
        lock.withLock {
            guard storedError == nil,
                  storedResponse == nil || (includesAccountDetails && storedAccount == nil) else { return }
            guard !data.isEmpty else { return }
            guard buffer.count - readOffset + data.count <= maximumBytes else {
                storedError = "Codex app-server response exceeded \(maximumBytes) bytes."
                return
            }

            buffer.append(data)
            while
                readOffset < buffer.endIndex,
                let newline = buffer[readOffset...].firstIndex(of: 0x0A)
            {
                let line = Data(buffer[readOffset..<newline])
                readOffset = buffer.index(after: newline)
                guard !line.isEmpty,
                      let envelope = try? JSONDecoder().decode(Envelope.self, from: line)
                else {
                    continue
                }
                if envelope.id == 1 {
                    receivedInitializeResponse = true
                } else if envelope.id == 2 {
                    storedResponse = line
                } else if envelope.id == 3, includesAccountDetails {
                    storedAccount = line
                }
            }
            compactBufferIfNeeded()
        }
    }

    private func compactBufferIfNeeded() {
        guard readOffset >= 64 * 1_024, readOffset >= buffer.count / 2 else {
            return
        }
        buffer.removeSubrange(..<readOffset)
        readOffset = 0
    }
}

enum CodexAccountDisplayParser {
    private struct Envelope: Decodable {
        struct Result: Decodable {
            struct Account: Decodable { var type: String; var email: String? }
            var account: Account?
        }
        var result: Result?
    }

    static func email(from data: Data) -> String? {
        guard let account = try? JSONDecoder().decode(Envelope.self, from: data).result?.account,
              account.type == "chatgpt", let email = account.email,
              !email.isEmpty, email.count <= 320,
              !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return email
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
