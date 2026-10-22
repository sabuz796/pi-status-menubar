# Menu as popover panel — short design (Option 1)

## Intent
Clicking π shows an NSPopover panel (system-drawn arrow, like the Dashboard)
containing all the menu options — sessions, view toggles, sounds, Dashboard, Quit.
Includes dashboard-popover features — the \u25b6 preview, hover highlights, restored
session subtitles — straight into panel rows.

## Approach
- `statusItem.button` gets a toggle action: first click opens a transient
  `NSPopover`, second click (or outside-click or ⎋) closes it.
- New `Sources/MenuPanel.swift` builds a stack of custom row views (this app
  already had to paint its own rows for the sound toggles; those views move
  here and every row reuses them).
- Dashboard row closes the panel first, then shows the existing Dashboard
  popover (one anchor, no arrow overlap).
- `NSMenu` and all its plumbing is deleted.

## Accepted trade-offs
- Full custom row rendering: hover, checkmarks, key hints drawn by us.
- ⌘ key hints display as text only; behavior comes from clicking rows.
- Arrow-key navigation does not apply (custom views).
- Session rows live-update while open via the existing 0.4 s tick.
