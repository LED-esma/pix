#!/bin/bash
# Builds Pix, wraps it in a disk image, and notarizes it with Apple so it opens on
# any Mac without warnings.
#
# Uses a notarytool Keychain profile (default "pix-notary"; set NOTARY_PROFILE=<name> to use another).
# Needs a Developer ID Application certificate on your team (DEVELOPMENT_TEAM in project.yml).
#
#   tools/package.sh          → dist/Pix-<version>.dmg (notarized if a profile works)
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-pix-notary}"
TEAM=$(awk '/DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml)

[[ -s Plugins/python/pyodide.asm.wasm ]] || tools/fetch-plugins.sh
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/Pix.app/Contents/Info.plist)
DMG="dist/Pix-$VERSION.dmg"

rm -rf build/dmg "$DMG" && mkdir -p build/dmg
ditto dist/Pix.app build/dmg/Pix.app
ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname "Pix" -srcfolder build/dmg -fs HFS+ -format UDZO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

CHECK=$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1 || true)
if echo "$CHECK" | grep -q "agreement"; then
  echo "Built $DMG (signed, not notarized)."
  echo "Apple needs you to accept the latest Developer agreement: sign in at https://developer.apple.com/account, accept it, then run tools/package.sh again."
  exit 0
elif ! echo "$CHECK" | grep -qiE "error|no keychain"; then
  echo "Notarizing (a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  echo "Ready to share: $DMG"
else
  echo "Built $DMG (signed, not notarized)."
  echo "To notarize, run once:  xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id $TEAM"
  echo "then run tools/package.sh again."
fi
