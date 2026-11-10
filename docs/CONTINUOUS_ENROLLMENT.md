# Continuous video enrollment — version 0.6.0

November 10, 2026. Implemented at the owner's request after inspecting the supplied Glance reference clip. This replaces the production seven-view collector; it does not enable identity matching, liveness, or password entry.

## User flow

1. Choose **Start face setup**, authenticate privately with macOS, and allow Camera access if requested.
2. Look naturally at the camera. The collector establishes a stable reference for the camera's angle rather than requiring zero head pitch.
3. Follow the circle: left → upper-left → up → upper-right → right → lower-right → down → lower-left. Move gently, then settle briefly. Ring segments fill from actual accepted frame windows.
4. The camera stops after all nine angles (including center) are collected. Choose **Save face** to encrypt the template. Nothing is persisted before this explicit action.
5. Restart the app and choose **Check saved face** to validate persistence privately through macOS authentication.

There are no brighter/dimmer tasks in the basic scan. Additional lighting variation and held-out genuine/impostor evaluation remain acceptance work. Switching apps pauses with the camera off; **Continue scan** starts a fresh stream within the original three-minute authorization. Sleep, lock, account change, cancellation, closing the window and expiry discard pending enrollment. Background review cannot save until the app returns to the foreground.

## Video pipeline

`EnrollmentCamera` captures video only, preferring 1280×720 when supported. A native `AVCaptureVideoPreviewLayer` renders the mirrored preview independently of inference. Analysis uses unmirrored, materialized frames downscaled to a maximum edge of 640, delivered at up to 10 Hz through a newest-frame-only stream. No movie writer, audio input, recording file or upload exists.

The recognition actor performs explicit revision-3 face detection first. Exactly one observation is then supplied to revision-3 landmarks and capture-quality requests, preventing the earlier implicit revision-2/missing-pitch cache path. The existing five-point transform renders 112×112 RGB input to the validated ArcFace model. Enrollment and later image analysis share this path. The chained detector changes preprocessing relative to older templates, so template format/pipeline compatibility is enforced below.

The camera session is exposed to its preview layer only after the first frame arrives, after capture configuration has committed. The preview layer is detached and transient images are released on pause, cancellation, failure and completion. In-flight inference results are checked again for cancellation, account, lease and foreground before collection can advance.

## Temporal collection

`VideoEnrollmentCollector` holds descriptors and small numeric tracking state, never images. It smooths pose and face position with an exponential filter. Both raw and smoothed pose must match; smoothing cannot accept a frame already outside the requested angle. A candidate burst needs:

- At least four distinct increasing timestamps, spanning at least 300 ms, without an inter-frame gap over 400 ms.
- Consistent pose/position, a single usable face, required landmarks, adequate size/light and a finite capture-quality estimate.
- Two quality-ranked samples at least 200 ms apart, selected from that burst. Nine angles yield 18 normalized 512-dimensional descriptors.

Camera warm-up is 350 ms per capture segment. Brief detection loss clears an unfinished burst and smoothing but does not repeatedly restart camera warm-up. Explicit pause/resume does restart warm-up. Candidate storage is bounded at 24 descriptors; the full accepted template is bounded at 18. Completed angles stay in memory only while the original authorization remains valid.

Center calibration tolerates a usable natural laptop-camera angle (yaw within ±0.35 rad, pitch within ±0.55 rad). Subsequent directions are relative to that stable reference. Current engineering quality checks include capture score ≥0.2, at least 120 pixels in each face dimension, luminance 35–235, visible/unclipped bounds, and limited extreme pose/roll. Initial centering applies to calibration, rather than repeatedly rejecting ordinary position drift during each turn. The stability and collection thresholds are provisional heuristics, not an identity confidence or calibrated authentication policy.

Spatial/pose tracking does not prove that the same person remained present, and a recorded image/video can supply enrollment frames. Enrollment requires the owner's macOS authorization, but this implementation makes no liveness claim. Milestone 4 must evaluate identity and replay/spoof resistance independently before any automated unlock integration.

## Template compatibility and storage

The private `enrollment-v1.enc` file and `FUE1` AES-GCM envelope remain the storage container. The encrypted payload is now schema 2 and binds:

- UID and exact model identifier;
- pipeline `vision-rect3-landmarks3-quality3-fivepoint-video-v2`;
- collection policy `nine-directions-stable-burst-v1`;
- 18 vectors in fixed order, two per `EnrollmentPose` direction.

Old seven-view schema-1 templates cannot be read as current verification templates. Fresh authenticated re-enrollment is required. Authenticated replacement validates old ciphertext before capture and preserves it until the new scan is explicitly saved; cancel/failure does not overwrite it. Current-format templates with mismatched pipeline/policy are rejected. Keys, AES-GCM associated data/account binding, private atomic-file permissions, separate biometric Keychain service, 180-second capture authorization and 90-second explicit read lease retain the development policy documented in Milestone 3. No password key or credential lease is used by enrollment.

Legacy collector code remains only for schema-1 compatibility tests. The production model instantiates `VideoEnrollmentCollector`.

## Validation and limits

The native suite passes **83 tests, zero failures and zero skips** with all opt-in native checks enabled. Coverage includes full nine-angle temporal collection, natural camera-angle offsets, single-frame/gap/duplicate rejection, raw-versus-smoothed pose lag, best separated sample selection, transient loss, pause/resume, late inference, cancellation/expiry/account protection, explicit Save, restart/file persistence, legacy upgrade preservation, and pipeline/policy mismatch rejection.

The user's supplied screen-recorded reference video is also replayed locally: 32 time positions at 8 Hz from 15.5 seconds, cropped to its camera preview and analyzed with actual Vision/Core ML. One measured run produced **30 analyzed frames and two captured angles**, with analysis median about **11 ms** on the development M2. This checks temporal collection on real successive images, not just mocked metadata. The example segment does not contain the entire nine-angle sweep, is not a raw webcam capture, and is not an owner enrollment or liveness test. The reference movie is never copied into the repository/app, logged as an identity, or committed to storage.

Reproduce with the original local reference movie (omit the movie variable to skip this one replay test):

```sh
FACEUNLOCK_TEST_ENROLLMENT_VIDEO_PATH="/path/to/the/original-reference.mp4" FACEUNLOCK_RUN_KEYCHAIN_TEST=1 FACEUNLOCK_TEST_MODEL_PATH="$PWD/build/compiled-models/ArcFace.mlmodelc" CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" swift test --disable-sandbox
./scripts/build-app.sh
```

The packaged 0.6.0 app was opened and visually checked with its camera off: the circular preview, direction ring, single Start action, privacy note and separate developer tab fit the window. On November 10, the owner completed the live nine-angle scan and reported **“Face saved successfully.”** A text-only UI observation confirmed **“Your face is registered”**, the camera off, and **“Your saved face data is valid for this account and model.”** No owner camera screenshot or recording was taken by the agent.

This establishes the owner-camera scan and explicit Save on the development Mac. Quit/relaunch with authenticated saved-template checking, real replacement/deletion and camera/lifecycle failure acceptance remain pending. Model commercial rights, supported-hardware coverage, identity calibration, liveness and automatic unlock remain open gates. Native replay performance is one development measurement, not a latency guarantee.
