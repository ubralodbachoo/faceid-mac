# Face Unlock for Mac

Functional-first development: Milestone 3 uses continuous video enrollment and encrypted face-template storage with the pinned ArcFace model. Milestone 4 provides an experimental live **Test my face** comparison. Milestone 5 now includes an explicitly opted-in experimental face-triggered password path and a notch-width indicator (0.9.0). The first manual password unlock was reported successful; remaining Milestone 1 acceptance is tracked separately.

Selected architecture: Candidate A. The eventual app will verify a face and liveness locally, then decrypt and enter the customer's saved Mac password using Accessibility. The app now includes authenticated development credential storage and an explicitly armed, one-shot password-entry experiment. Enrollment and desktop diagnostic comparisons remain separate from password entry. Version 0.13.0 adds mandatory experimental passive liveness based on Glance Heavy; evaluated spoof resistance is not established. The setup flow offers experimental convenience unlock only after photo/video-risk acknowledgement and fresh macOS authorization; it is not calibrated biometric authentication.

## Build and run

Requires macOS 15+ and a Swift 6 toolchain from Xcode. The initial development host is Apple Silicon on macOS 26.6.2; compatibility with other machines is unverified.

```sh
./scripts/build-app.sh
open 'build/Face Unlock.app'
```

Open `Package.swift` in Xcode to edit the project. The build script produces an ad-hoc-signed development app, not a customer distribution build.

Version **0.16.0** provides a menu bar app and two UI editions:

```sh
./scripts/build-app.sh admin       # build/Face Unlock.app (default)
./scripts/build-app.sh customer    # build/Face Unlock Customer.app
```

Both bundles remain ad-hoc-signed local builds, not signed/notarized customer releases. The customer edition is compiled with `FACEUNLOCK_CUSTOMER` and excludes the admin tools menu and setup replay control. It uses its own bundle identifier and installation preferences. Both editions currently use the existing development face/password vault; switching editions on the same Mac can reuse that saved data. Run one edition at a time when testing automatic unlock.

The Face ID icon stays in the menu bar while the app runs, including when its windows are closed. Its menu contains **System Settings…** (opens this app) and **Quit**. The icon's accessibility label and tooltip indicate whether unlocking is enabled. Settings offer five saved animation colors—green, blue, violet, orange and white—and a **Preview** action that does not scan or submit a password. The choice applies to the lock-screen indicator as well as the settings preview.

On a customer's first launch, an interactive black panel expands down from the notch: **Permissions → Register face → Enter password → Finish setup**. Grant Camera and Accessibility to that exact edition, save your face, enter your Mac login password (or reuse its saved encrypted copy), then finish setup with the photo/video-risk acknowledgement and macOS authorization. System permission and authentication prompts remain native macOS dialogs. On a display without a notch, setup is centered against the top edge; smaller displays can scroll the content. Setup suspends when the Mac locks or sleeps.

Completion is persisted only after automatic password-backed face unlock is enabled successfully. An incomplete or canceled customer setup appears again next launch. After completion, later launches open settings rather than repeating onboarding. Enabling unlock still requires fresh macOS authorization each app session; installation preferences never restore credential access. The application window has independent **Home**, **Permissions**, **Faces**, **Password** and **Appearance** pages, navigated with a native dock that magnifies on hover and respects Reduce Motion. Face registration, adding a face, password updates and permission controls stay in their own settings pages; none advances onboarding. The notch flow is used for initial setup and explicit replay only. Its panel resizes smoothly per step with short fades and compact progress dots. The React/Next.js scaffold was removed because the app is native SwiftUI. The admin edition opens the same setup on each launch and includes **Replay setup in notch** in settings. Replay stops automatic unlocking and clears the flow's consent, while preserving saved enrollment and the encrypted password.

The Faces page supports **Add face** while preserving existing registrations, up to three faces. Each face still requires a complete authenticated nine-angle scan. Saving an addition writes an encrypted schema-3 collection atomically; canceling, expiry, write failure or a changed source registration preserves existing data. **Register again** deliberately replaces all faces after confirmation; removal also requires confirmation and macOS authentication. Existing single-face schema-2 data remains readable. Older binaries cannot read schema 3.

Recognition scores each face's own top three descriptors separately. A change in the best matching registered face resets the identity window and passive liveness history; votes from different faces cannot be combined. The similarity thresholds, capture quality rules, passive liveness requirements and guarded password submission remain in place. Adding faces increases the set of appearances/people accepted by experimental convenience unlock and requires live owner validation.

Face registration retains the smooth native preview and directional progress ring. Follow the head-turn guide through nine angles, then **Save face and continue** commits 18 encrypted descriptors. Images and video are never saved. Switching apps pauses capture; **Continue scan** resumes within the original three-minute authorization. Older seven-view templates require fresh enrollment. Password saving uses macOS authentication and encrypted local storage; password correctness is not validated during setup.

