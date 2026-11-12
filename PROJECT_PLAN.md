# Face Unlock for Mac — functional-first project plan

Functional-first plan · updated November 10, 2026 · Milestone 3 live enrollment/Save confirmed; Milestone 4 experimental face comparison implemented. Recognition calibration, restart/lifecycle acceptance, commercial model rights and remaining Milestone 1 hardware acceptance are pending.

## Current increment

The owner authorized starting a new skeleton after the planning reset. The active Swift package now contains core setup requirements, a read-only macOS permission adapter, a minimal diagnostic app, tests, and a development app build script. The previous prototype remains archived. See [architecture notes](docs/ARCHITECTURE.md).

Step 2 adds read-only console/process/session account comparison, reported lock-state inspection, monotonic freshness checks, lifecycle invalidation, an in-memory change history, and a one-shot diagnostic CLI. Account matching was observed on the development Mac; the lock flag was absent and correctly shown as unknown. The user subsequently captured unknown → locked → unknown during a real lock cycle. Sleep/wake and fast-user-switch transitions remain unverified. See [validation notes](docs/SESSION_OBSERVATION.md).

The owner then requested the rest of Milestone 1. Implemented: AES-256-GCM credential storage, an app-specific development Keychain key, macOS-authenticated 90-second in-memory sessions measured including sleep, authenticated replacement/deletion, a 60-second one-shot manual attempt, Apple loginwindow secure-field checks, PID-directed input, cancellation/revocation, optional one-frame locked-camera probing, and an in-memory test report. The app distinguishes submitted events from a user-confirmed desktop return. No face match is connected.

Status: the main lock-screen mechanism has its first successful live result, reported by the user. Accessibility trust was repaired by exact-app re-registration. A controlled observation-only test verified the locked account and Apple loginwindow secure field at 16:11:30. The user privately saved the encrypted password and completed macOS authentication. An expired 90-second lease prevented initial arming; reauthorization succeeded without entering or saving the password again. The agent armed exactly one submission at 16:18:36 and locked the Mac. The app recorded submission to the verified loginwindow PID at 16:18:44 and revoked the credential session. The user's latest clarification states that the Mac returned to the desktop automatically, superseding an earlier fallback selection. This is user-reported confirmation, not independent programmatic attribution.

**Milestone 1 is not fully accepted yet**: repeat sleep/wake, camera availability while locked, wrong/changed password fallback, permission loss, account switching, and real restart/deletion checks remain. No second password attempt is armed or authorized by this result. Face recognition is not connected. No source/binary/signature change was made during these live tests. See [Milestone 1 evidence and acceptance matrix](docs/MILESTONE_1.md).

The development vault uses the file-based login Keychain with a creator-app ACL and an app-enforced LocalAuthentication gate. It does not claim hardware-enforced userPresence or Secure Enclave protection. The distribution Keychain design remains a separate required release task.


## Milestone 2 implementation status

At the owner's request, development proceeded to isolated model integration after the first positive Milestone 1 result; the remaining Milestone 1 tests have not been waived or marked complete.

Implemented: InsightFace `w600k_mbf` / MobileFaceNet trained with ArcFace, using the Core ML package pinned to Glance commit `b97f521397ec1197ba17768ba797cae1e628848d`. Original ONNX and converted-package hashes are recorded. Five deterministic synthetic comparisons against official ONNX passed. The compiled Swift `.all` runtime also passed against the reference vectors, with minimum cosine approximately 0.999983; one 30-run warm benchmark measured about 0.887 ms median and 0.980 ms p95 for embedding inference only. The actor-confined inference module includes Vision single-face detection, required five-point alignment, RGB pixel handling, 512-float normalization, and model-version-aware comparison helpers. Missing/bad models and failed validation cannot generate an accepted descriptor.

The version 0.3.0 app provides synthetic model diagnostics and a local-image analyzer. Its packaged-model self-test passed in the native app, and a synthetic image without a face was correctly rejected. The native regression suite passed 32 tests with one opt-in Keychain test skipped. No enrollment, persisted face descriptor, liveness, recognition threshold, automatic camera scan, or face-triggered password entry was added. The recognition module does not depend on the credential/input module. This preserves the functional-first scope without enabling biometric authentication prematurely.

**Milestone 2 is not commercially cleared:** InsightFace's pretrained weights are restricted to noncommercial research. Choosing the same weights as Glance does not grant commercial rights. Local research integration is ready; the distributable-model acceptance gate stays open until suitable rights are obtained. Real-user accuracy, camera integration and enrollment are subsequent milestones. See [Milestone 2 evidence](docs/MILESTONE_2.md).

