# Release & Homebrew Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the repo installable by strangers: MIT license, a tag-driven GitHub Release that ships a DMG, and a Homebrew cask in a personal tap — proven end to end with a throwaway `v0.0.1`.

**Architecture:** No Swift changes. `build.sh` becomes the single version source (tag → `CFBundleShortVersionString`, commit count → `CFBundleVersion`). One new workflow builds the DMG on a tag push and publishes it as a prerelease. A second repo, `sabuz796/homebrew-tap`, holds a cask that points at that DMG.

**Tech Stack:** bash, GitHub Actions (`macos-latest`, `gh` CLI), Homebrew cask.

**Spec:** none — the design is this plan plus the conversation of 2026-10-22. Sparkle is deliberately out of scope; it gets its own plan once `v0.0.1` proves the pipeline.

## Global Constraints

- Deployment target macOS 13; `build.sh` builds arm64 + x86_64.
- Signing stays ad-hoc (`codesign --sign -`). No notarization in this plan: there is no confirmed Apple Developer ID.
- **Nothing is committed, tagged, or pushed until the user says "go".** Tasks 1–3 edit files and stop. Tasks 5–7 are gated on that word, so commits are batched at the gate instead of per task.
- Repo is already public with Issues enabled. No license file exists yet.
- Existing CI (`ci.yml`) must stay green: typecheck, `tests/cues`, `tests/sessionrules`, `tsc --noEmit`, `tests/extension.test.mjs`.

## Review Focus

- A tag written `0.0.1` instead of `v0.0.1`: workflow trigger is `v*`, so the release never runs. The plan's tag command must be copied exactly.
- `git describe` on a shallow CI checkout finds no tag, so the app would build with the fallback version. Fixed by `fetch-depth: 0` plus explicit `PISTATUS_VERSION` from the workflow.
- Renamed DMG asset vs cask `url`: if the workflow renames the file, the cask sha256 and URL must use the new name. Task 7 reads both from `gh release view`.
- Quarantine on a downloaded, ad-hoc-signed app shows "damaged and can't be opened". Cask caveats must give the `xattr -dr` line.
- The bundle path contains a space (`Pi Status Bar.app`): every shell step that touches it quotes.

---

### Task 1: Open-source housekeeping

**Files:**
- Create: `LICENSE`
- Modify: `README.md` (add License and Contributing headings at the end)

**Interfaces:**
- Produces: MIT license text at repo root, referenced from README; repo topics via `gh`.

- [ ] **Step 1: Write `LICENSE`.** MIT text, copyright line `Copyright (c) 2026 sabuz796`.
- [ ] **Step 2: Append to `README.md`:**

```markdown
## Contributing

Issues and pull requests are welcome. CI runs the Swift type check and the test programs in
`tests/`; run them the way `.github/workflows/ci.yml` does before opening a PR.

## License

MIT. See [LICENSE](LICENSE).
```

- [ ] **Step 3: Set repo metadata (gated, task 5):**

```bash
gh repo edit sabuz796/pi-status-menubar \
  --add-topic macos,menubar,swift,pi,statusbar --description "Menu bar status for the Pi coding agent"
```

- [ ] **Step 4: Verify.** Run: `test -f LICENSE && head -1 LICENSE`. Expected: `MIT License`.

### Task 2: Version and build number from git

**Files:**
- Modify: `build.sh:9` (version line), `build.sh:33` (`CFBundleVersion`)

**Interfaces:**
- Produces: `VERSION` (marketing, e.g. `0.0.1`) and `BUILD` (integer, e.g. `57`); consumed by the workflow and, later, by Sparkle's version comparison.

- [ ] **Step 1: Replace the version fallback.** No silent `0.5.9`; a tagless source build is honestly a dev build:

```bash
VERSION="${PISTATUS_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"
# Monotonic integer for Sparkle; a tag rebuild of the same commit keeps its number.
BUILD="${PISTATUS_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
```

The `|| true` is required: `build.sh` runs `set -euo pipefail`, so a missing tag makes the
substitution fail and kills the script. Verified in a throwaway repo (exit 128 without it).

- [ ] **Step 2: Use it in the plist.** `<key>CFBundleVersion</key><string>$BUILD</string>`; `CFBundleShortVersionString` keeps `$VERSION`.
- [ ] **Step 3: Verify.**

```bash
PISTATUS_VERSION=0.0.1 PISTATUS_BUILD=1 ./build.sh
plutil -p "build/Pi Status Bar.app/Contents/Info.plist" | grep -i version
```

