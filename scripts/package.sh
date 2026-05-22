#!/usr/bin/env bash
# Package BetterMessages.app into a signed, notarized DMG.
#
# Required env (set in your shell, NEVER commit):
#   DEVELOPER_ID         e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE       keychain profile name from `xcrun notarytool store-credentials`
#
# Usage:
#   DEVELOPER_ID="..." NOTARY_PROFILE="..." ./scripts/package.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_ID:-}" ]; then
    echo "error: DEVELOPER_ID not set" >&2
    exit 1
fi
if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "error: NOTARY_PROFILE not set" >&2
    exit 1
fi

# Build Release.
./scripts/generate.sh

xcodebuild \
    -project BetterMessages.xcodeproj \
    -scheme BetterMessages \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    build

APP_PATH="build/Build/Products/Release/BetterMessages.app"
DMG_PATH="build/BetterMessages.dmg"

# Sanity check the signature.
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Build the DMG.
rm -f "$DMG_PATH"
create-dmg \
    --volname "Better Messages" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "BetterMessages.app" 175 190 \
    --app-drop-link 425 190 \
    --hdiutil-quiet \
    "$DMG_PATH" \
    "$APP_PATH"

# Sign the DMG itself.
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG_PATH"

# Notarize and staple.
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$DMG_PATH"

echo ""
echo "✓ Signed + notarized: $DMG_PATH"
