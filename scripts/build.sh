#!/usr/bin/env bash
# Build BetterMessages.app for local development.
# For release builds, see scripts/package.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Debug}"
SCHEME="${SCHEME:-BetterMessages}"

# Regenerate project file in case project.yml changed.
./scripts/generate.sh

xcodebuild \
    -project BetterMessages.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -derivedDataPath build \
    build \
    | xcbeautify 2>/dev/null || \
xcodebuild \
    -project BetterMessages.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -derivedDataPath build \
    build

APP_PATH="build/Build/Products/${CONFIG}/BetterMessages.app"
if [ -d "$APP_PATH" ]; then
    echo ""
    echo "✓ Built: $APP_PATH"
fi