Expected: `CFBundleShortVersionString => "0.0.1"`, `CFBundleVersion => "1"`. Note `CFBundleVersion` must stay numeric or Sparkle compares it as a string later.

### Task 3: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `build.sh --dmg` (existing), `VERSION`/`BUILD` env from task 2.
- Produces: release asset `PiStatusBar-<version>.dmg` plus `<same>.sha256` on a `v*` tag; consumed by the cask in task 7.

- [ ] **Step 1: Write the workflow.**

```yaml
name: Release
on:
  push:
    tags: ["v*"]
permissions:
  contents: write
jobs:
  release:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0        # git describe + rev-list need the history
      - name: Build
        run: |
          export PISTATUS_VERSION="${GITHUB_REF_NAME#v}"
          ./build.sh --dmg
          mv build/PiStatusBar.dmg "build/PiStatusBar-${PISTATUS_VERSION}.dmg"
          cd build && shasum -a 256 "PiStatusBar-${PISTATUS_VERSION}.dmg" > "PiStatusBar-${PISTATUS_VERSION}.dmg.sha256"
      - name: Publish prerelease
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          V="${GITHUB_REF_NAME#v}"
          gh release create "v$V" --prerelease --generate-notes --title "$V" \
            --clobber "build/PiStatusBar-$V.dmg" "build/PiStatusBar-$V.dmg.sha256"
```

- [ ] **Step 2: Verify the YAML parses.** Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml")' && echo ok`. Expected: `ok`.
- [ ] **Step 3: Verify the build steps run by hand** (the runner is the only untested part):

```bash
export PISTATUS_VERSION=0.0.1
./build.sh --dmg && mv build/PiStatusBar.dmg "build/PiStatusBar-0.0.1.dmg"
shasum -a 256 "build/PiStatusBar-0.0.1.dmg"
```

Expected: one hash line, file exists.

### Task 4: Local gate — prove the artifact before anything leaves the machine

**Files:** none (verification only)

**Interfaces:**
- Consumes: tasks 1–3.
- Produces: a green local run of every CI check plus an inspected DMG. This is the "test that everything is fine" the user asked for.

- [ ] **Step 1: Run every CI check locally.**

```bash
swiftc -typecheck Sources/*.swift Sources/Dashboard/*.swift -framework Cocoa
swiftc -O Sources/Sounds.swift tests/cues/main.swift -o /tmp/cues && /tmp/cues
swiftc -O Sources/Sounds.swift Sources/SessionRules.swift tests/sessionrules/main.swift -o /tmp/sr && /tmp/sr
npx tsc --noEmit && node tests/extension.test.mjs && bash -n build.sh
```

Expected: no errors; both test programs print their pass lines.

- [ ] **Step 2: Inspect the DMG itself.**

```bash
hdiutil attach "build/PiStatusBar-0.0.1.dmg" -nobrowse
APP="/Volumes/Pi Status Bar/Pi Status Bar.app"
plutil -p "$APP/Contents/Info.plist" | grep -i -E "version|identifier"
codesign -dv "$APP" 2>&1 | grep -E "Signature|Identifier"
open "$APP"; sleep 3; osascript -e 'quit app "PiStatusBar"'
hdiutil detach "/Volumes/Pi Status Bar"
```

Expected: version `0.0.1`, build number numeric, `Signature=adhoc`, app launches and quits.

- [ ] **Step 3: Stop.** Report the plutil and codesign lines to the user. Nothing is committed yet.

### Task 5: GATED — first commit and push

**Files:** all of tasks 1–3

- [ ] **Step 1: Wait for the user's explicit go.**
- [ ] **Step 2:**

```bash
git add -A && git status --short
git commit -m "Open source: MIT license, tag-driven release workflow, version from git"
git push origin main
```

- [ ] **Step 3: Verify.** Run: `gh run list --workflow=ci.yml --limit 1`. Expected: CI `completed  success`.

### Task 6: GATED — throwaway `v0.0.1` release, verified from GitHub

**Files:** none

**Interfaces:**
- Produces: release `v0.0.1` (prerelease) with `PiStatusBar-0.0.1.dmg` and its `.sha256`; consumed by task 7.

- [ ] **Step 1: Tag and push.**

```bash
git tag v0.0.1 && git push origin v0.0.1
```

