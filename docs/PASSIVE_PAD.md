# 0.14.0: stationary-face passive PAD evaluation

The owner wants quick genuine-face recognition without head movement while retaining selfie rejection. Glance Heavy cannot reliably provide a positive cue from a motionless face, and the owner's reports also include a glare rejection. This build adds an independent trained passive model trial to **Tools → Test my face**. Automatic unlocking still uses the mandatory Heavy path from 0.13.1. Neural evaluation outputs cannot authorize the password vault or unlock permit.

## 0.14.1: explicit lock-screen trial

After the owner reported a still real-face live candidate (0.994/0.993) and a selfie uncertain result, the owner explicitly requested connecting the model to main unlocking for a locked-Mac test. This is a limited owner observation, not a measured attack/genuine evaluation.

The main scanner now defaults to the passive pair. Preparation requires the bundled model and reference to load and pass numerical validation; model failure cannot silently fall back to Heavy. A scan requires both outputs ≥0.900 for three consecutive fresh measurements plus the existing identity window. Scores must remain positive while waiting for the password field. Missing/uncertain evidence blocks input; both outputs ≤0.100 for three frames reject the attempt. Heavy motion/blink/glare decisions are no longer on the active passive path; the Heavy implementation remains for regression coverage only. There is no user-facing liveness-off option.

Each scan owns a new temporal window. Identity discontinuities, quality/detection loss, stale analysis and cancellation discard it. The combined evidence timestamp uses the oldest of the last three live observations and the latest identity frame, preserving the 750 ms freshness bound through preparation and credential input. Mode and fixed cue/decision names are reported, with no neural scores, images or face coordinates saved. The existing verified-biometric permit still refuses experimental evidence. Single-account/focus checks and one-shot password input remain unchanged.

Restart and privately re-enable face unlock to test a still real face, then the exact selfie under locked-screen conditions. An uncertain selfie must produce no password input; any selfie unlock is a failed security test. This build does not establish reliable replay-video resistance.

## Model and preprocessing

Original: Minivision [Silent-Face-Anti-Spoofing](https://github.com/minivision-ai/Silent-Face-Anti-Spoofing), pinned revision `b6d5f04ad78778917853b25c778acef6d5626d15`. The official MiniFASNetV2 scale-2.7 and MiniFASNetV1SE scale-4.0 weights are combined into one FP32 Core ML model. Original source, weight URLs/hashes, conversion versions and output hashes are recorded in `Models/passive-pad-provenance.lock.json`. The upstream Apache-2.0 license is retained in `Models/Minivision-Apache-LICENSE.txt` and packaged with the app. Existing ArcFace weight restrictions are unchanged.

The model receives two original-image crops, inclusive end pixels and upstream edge-shift logic, resized to 80×80. Input is planar BGR float32 with raw 0–255 values, with no face alignment or /255 normalization. Swift implements bilinear resizing with rounded byte-valued output; native regressions compare its predictions with the original OpenCV/PyTorch path on the three upstream camera examples, allowing a small numerical tolerance for JPEG decode/resize differences. The model produces two three-class distributions; class index 1 is live.

The conversion script verifies source/weight hashes before importing the pinned architecture and loads weights with `weights_only=True`. Five deterministic artificial input pairs compare original PyTorch and Core ML outputs. Runtime validates contract and the same five reference cases before evaluation; failure clears the prepared model. Model and camera processing stay on this Mac. No camera image, crop or evaluation score is written to disk.

## Trial policy and evidence

Both model live-class outputs must be at least 0.90 for three consecutive usable frames to show **Live candidate**. Both must be at most 0.10 for three frames to show **Spoof candidate**; disagreement/intermediate values are **Uncertain**. Missing, stale, invalid or interrupted identity-track data resets the evaluation window. These are engineering trial cutoffs, not calibrated authentication probabilities or demonstrated operating points.

A first live candidate time is measured from the first camera frame; it excludes camera startup and authorization. Any live candidate during a test remains flagged even if later frames become spoof/uncertain. For a photo/video presentation, any such candidate is a failed spoof test. Results/presentation labels remain in the existing last-100-trials memory list only. No score can change automatic unlock configuration.

On the three public upstream examples using Vision face boxes, original PyTorch live-class outputs were: live T1 0.9994/0.9894; spoof F1 0.0167/0.0088; spoof F2 0.2412/0.5155 (uncertain, not a live candidate). Reference decoding explicitly ignores EXIF orientation to match CGImage/Vision coordinates; OpenCV’s default EXIF rotation produced an invalid initial comparison. These examples are not held-out data and do not establish camera-domain accuracy. Synthetic warm Core ML pair predictions measured about 4–7 ms after first-use setup; that excludes image preparation, camera startup and identity analysis and is not an unlock benchmark.

## Required owner evaluation

1. Restart 0.14.0. Turn off automatic face unlock while using the camera test.
2. Open **Tools → Test my face**. Under **Window evaluation**, select **My face**, then run a test while naturally still. Inspect **Passive liveness trial** and the model details. Repeat under ordinary lighting; movement must not be necessary for the live candidate.
3. Set presentation to **Photo on screen** and show the exact selfie that previously unlocked the Mac. Repeat at different sizes/brightness, with edges hidden and the photo tilted/moved. It must never show a live candidate.
4. Test printed photos and recorded blinking/head-motion video as additional attacks. Any live candidate fails the spoof criterion. Uncertain results are not successful verification.

Only after genuine/attack trials support an acceptable operating point should the neural gate replace the mandatory motion/blink confirmation in automatic unlocking. A trained RGB model is not guaranteed to generalize to this camera, lighting or unseen attacks; upstream explicitly cautions about camera/scene dependence. Merely relaxing Heavy or trusting the absence of glare/device edges would not meet the owner's two requirements.

## Reproduce

Create a separate `.venv-pad` with Python 3.12, install the pinned packages in `tools/passive-pad-requirements.txt`, then run `.venv-pad/bin/python tools/prepare_passive_pad.py`. The script fetches only pinned official architecture/weight/license assets if absent, converts, validates, and writes the provenance manifest. `scripts/build-app.sh` checks hashes and compiles/packages the optional model. Native test opt-in: `FACEUNLOCK_TEST_PAD_MODEL_PATH="$PWD/build/compiled-models/PassivePAD.mlmodelc"` together with the existing ArcFace test environment. No camera or credential authentication is needed for those numerical tests.

Validation: the full native suite ran 245 tests with four opt-in skips and zero failures. The final six-test passive-model suite, including the additional end-to-end public-image preprocessing regression, also passed. Correcting the reference's EXIF decoding convention resolved the apparent mismatch; raw crop pixel differences averaged below 0.25 intensity units against OpenCV. The 0.14.0 app was packaged with both model licenses, integrity checks and a verified development code signature. No owner camera capture or live password submission was performed by the agent.

Version 0.14.1 validation: 250 tests executed, 246 passed, four opt-in integrations skipped, zero failures with native Core ML/Vision and both compiled models enabled. New lock-screen cases cover stationary acceptance without Heavy measurements, missing/uncertain/spoof scores despite a blinking Heavy fixture, uncertainty during field waiting, and stale combined evidence during prompt preparation. Live locked-Mac genuine/selfie acceptance remains an owner test; no live password submission was performed by the agent.
