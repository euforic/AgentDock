import Darwin
import Foundation

enum SubprocessTerminator {
    static func terminateAndWait(_ process: Process, gracePeriod: TimeInterval = 1) {
        let rootPID = process.processIdentifier
        guard rootPID > 0 else { return }
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        let descendants = descendantProcessIDs(of: rootPID)
        let processIDs = Array(descendants.reversed()) + [rootPID]

        for processID in processIDs {
            _ = kill(processID, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(gracePeriod)
        while processIDs.contains(where: isRunning), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        for processID in processIDs where isRunning(processID) {
            _ = kill(processID, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func descendantProcessIDs(of rootPID: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }

            var childrenByParent: [Int32: [Int32]] = [:]
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count == 2,
                      let processID = Int32(fields[0]),
                      let parentID = Int32(fields[1])
                else {
                    continue
                }
                childrenByParent[parentID, default: []].append(processID)
            }

            var result: [Int32] = []
            var pending = childrenByParent[rootPID] ?? []
            while let processID = pending.popLast() {
                result.append(processID)
                pending.append(contentsOf: childrenByParent[processID] ?? [])
            }
            return result
        } catch {
            return []
        }
    }

    private static func isRunning(_ processID: Int32) -> Bool {
        guard kill(processID, 0) == 0 else {
            return errno == EPERM
        }
        return true
    }
}
