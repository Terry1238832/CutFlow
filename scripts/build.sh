#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-$PROJECT_DIR/dist}"
BUILD_CACHE="${CUTFLOW_BUILD_CACHE:-$PROJECT_DIR/.build}"
mkdir -p "$BUILD_CACHE"
BUILD_CACHE="$(cd "$BUILD_CACHE" && pwd)"
export CLANG_MODULE_CACHE_PATH="$BUILD_CACHE/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_CACHE/swift-cache"
mkdir -p "$DESTINATION"
DESTINATION="$(cd "$DESTINATION" && pwd)"
cd "$PROJECT_DIR"
# SwiftPM's output layout differs between build engines. Keep architectures in
# separate scratch directories and ask SwiftPM for each actual binary path.
for ARCH in arm64 x86_64; do
    swift build --disable-sandbox --cache-path "$BUILD_CACHE/swiftpm" --scratch-path "$BUILD_CACHE/$ARCH" -c release --arch "$ARCH"
    BIN_DIR="$(swift build --disable-sandbox --cache-path "$BUILD_CACHE/swiftpm" --scratch-path "$BUILD_CACHE/$ARCH" -c release --arch "$ARCH" --show-bin-path)"
    cp "$BIN_DIR/CutFlow" "$BUILD_CACHE/CutFlow-$ARCH"
done
APP="$DESTINATION/CutFlow.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BUILD_CACHE/CutFlow-arm64" "$BUILD_CACHE/CutFlow-x86_64" -output "$APP/Contents/MacOS/CutFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift -module-cache-path "$BUILD_CACHE/icon-cache" scripts/icon.swift "$BUILD_CACHE/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
SIGN_IDENTITY="${CUTFLOW_SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DESTINATION/CutFlow-macOS.zip"
echo "Built: $APP"
