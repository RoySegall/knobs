#!/usr/bin/env bash
# Builds Release and packages dist/Knobs-<version>.dmg: the app next to an Applications shortcut.
# The app is ad-hoc signed, not notarized: on another Mac, right-click › Open the first time.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?$/\1/p' project.yml | head -1)
derived="build/DerivedData.noindex"
dmg="dist/Knobs-$version.dmg"

scripts/generate.sh
xcodebuild build -scheme Knobs -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$derived" -quiet

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$derived/Build/Products/Release/Knobs.app" "$staging/Knobs.app"
ln -s /Applications "$staging/Applications"
mkdir -p dist
rm -f "$dmg"
hdiutil create -volname "Knobs $version" -srcfolder "$staging" -format UDZO -quiet "$dmg"
echo "$dmg"
