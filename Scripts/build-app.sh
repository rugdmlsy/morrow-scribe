#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --product MorrowScribeApp
BIN="$(swift build -c release --show-bin-path)/MorrowScribeApp"
ICON="$ROOT/.build/AppIcon.icns"
"$ROOT/Scripts/build-icon.sh" "$ROOT/Assets/AppIcon.png" "$ICON" >/dev/null
DEST="${1:-$HOME/Applications/Morrow Scribe.app}"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BIN" "$DEST/Contents/MacOS/MorrowScribeApp"
cp "$ICON" "$DEST/Contents/Resources/AppIcon.icns"
cat > "$DEST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MorrowScribeApp</string>
  <key>CFBundleIdentifier</key><string>com.morrow.scribe</string>
  <key>CFBundleName</key><string>Morrow Scribe</string>
  <key>CFBundleDisplayName</key><string>Morrow Scribe</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Accessibility/TCC grants are matched against the app's designated code requirement.
# Plain ad-hoc signing defaults that requirement to the current binary CDHash, so every
# rebuild invalidates an existing Accessibility grant. Keep a stable explicit requirement
# based on the bundle identifier instead.
codesign --force --deep --sign - \
  --identifier com.morrow.scribe \
  --requirements '=designated => identifier "com.morrow.scribe"' \
  "$DEST"
echo "$DEST"
