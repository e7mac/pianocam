#!/usr/bin/env bash
#
# snapshot-testset.sh — snapshot every image in
# ~/Pictures/pianocam-sim/test-set/ (plus the upright photo) with the
# alignment debug overlay on, then vstack them into a single montage
# you can review at a glance.
#
# Output: /tmp/pianocam-sim/visuals/<stem>-band.png per image plus
#         /tmp/pianocam-sim/visuals/testset.jpg (montage).
#
# Uses `find -delete` with absolute paths instead of `rm -f $VAR/*` so
# zsh doesn't trip permission prompts on the glob.

setopt nullglob

APP=/Users/mayank/Library/Developer/Xcode/DerivedData/PianoCam-auzxelljyvypnkdjrlwfsaumjqft/Build/Products/Debug/PianoCam.app/Contents/MacOS/PianoCam
DIR=$HOME/Pictures/pianocam-sim/test-set
UPRIGHT=$HOME/Pictures/pianocam-sim/upright_overhead.png
OUT=/tmp/pianocam-sim/visuals
VIS_DIR=$HOME/Library/Containers/com.mayank.pianocam/Data/Documents/pianocam-sim-vis
SNAP=$HOME/Library/Containers/com.mayank.pianocam/Data/Documents/pianocam-snapshot.png

[ -x "$APP" ] || { echo "Build PianoCam first (Debug)" >&2; exit 1; }
[ -d "$OUT" ] || mkdir -p "$OUT"
[ -d "$VIS_DIR" ] || mkdir -p "$VIS_DIR"

# Safe cleanup — absolute paths, fixed depth, only files we wrote.
find "$OUT" -maxdepth 1 -type f \( -name '*-band.png' -o -name '*-full.png' \) -delete

snap_one() {
  local img=$1 stem=$2 ext=$3
  find "$VIS_DIR" -maxdepth 1 -type f -delete
  cp "$img" "$VIS_DIR/single.$ext"
  /bin/rm -f "$SNAP"
  pkill -x PianoCam 2>/dev/null
  sleep 1
  PIANOCAM_OVERHEAD_SIM_IMAGE="~/Documents/pianocam-sim-vis/single.$ext" \
  PIANOCAM_DEBUG_OVERLAY=1 \
  PIANOCAM_SNAPSHOT_DIR='~/Documents' \
    "$APP" > /dev/null 2>&1 &
  sleep 4
  /usr/bin/osascript -e 'tell application "System Events" to click (checkbox "Overhead piano" of group 1 of window 1 of process "PianoCam")' >/dev/null 2>&1
  sleep 7
  pkill -x PianoCam 2>/dev/null
  if [ -f "$SNAP" ]; then
    cp "$SNAP" "$OUT/${stem}-full.png"
    ffmpeg -y -i "$OUT/${stem}-full.png" -vf "crop=1280:216:0:504,scale=2560:432" "$OUT/${stem}-band.png" 2>/dev/null
    echo "ok $stem"
  else
    echo "MISS $stem"
  fi
}

# Order matters for the vstack
ORDER=(
  00-synthetic-rotated
  01-chopin-t0
  02-chopin-t15
  03-chopin-t30
  04-chopin-t45
  05-chopin-t60
  06-chopin-t75
  07-chopin-t100
  08-chopin-t120
  09-chopin-t150
  10-chopin-t160
  11-wikimedia-pianotoetsen-closeup
  12-wikimedia-piano-keys-oblique
  13-upright-overhead
)

for IMG in "$DIR"/*; do
  BASE=$(basename "$IMG")
  STEM="${BASE%.*}"
  EXT="${BASE##*.}"
  snap_one "$IMG" "$STEM" "$EXT"
done
if [ -f "$UPRIGHT" ]; then
  snap_one "$UPRIGHT" "13-upright-overhead" "png"
fi

cd "$OUT"
INPUTS=()
for f in "${ORDER[@]}"; do
  if [ -f "${f}-band.png" ]; then
    INPUTS+=("-i" "${f}-band.png")
  fi
done
if [ ${#INPUTS[@]} -gt 0 ]; then
  N=$(( ${#INPUTS[@]} / 2 ))
  ffmpeg -y "${INPUTS[@]}" -filter_complex "vstack=inputs=${N}" -q:v 2 testset.jpg 2>&1 | tail -1
  ls -la testset.jpg
fi
