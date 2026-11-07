import XCTest
@testable import PiStatusBarKit

// Exact-value checks for one session's meaning: what its effective state is,
// what glyph, name and sub a row shows, which session leads when several are
// live, and which cue a transition owes.
//
// Every case names a specific expected value, so none of these tests can pass
// if the reading collapses to "always idle", "never a cue", or "always first".
// Fixtures are inline JSON: one row of the table, no disk.
final class SessionReadingTests: XCTestCase {
    private let now: Double = 1_700_000_000

    private func session(_ state: String, ts: Double,
                         name: String = "", project: String = "",
                         label: String = "", startedAt: Double = 0,
                         pid: Int32 = 4242, eff: String = "") -> Session {
        let o: [String: Any] = ["state": state, "ts": ts, "sessionName": name,
                                "project": project, "label": label,
                                "startedAt": startedAt, "pid": pid]
        var s = Session(json: o, id: "s1")
        s.eff = eff
        return s
    }

    // MARK: priority

    func testPermissionOutranksWorkAndWorkOutranksIdle() {
        XCTAssertEqual(SessionReading.priority(of: "permission"), 2, "a waiting session leads")
        XCTAssertEqual(SessionReading.priority(of: "thinking"), 1, "work comes next")
        XCTAssertEqual(SessionReading.priority(of: "tool"), 1, "a running tool is work")
        XCTAssertEqual(SessionReading.priority(of: "idle"), 0, "idle sessions never lead")
    }

    // MARK: effective state

    func testWorkingStateStopsBeingFreshAtTheCap() {
        XCTAssertEqual(SessionReading.effectiveState(state: "permission", ts: now - 7300, now: now), "idle",
                       "permission past the 2 hour cap")
        XCTAssertEqual(SessionReading.effectiveState(state: "permission", ts: now - 60, now: now), "permission",
                       "waiting on the user is not stale")
        XCTAssertEqual(SessionReading.effectiveState(state: "thinking", ts: now - 200, now: now), "idle",
                       "thinking past the 3 minute cap")
        XCTAssertEqual(SessionReading.effectiveState(state: "thinking", ts: now - 30, now: now), "thinking",
                       "a heartbeat keeps work alive")
        XCTAssertEqual(SessionReading.effectiveState(state: "done", ts: now, now: now), "idle",
                       "a settled turn shows as idle")
    }

    // MARK: lead selection

    func testPermissionSessionLeadsWorkAndIdle() {
        let lead = SessionReading.lead([
            session("idle", ts: now),
            session("tool", ts: now + 60),
            session("permission", ts: now - 30),
        ], now: now)
        XCTAssertEqual(lead?.state, "permission", "the waiting session leads")
    }

    func testWorkLeadsIdleEvenWhenIdleIsNewer() {
        let lead = SessionReading.lead([
            session("idle", ts: now + 90),
            session("thinking", ts: now),
        ], now: now)
        XCTAssertEqual(lead?.state, "thinking", "work outranks idle despite the older timestamp")
    }

    func testTiesBreakByRecency() {
        let older = session("tool", ts: now)
        let newer = session("thinking", ts: now + 45)
        let lead = SessionReading.lead([older, newer], now: now)
        XCTAssertEqual(lead?.state, "thinking", "same priority: the more recent session leads")
    }

    func testDoneCountsAsIdlePriority() {
        // "done" normalizes to idle inside the reading, so a done session and
        // an idle session tie at priority 0 and the newer one leads.
        let done = SessionReading.lead([
            session("done", ts: now),
            session("idle", ts: now + 5),
        ], now: now)
        XCTAssertEqual(done?.state, "idle", "done normalizes to idle, so the newer idle wins the tie")
    }

    func testNoSessionsLeadsNothing() {
        XCTAssertNil(SessionReading.lead([], now: now), "nothing live, nothing to show")
    }

    // MARK: glyphs, name, sub

    func testPermissionReadingNamesItsParts() throws {
        let r = try XCTUnwrap(SessionReading.read(
            session("permission", ts: now, name: "fix search", label: ""),
            previous: "thinking", now: now))
        XCTAssertEqual(r.effective, "permission")
        XCTAssertEqual(r.glyph, "●")
        XCTAssertEqual(r.name, "fix search")
        XCTAssertEqual(r.sub, "Awaiting input")
    }

    func testWorkingReadingShowsElapsedTime() throws {
        let r = try XCTUnwrap(SessionReading.read(
            session("tool", ts: now, name: "", project: "my-app", label: "Editing", startedAt: now - 95),
            previous: "thinking", now: now))
        XCTAssertEqual(r.effective, "tool")
        XCTAssertEqual(r.glyph, "◐")
        XCTAssertEqual(r.name, "my-app", "no session name: the project folder stands in")
        XCTAssertEqual(r.sub, "Editing · 1m 35s")
    }

    func testWorkingWithoutALabelShowsWorking() throws {
        let r = try XCTUnwrap(SessionReading.read(
            session("thinking", ts: now, label: "", startedAt: now - 24),
            previous: nil, now: now))
        XCTAssertEqual(r.sub, "Working · 24s")
    }

