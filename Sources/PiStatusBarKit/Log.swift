import Foundation

// One JSONL file shared by the app and the pi extension (logFilePath in
// AppPaths; the extension builds the same path itself). Every record is
// {ts, level, source, event, ...fields}. The file rotates to log.jsonl.1
// once it passes the cap, so at most two files exist on disk.
private let logCapBytes = 256 * 1024

func logEvent(level: String, source: String, event: String,
              _ fields: [String: String] = [:], to path: String = logFilePath) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
       let size = attrs[.size] as? Int, size > logCapBytes {
        try? FileManager.default.removeItem(atPath: path + ".1")
        try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
    }
    // Older builds appended records without newlines, gluing them into one
    // unparseable line. One-time repair: split glued records and terminate
    // the tail, so the file stays one JSON object per line. Events are
    // sparse and the file is capped at 256 KB, so the read per write is fine.
    if let whole = try? String(contentsOfFile: path, encoding: .utf8), !whole.isEmpty,
       !whole.hasSuffix("\n") || whole.contains("}{") {
        var repaired = whole.replacingOccurrences(of: "}{", with: "}\n{")
        if !repaired.hasSuffix("\n") { repaired.append("\n") }
        try? repaired.write(toFile: path, atomically: true, encoding: .utf8)
    }
    var record: [String: Any] = [
        "ts": ISO8601DateFormatter().string(from: Date()),
        "level": level,
        "source": source,
        "event": event,
    ]
    for (key, value) in fields { record[key] = value }
    guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
    data.append(0x0A)
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
