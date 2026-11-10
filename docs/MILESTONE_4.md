# Milestone 4 — recognition experiments

November 10, 2026 · Development version 0.7.0 · First increment implemented; acceptance and calibration pending.

## Try the live comparison

Use the existing 0.6.0 continuous-video enrollment; registration is not required again. From Face setup choose **Test my face**, or choose the **Face test** tab, then **Test my face**. Touch ID or the Mac password opens the encrypted enrollment for this explicit test; it is not the camera recognition result. After confirming, keep Face Unlock in front and look naturally toward the camera. No head-turn sequence is required. The camera stops before showing the result. **Test again** starts a fresh authorized attempt.

The former **Check saved face** control is now **Check saved data**. It checks encrypted-template persistence/compatibility only. The new Face test compares fresh frames against that template. The two purposes have separate labels and screens.

Results are **Face looks similar**, **Face looks different**, or **Could not decide**. The displayed similarity is a raw cosine-derived score, not a probability or security confidence. The cutoff is visibly experimental. A similar result cannot release a password, grant a credential lease, send keyboard events, or unlock the Mac. This increment has no liveness detector; printed/displayed photos and video may also compare as similar.

## Diagnostic comparison policy

- Use the exact validated bundled ArcFace model and revision-3 Vision / five-point alignment pipeline used for current enrollment. The biometric vault enforces schema, account, model, preprocessing and collection-policy compatibility. No migration or template write is performed.
- For each probe, compare with all 18 enrolled descriptors and average its three highest cosine similarities. Retain only scalar scores and transient bounds in the comparison window; no probe images or embeddings are persisted.
- Require 12 usable frames spaced at least 150 ms apart and spanning at least 1.65 seconds. A gap over 600 ms, detection/metadata/quality loss, duplicate/backward timestamp, or abrupt face-box movement resets the unfinished evidence. Inference older than 750 ms is discarded. These heuristics do not establish identity continuity or liveness.
- Engineering quality gates: one detected face, required pose/quality metadata, capture quality at least 0.2, both face dimensions at least 120 pixels, luminance 35–235, fully visible valid bounds, absolute yaw at most 0.50 rad, pitch 0.65 rad, roll 0.35 rad. No forced centering or head-turn challenge.
- Similar: median score at least **0.50**, with at least 10/12 scores at or above 0.50. Different: median below **0.40**, with at least 10/12 below 0.40. All other completed windows are inconclusive. Policy ID: `top3-median12-diagnostic-v1`.
- These fixed cutoffs are provisional engineering choices for this aggregation and model. They have not been fitted to owner results or calibrated against held-out genuine/impostor data. A single good score cannot complete the test.

Capture is bounded to 15 seconds, including startup. A watchdog also stops a stalled camera without another frame. The read lease remains the existing 90-second, sleep-aware biometric authorization; it is locked again when the test completes, fails, or is canceled. Account/lock/foreground/lease checks occur before and after every asynchronous inference and after camera shutdown. Switching apps during capture, sleep, lock, account changes, window closure and explicit cancellation stop the test and discard partial evidence. Returning does not resume it automatically. Late results cannot restore canceled UI or become completed comparisons. Active UI controls prevent overlapping registration/test operations across app windows. Each new test requires fresh authorization. There is no automatic retry or persistent authentication-attempt policy in this diagnostic increment; durable throttling remains an integration gate.

No movie/audio output, image files, test-score files, remote service, analytics or biometric log is added. The displayed result and scores remain only in app memory until a new test or app termination. Test images used by the agent are public fixtures; the live owner test is performed privately by the owner.

## Evidence

The native suite passed **100 tests, zero failures and zero skips** with the native model, disposable Keychain and reference replay checks enabled. Eight new core tests cover similar/different/inconclusive outcomes, single-template outliers, inconsistent evidence, temporal spacing/gaps, quality loss, abrupt position changes, compatibility and redacted printing. Eight app-flow tests cover actual read-to-capture orchestration with injected services, camera shutdown before result, cancellation/late inference, foreground/account/lease protection, detection and metadata loss, stale analysis, stalled-camera timeout, failed authorization/permission/model validation and overlapping-start prevention.

A new native integration test feeds brightness variants of the public NASA/scikit-image astronaut fixture through actual Vision, Core ML and the temporal comparison policy. It completes as similar. The enrollment and probes derive from one public photograph; this is a mechanics regression, not held-out accuracy measurement or liveness evidence. Existing enrollment replay still analyzes 30 frames and captures two angles from the supplied reference segment.

Reproduce all native checks with:

```sh
FACEUNLOCK_TEST_ENROLLMENT_VIDEO_PATH="/path/to/original-reference.mp4" FACEUNLOCK_RUN_KEYCHAIN_TEST=1 FACEUNLOCK_TEST_MODEL_PATH="$PWD/build/compiled-models/ArcFace.mlmodelc" CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" swift test --disable-sandbox
./scripts/build-app.sh
```

The packaged 0.7.0 app was quit/relaunched, found the existing enrollment, and opened from **Test my face** to the new Face test screen. Camera-off visual inspection confirmed the controls, explanation of Touch ID versus camera comparison, and experimental/liveness notes fit the window. The agent did not authenticate or start the owner's camera. Existing successful owner enrollment/Save is recorded separately in [continuous enrollment](CONTINUOUS_ENROLLMENT.md).

On November 10, the owner reported **“Face looks similar”** from the live 0.7.0 test. This is the first owner-reported positive camera comparison against the saved enrollment after app restart. No numeric score was supplied; a follow-up UI read was unavailable because the Mac was locked. The outcome is user-reported, not independently observed by the agent. Repeated genuine attempts, negative subjects, condition variation and presentation-attack evaluation remain pending; this one result does not establish accuracy or liveness.

## Live evaluation and remaining gates

First test the owner in the original lighting. Record the outcome and displayed similarity manually. Repeat in softer/brighter light, at another comfortable distance, with glasses if applicable, and with small natural pose changes. Use fresh captures after enrollment. A failure to acquire 12 usable frames is an acquisition failure, not an identity rejection. Borderline/inconsistent windows remain inconclusive.

For negative tests, use a consenting volunteer whose face was not enrolled. Keep only that person visible during the capture; the owner privately authorizes reading first and then moves out of view. Record false similarities separately from quality/timeouts. Also test no face and two faces. Evaluate printed photos, displayed photos and video replays separately; a similar score on these is evidence that recognition alone is insufficient, not a passed liveness test.

Keep calibration data separate from final evaluation. Establish application targets for false matches, false nonmatches, acquisition failures, latency and retries, then choose an aggregation/threshold on the calibration split and freeze it before evaluating held-out data. Report subjects, conditions, attempt counts and uncertainty. A few owner/volunteer successes cannot establish a population false-match rate. Supported-hardware coverage, durable throttling, presentation-attack detection, commercial model rights and all automatic-unlock integration gates remain open. Milestone 4 is not accepted as complete by this increment.

Primary background: [InsightFace model evaluation and threshold selection](https://www.insightface.ai/guides/choose-face-recognition-model-and-evaluate) discusses normalization and task-specific calibration. [NIST FATE presentation-attack evaluation](https://pages.nist.gov/frvt/html/frvt_pad.html) evaluates PAD separately; identity similarity does not supply that capability.
