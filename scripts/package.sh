#!/usr/bin/env bash
# Builds Release and packages dist/Knobs-<version>.dmg: the app next to an Applications shortcut.
# With a "Developer ID Application" certificate in the keychain it signs with the hardened runtime,
# notarizes with the App Store Connect API key in ~/.appstoreconnect and staples the ticket.
# Without one it falls back to ad-hoc signing (right-click › Open on other Macs).
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?$/\1/p' project.yml | head -1)
derived="build/DerivedData.noindex"
dmg="dist/Knobs-$version.dmg"
team="R597KLS2BP"
api_key_id="Y48SGJ825V"
api_issuer="f1962011-0711-47f0-a431-1bad9d8d3cde"
api_key="$HOME/.appstoreconnect/private_keys/AuthKey_$api_key_id.p8"

identity=$(security find-identity -v -p codesigning | sed -nE "s/.*\"(Developer ID Application: .*\($team\))\".*/\1/p" | head -1)

scripts/generate.sh
if [[ -n "$identity" ]]; then
  echo "Signing as $identity" >&2
  xcodebuild build -scheme Knobs -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$derived" -quiet \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp
else
  echo "No Developer ID Application certificate for $team: ad-hoc signing" >&2
  xcodebuild build -scheme Knobs -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$derived" -quiet
fi

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$derived/Build/Products/Release/Knobs.app" "$staging/Knobs.app"
ln -s /Applications "$staging/Applications"
mkdir -p dist
rm -f "$dmg"
hdiutil create -volname "Knobs $version" -srcfolder "$staging" -format UDZO -quiet "$dmg"

if [[ -n "$identity" ]]; then
  codesign --sign "$identity" --timestamp "$dmg"
  xcrun notarytool submit "$dmg" --key "$api_key" --key-id "$api_key_id" --issuer "$api_issuer" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi
echo "$dmg"
