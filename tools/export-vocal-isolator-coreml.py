#!/usr/bin/env python3
"""
Convert UVR-MDX-NET-Inst_HQ_3 (vocal isolation) ONNX → CoreML for PianoCam.

The model takes a 4-channel "stereo complex" tensor [1, 4, 3072, 256]
(L_real, L_imag, R_real, R_imag of the STFT magnitude-bound region) and
outputs the same shape (the isolated instrumental). STFT/iSTFT live on
the Swift side.

Setup (Python 3.11 venv from BasicPitch is fine):
  source .venv-bp/bin/activate
  pip install audio-separator    # downloads model on first run
  python tools/export-vocal-isolator-coreml.py

Output:  Shared/Models/VocalIsolator.mlpackage
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = REPO_ROOT / "Shared" / "Models"
OUTPUT_PATH = OUTPUT_DIR / "VocalIsolator.mlpackage"

# Model expects [batch, 4, n_fft//2, n_time_frames]
SHAPE = (1, 4, 3072, 256)


def main() -> int:
    src = Path("/tmp/audio-separator-models/UVR-MDX-NET-Inst_HQ_3.onnx")
    if not src.exists():
        print(f"Missing {src}. Download via:")
        print("  python -c \"from audio_separator.separator import Separator; "
              "Separator().load_model(model_filename='UVR-MDX-NET-Inst_HQ_3.onnx')\"")
        return 1

    import onnx
    import torch
    import coremltools as ct
    from onnx2torch import convert as onnx2torch_convert

    print(f"Loading {src}")
    onnx_model = onnx.load(str(src))

    print("Converting ONNX → PyTorch")
    torch_model = onnx2torch_convert(onnx_model)
    torch_model.eval()

    print("Tracing")
    example = torch.randn(*SHAPE, dtype=torch.float32)
    try:
        traced = torch.jit.trace(torch_model, example, strict=False)
    except Exception as e:
        print(f"Tracing failed: {type(e).__name__}: {e}")
        return 2

    print("Converting → CoreML")
    try:
        ml = ct.convert(
            traced,
            source="pytorch",
            inputs=[ct.TensorType(name="spec", shape=SHAPE)],
            minimum_deployment_target=ct.target.macOS14,
            compute_units=ct.ComputeUnit.ALL,
        )
    except Exception as e:
        print(f"\nCoreML conversion FAILED: {type(e).__name__}: {e}")
        return 3

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    ml.save(str(OUTPUT_PATH))
    print(f"\n✓ Saved {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
