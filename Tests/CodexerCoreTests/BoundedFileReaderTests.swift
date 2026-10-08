import Darwin
import XCTest
@testable import CodexerCore

final class BoundedFileReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedFileReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testReadsRegularFileAtExactLimit() throws {
        let url = root.appendingPathComponent("control.json")
        let expected = Data("12345678".utf8)
        try expected.write(to: url)

        XCTAssertEqual(
            try BoundedFileReader.data(at: url, maximumBytes: expected.count),
            expected
        )
    }

    func testRejectsOversizedAndSymlinkedFiles() throws {
        let outside = root.appendingPathComponent("outside.json")
        try Data(repeating: 0x41, count: 9).write(to: outside)
        XCTAssertThrowsError(
            try BoundedFileReader.data(at: outside, maximumBytes: 8)
        )

        let link = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(
            try BoundedFileReader.data(at: link, maximumBytes: 64)
        )
    }

    func testRejectsFIFOWithoutBlocking() throws {
        let fifo = root.appendingPathComponent("control.pipe")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)

        let started = ContinuousClock.now
        XCTAssertThrowsError(
            try BoundedFileReader.data(at: fifo, maximumBytes: 64)
        )
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }
}
