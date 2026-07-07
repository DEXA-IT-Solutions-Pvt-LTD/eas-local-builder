#!/bin/bash
# Host-side trigger. Usage:
#   EXPO_TOKEN=xxx ./scripts/run-build.sh /path/to/mobile-app [android|ios]
#
# - flock serializes builds so two runs never share the gradle/npm cache volume at once
# - timeout kills a hung build instead of letting it sit forever
# - source project is mounted read-only; build.sh copies it in, so your
#   working tree's node_modules/.gradle are never touched
set -euo pipefail

PROJECT_DIR="${1:?Usage: run-build.sh <path-to-mobile-app-project> [android|ios]}"
PLATFORM="${2:-android}"
IMAGE_NAME="admini-eas-builder:latest"
LOCK_FILE="/tmp/admini-eas-build.lock"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-3600}" # seconds, 1h default

: "${EXPO_TOKEN:?EXPO_TOKEN env var is required (use an Expo robot/access token)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

if [ "$PLATFORM" = "ios" ]; then
  echo "error: iOS builds require macOS/Xcode — not possible in this Linux container." >&2
  exit 1
fi

echo "==> Acquiring build lock ($LOCK_FILE)"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "error: another build is already running" >&2; exit 1; }

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/build-${STAMP}-${PLATFORM}.log"
CONTAINER_NAME="admini-eas-build-${STAMP}"

echo "==> Starting build (platform=$PLATFORM, timeout=${BUILD_TIMEOUT}s)"
echo "==> Live log: $LOG_FILE"
echo "==> Tail from another shell with: tail -f $LOG_FILE"
echo "==> Or stream the container directly with: docker logs -f $CONTAINER_NAME"

set +e
timeout "$BUILD_TIMEOUT" docker run --rm \
  --name "$CONTAINER_NAME" \
  --memory=4g \
  --cpus=4 \
  --pids-limit=512 \
  -e EXPO_TOKEN="$EXPO_TOKEN" \
  -e BUILD_PLATFORM="$PLATFORM" \
  -v "$PROJECT_DIR:/source:ro" \
  -v "$OUTPUT_DIR:/output" \
  -v admini-eas-gradle-cache:/root/.gradle \
  -v admini-eas-npm-cache:/root/.npm \
  "$IMAGE_NAME" 2>&1 | tee "$LOG_FILE"
BUILD_STATUS="${PIPESTATUS[0]}"
set -e

if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "==> Build FAILED (exit $BUILD_STATUS). Full log: $LOG_FILE" >&2
  exit "$BUILD_STATUS"
fi

echo "==> Done. Artifacts in $OUTPUT_DIR, log saved to $LOG_FILE"
