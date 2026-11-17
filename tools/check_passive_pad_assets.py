#!/usr/bin/env python3
import hashlib, json
from pathlib import Path
root = Path(__file__).resolve().parent.parent / 'Models'
lock = json.loads((root/'passive-pad-provenance.lock.json').read_text())
assert lock['modelIdentifier'] == 'minivision-minifasnet-pair-b6d5f04-fp32-v1'
for entry in lock['files']:
 path = root / entry['path']
 assert path.resolve().is_relative_to(root.resolve())
 assert hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256'], entry['path']
print('Pinned passive PAD package, reference and license verified.')
