import Foundation
import Darwin

// The state files the Pi extension writes, and the rules for what they
// mean: which state wins, when a file went stale, and whether the Pi
// process behind it is still alive. No AppKit here on purpose - the rules
// are checkable on their own (swift test, SessionRulesTests).

// One session's state file, as the extension wrote it.
struct Session {
    var id: String
    var state: String
    var label: String
    var project: String
    var cwd: String
    var sessionName: String
    var termProgram: String
    var terminalApp: String
    var terminalWindowId: String
    var terminalWorkspaceId: String
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
        self.terminalApp = o["terminalApp"] as? String ?? ""
        self.terminalWindowId = o["terminalWindowId"] as? String ?? ""
        self.terminalWorkspaceId = o["terminalWorkspaceId"] as? String ?? ""
        self.pid = Int32(truncatingIfNeeded: (o["pid"] as? NSNumber)?.intValue ?? 0)
        self.started = o["started"] as? Bool ?? true
        self.startedAt = (o["startedAt"] as? NSNumber)?.doubleValue ?? 0
        self.ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
    }
}

// TERM_PROGRAM values do not match the .app names `open -a` resolves, so the
// ones that need it are translated here, shared by the panel tooltip and the
// click fallback. Anything else passes to `open -a` unchanged (that lookup is
// case-insensitive); nil means no terminal to name, so the row has no target.
func terminalAppName(_ termProgram: String) -> String? {
    switch termProgram {
    case "": return nil
    case "Apple_Terminal": return "Terminal"
    case "iTerm.app": return "iTerm"
    case "WarpTerminal": return "Warp"
    case "vscode": return "Visual Studio Code"
    case "ghostty": return "Ghostty"
    default: return termProgram
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

    // Kernel start times and the extension's whole-second timestamp can differ
    // by a fraction of a second, so a reused pid has to start clearly after the
    // write before the file is retired on that evidence alone.
    static let pidStartTolerance: Double = 5

    // Does the file still belong to a live Pi process? A live session stops
    // refreshing its file while it idles, so age alone must never retire a
    // file with a usable pid; without a pid, age is the only signal left.
    // A live pid is not enough by itself: macOS reuses pids, and a reused one
    // would pin a dead session forever. A process that started after the file
    // was written cannot be the Pi that wrote it.
    static func shouldReap(state: String, ts: Double, pid: Int32, processAlive: Bool,
                           processStart: Double?, now: Double) -> Bool {
        if pid > 0 {
            guard processAlive else { return true }
            // A file with no timestamp is corrupt, not evidence of reuse.
            // A process cannot start in the future: after a backward clock
            // step the kernel start time is ahead of the file, and that is not
            // evidence that the pid was reused.
            if let start = processStart, ts > 0, start <= now, start > ts + pidStartTolerance { return true }
            return false
        }
        return effectiveState(state: state, ts: ts, now: now) == "idle" && now - ts > idleReapAfter
    }

    // Everything one file means right now. The cue follows the reported
    // state, so a staleness timeout stays silent instead of sounding like a
    // finished turn.
    static func decide(state: String, ts: Double, pid: Int32, processAlive: Bool,
                       processStart: Double?, previousReported: String?, now: Double) -> SessionDecision {
        let effective = effectiveState(state: state, ts: ts, now: now)
        let reaped = shouldReap(state: state, ts: ts, pid: pid, processAlive: processAlive,
                                processStart: processStart, now: now)
        return SessionDecision(effective: effective, reaped: reaped,
                               cue: reaped ? nil : CuePlayer.cue(from: previousReported, to: state))
    }

    // Is that process still running?
    static func processAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // When the process behind a pid started, in unix seconds, or nil when the
    // pid is gone or the kernel will not answer. Paired with the file's own
    // timestamp, this is what tells a live Pi from a reused pid.
    static func processStartTime(_ pid: Int32) -> Double? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec)
    }

    // MARK: files

    // The state files the extension wrote.
    static func stateFileNames(stateDir: String) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: stateDir) else {
            logEvent(level: "warn", source: "app", event: "state-dir-unreadable")
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
                logEvent(level: "warn", source: "app", event: "state-file-unreadable", ["file": f])
                continue
            }
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logEvent(level: "warn", source: "app", event: "state-file-unparsed", ["file": f])
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
