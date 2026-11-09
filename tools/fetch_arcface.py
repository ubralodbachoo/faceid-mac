#!/usr/bin/env python3
"""Fetch pinned development-only ArcFace assets. Never downloads biometric/user data."""
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "Models"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def download(url, limit=64 * 1024 * 1024):
    with urllib.request.urlopen(url, timeout=90) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise RuntimeError("Asset exceeded expected size limit")
    return data


def main():
    lock = json.loads((MODELS / "model-provenance.lock.json").read_text())
    for entry in lock["files"]:
        output = MODELS / entry["path"]
        if not output.resolve().is_relative_to(MODELS.resolve()):
            raise RuntimeError("Invalid asset path")
        data = output.read_bytes() if output.exists() else download(entry["url"])
        if digest(data) != entry["sha256"]:
            raise RuntimeError(f"Hash mismatch: {entry['path']}; remove that asset and fetch again")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(data)
        print(f"Verified {entry['path']}", flush=True)

    output = MODELS / "reference/w600k_mbf.onnx"
    reference = lock["reference"]
    if output.exists():
        data = output.read_bytes()
    else:
        archive = download(reference["url"])
        if digest(archive) != reference["archive_sha256"]:
            raise RuntimeError("InsightFace reference archive hash mismatch")
        with zipfile.ZipFile(io.BytesIO(archive)) as source:
            data = source.read(reference["member"])
    if digest(data) != reference["sha256"]:
        raise RuntimeError("Original ONNX hash mismatch")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)
    print("Verified official ONNX reference. These weights require separate commercial rights.")


if __name__ == "__main__":
    main()