## Milestone 3 implementation status

At the owner's request, the 0.4.0 development app now adds guided local camera enrollment and a separate encrypted template vault. Seven samples cover frontal/opposite yaw/opposite pitch and two light variations, with single-face, pose, size and quality checks. Camera and selected-image analysis share the same validated Vision/alignment/ArcFace pipeline. Captures stay in memory; an explicit Save commits seven descriptors with authenticated schema/account/model binding. Enrollment/replacement and deletion require fresh macOS authentication. Biometric capture authorization expires after three minutes; a separate read-only template lease expires after 90 seconds. Neither grants credential access or input permission.

Native synthetic tests cover file persistence across vault/store recreation, replacement/deletion, cancellation and failed writes preserving the original, account/model mismatches, corrupt payloads, missing/unavailable keys, and expiry/revocation. Disposable real-Keychain template storage and the existing compiled-model validation pass. **Real-person seven-step enrollment, app-restart validation, and camera/lifecycle failure acceptance remain pending.** Identity thresholds, liveness and automatic unlock are not enabled. See [Milestone 3 implementation and live runbook](docs/MILESTONE_3.md).

The owner subsequently requested a simple usable enrollment UI because blind diagnostic controls made registration difficult. Version 0.5.0 makes guided face setup the default, with a mirrored local preview, oval framing guide, individual pose/light instructions, seven-view progress and explicit Save. Developer/password controls move to a separate tab. The native suite passes 59 tests, including synthetic app-flow tests for preview lifecycle, cancellation, late results and explicit saving. This functional enrollment UX work does not mark Milestone 7 or the real-camera acceptance gates complete.

Version 0.5.1 corrects a live enrollment blocker: the implicit landmark detector and its cached observations omitted pitch, so every frame was rejected at 0/7. A fresh image handler with explicit revision-3 pose detection now supplies the required angles, while retaining the existing landmark alignment/render path. A public-photo regression reproduced the original failure and now passes through native Vision and the real Core ML model. Missing metadata and chin-position feedback are explicit. The native suite passes 64 tests; owner-camera acceptance still requires retry.

The owner's live 0.5.1 attempt advanced to 1/7, then reported framing trouble; full enrollment remains unaccepted. Version 0.5.2 adds a visible detected-face box and shared aspect-fit/mirrored guide geometry, separates clipping from centering feedback, and pauses with the camera off when switching apps. Explicit Continue resumes the partial scan only within its original lease; lock/sleep/account changes still revoke it. The native suite passes 74 tests including pause/resume, expiry/account protection, and framing geometry.

At the owner's request, version 0.6.0 replaces the seven-view collector with continuous multi-frame enrollment: native live preview, a directional ring, natural-angle calibration, stable temporal windows and two selected samples for each of nine poses. No manual lighting changes or video recording file is required. New encrypted schema-2 templates bind the preprocessing pipeline and collection policy; old templates require fresh enrollment and remain preserved until explicit replacement Save. The native suite passes 83 tests, including replay of the provided reference-video segment through actual Vision/Core ML (two angles captured). On November 10, the owner completed the live scan and reported successful Save; text-only UI inspection confirmed registered status and valid saved data. Quit/relaunch validation and remaining lifecycle acceptance are pending; see [continuous enrollment](docs/CONTINUOUS_ENROLLMENT.md).

## Product outcome

An opted-in customer wakes or locks their already logged-in Mac, looks at the camera, and returns to their desktop after a local identity match and the required liveness checks. The ordinary macOS password route remains available when the app cannot complete the attempt.

The first deliverable is a working, measurable end-to-end unlock on a declared Mac/macOS combination. Visual polish follows functional validation.

## Initial scope

- One enrolled macOS account on one explicitly supported Mac/macOS combination, followed by broader compatibility testing.
- On-device camera processing, recognition, enrollment, and storage. No recognition server or customer-uploaded face database.
- Lock/wake within an existing user session. Restart, FileVault preboot, switching between accounts, Apple Pay, and replacing system authentication prompts are outside the first release.
- Minimal native controls for permissions, enrollment, enabling/disabling, and diagnostics. No notch animation, decorative onboarding, or polished settings until the functional gates pass.
- A clean customer installation through a signed, notarized app package is a required release milestone.

## Milestone 1 — prove the selected password-entry mechanism

Decision confirmed by the project owner on November 9, 2026: **Candidate A (the Glance approach) is selected.** Encrypted storage and automatic entry of the customer's Mac password are accepted as the product architecture. Candidate B is outside the active plan.

