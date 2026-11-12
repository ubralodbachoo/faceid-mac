# Functional architecture

## Dependency direction

```text
FaceUnlockApp ──→ FaceUnlockMac ─────────→ FaceUnlockCore
       ├───────→ FaceUnlockRecognition ──→ FaceUnlockCore
       └────────────────────────────────→ FaceUnlockCore
FaceRecognitionDiagnostics ──→ FaceUnlockRecognition
```

The app constructs the macOS readiness provider and passes it into its model. The view reads the model and can request another read-only inspection. The core owns setup requirements without importing Apple UI, camera, or security frameworks. The macOS module owns platform API calls.

`ReadinessProviding` supplies setup inspection. `MacSessionReader` reads a point-in-time session snapshot; `MacSessionMonitor` refreshes it and handles lifecycle invalidation. Add operational service interfaces with their first working implementation instead of speculative camera, password, or model APIs. There are no mock success services in the production app.

## Current behavior

- Every setup requirement is enumerated in `Component`.
- A missing status defaults to `notImplemented`, so adding or omitting a component cannot silently complete setup.
- The readiness adapter inspects existing Camera and Accessibility authorization. Availability says nothing about hardware availability, camera capture while locked, or permission to submit a password.
- Session diagnostics, the development credential vault, and the manual password-entry harness are implemented. Live input/account checks remain diagnostic-only until hardware acceptance passes. ArcFace inference and experimental enrolled-face comparisons are implemented in isolated flows. Calibrated identity authentication and liveness remain open. See [session observation notes](SESSION_OBSERVATION.md) and [Milestone 1 runbook](MILESTONE_1.md).
- `isSetupComplete` is a configuration diagnostic. It must never authorize a credential read or password submission. Those need fresh per-attempt checks in the future coordinator.
- The development view has explicitly armed observation-only and one-shot submission tests. There is no automatic unlock switch or simulated success animation.
- Credentials persist only as AES-GCM ciphertext with a separate development Keychain key. Biometric descriptors now persist in a separate encrypted enrollment vault. There is no auto-start item or background helper. A pinned research-use face model is bundled locally after verification.

## Next implementation increments

Milestone 1 acceptance remains tracked independently while isolated Milestone 2 model work proceeds at the owner’s request:

1. Implemented: read-only lock/account observation and diagnostics. Actual lock/wake transitions still need target-Mac validation; unknown or stale state blocks an observation from being classified as reported locked.
2. Implemented: the development vault, system authentication gate, 90-second continuous-time lease, save/replace/delete, and restart-locked behavior. Automated tests use synthetic credentials; the user has also completed actual system authentication/save/reauthorization for the first successful manual test.
3. Implemented: `ManualUnlockController` and `LockScreenInput`. A manually armed 60-second attempt is consumed before reading plaintext. Input is directed only to verified Apple loginwindow PID with a focused secure field. No global event fallback exists. A submission is distinct from a user-confirmed desktop return. The first PID-directed submission was followed by a user-reported automatic desktop return. Remaining failure/reliability tests are pending.
4. Pending hardware acceptance: ordinary password fallback, permission loss, incorrect/changed credentials, app restart, and wake timing. See the runbook acceptance matrix.

Production biometric unlocking requires the roadmap model, enrollment and evaluated liveness gates. The manual Milestone 1 experiment, diagnostic comparison, and explicitly opted-in 0.9.0 experimental similarity-unlock path have separate entry points; that experimental path does not mark these security gates complete.

Future integrations belong in `FaceUnlockMac`, domain decisions in `FaceUnlockCore`, and composition in `FaceUnlockApp`. `FaceUnlockRecognition` now owns the Core ML/Vision dependency and has no access to the credential/input target. No authorization plug-in or Candidate B work is planned.

## Development identity and packaging

The development bundle is `org.faceunlock.development`, separate from the archived `org.faceunlock.lab`. `scripts/build-app.sh` builds the Swift package, creates a `.app`, and applies an ad-hoc signature. Camera usage text is included for the optional one-frame probe. The non-sandboxed development app has no microphone capability or camera auto-start. Developer ID signing, hardened runtime, notarization, model licensing, and clean-Mac installation remain release work.

