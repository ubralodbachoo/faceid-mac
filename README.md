# Face Unlock for Mac

Functional-first development: Glance’s ArcFace model is integrated for isolated Milestone 2 diagnostics. The first manual password unlock was reported successful; remaining Milestone 1 acceptance is tracked separately.

Selected architecture: Candidate A. The eventual app will verify a face and liveness locally, then decrypt and enter the customer's saved Mac password using Accessibility. The app now includes authenticated development credential storage and an explicitly armed, one-shot password-entry experiment. The ArcFace model is integrated separately and is not connected to password entry.

## Build and run

Requires macOS 15+ and a Swift 6 toolchain from Xcode. The initial development host is Apple Silicon on macOS 26.6.2; compatibility with other machines is unverified.

```sh
./scripts/build-app.sh
open 'build/Face Unlock.app'
```

Open `Package.swift` in Xcode to edit the project. The build script produces an ad-hoc-signed development app, not a customer distribution build.

The app shows a plain development window with credential and manual-test controls. **Refresh status** reads existing Camera and Accessibility authorization without requesting permissions. A session monitor refreshes account and reported screen-lock observations every second and invalidates them on sleep or account-session transitions. The last eight distinct observation summaries stay in memory; the window shows the latest three. Lock/account checks and password entry remain marked **Diagnostics only** until live acceptance passes. ArcFace inference is implemented; enrolled identity verification and liveness remain unimplemented. Setup readiness is not an authentication result.

A camera probe can receive and discard one frame during an explicitly armed locked-session test if you grant Camera permission. The app never uses the microphone. Password entry requires a fresh matching account and locked-session report, Accessibility permission, an authorized 90-second credential session, and a focused secure field owned by verified Apple loginwindow. It uses PID-directed keyboard events and has no global input fallback.

No unattended automatic unlock, login item, system helper, or authentication-policy change is installed. The local development app can bundle the pinned ArcFace model after preparation. The manually armed one-shot test has its first user-reported successful desktop return. The old prototype's identity and data are separate. Read [the Milestone 1 runbook](docs/MILESTONE_1.md) before the first live test. Enter your password only in the app; never in chat or terminal arguments.

## Project layout

| Path | Responsibility |
| --- | --- |
| `Sources/FaceUnlockCore/` | Platform-independent setup requirements and readiness contract |
| `Sources/FaceUnlockMac/` | macOS integrations; Session observation, development vault, guarded input, optional camera probe |
| `Sources/FaceUnlockRecognition/` | Actor-confined Core ML model, Vision landmarks, five-point alignment, synthetic validation |
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