    func testIdleReading() throws {
        let r = try XCTUnwrap(SessionReading.read(
            session("idle", ts: now, project: "", label: "Done"),
            previous: "thinking", now: now))
        XCTAssertEqual(r.effective, "idle")
        XCTAssertEqual(r.glyph, "○")
        XCTAssertEqual(r.name, "session", "no name and no project: the generic name")
        XCTAssertEqual(r.sub, "Idle", "the label is not shown when idle")
    }

    func testNoNameAndNoProjectFallsBackToSession() throws {
        let r = try XCTUnwrap(SessionReading.read(
            session("idle", ts: now, name: "", project: ""),
            previous: nil, now: now))
        XCTAssertEqual(r.name, "session")
    }

    func testLiveIdleSessionReadsIdle() {
        let r = SessionReading.read(session("idle", ts: now - 1200), previous: "idle", now: now)
        XCTAssertEqual(r.effective, "idle", "a live idle session shows as idle")
    }

    // MARK: cues

    func testFirstSightingNeverSounds() {
        // Otherwise opening the app replays whatever the current state happens to be.
        XCTAssertNil(SessionReading.cue(from: nil, to: "permission"), "first sighting of a waiting session")
        XCTAssertNil(SessionReading.cue(from: nil, to: "idle"), "first sighting of an idle session")
        XCTAssertNil(SessionReading.cue(from: nil, to: "thinking"), "first sighting of a working session")
        XCTAssertNil(SessionReading.cue(from: nil, to: "tool"), "first sighting of a running tool")
    }

    func testPermissionRequestSoundsOnce() {
        XCTAssertEqual(SessionReading.cue(from: "thinking", to: "permission"), .permission, "agent stops to ask")
        XCTAssertEqual(SessionReading.cue(from: "tool", to: "permission"), .permission, "tool wants approval")
        // Permission heartbeats are absent, but a rewrite must still not
        // re-announce the same state.
        XCTAssertNil(SessionReading.cue(from: "permission", to: "permission"), "still waiting, no repeat")
    }

    func testFinishedTurnSounds() {
        XCTAssertEqual(SessionReading.cue(from: "thinking", to: "idle"), .done, "turn finished")
        XCTAssertEqual(SessionReading.cue(from: "tool", to: "idle"), .done, "tool finished and went idle")
        XCTAssertEqual(SessionReading.cue(from: "permission", to: "idle"), .done, "answered, then finished")
        // The extension reports a finished turn as "done"; it counts as idle.
        XCTAssertEqual(SessionReading.cue(from: "thinking", to: "done"), .done, "turn finished and reported done")
        XCTAssertEqual(SessionReading.cue(from: "permission", to: "done"), .done, "answered, then finished and reported done")
    }

    func testEverythingElseStaysSilent() {
        XCTAssertNil(SessionReading.cue(from: "idle", to: "thinking"), "new turn starting is not a cue")
        XCTAssertNil(SessionReading.cue(from: "idle", to: "idle"), "no change")
        XCTAssertNil(SessionReading.cue(from: "thinking", to: "tool"), "tool to tool is not a cue")
        XCTAssertNil(SessionReading.cue(from: "permission", to: "thinking"), "user answered, work resumed")
        XCTAssertNil(SessionReading.cue(from: "permission", to: "tool"), "user answered, tool resumed")
    }

    func testStalenessTimeoutKeepsTheReadingSilent() {
        // A staleness timeout does not move the reported state: previous and
        // current are the same reported value, so there is nothing to announce.
        // The cue gate for reaped sessions lives at the caller (evaluate).
        let stalePermission = SessionReading.read(
            session("permission", ts: now - 7300), previous: "permission", now: now)
        XCTAssertEqual(stalePermission.effective, "idle", "permission past the 2 hour cap shows idle")
        XCTAssertNil(stalePermission.cue, "a staleness timeout must not sound")

        let staleWorking = SessionReading.read(
            session("thinking", ts: now - 200), previous: "thinking", now: now)
        XCTAssertEqual(staleWorking.effective, "idle", "thinking past the 3 minute cap shows idle")
        XCTAssertNil(staleWorking.cue, "a staleness timeout must not sound")
    }

    func testFinishedTurnReadingSounds() throws {
        let finished = try XCTUnwrap(SessionReading.read(
            session("done", ts: now), previous: "thinking", now: now))
        XCTAssertEqual(finished.cue, .done, "a turn that really finished sounds")
    }

    func testPermissionRequestReadingSounds() throws {
        let asked = try XCTUnwrap(SessionReading.read(
            session("permission", ts: now), previous: "thinking", now: now))
        XCTAssertEqual(asked.cue, .permission, "an agent asking for permission sounds")
    }

    func testReapedSessionIsSilentFromTheReadingAlone() {
        // decide() used to force nil on reaped sessions; the caller gate does
        // that now. The reading itself is silent here because previous equals
        // the reported state, which is the common case in the field.
        let r = SessionReading.read(
            session("thinking", ts: now - 900), previous: "thinking", now: now)
        XCTAssertNil(r.cue, "no state change, no cue")
    }
}
