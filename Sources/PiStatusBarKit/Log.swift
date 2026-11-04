import Foundation

// One JSONL file shared by the app and the pi extension (logFilePath in
// AppPaths; the extension builds the same path itself). Every record is
// {ts, level, source, event, ...fields}. The file rotates to log.jsonl.1 once
// it passes the cap, so at most two files exist on disk.
//
// Events are appended, never read back, so the append path stays a single
// write. The one whole-file rewrite lives in repairGluedLog, which runs once
// at startup.
private let logCapBytes = 256 * 1024

// Older builds appended records without newlines, gluing them into one
// unparseable line. This splits the glued records and terminates the tail, so
// the file stays one JSON object per line. It rewrites the whole file, so it
// runs once at startup rather than on every event: reading the file on each
// append cost a disk read per log line and could drop a record that the other
// writer appended between the read and the write.
func repairGluedLog(at path: String = logFilePath) {
    guard let whole = try? String(contentsOfFile: path, encoding: .utf8), !whole.isEmpty,
          !whole.hasSuffix("\n") || whole.contains("}{") else { return }
    var repaired = whole.replacingOccurrences(of: "}{", with: "}\n{")
    if !repaired.hasSuffix("\n") { repaired.append("\n") }
    try? repaired.write(toFile: path, atomically: true, encoding: .utf8)
}

func logEvent(level: String, source: String, event: String,
              _ fields: [String: String] = [:], to path: String = logFilePath) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
       let size = attrs[.size] as? Int, size > logCapBytes {
        // rename(2) replaces the old .1 in one step. Removing it first lets
        // the other writer delete the generation this one just moved.
        _ = rename(path, path + ".1")
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
    // O_APPEND makes the offset+write atomic for both writers; FileHandle's
    // seek-then-write could land on a record the extension appended meanwhile.
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else {
        try? data.write(to: URL(fileURLWithPath: path))
        return
    }
    data.withUnsafeBytes { raw in
        guard var buffer = raw.baseAddress else { return }
        var remaining = raw.count
        while remaining > 0 {
            let written = write(fd, buffer, remaining)
            if written < 0 {
                if errno == EINTR { continue }
                break
            }
            if written == 0 { break }
            buffer += written
            remaining -= written
        }
    }
    close(fd)
}
