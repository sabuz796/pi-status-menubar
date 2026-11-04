import XCTest
@testable import PiStatusBarKit

// Exact-value checks for the session rules: what is alive, what is stale,
// and what makes a sound.
//
// Every case names a specific expected value, so this test cannot pass if a
// rule collapses to "always alive" or "always reaped".
final class SessionRulesTests: XCTestCase {
    private let now: Double = 1_700_000_000

    // MARK: priority

    func testPermissionOutranksWorkAndWorkOutranksIdle() {
        XCTAssertEqual(SessionRules.priority(of: "permission"), 2, "a waiting session leads")
        XCTAssertEqual(SessionRules.priority(of: "thinking"), 1, "work comes next")
        XCTAssertEqual(SessionRules.priority(of: "tool"), 1, "a running tool is work")
        XCTAssertEqual(SessionRules.priority(of: "idle"), 0, "idle sessions never lead")
    }

    // MARK: effective state

    func testWorkingStateStopsBeingFreshAtTheCap() {
        XCTAssertEqual(SessionRules.effectiveState(state: "permission", ts: now - 7300, now: now), "idle",
                       "permission past the 2 hour cap")
        XCTAssertEqual(SessionRules.effectiveState(state: "permission", ts: now - 60, now: now), "permission",
                       "waiting on the user is not stale")
        XCTAssertEqual(SessionRules.effectiveState(state: "thinking", ts: now - 200, now: now), "idle",
                       "thinking past the 3 minute cap")
        XCTAssertEqual(SessionRules.effectiveState(state: "thinking", ts: now - 30, now: now), "thinking",
                       "a heartbeat keeps work alive")
        XCTAssertEqual(SessionRules.effectiveState(state: "done", ts: now, now: now), "idle",
                       "a settled turn shows as idle")
    }

    // MARK: liveness

    func testLiveIdleSessionSurvivesAge() {
        // The extension only heartbeats while a turn works, so a live session
        // that idles for 20 minutes has a file whose timestamp stopped
        // advancing. The file must survive: its Pi process is still running.
        let liveIdle = SessionRules.decide(state: "idle", ts: now - 1200, pid: 4242, processAlive: true,
                                           processStart: nil, previousReported: "idle", now: now)
        XCTAssertFalse(liveIdle.reaped, "age alone must not retire a live session")
        XCTAssertEqual(liveIdle.effective, "idle", "a live idle session shows as idle")
    }

    func testDeadProcessIsReaped() {
        let dead = SessionRules.decide(state: "thinking", ts: now - 10, pid: 4242, processAlive: false,
                                       processStart: nil, previousReported: "thinking", now: now)
        XCTAssertTrue(dead.reaped, "the file of a dead Pi process goes away")
    }

    // macOS reuses pids. A running process that started after the file was
    // written cannot be the Pi that wrote it, so the file must not pin the
    // app forever just because its number is live again.
    func testReusedPidIsReapedEvenThoughItIsAlive() {
        let reused = SessionRules.decide(state: "thinking", ts: now - 900, pid: 4242, processAlive: true,
                                         processStart: now - 60, previousReported: "thinking", now: now)
        XCTAssertTrue(reused.reaped, "a pid that started after the write is a different process")
        XCTAssertNil(reused.cue, "a reused pid must not sound like a finished turn")
    }

    func testLiveProcessStartedBeforeTheFileIsKept() {
        let live = SessionRules.decide(state: "idle", ts: now - 1200, pid: 4242, processAlive: true,
                                       processStart: now - 4000, previousReported: "idle", now: now)
        XCTAssertFalse(live.reaped, "the Pi that wrote the file started before it, so it is the owner")
    }

    // The start time is a whole second from the kernel and the timestamp is a
    // whole second from the extension, so a small gap is not evidence of reuse.
    func testStartJustAfterTheWriteStaysWithinTolerance() {
        let close = SessionRules.decide(state: "tool", ts: now - 100, pid: 4242, processAlive: true,
                                        processStart: now - 97, previousReported: "tool", now: now)
        XCTAssertFalse(close.reaped, "3s is inside the clock tolerance, so the file stays")
    }

    // If the wall clock steps backwards, the kernel start time is later than
    // the file timestamps. A process cannot start in the future, so that is a
    // clock skew, not evidence of a reused pid.
    func testFutureProcessStartDoesNotReapALiveSession() {
        let skewed = SessionRules.decide(state: "thinking", ts: now - 10, pid: 4242, processAlive: true,
                                         processStart: now + 60, previousReported: "thinking", now: now)
        XCTAssertFalse(skewed.reaped, "a start time ahead of the clock is not reuse evidence")
    }

    func testUnknownStartTimeKeepsALivePid() {
        let unknown = SessionRules.decide(state: "idle", ts: now - 1200, pid: 4242, processAlive: true,
                                          processStart: nil, previousReported: "idle", now: now)
        XCTAssertFalse(unknown.reaped, "no start time means no evidence, so the file stays")
    }

    // A file written without a timestamp is corrupt, not proof that its pid was
    // reused, so it keeps the old behaviour and stays.
    func testMissingTimestampKeepsALivePid() {
        let noTs = SessionRules.decide(state: "idle", ts: 0, pid: 4242, processAlive: true,
                                       processStart: now, previousReported: "idle", now: now)
        XCTAssertFalse(noTs.reaped, "a missing timestamp is not evidence of reuse")
    }

    func testPidlessFileFallsBackToAge() {
        let noPid = SessionRules.decide(state: "idle", ts: now - 1200, pid: 0, processAlive: false,
                                        processStart: nil, previousReported: "idle", now: now)
        XCTAssertTrue(noPid.reaped, "a file with no pid falls back to age")
        let noPidFresh = SessionRules.decide(state: "idle", ts: now - 60, pid: 0, processAlive: false,
                                             processStart: nil, previousReported: "idle", now: now)
        XCTAssertFalse(noPidFresh.reaped, "a fresh file without a pid is kept")
    }

