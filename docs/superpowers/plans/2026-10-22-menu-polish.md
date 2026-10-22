# Menu polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the pull-down menu as Demo 1: restored session subtitles, native-grid sound rows with aligned ▶ column, painted hover, typographic ellipsis, brighter play glyph.

**Architecture:** All changes confined to `Sources/main.swift` menu code (session-row rendering, sound-row custom views) plus one menu title change. No new files; `Sounds.swift` untouched.

**Tech Stack:** AppKit, Swift, existing `build.sh` (universal binary, target macos13).

**Spec:** docs/superpowers/specs/2026-10-22-menu-polish-design.md

## Global Constraints

- Deployment target macOS 13 (build.sh `-target …macos13.0`); `subtitle` guarded by `if #available(macOS 14.4, *)`.
- Main-thread only UI; current project has no XCTest target for UI — verification is build + running app + user visual check.
- No colors hardcoded: `labelColor`, `secondaryLabelColor`, `selectedMenuItemColor` only.

## Review Focus

- Dark mode + reduced transparency: hover fill must stay below text (contrast preserved) — visual check, task 3.
- Long session names: menu width grows via *native* rows; custom rows keep fixed width — check sound rows don't end up visually inset (task 2 step 4).
- Toggling from a custom row must still close the menu and persist (regression from native behavior) — task 2 step 4.
- Two sound rows preview actions must stay independent of toggle state — existing behavior, untouched (task 2 step 4).

---

### Task 1: Session rows — dot as `image`, restore subtitle

**Files:**
- Modify: `Sources/main.swift` (`applySessionRow`, plus `dotImage` helper; `refreshOpenMenuRows` already calls `applySessionRow`)

**Interfaces:**
- Consumes: `sessionParts(_:)` (existing).
- Produces: session rows render via `item.image` + `item.title` + `item.subtitle` (macOS 14.4+ guard).

- [ ] **Step 1: Remove `attributedTitle` path in `applySessionRow`; set `image`, `title`, `subtitle`.** Colored glyph drawn into a small `NSImage` (text glyph, glyph color); title = plain name; subtitle unchanged logic.
- [ ] **Step 2: Build.** Run: `PISTATUS_VERSION=0.0.1 ./build.sh`. Expected: builds; no new warnings.

### Task 2: Sound rows — native-grid height + aligned ▶ column + hover

**Files:**
- Modify: `Sources/main.swift` (`addSoundRow`, `toggleSound`, new hover row view)

**Interfaces:**
- Consumes: `cues.preview(_:)`, `cues.play(_:)` (existing). Produces: `addSoundRow(_:key:enabled:preview:)` signature unchanged.

- [ ] **Step 1: Replace stack row with 22 pt container** (toggle leading, play trailing at fixed insets), row width = 22 + max(label width of the two rows) + column gap + 16 so ▶ aligns across both rows.
- [ ] **Step 2: Add hover tracking:** tracking area on the row; on enter/exit set a flag and `needsDisplay = true`; `draw(_:)` fills a rounded rect (`selectedMenuItemColor`, radius ~5, alpha tuned) under the buttons.
- [ ] **Step 3: `▶` tint `.labelColor`.**
- [ ] **Step 4: Build + visual regressions.** Run: `PISTATUS_VERSION=0.0.1 ./build.sh`, swap into /Applications, relaunch, open menu: click text toggles (menu closes, setting persists), click ▶ previews one cue only, hover shows highlight.

### Task 3: Copy polish

**Files:**
- Modify: `Sources/main.swift` (~line 649)

- [ ] **Step 1: `Dashboard...` → `Dashboard…`.**
- [ ] **Step 2: Build, swap, launch; user visual check in dark + light.**

### Task 4: Report

- [ ] State what was verified vs left for the user's eye (menu rendering can't be asserted in-headless).
