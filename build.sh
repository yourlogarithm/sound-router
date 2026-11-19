#!/bin/sh
# Builds SoundRouter.app (menu-bar only, ad-hoc signed) next to this script.
set -e
cd "$(dirname "$0")"
APP=SoundRouter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/SoundRouter"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.soundrouter</string>
    <key>CFBundleName</key><string>SoundRouter</string>
    <key>CFBundleExecutable</key><string>SoundRouter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>SoundRouter plays your capture card's audio input on your speakers.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
