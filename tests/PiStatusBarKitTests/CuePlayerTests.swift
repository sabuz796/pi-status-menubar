import Cocoa
import XCTest
@testable import PiStatusBarKit

// Exact-value checks for the cue rules.
//
// Every case names a specific expected cue, so this test cannot pass if the
// rule collapses to "always nil" or "always fire".
final class CuePlayerTests: XCTestCase {
    func testFirstSightingNeverSounds() {
        // Otherwise opening the app replays whatever the current state happens to be.
        XCTAssertNil(CuePlayer.cue(from: nil, to: "permission"), "first sighting of a waiting session")
        XCTAssertNil(CuePlayer.cue(from: nil, to: "idle"), "first sighting of an idle session")
        XCTAssertNil(CuePlayer.cue(from: nil, to: "thinking"), "first sighting of a working session")
        XCTAssertNil(CuePlayer.cue(from: nil, to: "tool"), "first sighting of a running tool")
    }

    func testPermissionRequestSoundsOnce() {
        XCTAssertEqual(CuePlayer.cue(from: "thinking", to: "permission"), .permission, "agent stops to ask")
        XCTAssertEqual(CuePlayer.cue(from: "tool", to: "permission"), .permission, "tool wants approval")
        // Permission heartbeats are absent, but a rewrite must still not
        // re-announce the same state.
        XCTAssertNil(CuePlayer.cue(from: "permission", to: "permission"), "still waiting, no repeat")
    }

    func testFinishedTurnSounds() {
        XCTAssertEqual(CuePlayer.cue(from: "thinking", to: "idle"), .done, "turn finished")
        XCTAssertEqual(CuePlayer.cue(from: "tool", to: "idle"), .done, "tool finished and went idle")
        XCTAssertEqual(CuePlayer.cue(from: "permission", to: "idle"), .done, "answered, then finished")
        // The extension reports a finished turn as "done"; it counts as idle.
        XCTAssertEqual(CuePlayer.cue(from: "thinking", to: "done"), .done, "turn finished and reported done")
        XCTAssertEqual(CuePlayer.cue(from: "permission", to: "done"), .done, "answered, then finished and reported done")
    }

    func testEverythingElseStaysSilent() {
        XCTAssertNil(CuePlayer.cue(from: "idle", to: "thinking"), "new turn starting is not a cue")
        XCTAssertNil(CuePlayer.cue(from: "idle", to: "idle"), "no change")
        XCTAssertNil(CuePlayer.cue(from: "thinking", to: "tool"), "tool to tool is not a cue")
        XCTAssertNil(CuePlayer.cue(from: "permission", to: "thinking"), "user answered, work resumed")
        XCTAssertNil(CuePlayer.cue(from: "permission", to: "tool"), "user answered, tool resumed")
    }

    func testSoundAssetsExist() {
        // The sound assets themselves must exist, or the cues are silent no-ops.
        XCTAssertNotNil(NSSound(named: "Pop"), "NSSound(named: \"Pop\") resolves")
        XCTAssertNotNil(NSSound(named: "Tink"), "NSSound(named: \"Tink\") resolves")
    }
}