No changes to authorization policies, SIP, FileVault, system credentials, or the old prototype's data are part of this skeleton.

## Credential and manual-attempt boundaries

`CredentialVault` is main-actor isolated and receives key/blob/authentication adapters for deterministic tests. The development adapter uses a creator-app ACL in the file-based login Keychain; LocalAuthentication gates the app's key loading rather than enforcing a hardware ACL. AES-GCM authenticates the format/bundle namespace and UID. Replacement commits a private temporary ciphertext file with an atomic rename. Missing keys never silently regenerate over ciphertext.

`CredentialLease` expires after at most 90 seconds. `ContinuousTime` uses `mach_continuous_time`, including sleep. A cached key may survive a brief sleep only within that lease, enabling the deliberate wake experiment; switching away from the account, revoking, quitting, and finishing a live attempt clear it. Swift/CryptoKit-managed memory cannot be guaranteed completely erased. No decrypted value is logged.

`ManualAttempt` binds the UID and 60-second deadline and consumes the permit before credential reading. `LockScreenInput` freshly checks lock/account/lease and the focused secure field before clearing, each Unicode packet, and Return. Events are PID-directed to code-signature-verified Apple loginwindow; they are never globally posted. Focus unavailable or inaccessible means no submission. This is a feasibility path, not proof that macOS accepts the events.

`LockedCameraProbe` runs capture setup/stop on its own queue and sample callbacks on a separate queue. It returns only success/failure, discards frames, has a bounded streaming wait, and handles task cancellation. Hardware startup may add latency.

## Recognition boundary

`ArcFaceRecognizer` confines `MLModel` and `CIContext` to an actor. Its model must satisfy the exact 112×112 RGB image / 512-float tensor contract. Its numerical self-test must pass against synthetic vectors from the pinned official ONNX before image analysis is enabled. Failures invalidate readiness; there is no feature-print or alternate-model fallback.

`FaceImageProcessor` accepts exactly one Vision face, obtains five landmarks, fits a rotation/scale/translation transform to the ArcFace template, converts between Vision/Core Image coordinates, and renders a BGRA pixel buffer for Core ML's RGB input. Face orientation from image metadata is applied when decoding a selected image. Loose crops and missing landmarks are rejected.

`FaceEmbedding` validates dimensions/finiteness/nonzero norm, L2-normalizes, and rejects comparisons between different model IDs. Its printable descriptions redact vector values. A cosine score is not an identity probability, liveness result, or authentication permit.

`RecognitionTestModel` publishes aggregate diagnostics only; it does not retain an image or embedding, read a credential, request camera permission, or call `ManualUnlockController`. Explicitly started camera enrollment is now implemented separately; automatic verification remains later work. Model weights, their license limits and numerical test evidence are documented in [Milestone 2](MILESTONE_2.md).

## Enrollment boundary (Milestone 3)

`EnrollmentDraft` owns the seven-step pose/light collection policy. `EnrollmentCamera` owns bounded video-only capture and yields transient frames to the same actor-confined `ArcFaceRecognizer.analyze` path as image diagnostics. `EnrollmentModel` coordinates OS-authenticated capture, cancellation, progress and explicit commit; it never references the credential vault or manual-input controller. The recognition module still has no dependency on the macOS credential/input target.

`EnrollmentVault` owns a separate Keychain service/file, schema/UID/model validation and AES-GCM storage. It reuses the private atomic-file and development Keychain adapters with distinct parameters. New enrollment/replacement and deletion use fresh system authentication. Capture leases last at most 180 continuous seconds; explicit template-read leases last at most 90 seconds and cannot mutate enrollment. Startup has no lease. No face template authorizes password access or input. Real-camera acceptance and calibrated identity/liveness gates remain pending; see [Milestone 3](MILESTONE_3.md).

