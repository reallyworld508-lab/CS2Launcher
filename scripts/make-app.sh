#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product CS2Launcher
BIN_DIR="$(swift build -c release --product CS2Launcher --show-bin-path)"
BIN="$BIN_DIR/CS2Launcher"
APP="build/CS2 Launcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CS2Launcher"
cp -R "$BIN_DIR"/CS2Launcher_CS2LauncherCore.bundle "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CS2Launcher</string>
    <key>CFBundleIdentifier</key><string>com.vladimirrw.cs2launcher</string>
    <key>CFBundleName</key><string>CS2 Launcher</string>
    <key>CFBundleDisplayName</key><string>CS2 Launcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP"
echo "Built $APP"
