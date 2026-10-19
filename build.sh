#!/bin/bash
# Builds Clementine.app from source and installs it into Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Clementine.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "Compiling…"
xcrun swiftc -swift-version 5 -O Sources/*.swift -o "$APP/Contents/MacOS/Clementine"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Clementine</string>
<key>CFBundleIdentifier</key><string>com.nurelmasri.clementine</string>
<key>CFBundleName</key><string>Clementine</string>
<key>CFBundleDisplayName</key><string>Clementine</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -x Clementine 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/Clementine.app"
cp -R "$APP" "$DEST/"
open "$DEST/Clementine.app"
echo "Installed: $DEST/Clementine.app"
