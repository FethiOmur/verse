import Darwin
import Foundation
@testable import VerseUI
import XCTest

/// Review U1: an I/O error while logging (a full disk) drops the line instead of raising an Objective-C exception that ends
/// the app, and logging resumes with the next line.
final class FileLogTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("verse-filelog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAWriteErrorDropsTheLineAndTheLogRecovers() throws {
        let url = dir.appendingPathComponent("verse.log")
        let log = FileLog(url: url)
        log.write("first line")
        let h = try XCTUnwrap(log.handleForTesting)
        // Swap the handle's descriptor for a read-only one on the same file: the next write fails (EBADF), the way a full
        // disk fails it (ENOSPC). The descriptor number stays the handle's own, so closing it later is safe.
        let ro = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(ro, 0)
        XCTAssertEqual(dup2(ro, h.fileDescriptor), h.fileDescriptor)
        close(ro)

        log.write("lost line")      // before the fix: NSFileHandleOperationException, the whole process ends here
        XCTAssertEqual(log.droppedLines, 1)
        XCTAssertNil(log.handleForTesting, "the broken handle is closed")

        log.write("after the error")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("first line"), text)
        XCTAssertTrue(text.contains("after the error"), text)
        XCTAssertFalse(text.contains("lost line"), text)
        XCTAssertEqual(log.droppedLines, 1)
    }
}
