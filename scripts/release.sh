#!/bin/bash
# Build, notarize and verify a Developer ID distribution. Credentials stay in Keychain.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-$PROJECT_DIR/dist-release}"
: "${CUTFLOW_SIGN_IDENTITY:?Set a Developer ID Application identity}"
: "${CUTFLOW_NOTARY_PROFILE:?Set an existing notarytool Keychain profile}"
if [[ "$CUTFLOW_SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "Formal distribution requires Developer ID Application, not a development or ad-hoc signature." >&2
    exit 1
fi
bash "$PROJECT_DIR/scripts/build.sh" "$DESTINATION"
DESTINATION="$(cd "$DESTINATION" && pwd)"
APP="$DESTINATION/CutFlow.app"
ZIP="$DESTINATION/CutFlow-macOS.zip"
xcrun notarytool submit "$ZIP" --keychain-profile "$CUTFLOW_NOTARY_PROFILE" --wait --output-format json > "$DESTINATION/notarization.json"
NOTARY_STATUS="$(plutil -extract status raw -o - "$DESTINATION/notarization.json")"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "Notarization was not accepted; inspect notarization.json. Do not publish this build." >&2
    exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$DESTINATION/SHA256SUMS.txt"
echo "Notarization and Gatekeeper checks passed: $ZIP"
