#!/bin/bash
# Builds build/Hark.app and signs it with a stable local identity, so macOS keeps your
# Microphone/Accessibility grants across rebuilds. Set HARK_SIGN_IDENTITY to use your own
# Developer ID instead.
#
#   scripts/build-app.sh            # release build
#   scripts/build-app.sh --open     # build, then launch
#   HARK_APP=dist/Hark.app scripts/build-app.sh   # build somewhere else (release.sh does)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="${HARK_APP:-build/Hark.app}"

echo "→ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --product Hark
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

echo "→ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Hark" "$APP/Contents/MacOS/Hark"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Embed the dynamic frameworks Hark actually links (stale ones in the build folder are skipped).
for framework in "$BIN"/*.framework; do
  [ -d "$framework" ] || continue
  otool -L "$BIN/Hark" | grep -q "$(basename "$framework")" || continue
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$framework" "$APP/Contents/Frameworks/"
done
if [ -d "$APP/Contents/Frameworks" ]; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Hark" 2>/dev/null || true
fi

echo "→ Signing…"
IDENTITY="${HARK_SIGN_IDENTITY:-Hark Local Signing}"
[ -n "${HARK_SIGN_IDENTITY:-}" ] || scripts/dev-signing.sh >/dev/null
for framework in "$APP"/Contents/Frameworks/*.framework; do
  [ -d "$framework" ] && codesign --force --sign "$IDENTITY" "$framework"
done
codesign --force --sign "$IDENTITY" --identifier dev.hark.Hark "$APP"
codesign --verify "$APP" && echo "✓ Built $APP"

if [ "${1:-}" = "--open" ]; then
  pkill -x Hark 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi
