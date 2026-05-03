#!/usr/bin/env python3
"""
Convert Spotify Basic Pitch's TensorFlow model to CoreML for PianoCam.

Run this *once* on a Mac with Python 3.10–3.11, then commit the resulting
.mlpackage. (Python 3.12 has issues with TensorFlow 2.x at the time of writing.)

Usage:
  python3.11 -m venv .venv-bp
  source .venv-bp/bin/activate
  pip install --upgrade pip
  pip install basic-pitch coremltools tensorflow
  python tools/export-basic-pitch-coreml.py

Output:
  Shared/Models/BasicPitch.mlpackage   (~17 MB)
"""

import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = REPO_ROOT / "Shared" / "Models"
OUTPUT_PATH = OUTPUT_DIR / "BasicPitch.mlpackage"

# Basic Pitch's "Note Model with Pitch" expects 2 seconds of mono audio at 22050 Hz.
SAMPLE_RATE = 22_050
SAMPLE_COUNT = 43_844


def main() -> int:
    try:
        import tensorflow as tf
        import coremltools as ct
        from basic_pitch import ICASSP_2022_MODEL_PATH
    except ImportError as e:
        print("ERROR: missing dependency:", e)
        print("Install with:  pip install basic-pitch coremltools tensorflow")
        return 1

    print(f"Loading Basic Pitch SavedModel from:\n  {ICASSP_2022_MODEL_PATH}")
    saved = tf.saved_model.load(str(ICASSP_2022_MODEL_PATH))

    # Pick the most generic signature.
    sigs = saved.signatures
    print(f"Available signatures: {list(sigs.keys())}")
    sig_name = "serving_default" if "serving_default" in sigs else list(sigs.keys())[0]
    sig = sigs[sig_name]
    print(f"Using signature: {sig_name}")
    print(f"Inputs:  { {k: v.shape for k, v in sig.structured_input_signature[1].items()} }")
    print(f"Outputs: { {k: v.shape for k, v in sig.structured_outputs.items()} }")

    # Trace into a concrete function that takes (1, SAMPLE_COUNT) float audio.
    input_key = list(sig.structured_input_signature[1].keys())[0]

    @tf.function(input_signature=[
        tf.TensorSpec(shape=[1, SAMPLE_COUNT], dtype=tf.float32, name="audio")
    ])
    def model_fn(audio):
        return sig(**{input_key: audio})

    concrete = model_fn.get_concrete_function()

    print("\nConverting TensorFlow → CoreML… (this may take a minute)")
    try:
        mlmodel = ct.convert(
            [concrete],
            source="tensorflow",
            inputs=[ct.TensorType(name="audio", shape=(1, SAMPLE_COUNT))],
            minimum_deployment_target=ct.target.macOS14,
            compute_units=ct.ComputeUnit.ALL,
        )
    except Exception as e:
        print("\nCoreML conversion FAILED:")
        print(f"  {type(e).__name__}: {e}")
        print("\nLikely cause: a TF op used by Basic Pitch's CQT preprocessing")
        print("isn't supported by coremltools. Workarounds, in increasing effort:")
        print("  1. Try a newer coremltools (`pip install -U coremltools`).")
        print("  2. Convert via TFLite first (`python -m basic_pitch.tflite ...`),")
        print("     then TFLite→ONNX→CoreML.")
        print("  3. Implement CQT in Swift; convert only the Conv2D portion.")
        return 2

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(OUTPUT_PATH))
    print(f"\n✓ Saved to {OUTPUT_PATH}")
    print("\nNext: commit this .mlpackage; PianoCam's Swift code will load it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
