import Foundation

enum ScanDecision: Equatable {
    case rescan
    case resume(from: Int64)
    case skipUnchanged
}

struct ScanResult: Equatable {
    var contribution: FileContribution
    var cursor: FileCursor
}

// Splits a byte stream into newline terminated lines, carrying a trailing
// incomplete line into the next chunk so a torn write is never half-parsed.
struct LineSplitter {
    var carry = Data()

    @discardableResult
    mutating func process(_ data: Data, _ handler: (Data) -> Void) -> Int {
        let bytes = data.count
        var start = 0
        while start < bytes {
            var end = start
            while end < bytes && data[end] != 10 { end += 1 }
            if end < bytes {
                var line = carry
                line.append(data[start..<end])
                carry.removeAll(keepingCapacity: true)
                handler(line)
                start = end + 1
            } else {
                carry.append(data[start..<bytes])
                break
            }
        }
        return bytes
    }
}

private let usageKey = Data("\"usage\"".utf8)
private let toolCallKey = Data("\"toolCall\"".utf8)
private let timestampKey = Data("\"timestamp\":\"".utf8)
private let messagePrefix = Data("{\"type\":\"message\"".utf8)
private let sessionPrefix = Data("{\"type\":\"session\"".utf8)

final class Scanner {
    let rootDir: String
    private let dayFormatter = DateFormatter()
    private let isoFractional = ISO8601DateFormatter()
    private let isoPlain = ISO8601DateFormatter()
    private(set) var bytesReadThisPass: Int64 = 0

    init(rootDir: String) {
        self.rootDir = rootDir
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoPlain.formatOptions = [.withInternetDateTime]
    }

    func resetByteCounter() { bytesReadThisPass = 0 }

