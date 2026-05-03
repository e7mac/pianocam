#!/usr/bin/env python3
"""
Convert Yujia-Yan/Transkun (transformer piano transcription) to ONNX
for PianoCam.

Setup (Python 3.10 or 3.11):
  python3.11 -m venv .venv-transkun
  source .venv-transkun/bin/activate
  pip install --upgrade pip
  pip install transkun torch onnx 'numpy<2'

If `transkun` isn't on PyPI yet:
  git clone https://github.com/Yujia-Yan/Transkun /tmp/transkun
  cd /tmp/transkun && pip install -e .
  cd -

Pretrained weights: Transkun ships them inside the package (`transkun/2.0`)
or downloads on first use. Confirm with:
  python -c "import transkun; print(transkun.__file__)"

Usage:
  python tools/export-transkun-onnx.py
  # or with explicit weights:
  python tools/export-transkun-onnx.py --weights /path/to/weights.pt --config /path/to/conf.json

Output:  Shared/Models/Transkun.onnx
"""

import argparse
import importlib
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = REPO_ROOT / "Shared" / "Models"
OUTPUT_PATH = OUTPUT_DIR / "Transkun.onnx"


def find_module():
    """Locate transkun's model class. The package's API has shifted between
    versions; we try a few likely paths."""
    candidates = [
        ("transkun.model", "TransKun"),
        ("transkun.Model", "TransKun"),
        ("transkun.transcriber", "TransKun"),
        ("transkun", "TransKun"),
    ]
    for module_name, class_name in candidates:
        try:
            mod = importlib.import_module(module_name)
            cls = getattr(mod, class_name, None)
            if cls is not None:
                return mod, cls, class_name
        except ImportError:
            continue
    return None, None, None


def main(weights: Path | None, config: Path | None,
         frames: int, n_features: int) -> int:
    try:
        import torch
        import onnx
    except ImportError as e:
        print(f"ERROR: missing dep: {e}")
        print("Install with: pip install torch onnx 'numpy<2'")
        return 1

    try:
        import transkun  # noqa: F401
    except ImportError:
        print("ERROR: `transkun` package not found.")
        print("  pip install transkun  (if available)")
        print("  OR  git clone https://github.com/Yujia-Yan/Transkun and `pip install -e .`")
        return 1

    mod, cls, class_name = find_module()
    if cls is None:
        print("Could not find TransKun class. Inspect the package layout:")
        print("  python -c 'import transkun; print(dir(transkun))'")
        return 2
    print(f"Found {class_name} in {mod.__name__}")

    # Try to instantiate the model.
    if weights is not None and config is not None:
        with open(config) as f:
            conf = json.load(f)
        model = cls(**conf)
        state = torch.load(str(weights), map_location="cpu")
        if isinstance(state, dict) and "state_dict" in state:
            model.load_state_dict(state["state_dict"])
        else:
            model.load_state_dict(state)
    else:
        # Try the package's helper. transkun usually has a load helper that
        # downloads weights automatically.
        loader_candidates = [
            ("transkun", "loadModel"),
            ("transkun", "load_model"),
            ("transkun.loader", "loadModel"),
            ("transkun.utils", "loadModel"),
        ]
        loader = None
        for mname, fname in loader_candidates:
            try:
                m = importlib.import_module(mname)
                f = getattr(m, fname, None)
                if f is not None:
                    loader = f
                    print(f"Using loader {mname}.{fname}")
                    break
            except ImportError:
                continue
        if loader is None:
            print("Couldn't auto-load weights. Pass --weights and --config explicitly.")
            print("Inspect the transkun CLI to find the right paths:")
            print("  python -c 'import transkun, os; print(os.listdir(os.path.dirname(transkun.__file__)))'")
            return 3
        try:
            model = loader()
        except Exception as e:
            print(f"loader() failed: {e}")
            return 3

    model = model.eval().cpu()
    print(f"Model loaded: {model.__class__.__name__}")

    # Trace the model. We need to know its input format.
    print(f"Tracing with input shape (1, {frames}, {n_features})…")
    example = torch.randn(1, frames, n_features, dtype=torch.float32)
    try:
        traced = torch.jit.trace(model, example, strict=False)
    except Exception as e:
        print(f"\nTrace failed (try torch.jit.script, or include attention mask):")
        print(f"  {type(e).__name__}: {e}")
        return 4

    print(f"Exporting → {OUTPUT_PATH}")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    try:
        torch.onnx.export(
            traced,
            example,
            str(OUTPUT_PATH),
            input_names=["features"],
            output_names=["output"],
            dynamic_axes={
                "features": {1: "frames"},
                "output": {1: "frames"},
            },
            opset_version=17,
        )
    except Exception as e:
        print(f"\nONNX export FAILED: {type(e).__name__}: {e}")
        return 5

    try:
        loaded = onnx.load(str(OUTPUT_PATH))
        onnx.checker.check_model(loaded)
        print("✓ ONNX model verified.")
    except Exception as e:
        print(f"WARNING: ONNX check: {e}")

    print(f"\nDone. Size: {OUTPUT_PATH.stat().st_size / 1_000_000:.1f} MB")
    print("Inputs:")
    for i in onnx.load(str(OUTPUT_PATH)).graph.input:
        print(f"  {i.name}: {[d.dim_value or d.dim_param for d in i.type.tensor_type.shape.dim]}")
    print("Outputs:")
    for o in onnx.load(str(OUTPUT_PATH)).graph.output:
        print(f"  {o.name}: {[d.dim_value or d.dim_param for d in o.type.tensor_type.shape.dim]}")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", type=Path, default=None)
    parser.add_argument("--config", type=Path, default=None)
    parser.add_argument("--frames", type=int, default=200,
                        help="Trace-time frame count (model is dynamic; this is just a sample shape)")
    parser.add_argument("--features", type=int, default=229,
                        help="Mel feature dim (likely 229 or 256; check the paper/repo)")
    args = parser.parse_args()
    sys.exit(main(args.weights, args.config, args.frames, args.features))
