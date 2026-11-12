# Face Unlock for Mac

Functional-first development: Milestone 3 uses continuous video enrollment and encrypted face-template storage with the pinned ArcFace model. Milestone 4 provides an experimental live **Test my face** comparison. Milestone 5 now includes an explicitly opted-in experimental face-triggered password path and a notch-width indicator (0.9.0). The first manual password unlock was reported successful; remaining Milestone 1 acceptance is tracked separately.

Selected architecture: Candidate A. The eventual app will verify a face and liveness locally, then decrypt and enter the customer's saved Mac password using Accessibility. The app now includes authenticated development credential storage and an explicitly armed, one-shot password-entry experiment. Enrollment and desktop diagnostic comparisons remain separate from password entry. Evaluated liveness is not implemented. The setup flow offers experimental convenience unlock only after photo/video-risk acknowledgement and fresh macOS authorization; it is not calibrated biometric authentication.

## Build and run

Requires macOS 15+ and a Swift 6 toolchain from Xcode. The initial development host is Apple Silicon on macOS 26.6.2; compatibility with other machines is unverified.

```sh
./scripts/build-app.sh
open 'build/Face Unlock.app'
```

Open `Package.swift` in Xcode to edit the project. The build script produces an ad-hoc-signed development app, not a customer distribution build.

Version **0.10.0** opens a single four-step setup: **1. Permissions → 2. Register face → 3. Enter password → 4. Finish setup**. Grant Camera and Accessibility to this exact app, register and save your face, enter your Mac login password (or use the encrypted password already saved), then finish setup. The final step includes the photo/video-risk acknowledgement and macOS authorization. Setup reports success only after automatic password-backed face unlock is enabled. Keep the app open, lock normally, and look toward the camera. Existing face registration and encrypted passwords can be reused after restarting the app; automatic authorization itself is never restored silently.

Face registration retains the smooth native preview and directional progress ring. Follow the head-turn guide through nine angles, then **Save face and continue** commits 18 encrypted descriptors. Images and video are never saved. Switching apps pauses capture; **Continue scan** resumes within the original three-minute authorization. Older seven-view templates require fresh enrollment. Password saving uses macOS authentication and encrypted local storage; password correctness is not validated during setup.

The **Tools** menu holds **Test my face**, **Lock-screen diagnostics**, and **Developer tools**. Face testing remains an experimental comparison with the original 15-second window and 12-frame policy, with at least ten agreeing frames. It does not authorize password entry. Turn off automatic face unlock before running camera or manual credential tests. See [Milestone 4 testing](docs/MILESTONE_4.md) and [continuous enrollment](docs/CONTINUOUS_ENROLLMENT.md).

**Finish setup enables unlocking, not scan-only diagnostics.** Each new lock or genuine sleep/wake can submit the saved password once after a 12-frame experimental match. An existing idle scan-only session can be upgraded during setup instead of silently preventing activation. The yellow lock in scan-only diagnostics deliberately means no password was entered; that option is now confined to the diagnostics view. **Liveness remains unavailable, photos/video may unlock, and false matches are possible.** The default verified-biometric policy still requires identity and PAD verification; the separate experimental permit names the weaker assurance explicitly.

The automatic controller retains its own read-only credential key session in memory until disabled, quit, account/enrollment/password change, or a failed/unconfirmed submission. Plaintext is decrypted only around guarded submission and is not cached. The manual credential vault retains its separate 90-second policy. Every submission requires the fresh matching locked account and code-signature-verified Apple loginwindow secure field, with checks throughout input and no global keyboard fallback. Unconfirmed/partially failed submissions turn automatic unlock off instead of retrying. No login item is installed.

The small lock-screen indicator shows scanning, submission and confirmed desktop return. A failure shows its reason for four seconds. A single private local report at `~/Library/Application Support/FaceUnlockDevelopment/last-lock-attempt.json` records mode, stage, failure category, input/submission flags, timing and aggregate frame counts; it contains no images, embeddings, similarity scores, account IDs or passwords and replaces the prior report. Initial different/borderline windows continue within the original 15-second attempt, and camera shutdown does not block delivery of fresh match evidence. Camera cleanup is joined before another attempt can start. Live lock-screen acceptance for the simplified flow remains pending.

A camera probe can receive and discard one frame during an explicitly armed locked-session test if you grant Camera permission. The app never uses the microphone. Password entry requires a fresh matching account and locked-session report, Accessibility permission, an authorized 90-second credential session, and a focused secure field owned by verified Apple loginwindow. It uses PID-directed keyboard events and has no global input fallback.