The admin edition’s **Tools** menu holds **Test my face**, **Lock-screen diagnostics**, and **Developer tools**. Face testing remains an experimental comparison with the original 15-second window and 12-frame policy, with at least ten agreeing frames. It does not authorize password entry. Turn off automatic face unlock before running camera or manual credential tests. See [Milestone 4 testing](docs/MILESTONE_4.md) and [continuous enrollment](docs/CONTINUOUS_ENROLLMENT.md).

**Finish setup enables unlocking, not scan-only diagnostics.** Each new lock or genuine sleep/wake can submit the saved password once after an experimental match. Version **0.12.8** trials six frames with five agreeing over at least 0.75 seconds, replacing the previous 12-frame/10-agreement/1.65-second lock-screen window. Similarity thresholds, quality/continuity checks and the three-attempt limit are unchanged; live success and false-match rates of the shorter window remain unmeasured. An existing idle scan-only session can be upgraded during setup instead of silently preventing activation. Scan-only diagnostics deliberately enter no password; that option is now confined to the diagnostics view. **Version 0.13.0 requires positive experimental liveness evidence; photo/video attacks and false matches may still succeed.** The default verified-biometric policy still requires identity and PAD verification; the separate experimental permit names the weaker assurance explicitly.

Version **0.13.0** adds the five Glance liveness cues in mandatory Heavy mode: glare and device-shaped rectangles deny an attempt; natural blink, pose/nose correlation or nonplanar landmark motion can provide a positive cue. There is no Light mode or liveness-off option. Identity and liveness must pass before opening the password prompt, and missing measurements block input. Existing face templates remain compatible. Liveness uses faster sampling while identity keeps its six-frame policy. These are experimental RGB heuristics, not depth sensing or evaluated anti-spoofing. Live testing against the owner’s selfie, printed photos and replayed video remains required. See [implementation and acceptance steps](docs/LIVENESS.md).

Version **0.14.1** enables the passive pair in the main lock-screen flow for the owner's experimental trial. Both live-class outputs must be ≥0.900 for three consecutive fresh frames, together with the existing six-frame identity match. Uncertain, missing, inconsistent or stale liveness blocks password entry; there is no Heavy/blink fallback. Head movement is not required by the passive gate. The model is prepared and numerically checked before arming. Existing account/focus guards, single password submission and camera cancellation remain unchanged. Photo/video resistance and genuine-face latency still require live lock-screen testing.

Version **0.14.0** adds a trained **Passive liveness trial** to **Tools → Test my face**, targeting still-face recognition without a blink/head-movement requirement. Test **My face** and the actual **Photo on screen** presentation before using its outputs to design a new unlock gate. Both models must agree over three frames for a live candidate; any live candidate during a photo/video test is flagged as a spoof-test failure. The neural trial does not authorize password access or change automatic unlocking, which retains Heavy checks. See [model provenance, validation and camera test steps](docs/PASSIVE_PAD.md).

