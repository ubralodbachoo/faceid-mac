#!/usr/bin/env python3
"""Offline packaging integrity check; never runs inference or fetches anything."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
lock = json.loads((ROOT / "Models/model-provenance.lock.json").read_text())
for entry in lock["files"]:
    data = (ROOT / "Models" / entry["path"]).read_bytes()
    if hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise SystemExit(f"Pinned model asset mismatch: {entry['path']}")
fixture = ROOT / "Models/ArcFaceReference.json"
if hashlib.sha256(fixture.read_bytes()).hexdigest() != lock["reference_fixture_sha256"]:
    raise SystemExit("Synthetic reference fixture mismatch; validate the model again")
print("Pinned ArcFace package and synthetic reference verified.")
