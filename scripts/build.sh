#!/bin/bash
# Runs INSIDE the container. Copies the read-only mounted source into a
# writable workspace, builds, and drops the artifact into /output.
set -euo pipefail

: "${EXPO_TOKEN:?EXPO_TOKEN env var is required}"
: "${BUILD_PLATFORM:=android}"
: "${BUILD_PROFILE:=preview}"

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

# cp -a preserves the host's file ownership, which trips git's "dubious
# ownership" guard. Safe to trust here — this workspace is a disposable,
# single-use copy inside an ephemeral container.
git config --global --add safe.directory "$WORK_DIR"

if [ ! -d .git ]; then
  echo "==> No .git in source snapshot — initializing one so eas build can fingerprint it"
  git init -q
  git config user.email "build@admini-eas-local-builder.local"
  git config user.name "admini-eas-local-builder"
  git add -A
  git commit -q -m "build snapshot" --no-verify
fi

echo "==> Installing dependencies"
npm install

# android.buildType per profile in eas.json determines apk vs aab —
# "preview"/"development" build apk, "production" builds aab.
EXT="aab"
if [ "$BUILD_PLATFORM" = "android" ] && node -e "
    const c = require('./eas.json').build?.['$BUILD_PROFILE']?.android?.buildType;
    process.exit(c === 'apk' ? 0 : 1);
  " 2>/dev/null; then
  EXT="apk"
fi

echo "==> Running eas build --local (platform=$BUILD_PLATFORM, profile=$BUILD_PROFILE)"
eas build \
  --local \
  --platform "$BUILD_PLATFORM" \
  --profile "$BUILD_PROFILE" \
  --non-interactive \
  --output "$OUT_DIR/app-$(date -u +%Y%m%dT%H%M%SZ).${EXT}"

echo "==> Build artifact(s) in $OUT_DIR:"
ls -la "$OUT_DIR"
