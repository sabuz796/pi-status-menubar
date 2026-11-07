import Cocoa

// Two moments are worth interrupting for: the agent asking permission, and a
// turn finishing. Both use stock macOS sounds from /System/Library/Sounds, so
// nothing is shipped and nothing is downloaded.
//
// The two are deliberately different sounds. Permission needs attention now, a
// finished turn is only informational, and one sound for both would make them
// indistinguishable by ear. Which cue a transition owes is decided in
// SessionReading.cue(from:to:); this type is the speaker, not the decider.

final class CuePlayer {
    private let permissionSound = NSSound(named: "Pop")
    private let doneSound = NSSound(named: "Tink")

    var permissionEnabled = true
    var doneEnabled = true

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
