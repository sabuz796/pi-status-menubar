// Exact-value checks for the cue rules. Run with:
//   swiftc -O Sources/Sounds.swift tests/cues/main.swift -o /tmp/cues && /tmp/cues
//
// Every case names a specific expected cue, so this test cannot pass if the rule
// collapses to "always nil" or "always fire".
import Cocoa

var failures = 0
var checks = 0

func expect(_ previous: String?, _ current: String, _ want: Cue?, _ why: String) {
    checks += 1
    let got = CuePlayer.cue(from: previous, to: current)
    let gotName = got.map { $0 == .permission ? "permission" : "done" } ?? "nil"
    let wantName = want.map { $0 == .permission ? "permission" : "done" } ?? "nil"
    if gotName == wantName {
        print("  ok   \(previous ?? "first") -> \(current) = \(wantName)")
    } else {
        failures += 1
        print("  FAIL \(previous ?? "first") -> \(current) = \(gotName), want \(wantName)  (\(why))")
    }
}

print("cue rules")
// A session seen for the first time must never sound, otherwise opening the app
// replays whatever the current state happens to be.
expect(nil, "permission", nil, "first sighting of a waiting session")
expect(nil, "idle", nil, "first sighting of an idle session")
expect(nil, "thinking", nil, "first sighting of a working session")
expect(nil, "tool", nil, "first sighting of a running tool")

// Asking for permission is the one thing that needs attention immediately.
expect("thinking", "permission", .permission, "agent stops to ask")
expect("tool", "permission", .permission, "tool wants approval")
// Waiting does not repeat: permission heartbeats are absent, but a rewrite must
// still not re-announce the same state.
expect("permission", "permission", nil, "still waiting, no repeat")

// A turn finishing is working (or waiting) going back to idle.
expect("thinking", "idle", .done, "turn finished")
expect("tool", "idle", .done, "tool finished and went idle")
expect("permission", "idle", .done, "answered, then finished")
// The extension reports a finished turn as "done"; it counts as idle.
expect("thinking", "done", .done, "turn finished and reported done")
expect("permission", "done", .done, "answered, then finished and reported done")

// Everything else is noise and must stay silent.
expect("idle", "thinking", nil, "new turn starting is not a cue")
expect("idle", "idle", nil, "no change")
expect("thinking", "tool", nil, "tool to tool is not a cue")
expect("permission", "thinking", nil, "user answered, work resumed")
expect("permission", "tool", nil, "user answered, tool resumed")

// The sound assets themselves must exist, or the cues are silent no-ops.
print("sound assets")
for name in ["Pop", "Tink"] {
    checks += 1
    if NSSound(named: name) != nil {
        print("  ok   NSSound(named: \"\(name)\") resolves")
    } else {
        failures += 1
        print("  FAIL NSSound(named: \"\(name)\") is nil")
    }
}

print("\n\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
