import XCTest
@testable import PiStatusBarKit

// Exact-value checks for the scan decisions: when a file is skipped, resumed,
// or re-read from scratch, and that a rescan never adds old totals a second
// time.
final class ScannerTests: XCTestCase {
    private var dir = ""
    private var path = ""

    override func setUp() {
        dir = NSTemporaryDirectory() + "pistatusbar-scanner-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = (dir as NSString).appendingPathComponent("t.jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func write(_ text: String) -> (inode: UInt64, size: Int64, mtime: Date) {
        try? (text as NSString).write(toFile: path, atomically: true, encoding: String.Encoding.utf8.rawValue)
        return Scanner(rootDir: dir).stat(at: path)!
    }

    private func cursor(_ stat: (inode: UInt64, size: Int64, mtime: Date),
                        offset: Int64, mtime: Date? = nil) -> FileCursor {
        FileCursor(inode: stat.inode, offset: offset, size: stat.size,
                   lastChanged: Date(), mtime: mtime ?? stat.mtime)
    }

    private func contributedTokens(_ result: ScanResult) -> Int {
        result.contribution.byDay.values.reduce(0) { $0 + $1.tokens.total }
    }

    // MARK: decide

    private let line = "{\"type\":\"message\",\"timestamp\":\"2026-01-02T03:04:05.000Z\",\"message\":{\"role\":\"assistant\",\"usage\":{\"totalTokens\":10},\"content\":[]}}\n"

    func testSameSizeAndMtimeSkips() {
        let s = write(line)
        let scanner = Scanner(rootDir: dir)
        let d = scanner.decide(cursor: cursor(s, offset: s.size), inode: s.inode, size: s.size, mtime: s.mtime)
        XCTAssertEqual(d, .skipUnchanged, "identical file is skipped")
    }

    func testSameSizeNewerMtimeRescans() {
        let s = write(line)
        let scanner = Scanner(rootDir: dir)
        let old = cursor(s, offset: s.size, mtime: Date.distantPast)
        let d = scanner.decide(cursor: old, inode: s.inode, size: s.size, mtime: s.mtime)
        XCTAssertEqual(d, .rescan, "rewritten in place must be read again, not skipped")
    }

    func testResumeFromZeroRestartsWithoutOldBase() {
        let s = write(line)
        let scanner = Scanner(rootDir: dir)
        // First line with no trailing newline: offset is 0, so a resume would
        // read the bytes already counted. Restart instead.
        let d = scanner.decide(cursor: cursor(s, offset: 0), inode: s.inode, size: s.size + 5, mtime: s.mtime)
        XCTAssertEqual(d, .rescan, "offset 0 cannot resume onto stored totals")
    }

    // MARK: scan base semantics

    func testRescanReplacesRatherThanAddsOldTotals() {
        let s = write(line)
        var old = FileContribution()
        old.cwd = "/tmp/old"
        var bucket = DayBucket()
        bucket.tokens.total = 333
        bucket.messages = 7
        old.byDay["1999-01-01"] = bucket

        let scanner = Scanner(rootDir: dir)
        let result = scanner.scan(path: path, decision: .rescan, base: old,
                                  inode: s.inode, size: s.size, mtime: s.mtime)
        XCTAssertEqual(contributedTokens(result!), 10, "rescan counts the file once, not 333 + 10")
        XCTAssertEqual(result!.contribution.byDay["1999-01-01"], nil, "the old bucket is gone")
    }

    func testResumeAddsOnTopOfStoredTotals() {
        let s = write(line + line) // two messages: 20 tokens
        var stored = FileContribution()
        var bucket = DayBucket()
        bucket.tokens.total = 10
        stored.byDay["2026-01-02"] = bucket

        let scanner = Scanner(rootDir: dir)
        let result = scanner.scan(path: path, decision: .resume(from: Int64(line.utf8.count)), base: stored,
                                  inode: s.inode, size: s.size, mtime: s.mtime)
        XCTAssertEqual(contributedTokens(result!), 20, "stored 10 + resumed 10 = 20")
    }
}
