# Face Unlock for Mac

Functional-first development, step 1: a buildable native Swift skeleton.

Selected architecture: Candidate A. The eventual app will verify a face and liveness locally, then decrypt and enter the customer's saved Mac password using Accessibility. This skeleton does not implement authentication or password entry.

## Build and run

Requires macOS 15+ and a Swift 6 toolchain from Xcode. The initial development host is Apple Silicon on macOS 26.6.2; compatibility with other machines is unverified.

```sh
./scripts/build-app.sh
open 'build/Face Unlock.app'
```

Open `Package.swift` in Xcode to edit the project. The build script produces an ad-hoc-signed development app, not a customer distribution build.

The app shows a plain diagnostic window. **Refresh status** reads existing Camera and Accessibility authorization without requesting permissions. Other components remain explicitly unimplemented. Setup readiness is not an authentication result.

This build does not open the camera, request permissions, access the Keychain, collect passwords or face data, simulate keyboard events, observe wake events, or install background services. No model or external dependency is bundled. A new development bundle identifier avoids reusing the archived prototype's identity.

## Project layout

| Path | Responsibility |
| --- | --- |
| `Sources/FaceUnlockCore/` | Platform-independent setup requirements and readiness contract |
| `Sources/FaceUnlockMac/` | macOS integrations; currently read-only permission inspection |
| `Sources/FaceUnlockApp/` | App lifecycle, dependency composition, minimal diagnostic window |
| `Tests/FaceUnlockCoreTests/` | Incomplete setup and unimplemented-service checks |
| `scripts/` | Development app packaging and bundle metadata |
| `docs/ARCHITECTURE.md` | Module boundaries and next implementation steps |

## Verify

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" swift test --disable-sandbox
```

## Plan and previous work

See [PROJECT_PLAN.md](PROJECT_PLAN.md) for the roadmap and [architecture notes](docs/ARCHITECTURE.md) for the skeleton's boundaries.

The previous prototype remains inactive in `archive/2026-11-09-prototype/`. Its code, research, assets, and builds are preserved locally and ignored by Git; this is not a remote backup. Its enrollment data and Keychain entries outside the repository were not deleted. The new skeleton does not read or migrate them.