After local identity verification and required liveness checks, an authorized user-session app decrypts the stored login password and submits it using Accessibility keyboard events. A successful face comparison alone does not unlock macOS.

Define and validate the Keychain/session policy, including system authentication to authorize access, session expiry, credential replacement/deletion, and behavior while the Mac is locked. Reliable lock/account/focus checks must precede any credential submission. Webcam spoofing and recoverable-credential exposure remain product limitations; do not market this as Apple's Face ID.

The first functional proof is a controlled, manually triggered lock-screen password submission on the declared test Mac, before connecting biometric automation. Use minimal native controls. The owner has authorized implementing this manual test. The archived prototype remains inactive.

Acceptance evidence:

- Record exact Mac, macOS, app signing, and permission configuration.
- Demonstrate an actual locked-session-to-desktop transition through the selected mechanism, initially without biometric automation.
- Establish whether the app/camera runs while locked, and whether password input can be directed reliably to the intended account and field.
- Establish behavior after app restart, expired credential session, camera/Accessibility permission denial, and missing or incorrect credentials.
- Verify failure does not block ordinary password entry or send the password to an unrelated field.
- Document the mechanism's limits. Stop here if the core integration cannot be made reliable.

## Milestone 2 — select a distributable face model

Use Apple's Vision for face detection and landmarks, then a face-specific embedding model through Core ML. Glance's reference implementation uses MobileFaceNet/ArcFace `w600k_mbf`, aligned 112 × 112 RGB input, and a 512-dimensional output.

Model weights have their own licensing terms. Glance's MIT source license does not establish commercial redistribution rights for InsightFace weights. Obtain suitable rights or select a model with verified rights for the intended product before bundling it for customers. Conversion to Core ML does not change the source model's rights.

Acceptance evidence:

- Document model provenance, version, preprocessing, output format, and redistribution rights.
- Verify converted-model output against the original model on reference inputs.
- Package a working model in the app and measure inference on the first target Mac.
- Missing, corrupt, or incompatible models disable recognition. Do not fall back to a general image descriptor for unlocking.

## Milestone 3 — implement enrollment and local storage

Use the same detection/alignment/embedding pipeline during enrollment and verification. Capture sufficient pose and lighting variation, with single-person and quality checks. Customers enroll their own face locally; a separate neural network is not trained for each customer.

Store encrypted, versioned embeddings associated with the correct account and model version. Discard camera frames after processing. Authenticate enrollment, replacement, and deletion through macOS. Decide how encryption keys are accessed during an authorized unlock session and how that session expires. Re-enroll when model compatibility changes.

Acceptance evidence:

- Successful enrollment persists across app restarts and can be replaced and deleted.
- Canceled/failed replacement preserves the existing enrollment.
- Raw captures, embeddings, and passwords never enter diagnostic logs.
- Corrupt data, unavailable keys, wrong-account data, and model-version mismatches fail without granting access.

The archived prototype's encrypted reference photographs are not identity templates; the new implementation should start with fresh enrollment unless a deliberate migration is designed.

## Milestone 4 — validate identity and liveness

Started November 10, 2026 at the owner's request. Version 0.7.0 adds an explicit **Test my face** screen: fresh macOS-authorized template reading, live camera comparison, 12-frame temporal aggregation, visible provisional similarity cutoffs and similar/different/inconclusive results. The old storage check is relabeled **Check saved data**. Native validation passes 100 tests, including actual Vision/Core ML comparison of public-photo brightness variants. The owner reported the first live **“Face looks similar”** result after app restart; its numeric score was not supplied. Repeated genuine/negative tests and held-out accuracy/calibration remain pending. Liveness, durable attempt policy and automatic unlocking are not implemented by this increment. See [Milestone 4 implementation and evaluation runbook](docs/MILESTONE_4.md).

The owner then reported a selfie receiving the same similarity result and clarified that no Mac unlock occurred. Version 0.7.1 caches validated capture-model preparation, accepts the existing 12-frame identity window at analysis rate, exposes stage timings and adds an experimental prompted bilateral close/reopen-eye response. Static matching-photo/missing-eye tests cannot produce a response-observed completion; the face comparison keeps updating while waiting. Native validation passes 110 tests. This heuristic does not establish robust PAD: live/replay/print/display evaluation, held-out calibration, durable attempt policy and unlocking remain open. Neither identity similarity nor a blink grants an authentication permit.

