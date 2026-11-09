# Local ArcFace development assets

- `model-provenance.lock.json`: pinned Glance package files, SHA-256/Git blob hashes, original ONNX source and digest, synthetic-fixture digest.
- `ArcFaceReference.json`: five deterministic artificial RGB-pattern reference outputs from original ONNX. This contains no human face or enrollment data.
- `swift-runtime-validation.json`: the initial measured Swift/Core ML synthetic result; embedding-only latency, not end-to-end unlock timing.
- `NOTICE.md` and `Glance-MIT-LICENSE.txt`: source attribution and the separate pretrained-weight restriction.
- `ArcFace.mlpackage/`, `reference/`, and `validation.json`: ignored local model/download/validation assets.

Run `./scripts/prepare-model.sh` to fetch and numerically verify the model. Run `./scripts/build-app.sh` to compile it into the local development app. A checkout without weights can still build but recognition will remain unavailable; a present but altered model fails the packaging integrity check.

Commercial redistribution is not cleared. Read [NOTICE.md](NOTICE.md) before bundling these weights for anyone else.
