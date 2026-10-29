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
                                           previousReported: "idle", now: now)
        XCTAssertFalse(liveIdle.reaped, "age alone must not retire a live session")
        XCTAssertEqual(liveIdle.effective, "idle", "a live idle session shows as idle")
    }

    func testDeadProcessIsReaped() {
        let dead = SessionRules.decide(state: "thinking", ts: now - 10, pid: 4242, processAlive: false,
                                       previousReported: "thinking", now: now)
        XCTAssertTrue(dead.reaped, "the file of a dead Pi process goes away")
    }

    func testPidlessFileFallsBackToAge() {
        let noPid = SessionRules.decide(state: "idle", ts: now - 1200, pid: 0, processAlive: false,
                                        previousReported: "idle", now: now)
        XCTAssertTrue(noPid.reaped, "a file with no pid falls back to age")
        let noPidFresh = SessionRules.decide(state: "idle", ts: now - 60, pid: 0, processAlive: false,
                                             previousReported: "idle", now: now)
        XCTAssertFalse(noPidFresh.reaped, "a fresh file without a pid is kept")
    }

    // MARK: sound

    func testStalenessTimeoutStaysSilent() {
        let stalePermission = SessionRules.decide(state: "permission", ts: now - 7300, pid: 4242, processAlive: true,
                                                  previousReported: "permission", now: now)
        XCTAssertEqual(stalePermission.effective, "idle", "permission past the 2 hour cap shows idle")
        XCTAssertNil(stalePermission.cue, "a staleness timeout must not sound")

        let staleWorking = SessionRules.decide(state: "thinking", ts: now - 200, pid: 4242, processAlive: true,
                                               previousReported: "thinking", now: now)
        XCTAssertEqual(staleWorking.effective, "idle", "thinking past the 3 minute cap shows idle")
        XCTAssertNil(staleWorking.cue, "a staleness timeout must not sound")
    }

    func testFinishedTurnSounds() {
        let finished = SessionRules.decide(state: "done", ts: now, pid: 4242, processAlive: true,
                                           previousReported: "thinking", now: now)
        XCTAssertEqual(finished.cue, .done, "a turn that really finished sounds")
    }

    func testPermissionRequestSounds() {
        let asked = SessionRules.decide(state: "permission", ts: now, pid: 4242, processAlive: true,
                                        previousReported: "thinking", now: now)
        XCTAssertEqual(asked.cue, .permission, "an agent asking for permission sounds")
    }

    // MARK: app liveness

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
}