Version **0.13.1** narrows device-rectangle rejection after a genuine-face attempt was falsely classified as a screen. A rectangle must nearly enclose the face at a plausible relative size; large background rectangles, partial overlaps and face-sized details are ignored. Heavy still requires a positive liveness cue, and qualifying devices/glare still deny an attempt. Known cue failures now say **Screen shape detected** or **Screen glare detected**. Live genuine-face recovery and repeated selfie/video rejection remain to be tested; see the [follow-up notes](docs/LIVENESS.md#0131-real-face-device-cue-false-positive).

The automatic controller retains its own read-only credential key session in memory until disabled, quit, account/enrollment/password change, or a failed/unconfirmed submission. Plaintext is decrypted only around guarded submission and is not cached. The manual credential vault retains its separate 90-second policy. Every submission requires the fresh matching locked account and code-signature-verified Apple loginwindow secure field, with checks throughout input and no global keyboard fallback. Unconfirmed/partially failed submissions turn automatic unlock off instead of retrying. No login item is installed.

Version **0.12.4** opens the password prompt after a face match by pressing Return once through the system event stream, after verifying the locked account and Apple loginwindow. It waits at least 500 ms for the prompt animation, keeps scanning for fresh matching evidence, then verifies the secure field before entering the password. This also handles macOS reporting a focused secure field behind the lock-screen cover. The saved password is accessed only after this opening step; password entry and its final Return remain directed only to verified loginwindow. Version **0.12.9** fixes desktop-return confirmation when an unlock notification arrives before the lock-state report updates. Confirmation resets the lock-cycle allowance, and late cleanup events preserve the successful result so the notch dismisses and the next lock can scan.

Version **0.12.10** combines prompt opening and password preparation in the same matching-frame callback, replacing the 500 ms wait and mandatory additional camera frame. After the opening Return, a verified ready secure field permits immediate guarded submission with the current fresh match. If the field is unavailable, scanning continues and preparation retries without repeating the opening key. Account, focus, evidence-age and one-shot submission checks remain in force. macOS can report the field before its animation finishes; reliable delivery during that transition still requires live acceptance on the owner's Mac.

Version **0.12.7** keeps only the blue face icon during prompt opening/password input/desktop confirmation, without loading text or a spinner. A completed nonmatching face window fails immediately and displays “Try again”. Experimental automatic unlocking allows three recognition attempts per lock, with a one-second camera-off pause between failures. A scan without a usable match expires after six seconds; after three failures it stops and requests password or Touch ID. Display sleep stops the camera and cancels input; waking can use only the remaining attempts. A new desktop-to-lock cycle resets the allowance. Green “Unlocked” appears only after desktop return, and other terminal errors show orange “Failed”. A single private local report at `~/Library/Application Support/FaceUnlockDevelopment/last-lock-attempt.json` records mode, stage, failure category, input/submission flags, timing and aggregate frame counts; it contains no images, embeddings, similarity scores, account IDs or passwords and replaces the prior report. Different/borderline windows end an attempt without opening the password prompt, and camera shutdown does not block delivery of fresh matching evidence. Camera cleanup is joined before another attempt can start. Live lock-screen acceptance for the simplified flow remains pending.

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

Version **0.11.0** reuses camera configuration between captures and schedules comparison analysis from fresh camera frames before expensive image processing. Automatic unlock retains its original 12-frame policy. **Tools → Test my face → Window evaluation** compares the original window against a desktop-only six-frame candidate and records labeled outcomes for genuine, other-person and photo/video presentations in memory. The lock-attempt report now includes startup/analysis/scan timings. See [performance changes and evaluation procedure](docs/RECOGNITION_PERFORMANCE.md). Hardware speedup and real presentation results remain unmeasured.

Version **0.11.1** refreshes notch-window lock-screen attachment after ordering and during active display, and forces initial content layout before attachment. Reports now record whether the private window bridge was available and whether attachment succeeded. `last-failed-lock-attempt.json` retains the latest experimental unlock failure independently of the latest attempt, with rejection counts and peak usable-frame count. No images, similarity scores or passwords are included. A successful later scan no longer erases failure evidence. Actual lock-screen visibility and the owner's intermittent recognition failures still require live confirmation.

Version **0.11.2** prepares the private notch window bridge from the desktop before camera/model preparation. Version 0.11.1's live report showed 21 attachment attempts with the bridge unavailable: a failed first initialization was permanently cached. Initialization failures are now retried at most once per second, and reports identify the failed initialization stage. No recognition or password-entry policy changed. Lock-screen visibility still needs a live owner check.

Version **0.12.0** starts recognition before waiting for loginwindow's password field, keeps scanning for fresh evidence while that field loads, and can reveal a hidden prompt with one PID-directed non-secret Space key after a face match. The indicator distinguishes field preparation from scanning. Geometric continuity uses face-relative motion and overlap; clear match/nonmatch transitions reset evidence, and the newest frame must independently match. Multiple faces, missing/poor-quality observations and expired evidence still block a match. See [readiness and continuity changes](docs/RECOGNITION_PERFORMANCE.md#0120-readiness-and-continuity-follow-up). Live end-to-end owner verification remains pending.

Version **0.12.1** validates both application-level and system-level focused elements. A non-secure/stale application element no longer masks a valid system secure field; two conflicting valid targets fail closed. Secure-field discovery starts from loginwindow's focused window when available, rather than traversing every window. Input diagnostics record only the failed stage/check, fixed application category, attribute name and AX error code; field values, titles, passwords and arbitrary app names are never read or recorded. This addresses a lookup defect found after the owner reported repeated successful face matches while a visible password field remained pending. Live resolution of that intermittent failure remains unverified.

Version **0.12.2** corrects the notch bridge's handling of void private window-server functions and verifies actual overlay space membership, including system spaces. It also searches loginwindow's explicit window list when AXChildren is empty, and revalidates the prepared secure field during input instead of repeatedly walking the entire tree. Reports retain the original focus-query failure. This addresses the two blockers recorded in the owner's 0.12.1 report. The owner confirmed that the notch appears and the Mac unlocks automatically on 0.12.2; the matching report confirms successful attachment, one password submission, desktop return and no failure. This is one live acceptance test, not a broad reliability or accuracy evaluation. See [the detailed fixes and native verification](docs/RECOGNITION_PERFORMANCE.md#0122-real-overlay-placement-and-ax-window-roots).

The notch indicator keeps the green Face ID icon visible during scanning and processing, with occasional eye blinks and a gentle glow pulse. Only confirmed desktop return plays the fast sphere-to-checkmark flourish (about 0.63 seconds). Failure turns the same face sad and shakes it, without visible text or a replacement symbol. The animation targets 60 Hz, matches the hardware notch width (180 points on displays without a notch), and respects Reduce Motion. **Preview indicator** plays the success sequence without starting a scan or submitting a password.
