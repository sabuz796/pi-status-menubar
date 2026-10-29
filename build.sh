#!/bin/bash
# Builds PiStatusBar.app (and optionally a .dmg with: ./build.sh --dmg).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Pi Status Bar.app"
BIN="$APP/Contents/MacOS/PiStatusBar"
# Version comes from the latest git tag (GitHub releases), override with PISTATUS_VERSION=1.2.3.
# The || true matters: set -euo pipefail would otherwise abort on a tagless checkout.
VERSION="${PISTATUS_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
# Monotonic integer for update checks; a rebuild of the same commit keeps its number.
BUILD="${PISTATUS_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"

# Cleanup intermediate files on exit
ICON_TOOL=""
cleanup() { rm -f ${ICON_TOOL:+"$ICON_TOOL"}; }
trap cleanup EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "Building universal binary (arm64 + x86_64)…"
# Swift Package Manager builds the same code as `swift test` uses, so the
# shipped app and the tested library can never drift apart.
swift build -c release --arch arm64 --arch x86_64
BIN_SRC=""
for candidate in .build/out/Products/Release/PiStatusBar .build/apple/Products/Release/PiStatusBar .build/release/PiStatusBar; do
  if [[ -f "$candidate" ]]; then BIN_SRC="$candidate"; break; fi
done
if [[ -z "$BIN_SRC" ]]; then
  echo "error: SwiftPM did not produce a PiStatusBar binary" >&2
  exit 1
fi
cp "$BIN_SRC" "$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PiStatusBar</string>
  <key>CFBundleDisplayName</key><string>Pi Status Bar</string>
  <key>CFBundleIdentifier</key><string>io.github.sabuz796.pistatusbar</string>
  <key>CFBundleExecutable</key><string>PiStatusBar</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Bundle the Pi extension so first launch can install it, plus the icon.
mkdir -p "$APP/Contents/Resources"
cp extensions/pi-statusbar.ts "$APP/Contents/Resources/pi-statusbar.ts"
cp images/pi.png "$APP/Contents/Resources/pi.png"

# Real language marks. Vector SVG, loaded straight by AppKit, no conversion step.
mkdir -p "$APP/Contents/Resources/languages"
cp images/languages/*.svg "$APP/Contents/Resources/languages/"

# App icon. The SVG is the only source; the .icns is generated on every build,
# so no binary icon is kept in the repository.
echo "Rendering app icon from images/app-icon.svg…"
ICON_TOOL="build/AppIconTool"
ICONSET="build/AppIcon.iconset"
swiftc -O tools/AppIcon/main.swift -o "$ICON_TOOL" -framework Cocoa
"$ICON_TOOL" images/app-icon.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

xattr -cr "$APP"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if [[ "${1:-}" == "--dmg" ]]; then
  echo "Packaging DMG…"
  DMG="build/PiStatusBar.dmg"
  STAGE="build/dmg-stage"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Pi Status Bar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "Built $DMG"
fi
