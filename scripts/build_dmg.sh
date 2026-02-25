#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Blab.xcodeproj}"
SCHEME="${SCHEME:-Blab}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
BUILD_LOG="${BUILD_LOG:-$ROOT_DIR/build/blab_build.log}"
APP_NAME="${APP_NAME:-Blab}"
BUILD_ARCHS="${BUILD_ARCHS:-arm64 x86_64}"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$DIST_DIR" "$(dirname "$BUILD_LOG")"

echo "[1/4] Building app ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "ARCHS=$BUILD_ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  build >"$BUILD_LOG" 2>&1

SETTINGS="$(xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "ARCHS=$BUILD_ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  -showBuildSettings)"

TARGET_BUILD_DIR="$(echo "$SETTINGS" | awk -F' = ' '/ TARGET_BUILD_DIR = / {print $2; exit}')"
WRAPPER_NAME="$(echo "$SETTINGS" | awk -F' = ' '/ WRAPPER_NAME = / {print $2; exit}')"
EXECUTABLE_NAME="$(echo "$SETTINGS" | awk -F' = ' '/ EXECUTABLE_NAME = / {print $2; exit}')"
MARKETING_VERSION="$(echo "$SETTINGS" | awk -F' = ' '/ MARKETING_VERSION = / {print $2; exit}')"

if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${WRAPPER_NAME:-}" || -z "${EXECUTABLE_NAME:-}" ]]; then
  echo "Failed to parse build settings. Check $BUILD_LOG" >&2
  exit 1
fi

APP_PATH="$TARGET_BUILD_DIR/$WRAPPER_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

ARCH_LABEL="$(lipo -archs "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || true)"
if [[ "$ARCH_LABEL" == *"arm64"* && "$ARCH_LABEL" == *"x86_64"* ]]; then
  ARCH_LABEL="universal"
elif [[ -n "$ARCH_LABEL" ]]; then
  ARCH_LABEL="${ARCH_LABEL// /-}"
else
  ARCH_LABEL="$(uname -m)"
fi

VERSION="${MARKETING_VERSION:-0.0.0}"
STAGING_ROOT="$ROOT_DIR/build/dmg-staging"
STAGING_DIR="$STAGING_ROOT/$APP_NAME"
TIMESTAMP_DMG="$DIST_DIR/${APP_NAME}-v${VERSION}-${STAMP}-${ARCH_LABEL}.dmg"
LATEST_DMG="$DIST_DIR/${APP_NAME}-v${VERSION}-${ARCH_LABEL}.dmg"

echo "[2/4] Preparing staging directory..."
rm -rf "$STAGING_ROOT"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -sfn /Applications "$STAGING_DIR/Applications"

echo "[3/4] Creating DMG..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$TIMESTAMP_DMG" >/dev/null

cp -f "$TIMESTAMP_DMG" "$LATEST_DMG"

echo "[4/4] Writing checksums..."
shasum -a 256 "$TIMESTAMP_DMG" >"${TIMESTAMP_DMG}.sha256"
shasum -a 256 "$LATEST_DMG" >"${LATEST_DMG}.sha256"

echo "Build complete."
echo "  Latest : $LATEST_DMG"
echo "  Archive: $TIMESTAMP_DMG"
echo "  Log    : $BUILD_LOG"
