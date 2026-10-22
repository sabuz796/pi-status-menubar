// Exact-value checks for the session rules: what is alive, what is stale,
// and what makes a sound. Run with:
//   swiftc -O Sources/Sounds.swift Sources/SessionRules.swift tests/sessionrules/main.swift -o /tmp/sessionrules && /tmp/sessionrules
//
// Every case names a specific expected value, so this test cannot pass if a
// rule collapses to "always alive" or "always reaped".
import Foundation

var failures = 0
var checks = 0

func expect(_ label: String, _ got: String, _ want: String, _ why: String) {
    checks += 1
    if got == want {
        print("  ok   \(label) = \(got)")
    } else {
        failures += 1
        print("  FAIL \(label) = \(got), want \(want)  (\(why))")
    }
}

func flag(_ b: Bool) -> String { b ? "true" : "false" }
func cueName(_ c: Cue?) -> String { c.map { $0 == .permission ? "permission" : "done" } ?? "nil" }

let now: Double = 1_700_000_000

print("priority")
// Permission outranks work, work outranks idleness.
expect("priority(permission)", "\(SessionRules.priority(of: "permission"))", "2", "a waiting session leads")
expect("priority(thinking)", "\(SessionRules.priority(of: "thinking"))", "1", "work comes next")
expect("priority(tool)", "\(SessionRules.priority(of: "tool"))", "1", "a running tool is work")
expect("priority(idle)", "\(SessionRules.priority(of: "idle"))", "0", "idle sessions never lead")

print("effective state")
// A working state that stopped being refreshed shows as idle.
expect("stale permission", SessionRules.effectiveState(state: "permission", ts: now - 7300, now: now), "idle", "permission past the 2 hour cap")
expect("fresh permission", SessionRules.effectiveState(state: "permission", ts: now - 60, now: now), "permission", "waiting on the user is not stale")
expect("stale thinking", SessionRules.effectiveState(state: "thinking", ts: now - 200, now: now), "idle", "thinking past the 3 minute cap")
expect("fresh thinking", SessionRules.effectiveState(state: "thinking", ts: now - 30, now: now), "thinking", "a heartbeat keeps work alive")
expect("done", SessionRules.effectiveState(state: "done", ts: now, now: now), "idle", "a settled turn shows as idle")

print("liveness")
// The extension only heartbeats while a turn works, so a live session that
// idles for 20 minutes has a file whose timestamp stopped advancing. The
// file must survive: its Pi process is still running.
let liveIdle = SessionRules.decide(state: "idle", ts: now - 1200, pid: 4242, processAlive: true,
                                   previousReported: "idle", now: now)
expect("live idle session reaped", flag(liveIdle.reaped), "false", "age alone must not retire a live session")
expect("live idle session state", liveIdle.effective, "idle", "a live idle session shows as idle")

// A dead process is the only reason to delete a file.
let dead = SessionRules.decide(state: "thinking", ts: now - 10, pid: 4242, processAlive: false,
                               previousReported: "thinking", now: now)
expect("dead process reaped", flag(dead.reaped), "true", "the file of a dead Pi process goes away")

// Without a usable pid, age is the only liveness signal left.
let noPid = SessionRules.decide(state: "idle", ts: now - 1200, pid: 0, processAlive: false,
                                previousReported: "idle", now: now)
expect("pid-less old file reaped", flag(noPid.reaped), "true", "a file with no pid falls back to age")
let noPidFresh = SessionRules.decide(state: "idle", ts: now - 60, pid: 0, processAlive: false,
                                     previousReported: "idle", now: now)
expect("pid-less fresh file kept", flag(noPidFresh.reaped), "false", "a fresh file without a pid is kept")

print("sound")
// A staleness timeout is not a finished turn: it must stay silent.
let stalePermission = SessionRules.decide(state: "permission", ts: now - 7300, pid: 4242, processAlive: true,
                                           previousReported: "permission", now: now)
expect("stale permission state", stalePermission.effective, "idle", "permission past the 2 hour cap shows idle")
expect("stale permission cue", cueName(stalePermission.cue), "nil", "a staleness timeout must not sound")

let staleWorking = SessionRules.decide(state: "thinking", ts: now - 200, pid: 4242, processAlive: true,
                                       previousReported: "thinking", now: now)
expect("stale working state", staleWorking.effective, "idle", "thinking past the 3 minute cap shows idle")
expect("stale working cue", cueName(staleWorking.cue), "nil", "a staleness timeout must not sound")

// A real finish still sounds.
let finished = SessionRules.decide(state: "done", ts: now, pid: 4242, processAlive: true,
                                   previousReported: "thinking", now: now)
expect("finished turn cue", cueName(finished.cue), "done", "a turn that really finished sounds")

let asked = SessionRules.decide(state: "permission", ts: now, pid: 4242, processAlive: true,
                                previousReported: "thinking", now: now)
expect("permission cue", cueName(asked.cue), "permission", "an agent asking for permission sounds")

print("app liveness")
// The app must stay up while a Pi process is alive, and quit when none is.
let tmpDir = NSTemporaryDirectory() + "pi-statusbar-sessionrules-\(ProcessInfo.processInfo.processIdentifier)"
try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
let live = "{\"pid\": \(ProcessInfo.processInfo.processIdentifier), \"state\": \"idle\"}"
let gone = "{\"pid\": 2147483647, \"state\": \"idle\"}"
try? live.write(toFile: tmpDir + "/live.json", atomically: true, encoding: .utf8)
expect("live process keeps the app", flag(SessionRules.hasLiveProcess(stateDir: tmpDir)), "true", "a running Pi process keeps the app alive")
try? gone.write(toFile: tmpDir + "/gone.json", atomically: true, encoding: .utf8)
expect("live file still keeps the app", flag(SessionRules.hasLiveProcess(stateDir: tmpDir)), "true", "a dead file does not change that")
try? FileManager.default.removeItem(atPath: tmpDir + "/live.json")
expect("dead process only", flag(SessionRules.hasLiveProcess(stateDir: tmpDir)), "false", "the app quits when no Pi process remains")
try? FileManager.default.removeItem(atPath: tmpDir)

print("\n\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
