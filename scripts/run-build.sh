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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Auto-load .env next to this repo if EXPO_TOKEN wasn't already exported.
# An explicitly exported EXPO_TOKEN always takes priority.
if [ -z "${EXPO_TOKEN:-}" ] && [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

: "${EXPO_TOKEN:?EXPO_TOKEN env var is required (export it, or create .env in the repo root)}"

OUTPUT_DIR="$SCRIPT_DIR/output"
LOG_DIR="$SCRIPT_DIR/logs"
RETENTION_DAYS="${RETENTION_DAYS:-3}"
mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

# Server-side artifacts/logs are never deleted automatically otherwise --
# they'd accumulate forever since every build writes new files here.
# Prune anything older than RETENTION_DAYS before each run.
for dir in "$OUTPUT_DIR" "$LOG_DIR"; do
  OLD_FILES="$(find "$dir" -maxdepth 1 -type f ! -name '.gitkeep' -mtime "+${RETENTION_DAYS}")"
  if [ -n "$OLD_FILES" ]; then
    echo "==> Cleaning up files older than ${RETENTION_DAYS}d in $dir:"
    echo "$OLD_FILES" | sed 's/^/     /'
    echo "$OLD_FILES" | xargs rm -f
  fi
done

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
HISTORY_FILE="$LOG_DIR/build-history.csv"
[ -f "$HISTORY_FILE" ] || echo "timestamp_utc,platform,profile,status,duration_seconds,duration_human" > "$HISTORY_FILE"
START_EPOCH="$(date +%s)"

format_duration() {
  local total="$1"
  printf '%dm %02ds' "$((total / 60))" "$((total % 60))"
}

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

END_EPOCH="$(date +%s)"
DURATION_SEC="$((END_EPOCH - START_EPOCH))"
DURATION_HUMAN="$(format_duration "$DURATION_SEC")"

if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$PLATFORM,$PROFILE,failed,$DURATION_SEC,$DURATION_HUMAN" >> "$HISTORY_FILE"
  echo "==> Build FAILED (exit $BUILD_STATUS) after $DURATION_HUMAN. Full log: $LOG_FILE" >&2
  exit "$BUILD_STATUS"
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$PLATFORM,$PROFILE,success,$DURATION_SEC,$DURATION_HUMAN" >> "$HISTORY_FILE"

# Newest file in OUTPUT_DIR is this run's artifact — flock guarantees only
# one build (thus one writer) at a time, so this is unambiguous.
ARTIFACT="$(find "$OUTPUT_DIR" -maxdepth 1 -type f ! -name '.gitkeep' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
echo "==> Done in $DURATION_HUMAN. Log saved to $LOG_FILE"
echo "ARTIFACT: $ARTIFACT"
