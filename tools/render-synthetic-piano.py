#!/usr/bin/env python3
"""Render a clean top-down 88-key piano keyboard for alignment-detector testing.

Produces:
  ~/Pictures/pianocam-sim/synthetic_piano.jpg   — axis-aligned
  ~/Pictures/pianocam-sim/synthetic_piano_rot.jpg — rotated 8° (use this one)

The rotated version is what the test set uses as the best-case baseline.
The axis-aligned version is collinear in the black-key centers, which on
its own surfaces the homography rank-deficiency bug — keep it around for
that purpose.

Requires PIL (pillow). The pianocam venv at .venv-transkun/ already has it:
  .venv-transkun/bin/python tools/render-synthetic-piano.py
"""

import os
import subprocess
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("error: PIL/pillow not installed (.venv-transkun/bin/python has it)")

WHITE_KEYS = 52
WHITE_KEY_W = 30
WHITE_KEY_H = 250
BLACK_KEY_W = 18
BLACK_KEY_H = 150
PAD = 40

img_w = WHITE_KEYS * WHITE_KEY_W + 2 * PAD
img_h = WHITE_KEY_H + 2 * PAD

img = Image.new("RGB", (img_w, img_h), "white")
draw = ImageDraw.Draw(img)

# White keys
for i in range(WHITE_KEYS):
    x0 = PAD + i * WHITE_KEY_W
    x1 = x0 + WHITE_KEY_W - 1
    draw.rectangle(
        [x0, PAD, x1, PAD + WHITE_KEY_H],
        fill="white",
        outline=(180, 180, 180),
        width=1,
    )

# Black keys at pitch classes {C#, D#, F#, G#, A#}
BLACK_PCS = {1, 3, 6, 8, 10}
white_idx = 0
for midi in range(21, 109):
    if midi % 12 in BLACK_PCS:
        center_x = PAD + white_idx * WHITE_KEY_W
        draw.rectangle(
            [center_x - BLACK_KEY_W // 2, PAD,
             center_x + BLACK_KEY_W // 2, PAD + BLACK_KEY_H],
            fill="black",
        )
    else:
        white_idx += 1

out_dir = os.path.expanduser("~/Pictures/pianocam-sim")
os.makedirs(out_dir, exist_ok=True)
flat = os.path.join(out_dir, "synthetic_piano.jpg")
rot = os.path.join(out_dir, "synthetic_piano_rot.jpg")

img.save(flat, quality=95)

# Rotate via ffmpeg (matches the rest of the toolchain; avoids pulling in
# scipy/cv2 just for one transform).
subprocess.run(
    [
        "ffmpeg", "-y", "-i", flat,
        "-vf", "rotate=8*PI/180:fillcolor=white:ow=rotw(8*PI/180):oh=roth(8*PI/180)",
        rot,
    ],
    check=True,
    capture_output=True,
)

print(f"Wrote {flat}")
print(f"Wrote {rot}")