    func enumerateSessionFiles() -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: rootDir) else { return [] }
        var paths: [String] = []
        for case let relative as String in walker where relative.hasSuffix(".jsonl") {
            paths.append((rootDir as NSString).appendingPathComponent(relative))
        }
        return paths.sorted()
    }

    func stat(at path: String) -> (inode: UInt64, size: Int64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return (inode, size)
    }

    func decide(cursor: FileCursor?, inode: UInt64, size: Int64) -> ScanDecision {
        guard let cursor = cursor else { return .rescan }
        if cursor.inode != inode { return .rescan }
        if size < cursor.offset { return .rescan }
        if size == cursor.size { return .skipUnchanged }
        return .resume(from: cursor.offset)
    }

    func scan(path: String, decision: ScanDecision, base: FileContribution,
              inode: UInt64, size: Int64) -> ScanResult? {
        guard decision != .skipUnchanged else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }

        var contribution = base
        var splitter = LineSplitter()
        var read: Int64 = 0
        if case .resume(let offset) = decision {
            read = offset
            try? handle.seek(toOffset: UInt64(offset))
        }

        while read < size {
            let want = Int(min(4 * 1024 * 1024, size - read))
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            bytesReadThisPass += Int64(chunk.count)
            read += Int64(chunk.count)
            splitter.process(chunk) { line in self.consume(line, into: &contribution) }
        }

        let consumed = read - Int64(splitter.carry.count)
        contribution.sessionId = Scanner.sessionId(for: path)
        return ScanResult(contribution: contribution,
                          cursor: FileCursor(inode: inode, offset: consumed, size: size))
    }

    static func sessionId(for path: String) -> String {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let cut = stem.firstIndex(of: "_") { return String(stem[stem.index(after: cut)...]) }
        return stem
    }

    private func consume(_ raw: Data, into contribution: inout FileContribution) {
        // shortcut: the gate trusts Pi to emit these two quoted JSON keys. If a
        // future format drops them the line still counts as a message, but its
        // tokens and tool calls are missed.
        guard raw.range(of: usageKey) != nil || raw.range(of: toolCallKey) != nil else {
            if raw.starts(with: messagePrefix) {
                add(dayKey(in: raw), into: &contribution) { $0.messages += 1 }
            } else if raw.starts(with: sessionPrefix),
                      let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      let cwd = json["cwd"] as? String {
                contribution.cwd = cwd
            }
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              json["type"] as? String == "message",
              let message = json["message"] as? [String: Any] else { return }

        var bucket = DayBucket()
        bucket.messages = 1
        if message["role"] as? String == "assistant" {
            bucket.assistantMessages = 1
            fold(usage: message, into: &bucket)
            for item in (message["content"] as? [[String: Any]]) ?? [] {
                guard item["type"] as? String == "toolCall", let name = item["name"] as? String else { continue }
                bucket.toolCalls[name, default: 0] += 1
                if let args = item["arguments"] as? [String: Any] { countLines(tool: name, args: args, into: &bucket) }
            }
        }
        add(dayKey(in: raw), into: &contribution) { $0 = $0 + bucket }
    }

    // Merges one bucket into its day slot, creating the slot on first use.
    private func add(_ day: String, into contribution: inout FileContribution, _ body: (inout DayBucket) -> Void) {
        var bucket = contribution.byDay[day] ?? DayBucket()
        body(&bucket)
        contribution.byDay[day] = bucket
    }

    // The day a line belongs to, read without parsing the whole object. A tool
    // result body is the bulk of the file and carries no timestamp of its own.
    private func dayKey(in raw: Data) -> String {
        guard let key = raw.range(of: timestampKey) else { return "" }
        let start = key.upperBound
        guard let end = raw[start...].firstIndex(of: 0x22),
              let stamp = String(data: raw[start..<end], encoding: .utf8) else { return "" }
        return day(from: stamp) ?? ""
    }

    private func fold(usage message: [String: Any], into bucket: inout DayBucket) {
        guard let usage = message["usage"] as? [String: Any] else { return }
        var tokens = TokenTotals()
        tokens.input = number(usage["input"])
        tokens.output = number(usage["output"])
        tokens.cacheRead = number(usage["cacheRead"])
        tokens.cacheWrite = number(usage["cacheWrite"])
        tokens.reasoning = number(usage["reasoning"])
        tokens.total = number(usage["totalTokens"])
        tokens.records = 1
        if tokens.splittable == 0 && tokens.total > 0 { tokens.recordsWithoutSplit = 1 }
        bucket.tokens = bucket.tokens + tokens

        var cost = CostTotals()
        if let raw = usage["cost"] as? [String: Any] {
            cost.input = decimal(raw["input"])
            cost.output = decimal(raw["output"])
            cost.cacheRead = decimal(raw["cacheRead"])
            cost.cacheWrite = decimal(raw["cacheWrite"])
            cost.total = decimal(raw["total"])
        }
        bucket.cost = bucket.cost + cost

        let model = message["model"] as? String ?? "unknown"
        bucket.byModel[model, default: TokenTotals()] = bucket.byModel[model, default: TokenTotals()] + tokens
        bucket.costByModel[model, default: 0] += cost.total
    }

    private func countLines(tool: String, args: [String: Any], into bucket: inout DayBucket) {
        let path = args["path"] as? String ?? ""
        switch tool {
        case "write":
            addLines(args["content"] as? String, path: path, into: &bucket)
        case "edit":
            if let edits = args["edits"] as? [[String: Any]] {
                for edit in edits { addLines(edit["newText"] as? String, path: path, into: &bucket) }
            } else if let text = args["newText"] as? String {
                addLines(text, path: path, into: &bucket)
            } else if let text = args["new_text"] as? String {
                addLines(text, path: path, into: &bucket)
            }
        default:
            break
        }
    }

    private func addLines(_ text: String?, path: String, into bucket: inout DayBucket) {
        guard let text = text, !text.isEmpty else { return }
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return }
        let lines = text.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        bucket.linesByLanguage[ext, default: 0] += lines
    }

    private func number(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private func decimal(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private func day(from timestamp: String) -> String? {
        guard let date = isoFractional.date(from: timestamp) ?? isoPlain.date(from: timestamp) else { return nil }
        return dayFormatter.string(from: date)
    }

    // Naive pass: parses every line with no byte gate, visits toolResult
    // records, and only ever adds assistant toolCall blocks to `assistant`.
    func naiveToolCallCount(path: String) -> (assistant: Int, includingResults: Int) {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return (0, 0) }
        defer { try? handle.close() }

        var assistant = 0
        var includingResults = 0
        var splitter = LineSplitter()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            splitter.process(chunk) { raw in
                guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      json["type"] as? String == "message",
                      let message = json["message"] as? [String: Any] else { return }
                if message["role"] as? String == "assistant" {
                    for item in (message["content"] as? [[String: Any]]) ?? []
                    where item["type"] as? String == "toolCall" {
                        assistant += 1
                        includingResults += 1
                    }
                } else if message["role"] as? String == "toolResult" {
                    includingResults += 1
                }
            }
        }
        return (assistant, includingResults)
    }
}
