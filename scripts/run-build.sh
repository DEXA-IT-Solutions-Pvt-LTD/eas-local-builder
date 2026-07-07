#!/bin/bash
# Host-side trigger. Usage:
#   EXPO_TOKEN=xxx ./scripts/run-build.sh /path/to/mobile-app [android|ios] [profile]
#
# profile matches an eas.json build profile (e.g. preview -> apk,
# production -> aab). Defaults to "preview" for a directly-installable apk.
#
# - flock serializes builds so two runs never share the gradle/npm cache volume at once
# - timeout kills a hung build instead of letting it sit forever
# - source project is mounted read-only; build.sh copies it in, so your
#   working tree's node_modules/.gradle are never touched
set -euo pipefail

PROJECT_DIR="${1:?Usage: run-build.sh <path-to-mobile-app-project> [android|ios] [profile]}"
PLATFORM="${2:-android}"
PROFILE="${3:-preview}"
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

echo "==> Starting build (platform=$PLATFORM, profile=$PROFILE, timeout=${BUILD_TIMEOUT}s)"
echo "==> Live log: $LOG_FILE"
echo "==> Tail from another shell with: tail -f $LOG_FILE"
echo "==> Or stream the container directly with: docker logs -f $CONTAINER_NAME"

set +e
# eas-cli's internal build plugin sometimes prints its full subprocess
# command line on failure, which embeds a base64 job payload containing
# signing credentials (keystore + passwords) pulled from Expo. Strip any
# long base64-looking run before it ever reaches disk or the terminal.
timeout "$BUILD_TIMEOUT" docker run --rm \
  --name "$CONTAINER_NAME" \
  --memory=8g \
  --cpus=4 \
  --pids-limit=512 \
  -e EXPO_TOKEN="$EXPO_TOKEN" \
  -e BUILD_PLATFORM="$PLATFORM" \
  -e BUILD_PROFILE="$PROFILE" \
  -v "$PROJECT_DIR:/source:ro" \
  -v "$OUTPUT_DIR:/output" \
  -v admini-eas-gradle-cache:/root/.gradle \
  -v admini-eas-npm-cache:/root/.npm \
  "$IMAGE_NAME" 2>&1 \
  | sed -E 's/[A-Za-z0-9+\/=]{200,}/[REDACTED-POSSIBLE-SECRET]/g' \
  | tee "$LOG_FILE"
BUILD_STATUS="${PIPESTATUS[0]}"
set -e

if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "==> Build FAILED (exit $BUILD_STATUS). Full log: $LOG_FILE" >&2
  exit "$BUILD_STATUS"
fi

# Newest file in OUTPUT_DIR is this run's artifact — flock guarantees only
# one build (thus one writer) at a time, so this is unambiguous.
ARTIFACT="$(find "$OUTPUT_DIR" -maxdepth 1 -type f ! -name '.gitkeep' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
echo "==> Done. Log saved to $LOG_FILE"
echo "ARTIFACT: $ARTIFACT"
