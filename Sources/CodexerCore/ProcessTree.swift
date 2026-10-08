import Darwin
import Foundation

public struct ProcessIdentity: Hashable, Sendable {
    public var processID: Int32
    public var parentProcessID: Int32
    public var startKey: String
    public var command: String
    public var kernelStartKey: String?

    public init(
        processID: Int32,
        parentProcessID: Int32,
        startKey: String,
        command: String,
        kernelStartKey: String? = nil
    ) {
        self.processID = processID
        self.parentProcessID = parentProcessID
        self.startKey = startKey
        self.command = command
        self.kernelStartKey = kernelStartKey
    }
}

public protocol ProcessTreeSnapshotProviding: Sendable {
    func processTreeSnapshot() throws -> [ProcessIdentity]
}

public struct SystemProcessTreeSnapshotProvider: ProcessTreeSnapshotProviding {
    public init() {}

    public func processTreeSnapshot() throws -> [ProcessIdentity] {
        let result = try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ax", "-o", "pid=,ppid=,lstart=,command="],
            timeout: 3,
            maximumOutputBytes: 16 * 1_024 * 1_024
        )
        guard result.terminationStatus == 0, !result.exceededOutputLimit else {
            throw CodexLauncherError.processInspectionUnavailable
        }
        return Self.parse(String(decoding: result.output, as: UTF8.self))
    }

    public static func parse(_ snapshot: String) -> [ProcessIdentity] {
        snapshot.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(
                maxSplits: 7,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 8,
                  let processID = Int32(fields[0]),
                  let parentProcessID = Int32(fields[1])
            else {
                return nil
            }
            return ProcessIdentity(
                processID: processID,
                parentProcessID: parentProcessID,
                startKey: fields[2...6].joined(separator: " "),
                command: String(fields[7])
            )
        }
    }

    public static func descendants(
        of rootProcessIDs: Set<Int32>,
        in snapshot: [ProcessIdentity]
    ) -> [ProcessIdentity] {
        var childrenByParent: [Int32: [ProcessIdentity]] = [:]
        for identity in snapshot {
            childrenByParent[identity.parentProcessID, default: []].append(identity)
        }
        var descendants: [ProcessIdentity] = []
        var pending = rootProcessIDs.flatMap { childrenByParent[$0] ?? [] }
        while let identity = pending.popLast() {
            descendants.append(identity)
            pending.append(contentsOf: childrenByParent[identity.processID] ?? [])
        }
        return descendants
    }

    static func kernelStartKey(for processID: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, Int32(size))
        }
        guard result == Int32(size) else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    static func executableURL(for processID: Int32) -> URL? {
        var path = [CChar](
            repeating: 0,
            count: Int(MAXPATHLEN) * 4
        )
        let length = proc_pidpath(processID, &path, UInt32(path.count))
        guard length > 0 else { return nil }
        let bytes = path.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }
}

public protocol ProcessIdentitySignaling: Sendable {
    func signal(_ signal: Int32, identities: [ProcessIdentity]) throws
}

public struct SystemProcessIdentitySignaler: ProcessIdentitySignaling {
    private let snapshotProvider: any ProcessTreeSnapshotProviding
    private let validatesKernelIdentity: Bool
    private let signalSender: @Sendable (Int32, Int32) -> Int32

    public init(
        snapshotProvider: any ProcessTreeSnapshotProviding = SystemProcessTreeSnapshotProvider()
    ) {
        self.snapshotProvider = snapshotProvider
        validatesKernelIdentity = snapshotProvider is SystemProcessTreeSnapshotProvider
        signalSender = { processID, signal in kill(processID, signal) }
    }

    init(
        snapshotProvider: any ProcessTreeSnapshotProviding,
        signalSender: @escaping @Sendable (Int32, Int32) -> Int32
    ) {
        self.snapshotProvider = snapshotProvider
        validatesKernelIdentity = false
        self.signalSender = signalSender
    }

    public func signal(_ signal: Int32, identities: [ProcessIdentity]) throws {
        let currentByPID = Dictionary(
            uniqueKeysWithValues: try snapshotProvider.processTreeSnapshot().map {
                ($0.processID, $0)
            }
        )
        for identity in identities {
            guard let current = currentByPID[identity.processID],
                  current.startKey == identity.startKey,
                  current.command == identity.command
            else {
                continue
            }
            if validatesKernelIdentity {
                guard let kernelStartKey = identity.kernelStartKey,
                      SystemProcessTreeSnapshotProvider.kernelStartKey(for: identity.processID)
                        == kernelStartKey
                else {
                    continue
                }
            }
            _ = signalSender(identity.processID, signal)
        }
    }
}
