import Cocoa

// Two moments are worth interrupting for: the agent asking permission, and a turn
// finishing. Both use stock macOS sounds from /System/Library/Sounds, so nothing
// is shipped and nothing is downloaded.
//
// The two are deliberately different sounds. Permission needs attention now, a
// finished turn is only informational, and one sound for both would make them
// indistinguishable by ear.
enum Cue {
    case permission
    case done
}

final class CuePlayer {
    private let permissionSound = NSSound(named: "Pop")
    private let doneSound = NSSound(named: "Tink")

    var permissionEnabled = true
    var doneEnabled = true

    // Which cue, if any, a state change owes. Pure so it can be tested directly;
    // the rules that matter are that a first sighting stays silent, that waiting
    // for permission does not repeat, and that only real work finishing counts.
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

    // "done" is the reported form of a finished turn; it means idle.
    private static func normalized(_ state: String) -> String {
        state == "done" ? "idle" : state
    }

    func play(_ cue: Cue) {
        switch cue {
        case .permission:
            guard permissionEnabled else { return }
            play(permissionSound)
        case .done:
            guard doneEnabled else { return }
            play(doneSound)
        }
    }

    // Menu previews. Ignores the toggles on purpose: they exist to audition the
    // sound, so they have to make a noise even with both cues switched off.
    func preview(_ cue: Cue) {
        switch cue {
        case .permission: play(permissionSound)
        case .done: play(doneSound)
        }
    }

    // Restart rather than overlap: a burst of transitions should read as one cue,
    // not a stutter.
    private func play(_ sound: NSSound?) {
        guard let sound = sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
