#!/bin/bash
# Builds MacSweep.app into ./build.
#   ./build.sh              native architecture (needs Xcode or the Command Line Tools)
#   ./build.sh --universal  Apple silicon + Intel (needs Xcode)
set -euo pipefail
cd "$(dirname "$0")"

ARCH_FLAGS=()
RELEASE=false
for arg in "$@"; do
  case "$arg" in
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
    --release) RELEASE=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done
if "$RELEASE"; then
  case "${CODESIGN_IDENTITY:-}" in
    'Developer ID Application:'*) ;;
    *) echo 'Release builds require a Developer ID Application certificate.' >&2; exit 1 ;;
  esac
fi

echo "==> Compiling"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/MacSweep.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacSweep" "$APP/Contents/MacOS/MacSweep"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> Drawing the icon"
ICON_PNG="build/icon-1024.png"
ICONSET="build/MacSweep.iconset"
if "$APP/Contents/MacOS/MacSweep" --render-icon "$ICON_PNG"; then
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "   (icon skipped)"
fi

if "$RELEASE"; then
  echo "==> Signing for distribution with Hardened Runtime"
  codesign --force --options runtime --timestamp --entitlements Resources/Release.entitlements --sign "$CODESIGN_IDENTITY" "$APP"
else
  echo "==> Signing development build (ad hoc)"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo
echo "Built $(pwd)/$APP"
echo "Open it with:  open \"$(pwd)/$APP\""
