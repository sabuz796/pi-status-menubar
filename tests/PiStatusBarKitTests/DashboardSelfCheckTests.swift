import XCTest
@testable import PiStatusBarKit

// The dashboard invariants that used to ship as the app's --selfcheck. The
// fixture sessions are tiny, so a plain scan covers the parser, the cache and
// the range filter without a second binary in the app every user runs.
final class DashboardSelfCheckTests: XCTestCase {
    private var cachePath = ""

    // The fixture folder is excluded from the target, so it is found relative
    // to this source file, not to whatever working directory the runner uses.
    private let fixtureRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../fixtures/sessions")
        .standardized.path

    override func setUpWithError() throws {
        cachePath = NSTemporaryDirectory() + "pistatusbar-selfcheck-\(UUID().uuidString)/cache.json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: (cachePath as NSString).deletingLastPathComponent)
    }

    private func coldStore() -> DashboardStore {
        let store = DashboardStore(cachePath: cachePath, sessionRoot: fixtureRoot)
        store.runPassNow()
        return store
    }

    private func toolCalls(_ snapshot: DashboardSnapshot) -> Int {
        snapshot.tools.reduce(0) { $0 + $1.count }
    }

    func testColdScanProducesTotals() {
        let cold = coldStore().lastPassSnapshot
        XCTAssertGreaterThan(cold.filesScanned, 0)
        XCTAssertGreaterThan(cold.messages, 0)
        XCTAssertGreaterThan(cold.assistantMessages, 0)
        XCTAssertGreaterThan(cold.tokens.total, 0)
        XCTAssertGreaterThan(cold.usageRecords, 0)
        XCTAssertFalse(cold.tools.isEmpty)
    }

    func testSecondPassReadsNoBytes() {
        let store = coldStore()
        let coldCursors = store.allCursors
        store.runPassNow()
        XCTAssertEqual(store.bytesReadLastPass, 0, "an unchanged transcript must not be read again")
        XCTAssertEqual(store.allCursors, coldCursors, "cursors survive an unchanged pass")
    }

    func testColdAndIncrementalTotalsMatch() {
        let store = coldStore()
        let cold = store.lastPassSnapshot
        store.runPassNow()
        let warm = store.lastPassSnapshot
        XCTAssertEqual(cold.tokens, warm.tokens)
        XCTAssertEqual(cold.cost, warm.cost)
        XCTAssertEqual(cold.messages, warm.messages)
        XCTAssertEqual(toolCalls(cold), toolCalls(warm))
    }

    func testResummingContributionsEqualsSnapshot() {
        let store = coldStore()
        store.runPassNow()
        let warm = store.lastPassSnapshot
        let resummed = buildSnapshot(store.allContributions, range: .all, filesScanned: 0)
        XCTAssertEqual(resummed.tokens, warm.tokens)
        XCTAssertEqual(resummed.cost, warm.cost)
        XCTAssertEqual(resummed.messages, warm.messages)
        XCTAssertEqual(toolCalls(resummed), toolCalls(warm))
    }

