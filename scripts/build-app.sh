#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="${WALLPAPERI_BUILD_DIR:-.build}"
SWIFT_FLAGS=(-c release --scratch-path "$BUILD_DIR")
if [ "${WALLPAPERI_DISABLE_BUILD_SANDBOX:-0}" = "1" ]; then SWIFT_FLAGS+=(--disable-sandbox); fi
swift build "${SWIFT_FLAGS[@]}"
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"
APP="dist/Wallpaperi.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Wallpaperi" "$APP/Contents/MacOS/Wallpaperi.new"
# Replace the executable inode instead of overwriting a binary that may still be running.
mv -f "$APP/Contents/MacOS/Wallpaperi.new" "$APP/Contents/MacOS/Wallpaperi"
cp Info.plist "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$APP/Contents/Resources"
codesign --force --deep --sign "${WALLPAPERI_SIGN_IDENTITY:--}" "$APP"
echo "Built: $(pwd)/$APP"
