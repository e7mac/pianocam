#!/usr/bin/env python3
"""
Convert Spotify Basic Pitch's model to CoreML for PianoCam.

We try the ONNX path first (most reliable: bypasses TensorFlow's optimizer-
slot loader, which often breaks across TF versions). If ONNX conversion
fails, we fall back to the TF SavedModel path.

Setup (Python 3.10 or 3.11; TF doesn't have macOS wheels for 3.12 yet):

  python3.11 -m venv .venv-bp
  source .venv-bp/bin/activate
  pip install --upgrade pip
  pip install 'basic-pitch[onnx]' coremltools

If ONNX conversion fails too, also install `tensorflow==2.13.0` and re-run.

Output:  Shared/Models/BasicPitch.mlpackage   (~17 MB)
"""

import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = REPO_ROOT / "Shared" / "Models"
OUTPUT_PATH = OUTPUT_DIR / "BasicPitch.mlpackage"

SAMPLE_RATE = 22_050
SAMPLE_COUNT = 43_844


def find_onnx_model() -> Path | None:
    """Look for the .onnx file inside the installed basic_pitch package."""
    try:
        import basic_pitch
    except ImportError:
        return None
    pkg_root = Path(basic_pitch.__file__).parent
    candidates = list(pkg_root.glob("saved_models/**/*.onnx"))
    return candidates[0] if candidates else None


def convert_via_onnx(onnx_path: Path) -> int:
    print(f"Found ONNX model: {onnx_path}")
    try:
        import coremltools as ct
    except ImportError:
        print("ERROR: pip install coremltools")
        return 1

    print("Converting ONNX → CoreML…")
    try:
        mlmodel = ct.convert(
            str(onnx_path),
            source="onnx",
            minimum_deployment_target=ct.target.macOS14,
            compute_units=ct.ComputeUnit.ALL,
        )
    except Exception as e:
        print(f"\nONNX→CoreML conversion FAILED: {type(e).__name__}: {e}")
        return 2

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(OUTPUT_PATH))
    print(f"\n✓ Saved {OUTPUT_PATH}")
    return 0


def convert_via_tf() -> int:
    try:
        import tensorflow as tf
        import coremltools as ct
        from basic_pitch import ICASSP_2022_MODEL_PATH
    except ImportError as e:
        print(f"ERROR: missing dependency: {e}")
        return 1

    print(f"Loading Basic Pitch SavedModel from:\n  {ICASSP_2022_MODEL_PATH}")
    saved = tf.saved_model.load(str(ICASSP_2022_MODEL_PATH))
    sigs = saved.signatures
    sig_name = "serving_default" if "serving_default" in sigs else list(sigs.keys())[0]
    sig = sigs[sig_name]
    input_key = list(sig.structured_input_signature[1].keys())[0]

    @tf.function(input_signature=[
        tf.TensorSpec(shape=[1, SAMPLE_COUNT], dtype=tf.float32, name="audio")
    ])
    def model_fn(audio):
        return sig(**{input_key: audio})

    concrete = model_fn.get_concrete_function()
    print("Converting TF → CoreML…")
    mlmodel = ct.convert(
        [concrete],
        source="tensorflow",
        inputs=[ct.TensorType(name="audio", shape=(1, SAMPLE_COUNT))],
        minimum_deployment_target=ct.target.macOS14,
        compute_units=ct.ComputeUnit.ALL,
    )
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(OUTPUT_PATH))
    print(f"\n✓ Saved {OUTPUT_PATH}")
    return 0


def main() -> int:
    onnx_path = find_onnx_model()
    if onnx_path is not None:
        rc = convert_via_onnx(onnx_path)
        if rc == 0:
            return 0
        print("\nFalling back to TF path…\n")
    else:
        print("No ONNX file found; using TF SavedModel path.")
        print("(For ONNX, run `pip install 'basic-pitch[onnx]'`.)")

    return convert_via_tf()


if __name__ == "__main__":
    sys.exit(main())
