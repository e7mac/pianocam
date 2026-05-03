#!/usr/bin/env python3
"""
Convert jongwook/onsets-and-frames (PyTorch port of Magenta's piano
transcription model) to ONNX, for use in PianoCam via ONNX Runtime.

Setup (Python 3.10 or 3.11):
  python3.11 -m venv .venv-onf
  source .venv-onf/bin/activate
  pip install --upgrade pip
  pip install onsets-and-frames  # if available on PyPI; if not, see fallback below
  # Fallback (more reliable):
  #   git clone https://github.com/jongwook/onsets-and-frames /tmp/onsets-and-frames
  #   cd /tmp/onsets-and-frames && pip install -r requirements.txt
  #   pip install torch onnx 'numpy<2'
  pip install torch onnx 'numpy<2'

Pretrained weights:
  Download from https://github.com/jongwook/onsets-and-frames#pretrained-model
  Save the model-500000.pt (or similar) anywhere; pass its path with --weights.

Usage:
  python tools/export-onsets-and-frames-onnx.py --weights /path/to/model-500000.pt

Output:  Shared/Models/OnsetsAndFrames.onnx
"""

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = REPO_ROOT / "Shared" / "Models"
OUTPUT_PATH = OUTPUT_DIR / "OnsetsAndFrames.onnx"

# Onsets & Frames spec input: (B, T, 229) mel-spectrogram frames.
# Default trace length: 100 frames ≈ 3.2 sec at 31.25 Hz frame rate.
EXPORT_FRAMES = 100
N_MELS = 229


def main(weights_path: Path) -> int:
    try:
        import torch
        import onnx
    except ImportError as e:
        print(f"ERROR: missing dependency: {e}")
        print("Install with: pip install torch onnx 'numpy<2'")
        return 1

    # The PyTorch port uses a class commonly named OnsetsAndFrames.
    # We try a few common import paths.
    OnsetsAndFrames = None
    for candidate in [
        "onsets_and_frames",
        "onsets_and_frames.transcriber",
    ]:
        try:
            mod = __import__(candidate, fromlist=["OnsetsAndFrames"])
            OnsetsAndFrames = getattr(mod, "OnsetsAndFrames", None)
            if OnsetsAndFrames is not None:
                print(f"Loaded class from {candidate}")
                break
        except ImportError:
            continue
    if OnsetsAndFrames is None:
        print("Couldn't import OnsetsAndFrames. Either:")
        print("  pip install onsets-and-frames  (if available)")
        print("  or clone https://github.com/jongwook/onsets-and-frames and:")
        print("    PYTHONPATH=/path/to/repo python tools/export-onsets-and-frames-onnx.py …")
        return 2

    print(f"Loading weights: {weights_path}")
    state = torch.load(str(weights_path), map_location="cpu")

    # The PyTorch port's saved checkpoint is the entire model; re-import works.
    if isinstance(state, dict) and "state_dict" in state:
        # Build a fresh model and load weights.
        model = OnsetsAndFrames(N_MELS, 88, 48)
        model.load_state_dict(state["state_dict"])
    elif isinstance(state, torch.nn.Module):
        model = state
    else:
        # Original repo just torch.save's the whole nn.Module
        model = state
    model.eval()

    print("Tracing model…")
    example = torch.randn(1, EXPORT_FRAMES, N_MELS, dtype=torch.float32)
    try:
        traced = torch.jit.trace(model, example, strict=False)
    except Exception as e:
        print(f"\nTrace failed: {type(e).__name__}: {e}")
        return 3

    print(f"Exporting ONNX → {OUTPUT_PATH}")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    try:
        torch.onnx.export(
            traced,
            example,
            str(OUTPUT_PATH),
            input_names=["mel"],
            output_names=["onset", "offset", "frame", "velocity"],
            dynamic_axes={
                "mel": {1: "frames"},
                "onset": {1: "frames"},
                "offset": {1: "frames"},
                "frame": {1: "frames"},
                "velocity": {1: "frames"},
            },
            opset_version=17,
        )
    except Exception as e:
        print(f"\nONNX export FAILED: {type(e).__name__}: {e}")
        return 4

    # Verify it can be loaded.
    try:
        loaded = onnx.load(str(OUTPUT_PATH))
        onnx.checker.check_model(loaded)
        print("✓ ONNX model verified.")
    except Exception as e:
        print(f"WARNING: ONNX checker rejected the file: {e}")

    print(f"\nDone. Size: {OUTPUT_PATH.stat().st_size / 1_000_000:.1f} MB")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", type=Path, required=True,
                        help="Path to the pretrained .pt checkpoint")
    args = parser.parse_args()
    sys.exit(main(args.weights))
