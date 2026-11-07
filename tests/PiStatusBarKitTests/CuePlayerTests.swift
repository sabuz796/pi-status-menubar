import Cocoa
import XCTest
@testable import PiStatusBarKit

// The cue decision table lives in SessionReading, where it is covered by
// SessionReadingTests alongside the rest of a session's meaning. This suite
// keeps the only thing the player owns: the sound assets themselves.
final class CuePlayerTests: XCTestCase {
    func testSoundAssetsExist() {
        // The sound assets themselves must exist, or the cues are silent no-ops.
        XCTAssertNotNil(NSSound(named: "Pop"), "NSSound(named: \"Pop\") resolves")
        XCTAssertNotNil(NSSound(named: "Tink"), "NSSound(named: \"Tink\") resolves")
    }
}
