import XCTest
@testable import PiStatusBarKit

// Exact-value checks for pruning: which transcripts leave the hot set, and
// that a fresh set under the cap is never touched.
final class DashboardPruneTests: XCTestCase {
    private func cursor(changed: Date) -> FileCursor {
        var c = FileCursor(inode: 1, offset: 0, size: 0)
        c.lastChanged = changed
        return c
    }

    private func contribution(_ id: String) -> FileContribution {
        var c = FileContribution()
        c.sessionId = id
        return c
    }

    func testStaleTranscriptsRetireFirst() {
        var cursors = [String: FileCursor]()
        var contributions = [String: FileContribution]()
        let now = Date()
        // Three files: one stale, two fresh. The stale one is the only retiree.
        cursors["stale"] = cursor(changed: now.addingTimeInterval(-61 * 86400))
        cursors["fresh-1"] = cursor(changed: now)
        cursors["fresh-2"] = cursor(changed: now)
        contributions["stale"] = contribution("s1")
        contributions["fresh-1"] = contribution("s2")
        contributions["fresh-2"] = contribution("s3")

        let cutoff = now.addingTimeInterval(-60 * 86400)
        let retired = DashboardStore.retiredPaths(contributions, cursors,
                                                  staleCutoff: cutoff, hotCap: 64)
        XCTAssertEqual(retired, ["stale"], "only the 61-day-old transcript is cold")
    }

    func testCapRetiresOldestFirstAndKeepsTheCap() {
        var cursors = [String: FileCursor]()
        var contributions = [String: FileContribution]()
        let now = Date()
        // Five fresh files, hot cap 2: enough retire that two remain, oldest first.
        for (i, name) in ["a", "b", "c", "d", "e"].enumerated() {
            cursors[name] = cursor(changed: now.addingTimeInterval(Double(i) * 3600))
            contributions[name] = contribution("s\(i)")
        }
        let retired = DashboardStore.retiredPaths(contributions, cursors,
                                                  staleCutoff: now.addingTimeInterval(3600),
                                                  hotCap: 2)
        XCTAssertEqual(retired, ["a", "b", "c"], "the three oldest leave the hot set")
    }

    func testFreshSetUnderCapIsUntouched() {
        var cursors = [String: FileCursor]()
        var contributions = [String: FileContribution]()
        let now = Date()
        cursors["p1"] = cursor(changed: now)
        cursors["p2"] = cursor(changed: now)
        contributions["p1"] = contribution("s1")
        contributions["p2"] = contribution("s2")
        let retired = DashboardStore.retiredPaths(contributions, cursors,
                                                  staleCutoff: now.addingTimeInterval(-86400),
                                                  hotCap: 64)
        XCTAssertTrue(retired.isEmpty, "nothing to prune is a no-op")
    }

    // MARK: integration through a real pass

    // Seeds a saved cache (v2) with aged+fresh cursors over two real fixture
    // files, then runs an actual pass: the stale transcript must move to the
    // archive, the totals must survive, and the saved cache must round-trip.
    func testPassRetiresStaleTranscriptIntoArchiveAndKeepsTotals() {
        let root = NSTemporaryDirectory() + "pistatusbar-prune-\(UUID().uuidString)"
        let home = (root as NSString).appendingPathComponent("home")
        let cachePath = (home as NSString).appendingPathComponent("dashboard-cache.json")
        defer { try? FileManager.default.removeItem(atPath: root) }

        let scanner = Scanner(rootDir: root)
        var cursors = [String: FileCursor]()
        var contributions = [String: FileContribution]()
        var expectedTokens = 0
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // Two one-message transcripts; the tail line ends the day buckets.
        for name in ["stale", "fresh"] {
            let file = (root as NSString).appendingPathComponent(name + ".jsonl")
            let text = "{\"type\":\"message\",\"timestamp\":\"2026-01-02T03:04:05.000Z\",\"message\":{\"role\":\"assistant\",\"usage\":{\"totalTokens\":10,\"total\":10},\"content\":[]}}\n"
            try? (text as NSString).write(toFile: file, atomically: true, encoding: String.Encoding.utf8.rawValue)
            let s = scanner.stat(at: file)!
            // The fresh cursor must match the file exactly, or the pass would
            // rescan and rebuild the contribution from scratch.
            cursors[file] = FileCursor(inode: s.inode, offset: s.size, size: s.size,
                                       lastChanged: name == "stale"
                                           ? Date().addingTimeInterval(-70 * 86400)
                                           : Date(), mtime: s.mtime)
            var c = contribution("s-" + name)
            c.cwd = "/tmp/" + name
            var bucket = DayBucket()
            bucket.tokens.total = 10
            bucket.messages = 1
            c.byDay["2026-01-02"] = bucket
            contributions[file] = c
            expectedTokens += 10
        }
        let cache = DashboardCache(version: 2, timeZoneIdentifier: TimeZone.current.identifier,
                                   range: .all, savedAt: Date(), cursors: cursors,
                                   contributions: contributions, archive: [:],
                                   snapshot: DashboardSnapshot())
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: URL(fileURLWithPath: cachePath))

        let store = DashboardStore(cachePath: cachePath, sessionRoot: root)
        store.runPassNow()

        let staleFile = (root as NSString).appendingPathComponent("stale.jsonl")
        XCTAssertTrue(store.contributionsByPath[staleFile] == nil, "stale transcript left the hot set")
        let archived = store.archivedByPath[staleFile]
        XCTAssertEqual(archived?.byDay["2026-01-02"]?.tokens.total, 10, "stale totals live in the archive")
        XCTAssertEqual(store.lastPassSnapshot.tokens.total, expectedTokens,
                       "all-range totals keep the retired data")
        XCTAssertEqual(store.lastPassSnapshot.sessions, 2, "the archive keeps the session row")

        store.stop()
        let reloaded = DashboardStore.loadCache(at: cachePath)
        XCTAssertNotNil(reloaded?.archive[staleFile], "the archive persists to disk")
    }
}
