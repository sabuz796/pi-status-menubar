# Pi Status Bar

The language of the menu bar app and its Pi extension: how one live coding-agent session is reported, ranked, and announced.

## Language

**Session state vocabulary**:
The small wall of states a session can be reported in: idle, thinking, tool, permission, done. One wall, fixed names, written by the extension and read by the app. Nothing outside this set is displayable.
_Avoid_: status, mode, phase

**Session reading**:
The single act of interpreting one session file right now: its effective state, glyphs, labels, tooltip parts, and the cue the transition owes. Once per session, produced by the SessionReading module.
_Avoid_: evaluation, assessment, render

**Lead session**:
The one session the menu bar item shows when several are live, picked by the reading rule of the SessionReading module: permission outranks working, working outranks idle, ties break by recency.
_Avoid_: top session, current session, priority session

**Reported state**:
The state a session's file reported on the previous reading, kept by the app per session id. Reported state is what makes transitions audible; a session seen for the very first time is never announced.
_Avoid_: last state, previous state, before-state

## Protocol terms

**State file**:
One JSON file in `~/.pi/statusbar/state.d/`, one per session, written atomically by the extension and read by the app. The only inter-process medium. Named by the session id.
_Avoid_: session file, state.d file

**State directory**:
The 0700 folder `~/.pi/statusbar` and its `state.d/`, the keeper of state files, the log, markers and the dashboard cache. Private to the user's account.
_Avoid_: statusbar folder, data dir

**Marker**:
A small file at the state directory root that carries a cross-process instruction: the focus refresh marker (redetect your pane), the quit intent (do not relaunch the app). Written and consumed by both sides under the same-user protocol.
_Avoid_: signal file, flag file
