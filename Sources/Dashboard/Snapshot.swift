import Foundation

private let dayKeyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
}()

private struct Accumulator {
    var tokens = 0
    var cost = 0.0
    var count = 0
}

// The earliest day a range includes, or nil for the whole history.
func cutoffDay(for range: StatsRange, now: Date = Date()) -> String? {
    guard let window = range.window else { return nil }
    guard let start = Calendar.current.date(byAdding: .day, value: -(window - 1), to: now) else { return nil }
    return dayKeyFormatter.string(from: start)
}

// A snapshot is always re-derived by summing whole day buckets. Changing the
// range therefore needs no rescan and nothing can drift, because no total is
// ever adjusted, only rebuilt.
func buildSnapshot(_ contributions: [FileContribution], range: StatsRange,
                   filesScanned: Int, scanMillis: Int, now: Date = Date()) -> DashboardSnapshot {
    var snapshot = DashboardSnapshot()
    snapshot.generatedAt = now
    snapshot.range = range
    snapshot.filesScanned = filesScanned
    snapshot.scanMillis = scanMillis

    let cutoff = cutoffDay(for: range, now: now)
    // An empty key holds rows with no usable timestamp, so a bounded range drops
    // them by construction rather than guessing a day for them.
    func included(_ day: String) -> Bool {
        guard let cutoff = cutoff else { return true }
        return !day.isEmpty && day >= cutoff
    }

    var models: [String: Accumulator] = [:]
    var projects: [String: Accumulator] = [:]
    var tools: [String: Accumulator] = [:]
    var languages: [String: Int] = [:]
    var days: [String: Accumulator] = [:]
    var sessions = 0

    for contribution in contributions {
        let kept = contribution.byDay.filter { included($0.key) }
        guard !kept.isEmpty else { continue }
        if !contribution.cwd.isEmpty { sessions += 1 }

        var projectTokens = 0
        var projectCost = 0.0
        for (day, bucket) in kept {
            snapshot.messages += bucket.messages
            snapshot.assistantMessages += bucket.assistantMessages
            snapshot.tokens = snapshot.tokens + bucket.tokens
            snapshot.cost = snapshot.cost + bucket.cost

            for (model, totals) in bucket.byModel {
                var entry = models[model] ?? Accumulator()
                entry.tokens += totals.total
                entry.count += totals.records
                entry.cost += bucket.costByModel[model] ?? 0
                models[model] = entry
            }
            for (name, count) in bucket.toolCalls {
                var entry = tools[name] ?? Accumulator()
                entry.count += count
                tools[name] = entry
            }
            for (ext, lines) in bucket.linesByLanguage {
                languages[languageName(forExtension: ext), default: 0] += lines
            }

            var dayEntry = days[day] ?? Accumulator()
            dayEntry.tokens += bucket.tokens.total
            dayEntry.cost += bucket.cost.total
            days[day] = dayEntry

            projectTokens += bucket.tokens.total
            projectCost += bucket.cost.total
        }
        // Keyed by path, so two folders that share a basename stay separate.
        if !contribution.cwd.isEmpty {
            var project = projects[contribution.cwd] ?? Accumulator()
            project.tokens += projectTokens
            project.cost += projectCost
            project.count += 1
            projects[contribution.cwd] = project
        }
    }

    snapshot.sessions = sessions
    snapshot.usageRecords = snapshot.tokens.records
    snapshot.usageRecordsWithoutSplit = snapshot.tokens.recordsWithoutSplit
    snapshot.activeDays = days.values.filter { $0.tokens > 0 || $0.cost > 0 }.count

    let byCost = snapshot.metric == .cost
    func ranked(_ source: [String: Accumulator], label: (String) -> String) -> [RankedEntry] {
        source.map { key, value in
            RankedEntry(key: key, label: label(key), tokens: value.tokens, cost: value.cost, count: value.count)
        }.sorted { a, b in
            let left = byCost ? a.cost : Double(a.tokens)
            let right = byCost ? b.cost : Double(b.tokens)
            return left == right ? a.key < b.key : left > right
        }
    }

    snapshot.models = ranked(models) { $0 }
    var projectEntries = ranked(projects) { ($0 as NSString).lastPathComponent.isEmpty ? $0 : ($0 as NSString).lastPathComponent }
    // Two folders can share a basename, for example
    // ~/Programming/Vibe coding projects/Deutch and ~/TU Dortmund/Deutch. Prefix
    // the parent folder on the colliding rows so the list stays readable.
    var labelCounts: [String: Int] = [:]
    for entry in projectEntries { labelCounts[entry.label, default: 0] += 1 }
    for i in projectEntries.indices where (labelCounts[projectEntries[i].label] ?? 0) > 1 {
        let parent = ((projectEntries[i].key as NSString).deletingLastPathComponent as NSString).lastPathComponent
        if !parent.isEmpty { projectEntries[i].label = "\(parent)/\(projectEntries[i].label)" }
    }
    snapshot.projects = projectEntries
    snapshot.tools = ranked(tools) { $0 }
    snapshot.languages = languages
        .map { LanguageEntry(name: $0.key, lines: $0.value) }
        .sorted { $0.lines == $1.lines ? $0.name < $1.name : $0.lines > $1.lines }

    snapshot.days = series(days, cutoff: cutoff, now: now)
    return snapshot
}

// Ascending, gaps filled with zero. A bounded range shows the whole window, so
// the chart keeps one row per day even when a day was idle.
private func series(_ days: [String: Accumulator], cutoff: String?, now: Date) -> [DayUsage] {
    let keys = days.keys.sorted()
    let firstKey: String
    let lastKey: String
    if let cutoff = cutoff {
        firstKey = cutoff
        lastKey = max(keys.last ?? cutoff, dayKeyFormatter.string(from: now))
    } else {
        guard let first = keys.first, let last = keys.last else { return [] }
        firstKey = first
        lastKey = last
    }
    guard let start = dayKeyFormatter.date(from: firstKey),
          let end = dayKeyFormatter.date(from: lastKey) else { return [] }
    var result: [DayUsage] = []
    var cursor = start
    while cursor <= end {
        let key = dayKeyFormatter.string(from: cursor)
        let entry = days[key] ?? Accumulator()
        result.append(DayUsage(day: key, tokens: entry.tokens, cost: entry.cost))
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: cursor) else { break }
        cursor = next
    }
    return result
}

func languageName(forExtension ext: String) -> String {
    switch ext {
    case "swift": return "Swift"
    case "ts", "tsx": return "TypeScript"
    case "js", "jsx", "mjs", "cjs": return "JavaScript"
    case "py": return "Python"
    case "md", "mdx": return "Markdown"
    case "json": return "JSON"
    case "sh", "bash", "zsh": return "Shell"
    case "html", "htm": return "HTML"
    case "css": return "CSS"
    case "yml", "yaml": return "YAML"
    case "sql": return "SQL"
    case "rs": return "Rust"
    case "go": return "Go"
    case "java": return "Java"
    case "c", "h": return "C"
    case "cpp", "hpp", "cc", "cxx": return "C++"
    case "rb": return "Ruby"
    case "toml": return "TOML"
    case "xml": return "XML"
    case "txt", "text": return "Text"
    default: return ext.isEmpty ? "Other" : ext
    }
}
