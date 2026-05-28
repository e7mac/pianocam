#!/usr/bin/env bash
#
# run-with-sim-overhead.sh — launch a Debug build of PianoCam with the
# overhead-camera simulator enabled (PIANOCAM_OVERHEAD_SIM_IMAGE).
#
# Usage:
#   tools/run-with-sim-overhead.sh                                 # uses default test image
#   tools/run-with-sim-overhead.sh /path/to/image.jpg              # single image
#   tools/run-with-sim-overhead.sh /path/to/dir-of-images/         # directory (cycles every 3s)
#
# PianoCam is sandboxed — absolute paths outside the app's container can't
# be read even though `fileExists` may return true via the symlinked
# ~/Pictures. This script mirrors the supplied file or directory into the
# container's real (non-symlinked) Documents folder and passes a
# tilde-relative path so the app resolves it against NSHomeDirectory()
# (which inside the sandbox IS the container).

set -euo pipefail

cd "$(dirname "$0")/.."

DEFAULT_SOURCE="$HOME/Pictures/pianocam-sim/overhead_piano.jpg"
SRC="${1:-$DEFAULT_SOURCE}"

if [[ ! -e "$SRC" ]]; then
  echo "error: $SRC does not exist" >&2
  exit 1
fi

CONTAINER="$HOME/Library/Containers/com.mayank.pianocam/Data/Documents/pianocam-sim"
mkdir -p "$CONTAINER"

if [[ -d "$SRC" ]]; then
  # directory mode — mirror contents
  rsync -a --delete --include='*.jpg' --include='*.jpeg' --include='*.png' --exclude='*' \
        "$SRC/" "$CONTAINER/"
  REL_PATH="~/Documents/pianocam-sim"
else
  BASENAME="$(basename "$SRC")"
  cp -f "$SRC" "$CONTAINER/$BASENAME"
  REL_PATH="~/Documents/pianocam-sim/$BASENAME"
fi

DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
APP_PATH="$(find "$DERIVED" -name PianoCam.app -path '*/Debug/*' -not -path '*/Index.noindex/*' -maxdepth 6 2>/dev/null | head -1)"

if [[ -z "$APP_PATH" ]] || [[ ! -d "$APP_PATH" ]]; then
  echo "Building PianoCam (Debug)…"
  xcodebuild -project PianoCam.xcodeproj -scheme PianoCam -configuration Debug build -quiet
  APP_PATH="$(find "$DERIVED" -name PianoCam.app -path '*/Debug/*' -not -path '*/Index.noindex/*' -maxdepth 6 2>/dev/null | head -1)"
fi

echo "Source:    $SRC"
echo "Container: $CONTAINER"
echo "App:       $APP_PATH"
echo "Env var:   PIANOCAM_OVERHEAD_SIM_IMAGE=$REL_PATH"

pkill -x PianoCam 2>/dev/null || true
sleep 0.3
PIANOCAM_OVERHEAD_SIM_IMAGE="$REL_PATH" "$APP_PATH/Contents/MacOS/PianoCam" &
disown
