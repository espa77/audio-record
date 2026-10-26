#!/bin/zsh
# Builds AudioRecord.app with the Swift toolchain only (no Xcode.app needed).
#   scripts/build-app.sh            → dist/AudioRecord.app
#   scripts/build-app.sh --install  → also replaces /Applications/AudioRecord.app
# CODESIGN_IDENTITY env var selects a signing identity; default is ad-hoc ("-").
set -euo pipefail
cd "$(dirname "$0")/.."

APP=AudioRecord
BUNDLE="dist/$APP.app"

swift build -c release --product "${APP}App"
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/${APP}App" "$BUNDLE/Contents/MacOS/$APP"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cp Resources/vocabulary.txt "$BUNDLE/Contents/Resources/vocabulary.txt"   # domain terms, see README
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# SwiftPM resource bundles of dependencies (FluidAudio ships TTS lexicons; unused by ASR but kept complete).
SIGN_ID="${CODESIGN_IDENTITY:--}"
for b in "$BIN_DIR"/*.bundle(N); do
  ditto "$b" "$BUNDLE/Contents/Resources/$(basename "$b")"
  codesign --force --sign "$SIGN_ID" "$BUNDLE/Contents/Resources/$(basename "$b")"
done

codesign --force --sign "$SIGN_ID" --identifier com.esteiner.audiorecord --timestamp=none "$BUNDLE"
codesign --verify --verbose=2 "$BUNDLE"
echo "built $BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/$APP.app"
  ditto "$BUNDLE" "/Applications/$APP.app"
  echo "installed /Applications/$APP.app"
fi