The 0.5.0 app defaults to guided enrollment, with developer tools in a separate tab. `EnrollmentCaptureServices.live` always validates the real bundled model before camera access; injectable boundaries are used only by synthetic workflow tests. `EnrollmentModel` publishes a single transient preview and explicit UI phases, clears the preview on all termination paths, and never saves camera images. Preview is up to 12 Hz, analysis at most 2 Hz, and accepted samples at least 1.5 seconds apart. The preview mirrors display only, leaving recognition input unmirrored.

Version 0.5.1 adds explicit revision-3 face pose detection on a fresh `VNImageRequestHandler`. Reusing the landmark handler returned cached revision-2 observations without pitch on the target Mac. The pose pass runs after the existing landmark alignment/render work and must agree spatially with its single detected face. Missing pose/quality produces explicit feedback, never fabricated angles. Native public-photo tests cover real metadata and Core ML analysis in addition to synthetic app-flow tests.

Version 0.5.2 uses shared `EnrollmentFraming` geometry for the ellipse and the actual pose-detector center, plus `EnrollmentPreviewGeometry` for aspect-fit letterboxing and display mirroring. Transient face bounds are never persisted. Foreground loss now closes the current camera/stream segment and enters a paused phase; the local draft survives only within the original lease. Explicit Continue creates a new camera/stream without reauthorization or lease extension. The watchdog continues account/lock/expiry checks while paused/reviewing. Foreground is still required to process camera frames and commit enrollment. Lock/sleep/account changes or cancel clear the draft; returning focus alone cannot restart capture.

## Continuous video enrollment (0.6.0)

The production enrollment coordinator now uses `VideoEnrollmentCollector`, with exponentially smoothed pose/bounds, stable windows of distinct observations, separated quality-ranked descriptor selection, and nine relative directions. Native `AVCaptureVideoPreviewLayer` rendering runs independently of actor-confined inference. A bounded downscaled analysis stream runs at up to 10 Hz; no video writer or microphone exists. Explicit revision-3 detection feeds both landmarks and quality, preventing implicit legacy/cache ambiguity.

Template schema 2 binds the current recognition pipeline and temporal collection policy and stores 18 descriptors. Old seven-view templates cannot become current verification templates by reinterpretation; authenticated replacement preserves them until a fresh complete scan is saved. The former `EnrollmentDraft` is retained for legacy compatibility tests only. Account/lock/authentication/expiry, pause/resume, and manual password boundaries remain in place. See [the current runbook and validation](CONTINUOUS_ENROLLMENT.md).

## Explicit face comparison (0.7.0)

`FaceTestModel` coordinates a fresh, read-only biometric vault authorization, the same validated model/capture services, and a bounded 15-second camera attempt. `FaceComparisonWindow` in the core compares each probe against all 18 saved embeddings, averages its closest three similarities, and decides only after 12 spaced quality observations. Similar/different/inconclusive cutoffs are fixed experimental policy, not calibrated authentication. Detection/quality loss and discontinuities reset the unfinished window; stale inference is discarded. Foreground/account/lease checks bracket asynchronous work. Cancellation, lifecycle change and timeout clear the preview/evidence and revoke the biometric read lease. The camera is stopped before a completed scalar result is published.

The Face test screen has no credential/input capability and never mutates enrollment. It keeps displayed scores only in memory. Its macOS authorization opens the encrypted template; the following camera stage performs the comparison. No liveness detector, automatic unlock, auto-retry or durable authentication-attempt policy is supplied. [Milestone 4](MILESTONE_4.md) records mechanics tests and the outstanding accuracy/PAD/acceptance work.

Version 0.7.1 retains the validated capture recognizer across attempts and disables Core Image intermediate caching. Numerical capture preparation is reused only for the same actor/reference; explicit diagnostics rerun it and failed validation disables analysis. Identity still requires 12 quality frames and 10/12 agreement; 90 ms spacing allows use of the existing camera-analysis rate. Stage timing is shown separately from Touch ID. `BlinkResponse` uses transient roll-invariant eye contours for a prompted open/close/reopen response, with bilateral/timing/pose/bounds checks. The identity window rolls continuously while waiting; missing eye observations cannot fall back to similarity-only completion. This is an experimental response heuristic, not a PAD model or authentication grant; photo/video/replay resilience remains unverified.

