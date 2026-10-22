import Foundation

struct TokenTotals: Codable, Equatable {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, reasoning = 0
    var total = 0
    var records = 0
    var recordsWithoutSplit = 0

    static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheRead: a.cacheRead + b.cacheRead,
            cacheWrite: a.cacheWrite + b.cacheWrite,
            reasoning: a.reasoning + b.reasoning,
            total: a.total + b.total,
            records: a.records + b.records,
            recordsWithoutSplit: a.recordsWithoutSplit + b.recordsWithoutSplit
        )
    }

    var splittable: Int { input + output + cacheRead + cacheWrite }
}

struct CostTotals: Codable, Equatable {
    var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0, total = 0.0

    static func + (a: CostTotals, b: CostTotals) -> CostTotals {
        CostTotals(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheRead: a.cacheRead + b.cacheRead,
            cacheWrite: a.cacheWrite + b.cacheWrite,
            total: a.total + b.total
        )
    }
}

// One day of one transcript. Every dimension is scoped to the day so a range
// filter can rebuild any view without touching the files again.
struct DayBucket: Codable, Equatable {
    var messages = 0
    var assistantMessages = 0
    var tokens = TokenTotals()
    var cost = CostTotals()
    var byModel: [String: TokenTotals] = [:]
    var costByModel: [String: Double] = [:]
    var toolCalls: [String: Int] = [:]
    var linesByLanguage: [String: Int] = [:]

    static func + (a: DayBucket, b: DayBucket) -> DayBucket {
        var out = DayBucket()
        out.messages = a.messages + b.messages
        out.assistantMessages = a.assistantMessages + b.assistantMessages
        out.tokens = a.tokens + b.tokens
        out.cost = a.cost + b.cost
        for (k, v) in a.byModel { out.byModel[k] = (out.byModel[k] ?? TokenTotals()) + v }
        for (k, v) in b.byModel { out.byModel[k] = (out.byModel[k] ?? TokenTotals()) + v }
        for (k, v) in a.costByModel { out.costByModel[k, default: 0] += v }
        for (k, v) in b.costByModel { out.costByModel[k, default: 0] += v }
        for (k, v) in a.toolCalls { out.toolCalls[k, default: 0] += v }
        for (k, v) in b.toolCalls { out.toolCalls[k, default: 0] += v }
        for (k, v) in a.linesByLanguage { out.linesByLanguage[k, default: 0] += v }
        for (k, v) in b.linesByLanguage { out.linesByLanguage[k, default: 0] += v }
        return out
    }
}

// What the header control selects. The window is inclusive of today.
enum StatsRange: String, Codable, CaseIterable {
    case day, week, month, all

    var label: String {
        switch self {
        case .day: return "Today"
        case .week: return "7d"
        case .month: return "30d"
        case .all: return "All"
        }
    }

    // nil means no lower bound.
    var window: Int? {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }
}

struct FileContribution: Codable, Equatable {
    var sessionId = ""
    var cwd = ""
    // Keyed "yyyy-MM-dd" in the local calendar. Rows with no usable timestamp
    // land under "", which every bounded range excludes by construction.
    var byDay: [String: DayBucket] = [:]
}

struct FileCursor: Codable, Equatable {
    var inode: UInt64
    var offset: Int64
    var size: Int64
}

struct RankedEntry: Codable, Equatable {
    var key: String
    var label: String
    var tokens: Int
    var cost: Double
    var count: Int
}

struct DayUsage: Codable, Equatable {
    var day: String
    var tokens: Int
    var cost: Double
}

struct LanguageEntry: Codable, Equatable {
    var name: String
    var lines: Int
}

struct DashboardSnapshot: Codable, Equatable {
    var generatedAt = Date()
    var range: StatsRange = .all
    var sessions = 0, messages = 0, assistantMessages = 0, activeDays = 0
    var tokens = TokenTotals(), cost = CostTotals()
    var days: [DayUsage] = []
    var models: [RankedEntry] = []
    var projects: [RankedEntry] = []
    var languages: [LanguageEntry] = []
    var tools: [RankedEntry] = []
    var usageRecords = 0, usageRecordsWithoutSplit = 0
    var filesScanned = 0, scanMillis = 0
    var metric: Metric { Metric(costTotal: cost.total) }
    var topLanguage: LanguageEntry? { languages.first }
}

enum Metric: String, Codable {
    case tokens, cost
    init(costTotal: Double) { self = costTotal > 0 ? .cost : .tokens }
    var listLabel: String { self == .cost ? "by cost" : "by tokens" }
}

struct DashboardCache: Codable {
    var version = 2
    var timeZoneIdentifier: String
    var range: StatsRange = .all
    var savedAt: Date
    var cursors: [String: FileCursor]
    var contributions: [String: FileContribution]
    var snapshot: DashboardSnapshot
}