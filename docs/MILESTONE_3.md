# Milestone 3 — enrollment and local storage

Updated November 10, 2026. Current version 0.6.0 replaces seven-view capture with continuous nine-angle video enrollment and an encrypted, versioned template. Automated native checks pass, and the owner completed a live scan and Save. App-restart validation and hardware lifecycle acceptance remain pending. Enrollment cannot read a password, submit input, establish identity, or verify liveness.

### Current: 0.6.0 — continuous multi-frame enrollment

The owner authorized replacing the brittle seven-view flow with continuous video collection modeled on the supplied reference experience. Native preview is independent of analysis; a direction ring reflects stable multi-frame bursts. Nine directions collect 18 quality-ranked descriptors, with natural camera-angle calibration and no forced lighting changes. Payload schema 2 records preprocessing and collection-policy compatibility. Legacy schema-1 data requires fresh enrollment and is preserved until authenticated replacement commits.

**83 native tests pass**, including a real local replay of the reference segment (30 frames analyzed, two angles captured; approximately 11 ms median analysis on the development M2). The owner reported **“Face saved successfully”** after the live nine-angle scan; text-only UI inspection confirmed registration and saved data valid for this account and model. Quit/relaunch validation and remaining lifecycle acceptance are pending. See [the current implementation, runbook, and evidence](CONTINUOUS_ENROLLMENT.md). The sections below retain historical implementation and acceptance evidence; seven-view instructions and former thresholds describe those earlier versions.

### 0.5.2 — visible detection, shared framing and resumable scans

A text-only observation of the owner's 0.5.1 live scan confirmed **1 of 7 views captured**, establishing that the missing-pitch fix enabled a real first sample. The next hint reported framing trouble during the sideways view, and switching back to chat caused the old foreground policy to cancel the attempt. No owner camera screenshot or recording was taken by the agent; full enrollment was not accepted as complete.

The preview now displays **Face detected** and a rectangle from the pose-capable detector. Its rectangle and the oval are mapped through the same aspect-fit viewport, with exactly one horizontal mirror for display. The shared oval keeps its physical aspect ratio for 4:3, widescreen and portrait inputs. Centering uses the detected face center within that guide; a clipped face produces a distinct “move farther back” hint. The older landmark detector's padded rectangle and its 3% edge margin no longer produce a misleading “off center” result. Quality/size/pose/light checks and the embedding alignment path remain in place. Live face tracking continues at most twice per second even during the 1.5-second acceptance cooldown.

Switching applications now stops the camera, releases preview/stream images and pauses the scan while preserving accepted descriptors in memory **only within the original three-minute lease**. Return to the window and explicitly choose **Continue scan** to start a fresh camera stream; returning alone does not restart capture, and resuming does not authenticate again or extend the lease. Completed scans can wait for Save within the same lease, but saving still requires the foreground app and current account. Lock, sleep, account changes, cancellation, window closure and expiry still revoke/discard the attempt. The pause policy changes foreground loss from destructive cancellation to camera-off pause; it never permits background camera processing or password input.

The native suite passes **74 tests, zero failures and zero skips**. Added checks cover aspect-fit/mirror geometry, clipped-versus-off-center feedback, live tracking during cooldown, preserving/completing a partial scan after explicit resume, canceling while paused, expiry/account changes blocking resume, late inference after focus loss, and foreground-gated Save after background review. The full real-person seven-view/save/restart acceptance remains pending.

### 0.5.1 — fix enrollment stuck at zero views

The owner reported a live preview remaining at 0/7 while showing “Face the camera in even light and hold still.” That exact path meant enrollment metadata was absent, rather than a failed lighting check. A new native regression with the public NASA/scikit-image astronaut photo reproduced a detected/aligned face with missing enrollment metrics in 0.5.0.

A native metadata probe isolated the cause: `VNDetectFaceLandmarksRequest` used its implicit revision-2 face detector, which supplied yaw and roll but no pitch. More subtly, issuing an explicit `VNDetectFaceRectanglesRequestRevision3` on the **same image request handler** returned a cached revision-2 observation, still without pitch. On a **fresh handler**, the same revision-3 request returned revision-3 observations with yaw, pitch and roll. The fix explicitly performs pose detection on a fresh handler. The existing landmark/alignment/render path is preserved, and face-region overlap plus single-face checks bind the pose result to that aligned face. No missing angle is replaced with zero and no capture threshold was relaxed.

