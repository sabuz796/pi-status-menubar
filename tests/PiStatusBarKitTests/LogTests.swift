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
        logEvent(level: "info", source: "test", event: "new", to: path)
        let ls = lines()
        XCTAssertEqual(ls.count, 3, "the glued legacy tail is split, not extended")
        XCTAssertEqual(ls[0], "{\"event\":\"old\"}")
        XCTAssertEqual(ls[1], "{\"event\":\"old2\"}")
        XCTAssertEqual(try JSONDecoder().decode([String: String].self,
            from: Data(ls[2].utf8))["event"], "new")
    }
}
