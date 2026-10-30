#!/bin/bash
# Builds the app and packs it into build/CS2-Launcher-<version>-macOS.zip.
# Usage: scripts/package-release.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/make-app.sh
APP="build/CS2 Launcher.app"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
ZIP="build/CS2-Launcher-$VERSION-macOS.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Zip:    $ZIP"
echo "sha256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
