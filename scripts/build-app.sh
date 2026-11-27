#!/bin/bash
# Builds SwarfEngrave.app into ./build.
#
#   scripts/build-app.sh [debug|release]
#
# SE_VERSION=0.2 sets the version (default: the latest v* tag). SE_SCRATCH_PATH picks a SwiftPM scratch
# directory (default .build).
#
# Signing: with a "Developer ID Application" certificate in the keychain (or SE_SIGN_IDENTITY naming one)
# the app is signed with it (hardened runtime, timestamp), as notarization needs. Without one it's signed
# ad hoc, which is fine for running your own build.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
SCRATCH=()
[[ -n "${SE_SCRATCH_PATH:-}" ]] && SCRATCH=(--scratch-path "$SE_SCRATCH_PATH")

VERSION="${SE_VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo 0.1.0)}"
VERSION="${VERSION#v}"
# The build number is the commit time, so a later build always looks newer.
BUILD_NUMBER="${SE_BUILD_NUMBER:-$(git log -1 --format=%ct 2>/dev/null || echo 1)}"

IDENTITY="${SE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $2; exit }')
fi

swift build -c "$CONFIG" --product SwarfEngrave ${SCRATCH[@]+"${SCRATCH[@]}"}
BIN="$(swift build -c "$CONFIG" ${SCRATCH[@]+"${SCRATCH[@]}"} --show-bin-path)"
APP="build/SwarfEngrave.app"
EXE="$APP/Contents/MacOS/SwarfEngrave"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SwarfEngrave" "$EXE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
# SwiftPM resource bundles, if any target has resources.
for b in "$BIN"/*.bundle; do [[ -d "$b" ]] && ditto "$b" "$APP/Contents/Resources/$(basename "$b")"; done
printf 'APPL????' > "$APP/Contents/PkgInfo"

PLIST="$APP/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
pb "Set :CFBundleShortVersionString $VERSION"
pb "Set :CFBundleVersion $BUILD_NUMBER"

# Sparkle only when the binary actually links it (SwarfPath's package declares it for SwarfPath itself).
if otool -L "$EXE" | grep -q "Sparkle.framework"; then
  mkdir -p "$APP/Contents/Frameworks"
  SPARKLE="$BIN/Sparkle.framework"
  [[ -d "$SPARKLE" ]] || SPARKLE="$(find "${SE_SCRATCH_PATH:-.build}/artifacts" -path '*macos*/Sparkle.framework' -maxdepth 6 | head -1)"
  ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
  if ! otool -l "$EXE" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"
  fi
fi

if [[ -n "$IDENTITY" ]]; then
  echo "Signing with $IDENTITY"
  SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
else
  echo "No Developer ID certificate: signing ad hoc"
  SIGN=(codesign --force --sign -)
fi
sign() { local out; out=$("${SIGN[@]}" "$1" 2>&1) || { echo "$out" >&2; return 1; }; }
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$FW" ]]; then
  sign "$FW/Versions/B/Autoupdate"
  sign "$FW/Versions/B/Updater.app"
  sign "$FW"
fi
sign "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP ($VERSION)"
