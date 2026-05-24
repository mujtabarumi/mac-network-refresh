#!/bin/bash
# Build "Refresh Network.app" from RefreshNetwork.swift.
# Universal binary (arm64 + x86_64) when both SDKs are available.

set -euo pipefail
cd "$(dirname "$0")"

APP="Refresh Network.app"
EXE="RefreshNetwork"
SRC="RefreshNetwork.swift"
PLIST="Info.plist"
MIN_MACOS="14.0"

[ -f "$SRC" ]   || { echo "error: $SRC missing" >&2; exit 1; }
[ -f "$PLIST" ] || { echo "error: $PLIST missing" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "==> Building arm64"
swiftc -O -parse-as-library \
  -target "arm64-apple-macos$MIN_MACOS" \
  -framework SwiftUI -framework AppKit -framework Foundation \
  -o "$BUILD_DIR/$EXE.arm64" "$SRC"

echo "==> Building x86_64 (best-effort)"
if swiftc -O -parse-as-library \
  -target "x86_64-apple-macos$MIN_MACOS" \
  -framework SwiftUI -framework AppKit -framework Foundation \
  -o "$BUILD_DIR/$EXE.x86_64" "$SRC" 2>/dev/null; then
  echo "==> Creating universal binary"
  lipo -create "$BUILD_DIR/$EXE.arm64" "$BUILD_DIR/$EXE.x86_64" \
    -output "$APP/Contents/MacOS/$EXE"
else
  echo "==> x86_64 unavailable; shipping arm64-only"
  cp "$BUILD_DIR/$EXE.arm64" "$APP/Contents/MacOS/$EXE"
fi

chmod +x "$APP/Contents/MacOS/$EXE"
cp "$PLIST" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo
echo "Built: $APP"
file "$APP/Contents/MacOS/$EXE"