    // The scanner's byte gate skips non-assistant lines for speed. A naive
    // parse of the same files is the guard that the gate still counts every
    // assistant tool call once and never counts tool results.
    func testToolCallsEqualNaiveAssistantOnlyCount() {
        let store = coldStore()
        store.runPassNow()
        let warm = store.lastPassSnapshot
        var naiveAssistant = 0
        for path in Scanner(rootDir: fixtureRoot).enumerateSessionFiles() {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "message",
                      let message = json["message"] as? [String: Any],
                      message["role"] as? String == "assistant" else { continue }
                naiveAssistant += (message["content"] as? [[String: Any]] ?? [])
                    .filter { $0["type"] as? String == "toolCall" }.count
            }
        }
        XCTAssertEqual(toolCalls(warm), naiveAssistant,
                       "scanned tool calls must equal the naive assistant-only count")
    }

    // A bounded range is rebuilt from the same day buckets, so a wider range
    // must always contain the narrower one.
    func testRangeFilteringIsMonotonic() {
        let store = coldStore()
        store.runPassNow()
        let warm = store.lastPassSnapshot
        let day = buildSnapshot(store.allContributions, range: .day, filesScanned: 0)
        let week = buildSnapshot(store.allContributions, range: .week, filesScanned: 0)
        let month = buildSnapshot(store.allContributions, range: .month, filesScanned: 0)
        let every = buildSnapshot(store.allContributions, range: .all, filesScanned: 0)

        XCTAssertLessThanOrEqual(day.tokens.total, week.tokens.total)
        XCTAssertLessThanOrEqual(week.tokens.total, month.tokens.total)
        XCTAssertLessThanOrEqual(month.tokens.total, every.tokens.total)
        XCTAssertLessThanOrEqual(day.messages, week.messages)
        XCTAssertLessThanOrEqual(week.messages, every.messages)
        XCTAssertLessThanOrEqual(day.sessions, week.sessions)
        XCTAssertLessThanOrEqual(week.sessions, every.sessions)
        XCTAssertEqual(every.tokens.total, warm.tokens.total, "all range equals the cold totals")
        XCTAssertEqual(every.messages, warm.messages)
    }

    // One bad future timestamp must not stretch the day series: one 2400
    // stamp used to make 136,299 rows. The series still ends today and fills
    // the gap from the first day to today.
    func testFutureDayDoesNotStretchTheSeries() {
        let now = Date()
        let today = DayKey.key(now)
        let yesterday = DayKey.key(Calendar.current.date(byAdding: .day, value: -1, to: now)!)
        var contribution = FileContribution()
        contribution.byDay[yesterday] = DayBucket()
        contribution.byDay[today] = DayBucket()
        contribution.byDay["9999-12-31"] = DayBucket()

        let all = buildSnapshot([contribution], range: .all, filesScanned: 0, now: now)
        XCTAssertEqual(all.days.map(\.day), [yesterday, today], "the future day is not drawn")
        XCTAssertEqual(all.days.count, 2, "one row per day from the first key to today")

        let day = buildSnapshot([contribution], range: .day, filesScanned: 0, now: now)
        XCTAssertEqual(day.days.map(\.day), [today], "a bounded range also ends today")
    }

    // Removing the dead fields must not orphan a cache the old build wrote:
    // JSONDecoder ignores the extra keys, and the new encoding leaves them out.
    func testCacheStillDecodesTheOlderFieldSet() throws {
        let store = coldStore()
        store.saveNow()
        guard let data = FileManager.default.contents(atPath: cachePath),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var snapshot = object["snapshot"] as? [String: Any] else {
            return XCTFail("cache did not decode as JSON")
        }
        snapshot["scanMillis"] = 12
        snapshot["usageRecordsWithoutSplit"] = 3
        object["snapshot"] = snapshot
        try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: cachePath))

        guard let reloaded = DashboardStore.loadCache(at: cachePath) else {
            return XCTFail("an old cache with extra fields must still load")
        }
        XCTAssertEqual(reloaded.snapshot.tokens, store.lastPassSnapshot.tokens)
        let encoded = try JSONEncoder().encode(reloaded)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("scanMillis"), "the smaller cache drops the dead field")
        XCTAssertFalse(text.contains("usageRecordsWithoutSplit"))
    }

    func testCacheRoundTrips() {
        let store = coldStore()
        store.runPassNow()
        let warm = store.lastPassSnapshot
        store.saveNow()
        guard let reloaded = DashboardStore.loadCache(at: cachePath) else {
            return XCTFail("cache did not load from \(cachePath)")
        }
        XCTAssertEqual(reloaded.cursors, store.allCursors)
        XCTAssertEqual(reloaded.contributions, store.contributionsByPath)
        XCTAssertEqual(reloaded.archive, store.archivedByPath)
        XCTAssertEqual(reloaded.snapshot.tokens, warm.tokens)
        XCTAssertEqual(reloaded.snapshot.cost, warm.cost)
        XCTAssertEqual(reloaded.snapshot.messages, warm.messages)
        XCTAssertEqual(reloaded.snapshot.models, warm.models)
        XCTAssertEqual(reloaded.snapshot.days, warm.days)
        XCTAssertEqual(toolCalls(reloaded.snapshot), toolCalls(warm))
    }
}
