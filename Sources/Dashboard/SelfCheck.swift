import Foundation

enum SelfCheck {
    static func run(sessionRoot: String, cachePath: String) -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "ok  " : "FAIL") \(label): \(detail)")
            if !ok { failures += 1 }
        }

        let store = DashboardStore(cachePath: cachePath, sessionRoot: sessionRoot)
        store.maxFilesPerPass = Int.max // the check needs every file in one pass

        store.runPass()
        let cold = store.lastPassSnapshot
        let coldCursors = store.allCursors
        check("cold scan", cold.filesScanned > 0,
              "files=\(cold.filesScanned) sessions=\(cold.sessions) messages=\(cold.messages) " +
              "assistant=\(cold.assistantMessages) tokens=\(cold.tokens.total) cost=\(cold.cost.total) " +
              "activeDays=\(cold.activeDays) days=\(cold.days.count) models=\(cold.models.count) " +
              "projects=\(cold.projects.count) records=\(cold.usageRecords) " +
              "recordsWithoutSplit=\(cold.usageRecordsWithoutSplit) scanMillis=\(cold.scanMillis)")
        print("      tools:    " + cold.tools.prefix(5).map { "\($0.label)=\($0.count)" }.joined(separator: " "))
        print("      languages: " + cold.languages.prefix(5).map { "\($0.name)=\($0.lines)" }.joined(separator: " "))
        print("      projects: " + cold.projects.prefix(5).map { "\($0.label)=\($0.tokens)" }.joined(separator: " "))

        store.runPass()
        let warm = store.lastPassSnapshot
        let warmBytes = store.bytesReadLastPass
        let secondCursors = store.allCursors
        check("second pass reads only unchanged files", warmBytes == 0, "bytesRead=\(warmBytes)")
        check("cursors stable across passes", coldCursors == secondCursors,
              "cold=\(coldCursors.count) warm=\(secondCursors.count)")

        check("1. cold and incremental totals match",
              tokensEqual(cold.tokens, warm.tokens) && costEqual(cold.cost, warm.cost)
              && cold.messages == warm.messages && toolCalls(cold) == toolCalls(warm),
              "tokens=\(cold.tokens.total)/\(warm.tokens.total) cost=\(cold.cost.total)/\(warm.cost.total) " +
              "messages=\(cold.messages)/\(warm.messages) toolCalls=\(toolCalls(cold))/\(toolCalls(warm))")

        let resummed = buildSnapshot(store.allContributions, range: .all, filesScanned: warm.filesScanned, scanMillis: 0)
        check("2. re-summing contributions equals the snapshot",
              tokensEqual(resummed.tokens, warm.tokens) && costEqual(resummed.cost, warm.cost)
              && resummed.messages == warm.messages && toolCalls(resummed) == toolCalls(warm),
              "tokens=\(resummed.tokens.total) messages=\(resummed.messages) toolCalls=\(toolCalls(resummed))")

        let naive = Scanner(rootDir: sessionRoot)
        var naiveAssistant = 0
        var naiveIncludingResults = 0
        for path in naive.enumerateSessionFiles() {
            let counts = naive.naiveToolCallCount(path: path)
            naiveAssistant += counts.assistant
            naiveIncludingResults += counts.includingResults
        }
        check("3. tool calls equal the naive assistant-only count",
              toolCalls(warm) == naiveAssistant,
              "scan=\(toolCalls(warm)) naiveAssistant=\(naiveAssistant) " +
              "naiveIncludingResults=\(naiveIncludingResults) (double-count guard)")

        // 5. Range filtering is monotonic and never invents usage. A bounded
        // range is rebuilt from the same day buckets, so a wider range must
        // always contain the narrower one.
        func ranged(_ r: StatsRange) -> DashboardSnapshot {
            buildSnapshot(store.allContributions, range: r, filesScanned: 0, scanMillis: 0)
        }
        let day = ranged(.day), week = ranged(.week), month = ranged(.month), every = ranged(.all)
        let monotonic = day.tokens.total <= week.tokens.total
            && week.tokens.total <= month.tokens.total
            && month.tokens.total <= every.tokens.total
        let messagesMonotonic = day.messages <= week.messages && week.messages <= every.messages
        let sessionsMonotonic = day.sessions <= week.sessions && week.sessions <= every.sessions
        let allMatches = every.tokens.total == warm.tokens.total && every.messages == warm.messages
        check("5. range filtering is monotonic and bounded",
              monotonic && messagesMonotonic && sessionsMonotonic && allMatches,
              "tokens 1d=\(day.tokens.total) 7d=\(week.tokens.total) 30d=\(month.tokens.total) all=\(every.tokens.total) " +
              "sessions 1d=\(day.sessions) 7d=\(week.sessions) all=\(every.sessions) " +
              "days 1d=\(day.days.count) 7d=\(week.days.count)")

        store.saveNow()
        let reloaded = DashboardStore.loadCache(at: cachePath)
        let roundTrips = reloaded.map {
            $0.cursors == store.allCursors && $0.contributions == store.contributionsByPath
            && tokensEqual($0.snapshot.tokens, warm.tokens) && costEqual($0.snapshot.cost, warm.cost)
            && $0.snapshot.messages == warm.messages && toolCalls($0.snapshot) == toolCalls(warm)
            && $0.snapshot.models == warm.models && $0.snapshot.days == warm.days
        } ?? false
        check("4. cache save and load round-trip", roundTrips,
              "path=\(cachePath) exists=\(reloaded != nil)")

        print(failures == 0 ? "selfcheck PASS" : "selfcheck FAIL (\(failures))")
        return failures == 0 ? 0 : 1
    }

    private static func toolCalls(_ snapshot: DashboardSnapshot) -> Int {
        snapshot.tools.reduce(0) { $0 + $1.count }
    }

    private static func tokensEqual(_ a: TokenTotals, _ b: TokenTotals) -> Bool {
        a.input == b.input && a.output == b.output && a.cacheRead == b.cacheRead
        && a.cacheWrite == b.cacheWrite && a.reasoning == b.reasoning && a.total == b.total
        && a.records == b.records && a.recordsWithoutSplit == b.recordsWithoutSplit
    }

    private static func costEqual(_ a: CostTotals, _ b: CostTotals) -> Bool {
        a.input == b.input && a.output == b.output && a.cacheRead == b.cacheRead
        && a.cacheWrite == b.cacheWrite && a.total == b.total
    }
}