    // MARK: sound

    func testStalenessTimeoutStaysSilent() {
        let stalePermission = SessionRules.decide(state: "permission", ts: now - 7300, pid: 4242, processAlive: true,
                                                  processStart: nil, previousReported: "permission", now: now)
        XCTAssertEqual(stalePermission.effective, "idle", "permission past the 2 hour cap shows idle")
        XCTAssertNil(stalePermission.cue, "a staleness timeout must not sound")

        let staleWorking = SessionRules.decide(state: "thinking", ts: now - 200, pid: 4242, processAlive: true,
                                               processStart: nil, previousReported: "thinking", now: now)
        XCTAssertEqual(staleWorking.effective, "idle", "thinking past the 3 minute cap shows idle")
        XCTAssertNil(staleWorking.cue, "a staleness timeout must not sound")
    }

    func testFinishedTurnSounds() {
        let finished = SessionRules.decide(state: "done", ts: now, pid: 4242, processAlive: true,
                                           processStart: nil, previousReported: "thinking", now: now)
        XCTAssertEqual(finished.cue, .done, "a turn that really finished sounds")
    }

    func testPermissionRequestSounds() {
        let asked = SessionRules.decide(state: "permission", ts: now, pid: 4242, processAlive: true,
                                        processStart: nil, previousReported: "thinking", now: now)
        XCTAssertEqual(asked.cue, .permission, "an agent asking for permission sounds")
    }

    // MARK: app liveness

    func testLoadSessionsParsesOnlyChangedFilesAndReportsRemovedOnes() {
        let dir = NSTemporaryDirectory() + "pi-statusbar-load-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        func write(_ name: String, label: String) {
            let json = "{\"state\":\"idle\",\"label\":\"\(label)\",\"pid\":0}"
            try? json.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        }
        write("a.json", label: "first")
        write("b.json", label: "second")

        var mtimes = [String: Date]()
        let first = SessionRules.loadSessions(stateDir: dir, mtimes: &mtimes)
        XCTAssertEqual(first.sessions.keys.sorted(), ["a", "b"], "both files load on the first pass")
        XCTAssertEqual(first.removed, [], "nothing has vanished yet")
        XCTAssertEqual(first.sessions["a"]?.label, "first")

        // Rewrite one file and stamp a new mtime, so the change is visible to
        // the second pass regardless of the filesystem's timestamp resolution.
        write("a.json", label: "changed")
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: dir + "/a.json")
        let second = SessionRules.loadSessions(stateDir: dir, mtimes: &mtimes)
        XCTAssertEqual(second.sessions.keys.sorted(), ["a"], "only the changed file is parsed again")
        XCTAssertEqual(second.sessions["a"]?.label, "changed", "the new label is visible")
        XCTAssertEqual(second.removed, [])

        try? FileManager.default.removeItem(atPath: dir + "/b.json")
        let third = SessionRules.loadSessions(stateDir: dir, mtimes: &mtimes)
        XCTAssertEqual(third.removed, ["b"], "the deleted file is reported as removed")
        XCTAssertNil(third.sessions["b"], "the deleted session is gone")
    }

    func testAppLivenessFollowsThePiProcess() {
        // The app must stay up while a Pi process is alive, and quit when none is.
        let tmpDir = NSTemporaryDirectory() + "pi-statusbar-sessionrules-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let live = "{\"pid\": \(ProcessInfo.processInfo.processIdentifier), \"state\": \"idle\"}"
        let gone = "{\"pid\": 2147483647, \"state\": \"idle\"}"
        try? live.write(toFile: tmpDir + "/live.json", atomically: true, encoding: .utf8)
        XCTAssertTrue(SessionRules.hasLiveProcess(stateDir: tmpDir), "a running Pi process keeps the app alive")
        try? gone.write(toFile: tmpDir + "/gone.json", atomically: true, encoding: .utf8)
        XCTAssertTrue(SessionRules.hasLiveProcess(stateDir: tmpDir), "a dead file does not change that")
        try? FileManager.default.removeItem(atPath: tmpDir + "/live.json")
        XCTAssertFalse(SessionRules.hasLiveProcess(stateDir: tmpDir), "the app quits when no Pi process remains")
    }

    // MARK: terminal app

    func testKnownTerminalsMapToTheirApp() {
        XCTAssertEqual(terminalAppName("Apple_Terminal"), "Terminal")
        XCTAssertEqual(terminalAppName("iTerm.app"), "iTerm")
        XCTAssertEqual(terminalAppName("WarpTerminal"), "Warp")
        XCTAssertEqual(terminalAppName("vscode"), "Visual Studio Code")
        XCTAssertEqual(terminalAppName("ghostty"), "Ghostty")
        XCTAssertEqual(terminalAppName("alacritty"), "Alacritty")
        XCTAssertEqual(terminalAppName("WezTerm"), "WezTerm")
        XCTAssertEqual(terminalAppName("Hyper"), "Hyper")
    }

    func testUnknownTermProgramNamesNoApp() {
        // term_program is read from a state file and handed to `open -a`,
        // which launches any app it names, full paths included.
        XCTAssertNil(terminalAppName(""), "no terminal, no target")
        XCTAssertNil(terminalAppName("/tmp/evil.app"), "a path must never reach open -a")
        XCTAssertNil(terminalAppName("Calculator"), "an unknown name must not launch an app")
        XCTAssertNil(terminalAppName("tmux"), "tmux is not an app open -a can raise")
    }
}
