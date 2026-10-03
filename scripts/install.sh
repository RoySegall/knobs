#!/usr/bin/env bash
# Builds Release and installs the one copy of Knobs at ~/Applications/Knobs.app.
# Build products live under a *.noindex folder, so Spotlight and the App Library list only this copy.
set -euo pipefail
cd "$(dirname "$0")/.."
derived="build/DerivedData.noindex"
target="$HOME/Applications/Knobs.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

xcodebuild build -scheme Knobs -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" -quiet
pkill -x Knobs || true
rm -rf "$target"
ditto "$derived/Build/Products/Release/Knobs.app" "$target"
"$lsregister" -u "$derived/Build/Products/Release/Knobs.app" 2>/dev/null || true
"$lsregister" -f "$target"
echo "$target"
