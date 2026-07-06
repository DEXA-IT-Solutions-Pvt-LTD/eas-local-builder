#!/bin/bash
# Runs INSIDE the container. Copies the read-only mounted source into a
# writable workspace, builds, and drops the artifact into /output.
set -euo pipefail

: "${EXPO_TOKEN:?EXPO_TOKEN env var is required}"
: "${BUILD_PLATFORM:=android}"

SRC_DIR=/source
WORK_DIR=/workspace
OUT_DIR=/output

if [ ! -d "$SRC_DIR" ]; then
  echo "error: expected project source mounted at $SRC_DIR" >&2
  exit 1
fi

echo "==> Copying project source into writable workspace"
cp -a "$SRC_DIR/." "$WORK_DIR/"
cd "$WORK_DIR"

echo "==> Installing dependencies"
npm install

echo "==> Running eas build --local (platform=$BUILD_PLATFORM)"
eas build \
  --local \
  --platform "$BUILD_PLATFORM" \
  --non-interactive \
  --output "$OUT_DIR/app-$(date -u +%Y%m%dT%H%M%SZ).apk"

echo "==> Build artifact(s) in $OUT_DIR:"
ls -la "$OUT_DIR"