New latency requirement: the owner reports about 10 seconds after preview start and requests a 1.5-second maximum. This supersedes the prompted response as a suitable target architecture: evaluate passive PAD alongside identity within a bounded decision budget, with missing/late/uncertain evidence yielding not verified. Profiling the live stages, model selection/conversion/calibration, spoof evaluation and achieved latency remain pending. No new PAD implementation or speed guarantee is implied by recording this requirement.

The owner explicitly requested removal of the eye challenge after pointing to Glance's 0:06–0:10 launch segment. Version 0.7.2 removes that response and its eye-contour code, retains the existing identity policy and adds a 1.5-second logical decision budget after preview starts. Insufficient/late evidence cannot produce a positive result; native OS scheduling is not a hard real-time guarantee. The native suite passes 109 tests, and the packaged camera-off test screen was checked after restart; live owner timing remains pending. Liveness is explicitly unverified, and photos/video may match. Glance source review found passive cues, optional natural blinks, and a default Light mode that auto-confirms after three frames absent a deny cue; these have not been ported as a security claim. See [Glance analysis](docs/GLANCE_COMPARISON.md). Accuracy/PAD and live timing remain acceptance work.

The first 0.7.2 live attempt timed out, and the owner clarified that 1.5 seconds is an **average recognition target**, not a cutoff. Version 0.7.3 removes that short deadline, allows up to eight seconds for poor acquisition, and uses a six-frame/five-vote diagnostic burst with unchanged similarity/quality cutoffs. It reports measured completed-test averages and failed-camera-test counts separately, plus acquisition feedback on failure. Reduced-sample accuracy and achieved live average remain unverified; no liveness or automatic unlock capability is implied.

On November 11 the owner requested undoing the recognition timing changes and explicitly confirmed **Restore earlier recognition timing**. Version 0.7.4 restores the original 15-second total scan, 12 usable frames, 10 agreeing votes, 150 ms spacing and 1.65-second span. The short target is removed from the UI; model/enrollment and quality/similarity thresholds remain compatible. Gesture-free operation and measured diagnostics remain. Lock-screen unlocking remains the intended product, but this increment does not connect diagnostic similarity to password entry or claim liveness.

Compare normalized embeddings against enrolled templates with an explicitly calibrated threshold. Set false-acceptance, false-rejection, latency, and retry targets before enabling automatic unlock. Similarity values are not probabilities of identity.

Evaluate held-out genuine and impostor samples under different lighting, distance, glasses, facial changes, and camera conditions. Evaluate printed photographs, displayed photographs, and video replays independently. A blink or head turn alone is insufficient evidence for an anti-spoofing claim.

Acceptance evidence:

- Report measured outcomes and dataset limits rather than claiming security from a few successful demonstrations.
- No face, multiple faces, unknown face, poor input, uncertain liveness, timeout, or canceled attempt cannot cause an unlock.
- Define attempt throttling and verify restarting a component does not bypass the selected policy.
- If video replay remains effective, document that limitation and decide whether the convenience/security tradeoff is acceptable before release.

## Milestone 5 — connect the functional flow

Started November 11, 2026 at the owner's explicit request, with the supplied video's 0:06–0:10 segment as the visual reference. Version 0.8.0 adds a compact black top-center, blue-icon indicator with no camera image, a camera-off preview, and a desktop-authorized single lock-screen scan. The existing diagnostic similarity is not promoted to authenticated identity/liveness. The live composition is scan-only; the guarded submitter is present for a later verified provider, with a default-off submission gate. Synthetic tests exercise verified submission and separately observed desktop return without sending real keyboard events. Milestone 4 identity calibration/PAD remains unfinished, and Milestone 5 is started, not accepted as complete. See [implementation and acceptance runbook](docs/MILESTONE_5.md).

The owner's next correction requests scanning on **every lock**, without manual rearming, and a notch-sized indicator. Version 0.8.1 adds a desktop-authorized, in-memory automatic scan session. Each newly observed lock (or genuine sleep/wake) starts one bounded scan; duplicate lock/wake signals do not rearm it. Disable, quit, account/session change and enrollment replacement/deletion clear the cached template. The biometric vault's 90-second key lease and all password restrictions remain unchanged. The indicator uses macOS auxiliary top-area geometry to match notch width, with only a 28-point visible icon strip below it. Automatic password entry remains blocked; live lock/wake and notch acceptance are pending.

