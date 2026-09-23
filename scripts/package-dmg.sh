#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$PROJECT_DIR/dist/CutFlow.app}"
OUTPUT="${2:-$PROJECT_DIR/dist/CutFlow-macOS.dmg}"

if [[ ! -d "$APP" ]]; then
    echo "Missing app: $APP" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGING="$(mktemp -d "${TMPDIR:-/tmp/}cutflow-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/CutFlow.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$(dirname "$OUTPUT")"
hdiutil create -quiet -volname "CutFlow $VERSION" -srcfolder "$STAGING" -format UDZO -fs HFS+ -ov "$OUTPUT"
hdiutil verify "$OUTPUT"
echo "Packaged: $OUTPUT"
