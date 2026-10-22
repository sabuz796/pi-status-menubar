import Foundation
import Darwin

// The state files the Pi extension writes, and the rules for what they
// mean: which state wins, when a file went stale, and whether the Pi
// process behind it is still alive. No AppKit here on purpose - the rules
// are checkable on their own (tests/sessionrules).

// One session's state file, as the extension wrote it.
struct Session {
    var id: String
    var state: String
    var label: String
    var project: String
    var cwd: String
    var sessionName: String
    var termProgram: String
    var pid: Int32
    var started: Bool
    var startedAt: Double
    var ts: Double
    var eff: String = "" // the derived state, set by the app

    init(json o: [String: Any], id: String) {
        self.id = id
        self.state = o["state"] as? String ?? "idle"
        self.label = o["label"] as? String ?? ""
        self.project = o["project"] as? String ?? ""
        self.cwd = o["cwd"] as? String ?? ""
        self.sessionName = o["sessionName"] as? String ?? ""
        self.termProgram = o["term_program"] as? String ?? ""
        self.pid = Int32(truncatingIfNeeded: (o["pid"] as? NSNumber)?.intValue ?? 0)
        self.started = o["started"] as? Bool ?? true
        self.startedAt = (o["startedAt"] as? NSNumber)?.doubleValue ?? 0
        self.ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
    }
}

// What one session file means right now.
struct SessionDecision {
    let effective: String // the state to show
    let reaped: Bool // the file is dead: delete it
    let cue: Cue? // the sound the change owes, if any
}

enum SessionRules {
    // Staleness caps - aligned with extension's heartbeat refresh
    static let workingStaleCap: TimeInterval = 180 // 3 missed heartbeats (30s each)
    static let permissionStaleCap: TimeInterval = 7200 // 2 hours
    static let idleReapAfter: TimeInterval = 900 // 15 minutes for files without a pid

    // Which state wins when several sessions are live.
    static func priority(of eff: String) -> Int {
        switch eff {
        case "permission": return 2
        case "thinking", "tool": return 1
        default: return 0
        }
    }

    // The state to show. A working state that stopped being refreshed shows
    // as idle; permission has no heartbeat - waiting on the user can
    // legitimately last hours.
    static func effectiveState(state: String, ts: Double, now: Double) -> String {
        if state == "thinking" || state == "tool" || state == "permission" {
            let cap: Double = state == "permission" ? permissionStaleCap : workingStaleCap
            if now - ts > cap { return "idle" }
            return state
        }
        return state == "done" ? "idle" : state
    }

    // Does the file still belong to a live Pi process? A live session stops
    // refreshing its file while it idles, so age alone must never retire a
    // file with a usable pid; without a pid, age is the only signal left.
    static func shouldReap(state: String, ts: Double, pid: Int32, processAlive: Bool, now: Double) -> Bool {
        if pid > 0 { return !processAlive }
        return effectiveState(state: state, ts: ts, now: now) == "idle" && now - ts > idleReapAfter
    }

    // Everything one file means right now. The cue follows the reported
    // state, so a staleness timeout stays silent instead of sounding like a
    // finished turn.
    static func decide(state: String, ts: Double, pid: Int32, processAlive: Bool,
                       previousReported: String?, now: Double) -> SessionDecision {
        let effective = effectiveState(state: state, ts: ts, now: now)
        let reaped = shouldReap(state: state, ts: ts, pid: pid, processAlive: processAlive, now: now)
        return SessionDecision(effective: effective, reaped: reaped,
                               cue: reaped ? nil : CuePlayer.cue(from: previousReported, to: state))
    }

    // Is that process still running?
    static func processAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: files

    // The state files the extension wrote.
    static func stateFileNames(stateDir: String) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: stateDir) else {
            NSLog("PiStatusBar: cannot read state directory")
            return []
        }
        return files.filter { $0.hasSuffix(".json") }
    }

    // Reads the state directory. Only files whose mtime changed are parsed
    // again; ids whose file vanished come back in `removed`.
    static func loadSessions(stateDir: String, mtimes: inout [String: Date]) -> (sessions: [String: Session], removed: [String]) {
        let fm = FileManager.default
        let files = stateFileNames(stateDir: stateDir)
        let present = Set(files)
        var removed: [String] = []
        for key in Array(mtimes.keys) where !present.contains(key) {
            mtimes[key] = nil
            removed.append((key as NSString).deletingPathExtension)
        }
        var loaded: [String: Session] = [:]
        for f in files {
            let full = (stateDir as NSString).appendingPathComponent(f)
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let m = attrs[.modificationDate] as? Date else { continue }
            if mtimes[f] == m { continue }
            mtimes[f] = m
            guard let data = fm.contents(atPath: full) else {
                NSLog("PiStatusBar: cannot read state file \(f)")
                continue
            }
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("PiStatusBar: cannot parse state file \(f)")
                continue
            }
            let id = (f as NSString).deletingPathExtension
            loaded[id] = Session(json: o, id: id)
        }
        return (loaded, removed)
    }

    // Is a Pi process still running behind any state file? The app must not
    // quit while one is: an idle session stops refreshing its file.
    static func hasLiveProcess(stateDir: String) -> Bool {
        let fm = FileManager.default
        for f in stateFileNames(stateDir: stateDir) {
            let full = (stateDir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: full),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.intValue else { continue }
            if processAlive(Int32(pid)) { return true }
        }
        return false
    }
}
