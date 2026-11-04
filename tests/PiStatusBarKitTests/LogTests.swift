import XCTest
@testable import PiStatusBarKit

// logEvent must keep the file parseable: one JSON object per line. It also
// has to survive a file left behind by older builds, which appended records
// without any newline, gluing them into one unparseable blob.
final class LogTests: XCTestCase {
    private var path = ""

    override func setUp() {
        path = NSTemporaryDirectory() + "pistatusbar-log-\(UUID().uuidString).jsonl"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".1")
    }

    private func lines() -> [String] {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
    }

    func testEachRecordIsItsOwnLine() throws {
        logEvent(level: "info", source: "test", event: "one", to: path)
        logEvent(level: "warn", source: "test", event: "two", to: path)
        let ls = lines()
        XCTAssertEqual(ls.count, 2, "one record per line")
        XCTAssertEqual(try JSONDecoder().decode([String: String].self,
            from: Data(ls[0].utf8))["event"], "one")
        XCTAssertEqual(try JSONDecoder().decode([String: String].self,
            from: Data(ls[1].utf8))["event"], "two")
    }

    func testSeparatesFromALegacyNewlinelessTail() throws {
        try "{\"event\":\"old\"}{\"event\":\"old2\"}".write(toFile: path, atomically: true, encoding: .utf8)
        repairGluedLog(at: path)
        logEvent(level: "info", source: "test", event: "new", to: path)
        let ls = lines()
        XCTAssertEqual(ls.count, 3, "the glued legacy tail is split, not extended")
        XCTAssertEqual(ls[0], "{\"event\":\"old\"}")
        XCTAssertEqual(ls[1], "{\"event\":\"old2\"}")
        XCTAssertEqual(try JSONDecoder().decode([String: String].self,
            from: Data(ls[2].utf8))["event"], "new")
    }

    // The repair rewrites the whole file, so it must not run on the append
    // path: a record appended by the other writer between the read and the
    // write would be lost.
    func testAppendingDoesNotRewriteTheFile() throws {
        let legacy = "{\"event\":\"glued\"}{"
        try legacy.write(toFile: path, atomically: true, encoding: .utf8)
        logEvent(level: "info", source: "test", event: "new", to: path)
        let whole = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(whole.hasPrefix(legacy), "the append leaves earlier bytes exactly as they were")
        XCTAssertEqual(whole.filter { $0 == "\n" }.count, 1, "no split happens on append")
    }

    func testRepairIsIdempotent() throws {
        try "{\"event\":\"a\"}{\"event\":\"b\"}".write(toFile: path, atomically: true, encoding: .utf8)
        repairGluedLog(at: path)
        let once = try String(contentsOfFile: path, encoding: .utf8)
        repairGluedLog(at: path)
        let twice = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(once, twice, "a repaired file is left alone")
        XCTAssertEqual(lines().count, 2)
    }

    // Rotation keeps one generation. The cap is 256 KB, so the test fills the
    // file past it instead of writing thousands of records. This is a
    // regression guard for the path: the defect it guards against is a race
    // between two writers, which a sequential test cannot reproduce.
    func testRotationKeepsThePreviousGeneration() throws {
        let old = String(repeating: "o", count: 300_000)
        try old.write(toFile: path, atomically: true, encoding: .utf8)
        logEvent(level: "info", source: "test", event: "first", to: path)
        XCTAssertEqual(try String(contentsOfFile: path + ".1", encoding: .utf8), old,
                       "the full file moves to .1")
        XCTAssertEqual(lines().count, 1, "the live file starts over with one record")

        let newer = String(repeating: "n", count: 300_000)
        try newer.write(toFile: path, atomically: true, encoding: .utf8)
        logEvent(level: "info", source: "test", event: "second", to: path)
        XCTAssertEqual(try String(contentsOfFile: path + ".1", encoding: .utf8), newer,
                       "a second rotation replaces .1 in one step")
        XCTAssertEqual(lines().count, 1)
    }
}
