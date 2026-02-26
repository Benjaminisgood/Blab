#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Blab.xcodeproj}"
SCHEME="${SCHEME:-Blab}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
BUILD_LOG="${BUILD_LOG:-$ROOT_DIR/build/blab_build.log}"
APP_NAME="${APP_NAME:-Blab}"
DMG_FORMAT="${DMG_FORMAT:-UDZO}"
STAMP="${BUILD_STAMP:-$(date +%Y%m%d-%H%M%S)}"

if [[ -z "${BUILD_ARCHS:-}" ]]; then
  case "$(uname -m)" in
    arm64) BUILD_ARCHS="arm64" ;;
    x86_64) BUILD_ARCHS="x86_64" ;;
    *) BUILD_ARCHS="$(uname -m)" ;;
  esac
fi

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

ensure_dir() {
  [[ -n "$1" ]] || return 0
  mkdir -p "$1"
}

ensure_parent_dir() {
  ensure_dir "$(dirname "$1")"
}

parse_setting() {
  local key="$1"
  printf '%s\n' "$SETTINGS" | awk -F' = ' -v key="$key" '$0 ~ (" " key " = ") {print $2; exit}'
}

for cmd in xcodebuild hdiutil shasum lipo awk find; do
  require_cmd "$cmd"
done

[[ -e "$PROJECT_PATH" ]] || fail "Project path not found: $PROJECT_PATH"

ensure_dir "$DERIVED_DATA_PATH"
ensure_dir "$DIST_DIR"
ensure_dir "$ROOT_DIR/build"
ensure_parent_dir "$BUILD_LOG"

log "[1/4] Building app ($CONFIGURATION, ARCHS=$BUILD_ARCHS)..."
if ! xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "ARCHS=$BUILD_ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  build >"$BUILD_LOG" 2>&1; then
  log "Build failed. Last 40 lines from log:"
  tail -n 40 "$BUILD_LOG" >&2 || true
  fail "xcodebuild failed. Full log: $BUILD_LOG"
fi

SETTINGS="$(xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "ARCHS=$BUILD_ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  -showBuildSettings 2>/dev/null || true)"

TARGET_BUILD_DIR="$(parse_setting TARGET_BUILD_DIR)"
WRAPPER_NAME="$(parse_setting WRAPPER_NAME)"
EXECUTABLE_NAME="$(parse_setting EXECUTABLE_NAME)"
MARKETING_VERSION="$(parse_setting MARKETING_VERSION)"
CURRENT_PROJECT_VERSION="$(parse_setting CURRENT_PROJECT_VERSION)"

[[ -n "${WRAPPER_NAME:-}" ]] || WRAPPER_NAME="${APP_NAME}.app"

APP_PATH="$TARGET_BUILD_DIR/$WRAPPER_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  FALLBACK_APP_PATH="$(find "$DERIVED_DATA_PATH/Build/Products" -type d -name "$WRAPPER_NAME" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${FALLBACK_APP_PATH:-}" ]]; then
    APP_PATH="$FALLBACK_APP_PATH"
  fi
fi

if [[ ! -d "$APP_PATH" ]]; then
  fail "App bundle not found after build: $APP_PATH"
fi

ARCH_LABEL=""
if [[ -n "${EXECUTABLE_NAME:-}" && -f "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" ]]; then
  ARCH_LABEL="$(lipo -archs "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || true)"
fi

if [[ "$ARCH_LABEL" == *"arm64"* && "$ARCH_LABEL" == *"x86_64"* ]]; then
  ARCH_LABEL="universal"
elif [[ "$ARCH_LABEL" == *"arm64"* ]]; then
  ARCH_LABEL="arm64"
elif [[ "$ARCH_LABEL" == *"x86_64"* ]]; then
  ARCH_LABEL="x86_64"
elif [[ -n "$ARCH_LABEL" ]]; then
  ARCH_LABEL="${ARCH_LABEL// /-}"
else
  ARCH_LABEL="$(uname -m)"
fi

if [[ "$(uname -m)" == "arm64" && "$ARCH_LABEL" != "arm64" && "$ARCH_LABEL" != "universal" ]]; then
  fail "Built app architecture is '$ARCH_LABEL', which is not installable on Apple Silicon."
fi

VERSION="${MARKETING_VERSION:-${CURRENT_PROJECT_VERSION:-0.0.0}}"
VERSION_SAFE="${VERSION// /_}"
STAGING_ROOT="$(mktemp -d "$ROOT_DIR/build/dmg-staging.XXXXXX")"
STAGING_DIR="$STAGING_ROOT/$APP_NAME"
TIMESTAMP_DMG="$DIST_DIR/${APP_NAME}-v${VERSION_SAFE}-${STAMP}-${ARCH_LABEL}.dmg"
LATEST_DMG="$DIST_DIR/${APP_NAME}-latest-${STAMP}-${ARCH_LABEL}.dmg"
LATEST_ALIAS="$DIST_DIR/${APP_NAME}-latest-${ARCH_LABEL}.dmg"

cleanup() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

log "[2/4] Preparing staging directory..."
ensure_dir "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -sfn /Applications "$STAGING_DIR/Applications"

log "[3/4] Creating DMG..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format "$DMG_FORMAT" \
  "$TIMESTAMP_DMG" >/dev/null

cp -f "$TIMESTAMP_DMG" "$LATEST_DMG"
ln -sfn "$(basename "$LATEST_DMG")" "$LATEST_ALIAS"

log "[4/4] Writing checksums..."
shasum -a 256 "$TIMESTAMP_DMG" >"${TIMESTAMP_DMG}.sha256"
shasum -a 256 "$LATEST_DMG" >"${LATEST_DMG}.sha256"
shasum -a 256 "$LATEST_ALIAS" >"${LATEST_ALIAS}.sha256"

log "Build complete."
log "  App    : $APP_PATH"
log "  Latest : $LATEST_DMG"
log "  Alias  : $LATEST_ALIAS"
log "  Archive: $TIMESTAMP_DMG"
log "  Log    : $BUILD_LOG"
