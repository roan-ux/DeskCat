#!/usr/bin/env bash
# Builds a release binary and wraps it in DeskCat.app (menu-bar only, ad-hoc signed for local use).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/DeskCat.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/DeskCat" "$APP/Contents/MacOS/DeskCat"
mkdir -p "$APP/Contents/Resources"
cp -R Sounds "$APP/Contents/Resources/Sounds"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DeskCat</string>
    <key>CFBundleIdentifier</key><string>com.skailama.deskcat</string>
    <key>CFBundleExecutable</key><string>DeskCat</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
