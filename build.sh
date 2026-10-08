#!/bin/bash
# Builds Pix.app, signed with your Developer ID so screen permissions survive
# rebuilds. Runs the self-check against the built app.
#   ./build.sh            build into dist/
#   ./build.sh --install  also replace /Applications/Pix.app and relaunch it
set -euo pipefail
cd "$(dirname "$0")"

# App icon is drawn from the same pixel map as the buddy.
mkdir -p build/icon
swiftc -O tools/icon/main.swift Sources/Pix/Blob.swift -o build/icon/draw
build/icon/draw build/icon/Pix.iconset
iconutil -c icns build/icon/Pix.iconset -o Sources/Pix/Resources/Pix.icns

xcodegen generate --quiet
# Without a Developer ID certificate on this Mac (anyone building from source), sign ad hoc:
# it runs fine, but macOS asks for Screen Recording and Accessibility again after each rebuild.
SIGN=()
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  echo "No Developer ID certificate here: signing ad hoc."
  SIGN=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS=)
  export PIX_UNSIGNED=1
fi
xcodebuild -project Pix.xcodeproj -scheme Pix -configuration Release \
  -derivedDataPath build -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  -quiet build ${SIGN[@]+"${SIGN[@]}"}  # universal: Apple silicon and Intel Macs

rm -rf dist && mkdir -p dist
ditto build/Build/Products/Release/Pix.app dist/Pix.app
codesign --verify --deep --strict dist/Pix.app
[ "$(lipo -archs dist/Pix.app/Contents/MacOS/Pix)" = "x86_64 arm64" ] || { echo "Not universal: $(lipo -archs dist/Pix.app/Contents/MacOS/Pix)"; exit 1; }

dist/Pix.app/Contents/MacOS/Pix --selfcheck

if [[ "${1:-}" == "--install" ]]; then
  # Quit only the app (no arguments), not Pix commands you're running (--doctor, --ask) or a run's tools (--mcp).
  pkill -f '/Pix\.app/Contents/MacOS/Pix$' 2>/dev/null || true
  rm -rf /Applications/Pix.app
  ditto dist/Pix.app /Applications/Pix.app
  # Same path and version every time, so macOS kept showing a cached older icon: tell it to look again.
  touch /Applications/Pix.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Pix.app
  sleep 1
  open /Applications/Pix.app
  echo "Installed and launched /Applications/Pix.app"
else
  echo "Built dist/Pix.app"
fi