The owner then reported that the Mac still would not unlock and restated the reference drop-down appearance. Live app inspection confirmed that the locked scan completed with “Face looks similar” but deliberately entered no password. Version 0.9.0 implements a separate, explicitly acknowledged **experimental similarity unlock** permit and controller-owned credential session. It retains unavailable liveness as unavailable rather than fabricating verification. The normal verified-biometric permit remains strict; experimental use accepts the known photo/video/false-match risk, requires fresh desktop system authorization, and submits at most once per lock only to the verified Apple loginwindow secure field. Failed/unconfirmed input disables further automatic unlock. The overlay uses notch-width expanded geometry and isolated optional private SkyLight placement, referenced from Glance's MIT source. This is a development convenience path, not Milestone 4 security acceptance or completed end-to-end hardware acceptance. User-reported/observed live unlock after 0.9.0 remains pending.

Use an explicit state sequence: inactive → eligible locked session → scanning → identity/liveness verified → final lock/account/focus recheck → one unlock submission → observed result.

Cancel pending work on sleep, account changes, permission loss, disable, or timeout. Prevent stale results and overlapping scans from submitting a password. Keep decrypted credentials in memory only for the defined session/window. A face match, a submitted password, and an observed unlocked desktop are distinct events.

Acceptance evidence:

- Repeated real sleep/wake and lock/unlock cycles pass on the target Mac.
- Ordinary password and Touch ID behavior remain usable where available.
- Wrong person, spoof attempt, app failure, missing camera, expired session, changed password, and repeated wake events fail predictably.
- No extra submission occurs after manual unlock or when another account/session becomes active.
- Minimal diagnostics explain failures without retaining biometric or credential material.

## Milestone 6 — make installation work for another customer

Create the app's own bundle identity, signing configuration, entitlements, Keychain policy, and supported OS/hardware matrix. Use Developer ID signing, hardened runtime, notarization, and a distributable DMG. Include the licensed model in the package.

Customer flow: install → grant permissions → authorize enrollment/session → enroll face → save the Mac password encrypted → explicitly enable → perform a guided real lock/unlock test.

Acceptance evidence:

- A second clean Mac/account installs and completes setup without Xcode or developer terminal commands.
- Test every OS/architecture/camera combination actually claimed as supported; do not inherit Glance's compatibility claims.
- Validate permission denial/revocation, updates, signature continuity, password changes, disable, deletion, and uninstall.
- Explain what local data remains if the app alone is deleted, and provide a working removal path.

## Milestone 7 — build the UI

Only after end-to-end functionality and customer installation pass: design enrollment, settings, status/error recovery, notch/notchless presentation, animations, accessibility, and reduced-motion behavior. UI observes functional state; an animation can never grant authentication success.

The old UI and supplied animation are optional references, not a committed design direction. Verify redistribution rights before reusing supplied artwork.

## Decisions for the next planning discussion

1. Which exact Mac/macOS combination is the first supported target?
2. Is the product a private experiment or intended for paying customers? This affects the model-rights and release work.
3. What measured accuracy, latency, and spoof-resistance targets must a release meet?

Work proceeds in explicit functional increments. The skeleton does not itself complete Milestone 1 or demonstrate a Mac unlock.

## Reference material

- [Glance recognition implementation](https://github.com/jonnyoo/glance/blob/main/glance/ArcFaceEmbedder.swift)
- [Glance password-entry implementation](https://github.com/jonnyoo/glance/blob/main/glance/KeystrokeInjector.swift)
- [Glance documented limitations](https://github.com/jonnyoo/glance#read-before-downloading)
- [Glance source license](https://github.com/jonnyoo/glance/blob/main/LICENSE)
- [InsightFace model licensing](https://github.com/deepinsight/insightface#license)
- [Apple Developer ID and distribution](https://developer.apple.com/developer-id/)

November 12 follow-up (0.9.1): the owner reported a lock-icon-only rejection after enablement. Actual failure category remains unknown. Fixed premature completion on an initial negative comparison and camera shutdown consuming evidence freshness before guarded input. Added classified indicator captions and a last-attempt private operational report without biometric data or secrets. Native validation: 158 passed, three opt-in skipped, zero failures. Live owner verification remains pending; no computer-control session was started.

November 12 follow-up (0.10.0): replaced the primary four-tab interface with Permissions → Register face → Enter password → Finish setup. Existing enrollment and encrypted credentials can be reused. Finishing now awaits actual automatic-unlock enablement and surfaces authorization failures; an idle scan-only session can be upgraded instead of silently blocking it. Optional tests and scan-only diagnostics moved under Tools. The native suite passed (165 passed, three opt-in skipped), followed by final setup/credential regression validation (18 passed, one opt-in skipped). Rebuilt the development bundle and visually verified the permissions screen. Real owner face/password authorization and live lock-screen acceptance remain pending.
