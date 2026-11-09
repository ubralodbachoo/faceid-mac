# Milestone 2 — ArcFace model integration

Updated November 10, 2026. Model engineering is validated on the development Mac; **commercial distribution rights remain unresolved**. The recognition path cannot authorize password entry.

## Model and provenance

| Item | Pinned value |
| --- | --- |
| Model | InsightFace `w600k_mbf` from official `buffalo_s` release v0.7 |
| Backbone / training loss | MobileFaceNet / ArcFace |
| Core ML package | Glance commit `b97f521397ec1197ba17768ba797cae1e628848d` |
| Runtime model ID | `insightface-w600k_mbf-glance-b97f5213-fp16-v1` |
| ONNX SHA-256 | `9cc6e4a75f0e2bf0b1aed94578f144d15175f357bdc05e815e5c4a02b319eb4f` |
| Input | `input_image`, canonically aligned 112×112 RGB image |
| Preprocessing | RGB `(pixel - 127.5) / 127.5`, baked into the model; Swift must not normalize pixels again |
| Output | `embedding`, shape 1×512, finite floats; Swift L2-normalizes it |
| Precision | Glance's converted FP16 ML Program |
| Runtime compute setting | `.all`; Core ML selects available units, with no claim that the Neural Engine was actually used |

The exact file URLs and hashes are in [the provenance lock](../Models/model-provenance.lock.json). We use Glance's existing converted package rather than repeating its ONNX → PyTorch → Core ML conversion. The independent ONNX comparison below checks that package, and the Swift comparison checks the actual pixel-buffer/runtime path.

## What is implemented

- An isolated `FaceUnlockRecognition` Swift target with Core ML/Vision, depending only on `FaceUnlockCore`.
- Actor-confined model loading and exact input/output validation. Model absence, incompatible contract, non-finite/zero descriptors, or failed numerical validation leaves image analysis disabled.
- Five-point canonical alignment using eyes, nose and mouth corners. Eye/mouth positions use image-left/image-right ordering. Vision bottom-left coordinates are converted explicitly; Core Image's transform is tested separately.
- Exactly one face is required. No dominant-face selection, loose-crop fallback, general-image feature print, or alternate-model substitution.
- A normalized 512-number descriptor with version-aware cosine comparison helpers. Descriptor debug descriptions redact values.
- A standalone synthetic CLI check and app buttons **Run model self-test** / **Analyze local image…**. Image decoding applies orientation and bounds resolution. The local image and computed descriptor stay in memory; neither is saved or uploaded.
- Hash-checked asset preparation and native model compilation into the ad-hoc development app, including provenance and notices.

This increment does not enroll a face, identify the owner, calibrate a match threshold, verify liveness, scan the camera, or invoke credential decryption/input. Face images are not necessary for its synthetic validation.

## Numerical and performance evidence

Five deterministic artificial RGB patterns with seeds 0, 1, 7, 19 and 113 were fed to the official ONNX model and Glance's Core ML package. The test requires cosine > 0.999 and relative L2 error < 0.03 for every case. Both packages and original ONNX were hash checked first.

The Python CPU-only run passed all five cases: minimum cosine **0.9998257**, maximum relative L2 error **0.0188573**. This is conversion parity, not a biometric false-accept or false-reject measurement. Its local report is `Models/validation.json`.

The compiled Swift runtime passed the same five source-ONNX references using native BGRA buffers and the model's RGB contract. The first measured report on Mac14,2 / Apple M2 / macOS 26.6.2 (25G83) was:

| Measurement | Result |
| --- | --- |
| Minimum reference cosine | 0.9999831 |
| Valid output dimensions | 512 |
| Cold model load | about 885 ms |
| Warm embedding median | about 0.887 ms |
| Warm embedding p95 | about 0.980 ms |
| Measured warm predictions | 30 after warm-up |

See [the raw Swift report](../Models/swift-runtime-validation.json). These are one-run development measurements for embedding inference only. They exclude image loading, detection, landmark estimation, alignment, camera, liveness, credential handling and desktop unlock. They are not a release performance guarantee.