Missing pose and missing quality now have distinct feedback rather than the misleading generic lighting instruction. Rejected frontal poses explain whether to lift/lower the chin or face the camera directly. Native tests now exercise a real photo through Vision, alignment and the actual validated Core ML model, not only synthetic model inputs and mocked app-flow frames. The public fixture and attribution are under `Tests/FaceUnlockCoreTests/Fixtures/`; they are test resources only, never included in the development app or used as an enrolled identity. See [fixture provenance](../Tests/FaceUnlockCoreTests/Fixtures/NOTICE.md).

The complete native suite passes **64 tests, zero failures and zero skips**, including missing-angle/quality/mismatched-region rejection, real-face pose metadata, real-face Core ML analysis and the app's metadata-error feedback. Real owner enrollment still requires a live retry; the public-photo test proves the metadata regression is corrected, not face accuracy or liveness.

Apple documents [face detection request revisions](https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest) and the separate [capture-quality request](https://developer.apple.com/documentation/vision/vndetectfacecapturequalityrequest). The installed SDK explicitly specifies that face detector revision 3 adds pitch; the fresh-handler requirement above was established by the native reproduction on this Mac.

### 0.5.0 — guided native face setup

At the owner's request after difficulty registering, the default screen is now a dedicated SwiftUI setup flow: **Start face setup → confirm with macOS → guided scan → Save face**. A mirrored live camera preview with an oval positioning guide replaces blind capture. One pose/light instruction is shown at a time, with seven-view progress, a countdown, and specific positioning/quality hints. The camera stops before the review screen. Existing enrollment can be checked, registered again, or removed with confirmation and macOS authentication. A denied Camera permission offers an explicit settings link. Developer/model/credential/manual-input diagnostics are on a separate **Developer tools** tab, which cannot be entered during capture or pending Save.

The live preview displays the latest transient CGImage at up to 12 frames/second; face analysis remains limited to at most two frames/second and accepted views remain at least 1.5 seconds apart. Capture output is explicitly unmirrored for the recognition pipeline; only the displayed preview is mirrored. No quality, pose, lighting, authentication, expiry, account, or lock gate is bypassed. The latest preview is cleared on cancellation, error, session loss, and capture completion. Camera images are never app-written files or diagnostic logs. Closing the setup window also cancels capture and clears the preview. The preview is not an identity or liveness result.

The complete native suite passes **59 tests with no failures or skips**. New app-coordinator tests use synthetic frames and injected capture/model services to cover the seven-view flow, explicit Save, preview updates during sample cooldown, cancel clearing preview/pending work, late analysis after cancel, no-face guidance, denied permission, and model failure preventing camera startup. The packaged app was visually checked with the camera off: the oval guide, single Start action, privacy note, and separate developer tab are visible without scrolling. Native tab switching and the packaged five-case model self-test passed. Real camera enrollment still requires the owner to authenticate privately and complete a live run; synthetic workflow tests do not establish real-person acceptance.

### 0.4.1 — distinguish foreground checks from expiry

The owner reported an immediate “biometric session expired or was canceled” message upon clicking **Enroll my face…**, before authentication. The 0.4.0 implementation used that same error for any failed foreground/account check, so the screenshot does not establish a genuine lease timeout. The updated enrollment-only session gate allows up to five seconds for activation after the initial click and OS prompts, while continuously checking the account, login and reported lock state. It does not activate the app itself or start the camera in the background. During capture and before Save, foreground checks remain immediate; the three-minute lease is unchanged.

Focus loss, account changes, inactive/unknown sessions, reported lock, and actual vault expiry now have distinct feedback. Six regression tests cover delayed activation, bounded background waiting, lock/account changes during the wait, unavailable/stale sessions, immediate foreground loss during capture, and cancellation. The complete native suite passes **51 tests with zero failures or skips**. A real click/authentication/camera retry is still required to confirm the reported issue is resolved on this Mac.

Apple exposes app activation independently through [`isActive`](https://developer.apple.com/documentation/appkit/nsapplication/isactive) and [`didBecomeActiveNotification`](https://developer.apple.com/documentation/appkit/nsapplication/didbecomeactivenotification); the short wait handles that activation boundary without weakening account or lease checks.

## Implemented flow

1. Choose **Start face setup** or **Register again** on the Face setup screen. Enroll your own face only.
2. Authenticate with macOS. Each enrollment or replacement requires fresh authentication and starts a three-minute biometric capture lease measured using `mach_continuous_time`, including sleep. It does not reuse the credential session.
3. The app validates the packaged ArcFace model against its five synthetic ONNX references before requesting camera permission or starting capture.
4. Follow seven steps: frontal normal light, two opposite small turns, two opposite small vertical tilts, frontal brighter light, and frontal dimmer light. Each sample passes the same Vision detection, five-point alignment and Core ML embedding path used by the image analyzer and available to a future verifier.
5. After seven accepted samples, the camera stops. Choose **Save face** to atomically commit the encrypted template, or **Cancel** to discard the pending descriptors. The original enrollment remains unchanged throughout capture and until a successful save.
6. **Check saved face** requires new macOS authentication, decrypts and checks schema/account/model/dimensions, and displays only a sample count. It performs no identity comparison. The diagnostic immediately revokes its read lease after inspection.
7. **Remove saved face…** requires new macOS authentication and removes the separate biometric key and template file. It does not delete the stored password.

The UI must be foregrounded with matching process/console/session accounts and a completed console login. A reported lock rejects enrollment. An absent desktop lock flag is explicitly unknown; enrollment additionally requires OS authentication and the foreground UI. This allowance is never an unlock authorization. Sleep, inactive-account and reported-lock notifications cancel the operation, discard pending descriptors and revoke the biometric lease. During capture and before save, the app rechecks account/foreground state and the lease. A one-second watchdog also revokes pending capture/save authorization on expiry or session loss. Quitting cancels camera work and authorization.

## Capture policy and limits

Exactly one face is required in every accepted frame. Missing quality or pose estimates cannot produce an accepted sample. Current engineering heuristics require Vision capture quality ≥ 0.35, a centered/unclipped face at least 120 pixels in each dimension, small roll (≤ 0.20 radians), limited yaw/pitch, and aligned central-face luminance between 45 and 220. Side turns must have opposite yaw signs with magnitude ≥ 0.16 radians; vertical tilts must have opposite pitch signs with magnitude ≥ 0.12. The two lighting samples require at least ±12 luminance relative to the initial frontal sample. Accepted samples are spaced by at least 1.5 seconds.

These are provisional collection heuristics, **not calibrated identity or spoof thresholds**. Camera exposure behavior, pose conventions, glasses, skin tones and real-user usability must be tested before acceptance. No claim is made that seven frames provide adequate production recognition accuracy. The collection policy does not prove that the same person stayed present between frames; held-out identity validation belongs to Milestone 4. Two opposite vertical tilts are accepted to avoid relying on a camera-specific sign convention.

AVFoundation uses video-only 640×480 capture, discards late frames, throttles preview conversion to 12 frames/second, separately limits face analysis to two frames/second, and buffers at most one pending image in the async stream. Capture has an eight-second initial-frame timeout and a three-minute total timeout. Native startup/stop operations execute on a dedicated queue; inference is confined to the recognition actor. Camera frames are transient inputs, never app-written images or diagnostics. A canceled or late inference result is rechecked before it can advance or save enrollment.

Apple documents capture quality as a relative measure of lighting, sharpness and positioning; it is not an authentication confidence. See [Apple capture quality documentation](https://developer.apple.com/documentation/vision/vnfaceobservation/facecapturequality-bjg5) and [late-frame behavior](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/alwaysdiscardslatevideoframes).

## Storage and authorization

- File: `~/Library/Application Support/FaceUnlockDevelopment/enrollment-v1.enc`, separate from `credential-v1.enc`.
- Keychain service: `org.faceunlock.development.enrollment-key.v1`, account = process UID; separate from the credential key service.
- Format: `FUE1` header plus AES-256-GCM combined nonce/ciphertext/tag. Authenticated associated data binds the development namespace, format and UID. The encrypted JSON payload contains schema 1, UID, exact model identifier, and seven normalized 512-dimensional vectors. It contains no photographs, filenames or password.
- Directory permissions are 0700, ciphertext is 0600, the directory is excluded from backup, and replacement uses a private temporary file followed by atomic rename. Existing private-file path/symlink checks also protect the new file.
- Restart begins without a cached key or biometric session. A verifier must explicitly authenticate for a read-only, at-most-90-second lease before requesting a compatible template. Enrollment leases cannot retrieve templates for verification, and read leases cannot save an enrollment. No verifier or automatic unlocking is connected by this milestone.
- Missing keys alongside ciphertext never regenerate. Bad headers, oversized/corrupt ciphertext, wrong-account authenticated data, unsupported schemas, incomplete or invalid descriptors, and incompatible model IDs cannot yield a template. An authenticated new enrollment can replace a valid older-model template; the old template cannot be read as the current model.
- Failed/canceled capture, authorization, or atomic replacement preserves existing ciphertext. Deletion removes the key first; if subsequent file removal fails, remaining ciphertext is unusable and an authenticated deletion retry can remove it. Canceled deletion preserves both key and ciphertext.

This retains the existing **development** Keychain policy: file-based login Keychain creator-app ACL plus app-enforced LocalAuthentication. It does not claim hardware-enforced userPresence or Secure Enclave protection. Swift/CryptoKit allocations and OS memory copies cannot be guaranteed erased. Explicit plaintext byte buffers are cleared after encryption/decryption; descriptors and keys are released on cancellation/expiry. Distribution Keychain/signing policy remains Milestone 6 work. Changing an ad-hoc signature may require repairing app trust; the app never broadens an ACL automatically.

No raw vectors, captures, keys, passwords, or selected filenames are sent to diagnostic logging. Descriptor/template/draft printable descriptions redact vectors. Status messages contain only fixed feedback, sample counts and sanitized errors.

## Automated evidence

Native regression checks cover the guided pose/light sequence, poor/nonfinite input, encrypted file persistence across store/vault recreation, successful replacement/deletion, canceled/failed replacement preserving the original, canceled/failed deletion, keyless deletion retry, corrupt/oversized/malformed payloads, account/model mismatch, deliberate model upgrade, unavailable/missing keys, capture/read expiry and late authentication revocation. A disposable Keychain round trip uses synthetic vectors, a unique test service and a temporary directory. No saved customer credential or biometric key is read or changed by that test.

The complete native suite passes **45 tests with zero failures and zero skips**, including real Core ML reference validation and both opt-in disposable Keychain tests. Camera checks also cover idempotent shutdown before hardware startup and image materialization before a capture buffer is reused. Restricted agent-sandbox execution blocks the pre-existing native Vision/Core Video tests; native execution is required rather than substituting synthetic success.

The packaged 0.4.0 app was launched and its enrollment controls were visually checked. With no enrollment present, Save/Validate/Delete were disabled, Enroll was available, and no manual password test was armed. The packaged model self-test also passed its five synthetic ONNX cases. No live camera capture, biometric save, permission grant, or credential read was performed during that UI check.

Reproduce on the development Mac:

```sh
FACEUNLOCK_RUN_KEYCHAIN_TEST=1 FACEUNLOCK_TEST_MODEL_PATH="$PWD/build/compiled-models/ArcFace.mlmodelc" CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" swift test --disable-sandbox
./scripts/build-app.sh
```

The Keychain flag creates/removes disposable synthetic test items only. Without it, the two real-Keychain tests are skipped. Without the model path, compiled-model validation is skipped.

## Live acceptance still required

| Check | Status |
| --- | --- |
| Native encrypted round trip/recreation/replacement/deletion with synthetic vectors | Passed |
| Disposable real-Keychain template round trip | Passed |
| Real camera captures all seven steps and accepts usable lighting/poses | Pending owner test |
| Save real enrollment, quit/relaunch, authenticate and validate saved file | Pending owner test |
| Cancel real replacement and verify old enrollment remains readable | Pending owner test |
| Complete real replacement and authenticated deletion, relaunch and verify absence | Pending owner test |
| Cancel OS authentication; deny/revoke Camera permission | Pending owner test |
| Sleep, lock, switch account, disconnect camera and expire capture/save window | Pending owner test |
| Confirm ordinary password/Touch ID remains usable | Pending Milestone 1/5 acceptance |

For a live test, open the 0.5.0 app, choose **Start face setup**, complete the guided scan and **Save face**, relaunch it, then use **Check saved face**. Next test canceled replacement, successful replacement and deletion. Perform authentication privately in macOS; no password or face file needs to be provided in chat. Do not arm the manual password experiment for enrollment testing.

Commercial model rights remain unresolved as documented in [Milestone 2](MILESTONE_2.md). No old prototype photographs are read or migrated. Milestones 1, 2 commercial clearance, 4 liveness/accuracy and 5 automatic integration remain separate gates.
