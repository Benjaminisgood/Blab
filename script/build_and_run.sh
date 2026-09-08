#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="run"
PREVIEW=0

usage() {
  printf '%s\n' "Usage: $0 [--preview] [--verify|--build-only|--debug|--logs|--telemetry]"
  printf '%s\n' '  --preview     Launch a separate preview app with disposable sample data.'
  printf '%s\n' '  --verify      Launch and verify this exact built executable is running.'
  printf '%s\n' '  --build-only  Build without stopping or launching an app.'
}

for argument in "$@"; do
  case "$argument" in
    --preview) PREVIEW=1 ;;
    --verify|--build-only|--debug|--logs|--telemetry) MODE="$argument" ;;
    --help|-h) usage; exit 0 ;;
    run) MODE="run" ;;
    *) usage >&2; exit 2 ;;
  esac
done

# A full Xcode installation is needed; keep the machine's xcode-select unchanged.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  SELECTED_DEVELOPER_DIR="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [[ -x "$SELECTED_DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
  elif [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    printf '%s\n' 'Full Xcode was not found. Set DEVELOPER_DIR to Xcode.app/Contents/Developer.' >&2
    exit 1
  fi
fi

BUILD_ROOT="$ROOT_DIR/build/DerivedData"
BUNDLE_ID="BenBenBuBen.Blab"
BUILD_LOG="$ROOT_DIR/build/development-build.log"
if [[ "$PREVIEW" == 1 ]]; then
  BUILD_ROOT="$ROOT_DIR/build/PreviewDerivedData"
  BUNDLE_ID="BenBenBuBen.Blab.Preview"
  BUILD_LOG="$ROOT_DIR/build/preview-build.log"
fi
APP_BUNDLE="$BUILD_ROOT/Build/Products/Debug/Blab.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Blab"

project_app_pids() {
  local candidate executable
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    executable="$(/bin/ps -p "$candidate" -o comm= 2>/dev/null || true)"
    if [[ "$executable" == "$APP_BINARY" ]]; then
      printf '%s\n' "$candidate"
    fi
  done < <(/usr/bin/pgrep -x Blab || true)
}

stop_project_app() {
  local process_id attempt
  while IFS= read -r process_id; do
    [[ -n "$process_id" ]] || continue
    /bin/kill -TERM "$process_id" 2>/dev/null || continue
    for ((attempt=0; attempt<30; attempt++)); do
      /bin/kill -0 "$process_id" 2>/dev/null || break
      sleep 0.1
    done
    if /bin/kill -0 "$process_id" 2>/dev/null; then
      printf 'Blab process %s has not exited. Close this development app and retry.\n' "$process_id" >&2
      exit 1
    fi
  done < <(project_app_pids)
}

if [[ "$MODE" != --build-only ]]; then
  stop_project_app
fi

mkdir -p "$ROOT_DIR/build"
printf 'Building Blab (preview=%s)…\n' "$PREVIEW"
# Ad hoc signing retains sandbox entitlements for local development and does
# not require the original author's signing identity or a developer account.
if ! /usr/bin/xcodebuild \
  -project "$ROOT_DIR/Blab.xcodeproj" \
  -scheme Blab \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$BUILD_ROOT" \
  "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build >"$BUILD_LOG" 2>&1; then
  tail -n 50 "$BUILD_LOG" >&2
  printf 'Build failed. Full log: %s\n' "$BUILD_LOG" >&2
  exit 1
fi
[[ -x "$APP_BINARY" ]] || { printf 'Built executable missing: %s\n' "$APP_BINARY" >&2; exit 1; }
printf 'Built: %s\n' "$APP_BUNDLE"
[[ "$MODE" != --build-only ]] || exit 0

launch_app() {
  /usr/bin/open -n "$APP_BUNDLE" --env "BLAB_PREVIEW=$PREVIEW"
}

case "$MODE" in
  --debug)
    BLAB_PREVIEW="$PREVIEW" /usr/bin/xcrun lldb -- "$APP_BINARY"
    ;;
  --logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "processImagePath == \"$APP_BINARY\""
    ;;
  --telemetry)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify)
    launch_app
    for ((attempt=0; attempt<30; attempt++)); do
      if [[ -n "$(project_app_pids)" ]]; then
        sleep 1
        if [[ -n "$(project_app_pids)" ]]; then
          printf 'Verified running executable: %s\n' "$APP_BINARY"
          exit 0
        fi
      fi
      sleep 0.1
    done
    printf 'Launch verification failed for: %s\n' "$APP_BINARY" >&2
    exit 1
    ;;
  run) launch_app ;;
esac