Version 0.7.2 removes that prompted response and eye-contour extraction at the owner's explicit request. A dedicated 1.5-second deadline starts at the first preview frame and does not restart on quality/detection loss. Pre/post inference and post-shutdown checks reject late results; a deadline task clears a stalled preview and cancels the operation. Camera startup is separately bounded to eight seconds. Existing sample count, similarity thresholds, model validation and biometric authorization remain in place. The scalar result is explicitly identity-only with liveness unverified, and no credential/input integration exists. See [Glance source/video analysis](GLANCE_COMPARISON.md) for the distinction from Glance's passive-cue gate and default Light policy.

Version 0.7.3 supersedes that short deadline after the owner clarified **average latency**, not a cutoff. Comparison requires six spaced quality frames over at least 0.45 seconds with five agreeing votes; reduced-sample accuracy remains uncalibrated. Acquisition can continue past 1.5 seconds, up to an eight-second timeout from preview; stale/canceled/late results remain rejected. The coordinator records up to 20 completed camera durations in memory, a separate failed-camera-test count, and aggregate acquisition feedback. Startup/model/Touch ID remain separate measurements. No eye gesture or liveness capability is added.

Version 0.7.4 restores the original recognition timing at the owner's request: 15 seconds from capture start (including startup), 12 spaced frames over at least 1.65 seconds, and 10 agreeing votes. The dedicated stalled-stream timer now covers that same total window. The UI removes the 1.5-second target; measured startup/scan diagnostics remain. Rolling evidence, model caching, stale-result rejection and lock/session cancellation are retained. The biometric test remains separate from credential entry; lock-screen face unlocking remains future integration work.

## Milestone 5 foundation (0.8.0)

`LockScreenFlowModel` composes a fresh read-only enrollment lease, model/permission preparation on the desktop, one explicitly armed locked-session scan, and scalar results. It never publishes camera frames. `LockScreenFaceScanner` reuses the validated capture service and restored 12-frame policy but emits unavailable authenticated identity/liveness for diagnostic matches. Acquisition and authorization evidence use the continuous clock; session freshness uses uptime. Scanning does not require app foreground, while fresh matching account/explicit lock, template lease, suspension and timeout checks remain mandatory before/after inference and shutdown.

`FaceUnlockAttempt` binds the UID, attempt UUID, 60-second arm and 15-second scan. Consumption requires fresh same-attempt identity and PAD evidence, credentials, and secure focus. `VerifiedUnlockSubmitter` reuses the Apple-loginwindow-only PID-directed input path and consumes before plaintext access; it rechecks account/lock/lease/suspension/evidence while typing. The shipped composition has `submissionEnabled = false`, does not authorize password access, and cannot turn a diagnostic match into a credential permit. Verified-provider branches are exercised only with injected synthetic test services.