- [ ] **Step 2: Watch the run.** Run: `gh run watch --exit-status`. Expected: success.
- [ ] **Step 3: Download the published asset, not the local one.**

```bash
gh release download v0.0.1 --pattern "*.dmg*" --dir /tmp/rel
cd /tmp/rel && shasum -a 256 -c PiStatusBar-0.0.1.dmg.sha256
gh release view v0.0.1 --json isPrerelease,assets --jq '.isPrerelease, (.assets[].name)'
```

Expected: `OK`, `true`, both asset names.

- [ ] **Step 4: Install that copy and use it.**

```bash
hdiutil attach /tmp/rel/PiStatusBar-0.0.1.dmg -nobrowse
rm -rf "/Applications/Pi Status Bar.app" && cp -R "/Volumes/Pi Status Bar/Pi Status Bar.app" /Applications/
open "/Applications/Pi Status Bar.app"
```

Expected: π appears, panel opens, Report a Bug opens a new-issue page.

- [ ] **Step 5: Keep or roll back.**

```bash
# broken:
git tag -d v0.0.1 && git push --delete origin v0.0.1 && gh release delete v0.0.1 --yes
# fine: leave it as a prerelease; the real release is v0.1.0
```

### Task 7: GATED — Homebrew tap and cask

**Files:**
- Create in `sabuz796/homebrew-tap`: `Casks/pi-status-bar.rb`

**Interfaces:**
- Consumes: asset name and sha256 from task 6 step 3.
- Produces: `brew install --cask sabuz796/tap/pi-status-bar` works on a machine that has never built the app.

- [ ] **Step 1: Create the tap.**

```bash
gh repo create sabuz796/homebrew-tap --public \
  --description "Homebrew casks for sabuz796's apps"
git clone git@github.com:sabuz796/homebrew-tap.git /tmp/tap && mkdir -p /tmp/tap/Casks
```

- [ ] **Step 2: Write the cask.** `version` and `sha256` come from task 6; the URL file name must match the uploaded asset exactly.

```ruby
cask "pi-status-bar" do
  version "0.0.1"
  sha256 "PASTE_SHA256_FROM_TASK_6"

  url "https://github.com/sabuz796/pi-status-menubar/releases/download/v#{version}/PiStatusBar-#{version}.dmg"
  name "Pi Status Bar"
  desc "Menu bar status for the Pi coding agent"
  homepage "https://github.com/sabuz796/pi-status-menubar"

  depends_on macos: ">= :ventura"
  app "Pi Status Bar.app"

  caveats <<~EOS
    This build is not notarized. If macOS says it is damaged, run:
      xattr -dr com.apple.quarantine "/Applications/Pi Status Bar.app"
  EOS
end
```

- [ ] **Step 3: Push the tap, then install through it.**

```bash
cd /tmp/tap && git add . && git commit -m "Add pi-status-bar 0.0.1" && git push
brew tap sabuz796/tap && brew install --cask sabuz796/tap/pi-status-bar
```

Expected: cask installs into `/Applications`, version `0.0.1`.
- [ ] **Step 4: Verify a clean path.** Run: `brew info --cask sabuz796/tap/pi-status-bar` and `brew uninstall --cask pi-status-bar && brew install --cask sabuz796/tap/pi-status-bar`. Expected: install → uninstall → install all succeed.

### Task 8: GATED — README install section

**Files:**
- Modify: `README.md` (Install section, before "**1. Build the app**")

- [ ] **Step 1: Insert Homebrew as the primary install**, keeping build-from-source as the fallback:

```markdown
**The quick way**

```bash
brew install --cask sabuz796/tap/pi-status-bar
```

The build is not notarized. If macOS says the app is damaged, run
`xattr -dr com.apple.quarantine "/Applications/Pi Status Bar.app"`, then open it again.

**Building it yourself**
```

- [ ] **Step 2: Commit and push** (same gate, separate commit): `git add README.md && git commit -m "README: install with Homebrew" && git push`.
- [ ] **Step 3: Verify.** Run: `gh repo view --web` and read the Install section. Expected: Homebrew first, no broken links.

---

## Out of scope (next plan)

Sparkle auto-update: `Package.swift`, `SPUStandardUpdaterController`, `SUFeedURL`, `SUPublicEDKey`, `sign_update` + appcast step in `release.yml`, hardened runtime. Blocked on the same unanswered question: is there an Apple Developer ID account ($99/yr)? Without it there is no notarization, and Homebrew users meet Gatekeeper on every install.
