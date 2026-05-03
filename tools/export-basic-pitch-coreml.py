#!/usr/bin/env python3
"""
Convert Spotify Basic Pitch's model to CoreML for PianoCam.

Path: ONNX → PyTorch (via onnx2torch) → CoreML.
This avoids both TF SavedModel's `add_slot` loader bug and the fact that
modern coremltools no longer accepts `source="onnx"` directly.

Setup (Python 3.10 or 3.11 — TF wheels for 3.12+ are flaky on macOS):

  python3.11 -m venv .venv-bp
  source .venv-bp/bin/activate
  pip install --upgrade pip
  pip install 'basic-pitch[onnx]' onnx2torch torch coremltools 'numpy<2'

Then:
  python tools/export-basic-pitch-coreml.py

Output:  Shared/Models/BasicPitch.mlpackage
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = REPO_ROOT / "Shared" / "Models"
OUTPUT_PATH = OUTPUT_DIR / "BasicPitch.mlpackage"

SAMPLE_COUNT = 43_844


def find_onnx_model() -> Path | None:
    try:
        import basic_pitch
    except ImportError:
        return None
    pkg_root = Path(basic_pitch.__file__).parent
    candidates = list(pkg_root.glob("saved_models/**/*.onnx"))
    return candidates[0] if candidates else None


def main() -> int:
    onnx_path = find_onnx_model()
    if onnx_path is None:
        print("Couldn't locate basic_pitch's .onnx file.")
        print("Did you run `pip install 'basic-pitch[onnx]'`?")
        return 1
    print(f"Found ONNX: {onnx_path}")

    try:
        import onnx
        import torch
        import coremltools as ct
        from onnx2torch import convert as onnx2torch_convert
    except ImportError as e:
        print(f"ERROR: missing dependency: {e}")
        print("Install with: pip install onnx onnx2torch torch coremltools 'numpy<2'")
        return 1

    print("Loading ONNX…")
    onnx_model = onnx.load(str(onnx_path))

    # Print I/O so we know what we're dealing with.
    print(f"Inputs:  {[(i.name, [d.dim_value for d in i.type.tensor_type.shape.dim]) for i in onnx_model.graph.input]}")
    print(f"Outputs: {[(o.name, [d.dim_value for d in o.type.tensor_type.shape.dim]) for o in onnx_model.graph.output]}")

    print("Converting ONNX → PyTorch…")
    torch_model = onnx2torch_convert(onnx_model)
    torch_model.eval()

    # ONNX inputs may have ambiguous batch dims. Set up a concrete shape that
    # matches the model's audio expectations.
    print("Tracing PyTorch model…")
    example = torch.randn(1, SAMPLE_COUNT, dtype=torch.float32)
    try:
        traced = torch.jit.trace(torch_model, example, strict=False)
    except Exception as e:
        print(f"\nTorch tracing failed: {type(e).__name__}: {e}")
        print("If the input shape mismatch is the cause, the ONNX model probably")
        print("expects a different shape. Inspect the printed inputs above and")
        print("update SAMPLE_COUNT in this script accordingly.")
        return 2

    print("Converting PyTorch → CoreML…")
    try:
        mlmodel = ct.convert(
            traced,
            source="pytorch",
            inputs=[ct.TensorType(name="audio", shape=(1, SAMPLE_COUNT))],
            minimum_deployment_target=ct.target.macOS14,
            compute_units=ct.ComputeUnit.ALL,
        )
    except Exception as e:
        print(f"\nCoreML conversion FAILED: {type(e).__name__}: {e}")
        print("\nIf this is an unsupported-op error, paste it back and we'll")
        print("either patch coremltools or implement that op in Swift.")
        return 3

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(OUTPUT_PATH))
    print(f"\n✓ Saved {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
