import Foundation

// One session's meaning in a single reading: state, glyphs, labels, and the
// cue a transition owes, produced by SessionReading per session. The module
// holds no state and imports no AppKit: callers feed it a session, the
// reported previous state, and the clock; they keep their own transitions and
// their own side effects (playing sounds, deleting reaped files, drawing).

// Two moments are worth interrupting for: the agent asking permission, and a
// turn finishing: the decision table lives here with the rest of the meaning.
// The player that makes noise stays in Sounds.swift.
enum Cue {
    case permission
    case done
}

struct Reading {
    let effective: String // the state to show, after staleness and "done"
    let glyph: String // the state mark shown on rows and in the tooltip
    let name: String // what distinguishes this session from others
    let sub: String // the one-line status text
    let cue: Cue? // nil on first sighting and when nothing changed
}

enum SessionReading {
    // Which cue, if any, a state change owes. A first sighting stays silent;
    // waiting for permission does not repeat; only real work finishing counts.
    // The states are the ones the extension reports: "done" is how it reports a
    // finished turn, so it counts as idle.
    static func cue(from previous: String?, to current: String) -> Cue? {
        guard let previous = previous.map({ normalized($0) }) else { return nil }
        let current = normalized(current)
        guard previous != current else { return nil }
        if current == "permission" { return .permission }
        if current == "idle", previous == "thinking" || previous == "tool" || previous == "permission" {
            return .done
        }
        return nil
    }

    // "done" is the reported form of a finished turn; it means idle. Normalized
    // in one place here, and nowhere else.
    private static func normalized(_ state: String) -> String {
        state == "done" ? "idle" : state
    }

    // Staleness caps, aligned with the extension's heartbeat refresh.
    static let workingStaleCap: TimeInterval = 180 // 3 missed heartbeats (30s each)
    static let permissionStaleCap: TimeInterval = 7200 // 2 hours

    // The state to show. A working state that stopped being refreshed shows as
    // idle; permission has no heartbeat (waiting on the user can legitimately
    // last hours), so it has its own, longer cap.
    static func effectiveState(state: String, ts: Double, now: Double) -> String {
        if state == "thinking" || state == "tool" || state == "permission" {
            let cap: Double = state == "permission" ? permissionStaleCap : workingStaleCap
            if now - ts > cap { return "idle" }
            return state
        }
        return state == "done" ? "idle" : state
    }

    // Which session outranks which: a waiting session leads, work comes next,
    // idle sessions never lead.
    static func priority(of eff: String) -> Int {
        switch eff {
        case "permission": return 2
        case "thinking", "tool": return 1
        default: return 0
        }
    }

    // Everything one session means right now: the reading a caller can lay on
    // the icon, a panel row, or a tooltip without touching the rules again.
    // The effective state is always recomputed from the file: `s.eff` still
    // holds the previous tick's value while the file is unchanged, and
    // staleness must keep advancing with the clock.
    static func read(_ s: Session, previous: String?, now: Double) -> Reading {
        let effective = effectiveState(state: s.state, ts: s.ts, now: now)
        let p = parts(s, effective: effective, now: now)
        return Reading(effective: effective, glyph: p.glyph, name: p.name, sub: p.sub,
                       cue: cue(from: previous, to: s.state))
    }

    // The session the menu bar item shows when several are live: permission
    // outranks work, work outranks idle, ties break by recency. Every session
    // is read fresh with the given clock.
    static func lead(_ sessions: [Session], now: Double) -> Session? {
        func rank(_ s: Session) -> Int {
            priority(of: effectiveState(state: s.state, ts: s.ts, now: now))
        }
        return sessions.max { a, b in
            let pa = rank(a), pb = rank(b)
            return pa == pb ? a.ts < b.ts : pa < pb
        }
    }

    // Sonoma-style state parts: glyph + name + one-line status text. Color is
    // the one reading kept out of here: it is AppKit, not meaning, so the
    // caller applies it to the effective state.
    private static func parts(_ s: Session, effective: String, now: Double) -> (glyph: String, name: String, sub: String) {
        // Pi's own session name is what distinguishes two sessions in the
        // same project; fall back to the project folder when it is empty.
        let name = !s.sessionName.isEmpty ? s.sessionName
                   : (s.project.isEmpty ? "session" : s.project)
        switch effective {
        case "permission":
            return ("●", name, "Awaiting input")
        case "thinking", "tool":
            var sub = s.label.isEmpty ? "Working" : s.label
            if s.startedAt > 0 { sub += " · " + elapsed(max(0, Int(now - s.startedAt))) }
            return ("◐", name, sub)
        default:
            return ("○", name, "Idle")
        }
    }

    // "3m 24s" (or just "24s"): the shared clock format for the status bar
    // timer and the panel's working label.
    static func elapsed(_ secs: Int) -> String {
        let m = secs / 60, s = secs % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
