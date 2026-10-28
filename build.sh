#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/InstanceManager"

APP="build/InstanceManager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/InstanceManager"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp config.example.json "$APP/Contents/Resources/config.example.json"
codesign --force --sign - "$APP"

echo "Built: $APP"
echo "Run: open $APP"
