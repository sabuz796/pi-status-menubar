# Pi Status Bar

A tiny macOS menu bar app showing **Pi coding agent's live status**: a spinning indicator while Pi thinks or runs a tool, the tool label (`Editing`, `Running command`, …), the elapsed turn timer, a yellow dot while Pi waits on your input, and a per-session dropdown. No dock icon, no window.

Built so you can tab away during a long run and still see at a glance whether Pi is working, waiting on you, or done.

## How it works

Two parts talk through files. No socket, no server.

1. **Pi extension** (`extensions/pi-statusbar.ts`) listens to Pi events (`session_start`, `agent_start`, `tool_execution_start/end`, `ui_prompt_start/end`, `agent_settled`, `session_shutdown`) and writes one JSON file per session to `~/.pi/statusbar/state.d/<sessionId>.json`.
2. **Swift menu bar app** (`Sources/main.swift`) polls that folder every 0.4s, shows the most urgent session (waiting > working > idle, recency tiebreak), and quits itself when no session is live.

## Install

1. Build: `./build.sh` (or `./build.sh --dmg` for a disk image).
2. Copy `build/Pi Status Bar.app` to Applications and launch it once. First launch copies the extension to `~/.pi/agent/extensions/pi-statusbar.ts`, so Pi loads it from then on.
3. Run Pi. The icon appears whenever a Pi session is active.

## Uninstall

1. Quit the app from its menu (this also suppresses auto-relaunch).
2. Delete `~/.pi/agent/extensions/pi-statusbar.ts` and `~/.pi/statusbar`.
3. Drag the app to the Trash.

## States

| State | Icon |
|---|---|
| Thinking / tool running | thin arc orbiting the π (GPU layer, 30fps) + label + timer (`Editing  1m 1s`) |
| Awaiting input (confirm/select) | amber dot, soft pop-in + gentle pulse |
| Idle / done | static dimmed π, zero motion (timer stopped) |

Menu options: Show timer, Show text, Permission sound, Turn finished sound, Test sound. Clicking a session row activates the terminal application (when `TERM_PROGRAM` is known). Selecting the exact window or tab is not supported: the app only runs `open -a <AppName>`, which brings the application to the front.

## Sounds

Two stock macOS sounds, no files shipped and nothing downloaded:

- **Permission** (`Pop`): the agent is asking for approval.
- **Turn finished** (`Tink`): a turn ended.

Both are independently switchable from the menu and are remembered across launches. `Test sound` previews the permission cue so a choice can be heard without waiting for a turn. A session seen for the first time never sounds, so opening the app does not replay the current state.

## App icon

The app icon comes from `images/app-icon.svg`. The SVG is the only source: `build.sh` renders it through AppKit into a `.iconset` and `iconutil` packs that into `AppIcon.icns` on every build, so no binary icon is kept in the repository. The artwork is clipped to the macOS icon shape, a superellipse with exponent 5.

The menu bar glyph is a separate asset, `images/pi.png`, and is unrelated to the app icon.

## Layout

- `extensions/pi-statusbar.ts`: Pi extension (event → state file writer).
- `Sources/main.swift`: Swift menu bar app (~600 lines, one animation style).
- `Sources/Sounds.swift`: the two notification cues and the rules for when they fire.
- `Sources/Dashboard/`: the Pi Stats dashboard, five tabs, no third-party dependencies.
- `tools/AppIcon/main.swift`: renders `images/app-icon.svg` into a `.iconset`.
- `build.sh`: universal `swiftc` build + `.app` bundle + icon generation + optional DMG.
- `tests/cues/`: the cue rules, checked against exact expected values.
- `PLAN.md`: the build plan.