`LockScreenIndicator` is a borderless nonactivating, mouse-transparent panel at the top center, extending below a hardware notch where present. It displays scanning, submitting, awaiting desktop, fallback and observed-desktop states. A checkmark requires desktop observation after a submission; manual unlock while scanning never produces that checkmark. Its standalone preview animates scanning only, with no camera. Supported OS lock-screen visibility, display changes and Accessibility interaction still require live acceptance; a window level is not proof of lock-screen compatibility. [Apple's panel focus documentation](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded) informed the focus-neutral presentation. No private WindowServer APIs or UI scripting are used by the indicator. See [Milestone 5](MILESTONE_5.md).

Version 0.8.1 adds an explicit every-lock scan session at the owner's request. A fresh desktop authorization loads a template into memory; the read-vault key is then revoked, without altering existing lease policy. A 100 ms observer loop plus lock/unlock notifications starts one 15-second scan per lock cycle. Unknown lock observations cannot start a scan or clear its latch. An unlock notification may clear the latch only after a fresh same-account desktop observation; genuine sleep/wake resets it once, and repeated wake notifications do not. Sleep stops the current camera but preserves the opted-in template for wake; account/session changes, enrollment commit/deletion notifications, disable and quit discard it. Each scan gets a fresh attempt UUID and deadline; no automatic mode is available in a submission-enabled composition.

The indicator now derives its width/center from the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` in global screen coordinates, as described in [Apple's NSScreen documentation](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytoprightarea-gr2n). Its visible icon strip is 28 points high below the hardware notch, using a 20-point icon; notchless displays use a 180×28-point strip. No private display API, preview image or camera recording is introduced.

## Experimental functional connection (0.9.0)

The owner explicitly requested actual face-triggered unlocking after the scan-only prototype. `UnlockAuthorizationPolicy` now distinguishes strict verified biometrics (the default) from acknowledged experimental similarity. The scanner emits `experimentalMatch`, never verified identity/PAD, for a completed diagnostic match; liveness remains unavailable. A fresh matching experimental permit can accept this evidence only after mode-level photo/video-risk acknowledgement and separate credential authorization. Explicit rejection, stale/foreign evidence, missing credentials and invalid focus/session remain deny gates.

The automatic coordinator uses a separate `CredentialVault` instance with an explicitly authorized read-only app-session lifetime. It does not extend or repurpose the manual 90-second lease. It binds the authorized ciphertext digest, disallows writes from that session, decrypts only within `withPassword`, and revokes on disable/quit/account/enrollment/password changes. Camera cancellation before input preserves opted-in authorization for the next lock/wake; consumed/failed or unconfirmed input disables it. Desktop completion accepts an explicit unlocked snapshot or an unlock notification corroborated by a fresh same-account desktop snapshot after submission; unknown flags alone never authorize input or display success. Automatic polling/notifications must not cancel the awaiting-desktop phase.

`LockScreenWindowBridge` independently resolves private SkyLight symbols and attaches only the decorative panel while a fresh same-account lock is reported. Its implementation references [Glance's MIT interop source](https://github.com/jonnyoo/glance/blob/main/glance/NotchOverlay/NotchSkyLight.swift); the license is bundled. The panel remains non-key/non-main and mouse transparent, at the shielding tier, and detaches on unlock/hide. Symbols/status failures mean unavailable lock-screen decoration, not a credential fallback. Undocumented ABI behavior and real lock-screen rendering require target-OS acceptance. The drop-down matches notch width with a large blue face icon and rounded lower corners, replacing the prior thin strip. No camera view, global typing, OS authentication policy modification, or release-level liveness claim is introduced.

Version 0.9.1 continues rolling lock-screen comparisons past initial negative/borderline windows within the existing deadline. On a match, camera stop is requested without awaiting shutdown before input. The coordinator joins `finishCamera` after its attempt and keeps `isBusy` set until cleanup completes. Match freshness, thresholds and one-shot input guards remain unchanged. `LockScreenDiagnostics` classifies failures for the indicator and writes only the last operational report on a background serial queue, with private atomic storage and no images, descriptors, scores, account IDs or secrets. This enables read-only diagnosis without computer-control sessions.


### Four-step setup (0.10.0)

`SetupFlowModel` owns the Permissions → Register face → Enter password → Finish setup sequence. Permission and storage prerequisites are rechecked before finishing. Password saving uses the existing 90-second credential vault and revokes that write session immediately afterward. `enableForSetup` awaits the automatic controller's authorization operation and propagates its failure; completion cannot be inferred from saving a face/password or starting a task. An idle scan-only session can be upgraded to the explicit experimental unlock mode. Setup does not change biometric thresholds, input target verification, one-submission limits or credential revocation rules.

`StatusView` presents setup as the main screen, with optional face tests and diagnostics under Tools. The Finish action explicitly enables automatic unlock for the current process, following photo/video-risk acknowledgement. Password storage and face registration may be reused on a later launch, but unlock authorization must be obtained again. Controller failure details remain visible when automatic unlocking is disabled after unsuccessful input.
