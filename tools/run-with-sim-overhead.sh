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
# Builds if needed, then launches the Debug app with the env var set.
# Toggle "Overhead piano" in the control panel — the camera picker is
# replaced by "Simulated — <name>" and the alignment detector runs over
# the supplied image.

set -euo pipefail

cd "$(dirname "$0")/.."

DEFAULT_IMAGE="$HOME/Pictures/pianocam-sim/overhead_piano.jpg"
SIM_TARGET="${1:-$DEFAULT_IMAGE}"

if [[ ! -e "$SIM_TARGET" ]]; then
  echo "error: $SIM_TARGET does not exist" >&2
  exit 1
fi

DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
APP_PATH="$(find "$DERIVED" -name PianoCam.app -path '*/Debug/*' -maxdepth 6 2>/dev/null | head -1)"

if [[ -z "$APP_PATH" ]] || [[ ! -d "$APP_PATH" ]]; then
  echo "Building PianoCam (Debug)…"
  xcodebuild -project PianoCam.xcodeproj -scheme PianoCam -configuration Debug build -quiet
  APP_PATH="$(find "$DERIVED" -name PianoCam.app -path '*/Debug/*' -maxdepth 6 2>/dev/null | head -1)"
fi

echo "Launching $APP_PATH"
echo "PIANOCAM_OVERHEAD_SIM_IMAGE=$SIM_TARGET"

pkill -x PianoCam 2>/dev/null || true
sleep 0.3
open --env "PIANOCAM_OVERHEAD_SIM_IMAGE=$SIM_TARGET" "$APP_PATH"
