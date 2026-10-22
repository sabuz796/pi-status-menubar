# Menu polish (Sonoma-style pf menu) — short design

## Intent
Finish the pull-down menu as a coherent Sonoma-style menu in both light and dark
mode, per Demo 1 ("Finished custom") chosen on 2026-10-22.

## Goals
1. Session rows show state again: colored dot image + name + gray subtitle
   (subtitle currently suppressed when `attributedTitle` is set).
2. Sound rows sit on the native grid: 22 pt row, native baseline, and the `▶`
   preview button aligns into one right-hand column across both rows.
3. Hover on custom rows paints the system highlight (rounded, accent-aware),
   matching native rows.
4. `Dashboard...` → `Dashboard…` (typographic ellipsis, `menus.md › Labels`).
5. ▶ tint to `labelColor` (contrast ≥ 4.5:1 in dark, semantic per `dark-mode.md`).

## Non-goals
- No change to Dashboard panel, cue logic, status-bar `M: 67%` strip.
- No app-specific appearance toggle.

## Approaches considered
- **A (chosen): custom-view sound rows + painted hover.** Keeps the inline ▶
  the user requested twice. Cost: keyboard nav skips the two custom rows
  (accepted, documented); hover is our drawing.
- **B (rejected): native rows +submenu for play.** Perfectly native, loses the
  inline ▶.
- **C (rejected): gap-only grouping, no section headers.** Quieter, but loses
  the scannable signposts for a 9-item utility menu.

## Left to the builder
- Exact hover-draw color: use `NSColor.selectedMenuItemColor`; adjust alpha by eye.
- Dot-image sizing so the glyph's optical width matches the text baseline.
