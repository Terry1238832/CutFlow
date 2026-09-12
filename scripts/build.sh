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
swift build --disable-sandbox --cache-path "$BUILD_CACHE/swiftpm" --scratch-path "$BUILD_CACHE" -c release --arch arm64
swift build --disable-sandbox --cache-path "$BUILD_CACHE/swiftpm" --scratch-path "$BUILD_CACHE" -c release --arch x86_64
APP="$DESTINATION/CutFlow.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BUILD_CACHE/arm64-apple-macosx/release/CutFlow" "$BUILD_CACHE/x86_64-apple-macosx/release/CutFlow" -output "$APP/Contents/MacOS/CutFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift -module-cache-path "$BUILD_CACHE/icon-cache" scripts/icon.swift "$BUILD_CACHE/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign "${CUTFLOW_SIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DESTINATION/CutFlow-macOS.zip"
echo "Built: $APP"