No login item, system helper, or macOS authentication-policy change is installed. Automatic face-triggered password entry starts only after the experimental mode is explicitly enabled for the current app session. The local development app can bundle the pinned ArcFace model after preparation. The manually armed one-shot test has its first user-reported successful desktop return. The old prototype's identity and data are separate. Read [the Milestone 1 runbook](docs/MILESTONE_1.md) before the first live test. Enter your password only in the app; never in chat or terminal arguments.

## Project layout

| Path | Responsibility |
| --- | --- |
| `Sources/FaceUnlockCore/` | Setup/session policy, embeddings, enrollment sample policy and readiness contract |
| `Sources/FaceUnlockMac/` | macOS integrations; Session observation, development vault, guarded input, optional camera probe, separate encrypted enrollment vault |
| `Sources/FaceUnlockRecognition/` | Actor-confined Core ML model, Vision landmarks, five-point alignment, synthetic validation, bounded enrollment camera capture |
| `Sources/FaceRecognitionDiagnostics/` | Standalone synthetic model check/benchmark; no credential dependency |
| `Models/` | Model provenance, research-use notice, synthetic reference; weights remain ignored local assets |
| `Sources/FaceUnlockApp/` | App lifecycle, dependency composition, minimal diagnostic window |
| `Tests/FaceUnlockCoreTests/` | Setup/session gates, crypto/storage lifecycle, single-use attempt policy |
| `Sources/FaceUnlockDiagnostics/` | One-shot session inspection from the terminal |
| `scripts/` | Development app packaging and bundle metadata |
| `docs/ARCHITECTURE.md` | Module boundaries and next implementation steps |

## Verify

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" swift test --disable-sandbox
```

## Prepare the ArcFace model

The existing local build has the model. On a fresh checkout, install [uv](https://docs.astral.sh/uv/), then run:

```sh
./scripts/prepare-model.sh
./scripts/build-app.sh
```

Preparation downloads the pinned Glance Core ML package and official InsightFace ONNX reference, checks hashes, installs isolated Python validation dependencies, and compares synthetic predictions. The weights and Python environment stay out of Git. This is a development/research setup; **commercial distribution rights for the pretrained weights are not cleared**. See [model notice](Models/NOTICE.md).

In the app choose **Run model self-test**. After it passes, **Analyze local image…** can detect one face, align it to 112×112, and generate a 512-number descriptor. It does not enroll an identity, decide that a face is yours, establish liveness, or enter a password. Images and descriptors are not saved or uploaded. The model check uses artificial pixel patterns rather than camera images.

Model engineering results, measurements, dependencies and remaining gates are in [Milestone 2](docs/MILESTONE_2.md).

For native model integration in the test suite after building:

```sh
FACEUNLOCK_TEST_MODEL_PATH="$PWD/build/compiled-models/ArcFace.mlmodelc" CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" swift test --disable-sandbox
```

Vision/Core ML/Core Image tests need a normal macOS process with GUI/native-framework access. The agent execution sandbox restricts these APIs; a restricted run can fail to allocate IOSurface or compile native models. No authentication or camera grant is needed for the synthetic model checks.

## Session inspection

For a one-shot read-only report:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" swift run --disable-sandbox FaceUnlockDiagnostics
```

The reported lock flag is undocumented. Missing information is **unknown**, never an inferred unlocked or locked state. Running in a restricted sandbox may also make account information unavailable. This diagnostic cannot authorize password entry. See [session observation notes](docs/SESSION_OBSERVATION.md) for the observation layer. The [Milestone 1 runbook](docs/MILESTONE_1.md) covers credential setup and live acceptance.

## Plan and previous work

See [PROJECT_PLAN.md](PROJECT_PLAN.md) for the roadmap and [architecture notes](docs/ARCHITECTURE.md) for the skeleton's boundaries.

The previous prototype remains inactive in `archive/2026-11-09-prototype/`. Its code, research, assets, and builds are preserved locally and ignored by Git; this is not a remote backup. Its enrollment data and Keychain entries outside the repository were not deleted. The new skeleton does not read or migrate them.

Version **0.10.1** waits up to three seconds for the verified Apple loginwindow password field before starting a face scan. It checks application-level focus as well as system-level focus and can focus a single enabled secure field inside the verified loginwindow tree. Ambiguous, unavailable or foreign fields still block input. Fresh face evidence and one-shot submission checks remain required. Live acceptance of this change remains pending.