The native test suite ran **33 tests: 32 passed, one real-Keychain test skipped**, including the real compiled-model check. New checks cover normalization and bad vectors, model-version mismatch, fit geometry, coordinate conversion, pixel channels/stride, missing landmarks, no face, multiple faces, missing models, failed revalidation and numerical parity. The previously completed isolated synthetic Keychain round trip remains documented under Milestone 1; this increment did not access the saved user credential.

Vision/Core Image/IOSurface and Core ML prediction need native macOS execution. Restricted agent-sandbox runs could not allocate the required pixel buffers/native working directory. Running the native checks outside that sandbox succeeded; the implementation does not substitute fake inference to work around that restriction.

## Packaged app verification

The version 0.3.0 app was launched after packaging. **Run model self-test** passed all five synthetic reference cases in the actual app, and the image analyzer became available only after that pass. A generated solid-red PNG was then selected through the native file picker; the app correctly returned **No face was detected**. No real face image or camera capture was used for this check, and no password attempt was armed. The app remains open after that expected no-face rejection; the valid synthetic model report is still available.

As expected after changing an ad-hoc binary, the new app reported Accessibility permission missing. That does not affect model diagnostics. Permission repair for future lock-screen experiments is a separate user action; no permission was granted by this task.

## Reproduce

```sh
./scripts/prepare-model.sh
./scripts/build-app.sh
.build/debug/FaceRecognitionDiagnostics build/compiled-models/ArcFace.mlmodelc Models/ArcFaceReference.json
```

`prepare-model.sh` uses a project-local Python 3.12.13 environment and version-pinned dependencies in `tools/model-requirements.lock.txt`. It downloads only pinned model assets and checks their hashes. The app does not download models or use Python at runtime. The original ONNX reference is not bundled into the app.

For native integration tests:

```sh
FACEUNLOCK_TEST_MODEL_PATH="$PWD/build/compiled-models/ArcFace.mlmodelc" CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" swift test --disable-sandbox
```

Without that environment variable the native compiled-model integration test is skipped. The real-Keychain mutation test stays opt-in and is not required for model work.

## Open acceptance gates

1. **Commercial model rights:** InsightFace lists these pretrained weights for noncommercial research. Glance's MIT source license does not grant commercial model rights. Obtain appropriate rights before customer distribution; neither this task nor the conversion grants them.
2. **Actual enrollment and accuracy:** enrollment, encrypted/versioned face templates, genuine/impostor validation and threshold calibration are subsequent milestones. Successful artificial-pattern tests do not prove recognition accuracy.
3. **Camera and lock-screen operation:** camera capture during a locked session still needs validation and integration with this model. The selected-image analyzer is not a live camera verifier.
4. **Liveness:** no spoof defense was added by this model integration. No face-triggered password entry is permitted by the current code.
5. **Distribution:** Developer ID signing, notarization, model licensing, clean-Mac install and supported OS/hardware claims remain release work. Rebuilding an ad-hoc app may require re-establishing Accessibility/Keychain trust. No credential plaintext or encryption key was read, and no credential was overwritten, migrated or deleted. Normal app startup still checks ciphertext presence; the model diagnostics do not access the vault.

## Primary references

- [Glance ArcFace implementation](https://github.com/jonnyoo/glance/blob/b97f521397ec1197ba17768ba797cae1e628848d/glance/ArcFaceEmbedder.swift)
- [Glance conversion script](https://github.com/jonnyoo/glance/blob/b97f521397ec1197ba17768ba797cae1e628848d/tools/convert_arcface.py)
- [InsightFace official model release](https://github.com/deepinsight/insightface/releases/tag/v0.7)
- [InsightFace licensing](https://github.com/deepinsight/insightface#license)
- [Apple Core ML prediction validation guide](https://apple.github.io/coremltools/docs-guides/source/model-prediction.html)
