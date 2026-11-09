#!/usr/bin/env python3
"""Compare the pinned Core ML package with official ONNX using only synthetic RGB pixels."""
import hashlib
import json
from pathlib import Path
import platform
import time

import coremltools as ct
import numpy as np
import onnxruntime as ort
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "Models"
IDENTIFIER = "insightface-w600k_mbf-glance-b97f5213-fp16-v1"


def pixels(seed):
    y, x = np.mgrid[0:112, 0:112]
    return np.stack([
        (x * 37 + y * 17 + seed * 13) % 256,
        (x * 11 + y * 43 + seed * 29) % 256,
        (x * 53 + y * 7 + seed * 47) % 256,
    ], axis=-1).astype(np.uint8)


def main():
    lock = json.loads((MODELS / "model-provenance.lock.json").read_text())
    for entry in lock["files"]:
        assert hashlib.sha256((MODELS / entry["path"]).read_bytes()).hexdigest() == entry["sha256"], entry["path"]
    onnx_path = MODELS / "reference/w600k_mbf.onnx"
    assert hashlib.sha256(onnx_path.read_bytes()).hexdigest() == lock["reference"]["sha256"]
    source = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    model = ct.models.MLModel(str(MODELS / "ArcFace.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    spec = model.get_spec()
    assert len(spec.description.input) == len(spec.description.output) == 1
    image = spec.description.input[0]
    assert image.name == "input_image" and image.type.imageType.width == image.type.imageType.height == 112
    assert image.type.imageType.colorSpace == ct.proto.FeatureTypes_pb2.ImageFeatureType.RGB
    assert spec.description.output[0].name == "embedding"
    cases, vectors = [], []
    for seed in [0, 1, 7, 19, 113]:
        image = pixels(seed)
        normalized = (image.astype(np.float32).transpose(2, 0, 1)[None] - 127.5) / 127.5
        expected = source.run(None, {source.get_inputs()[0].name: normalized})[0].reshape(-1).astype(np.float64)
        start = time.perf_counter()
        actual = np.asarray(model.predict({"input_image": Image.fromarray(image)})["embedding"]).reshape(-1).astype(np.float64)
        elapsed = (time.perf_counter() - start) * 1000
        assert expected.shape == actual.shape == (512,)
        assert np.isfinite(actual).all() and np.isfinite(expected).all()
        cosine = float(np.dot(expected, actual) / (np.linalg.norm(expected) * np.linalg.norm(actual)))
        relative_l2 = float(np.linalg.norm(expected - actual) / np.linalg.norm(expected))
        assert cosine > 0.999 and relative_l2 < 0.03, (seed, cosine, relative_l2)
        cases.append({"seed": seed, "cosine": cosine, "relative_l2_error": relative_l2, "prediction_ms": elapsed})
        vectors.append({"seed": seed, "embedding": expected.tolist()})
        print(f"seed={seed}: cosine={cosine:.8f}, relative L2={relative_l2:.6f}", flush=True)
    fixtures = {"schema": 1, "modelIdentifier": IDENTIFIER,
                "onnxSHA256": lock["reference"]["sha256"], "minimumCosine": 0.999, "vectors": vectors}
    fixture_data = (json.dumps(fixtures, separators=(",", ":")) + "\n").encode()
    (MODELS / "ArcFaceReference.json").write_bytes(fixture_data)
    lock["reference_fixture_sha256"] = hashlib.sha256(fixture_data).hexdigest()
    (MODELS / "model-provenance.lock.json").write_text(json.dumps(lock, indent=2) + "\n")
    report = {"schema": 1, "modelIdentifier": IDENTIFIER, "passed": True,
              "glance_commit": lock["glance_commit"], "platform": platform.platform(),
              "packages": {"coremltools": ct.__version__, "onnxruntime": ort.__version__, "numpy": np.__version__},
              "input": "112x112 RGB; (pixel-127.5)/127.5 is baked into the Core ML package",
              "output": "512 floats; normalization is performed by Swift", "cases": cases,
              "limitation": "Numerical conversion check only; not biometric accuracy, calibration, or liveness."}
    (MODELS / "validation.json").write_text(json.dumps(report, indent=2) + "\n")
    print("All synthetic parity checks passed. Swift reference fixture written.")


if __name__ == "__main__":
    main()
