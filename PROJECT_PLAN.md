# Face Unlock for Mac — functional-first project plan

Functional-first plan · November 9, 2026 · step 1 skeleton implemented; unlock functionality remains unimplemented.

## Current increment

The owner authorized starting a new skeleton after the planning reset. The active Swift package now contains core setup requirements, a read-only macOS permission adapter, a minimal diagnostic app, tests, and a development app build script. The previous prototype remains archived. See [architecture notes](docs/ARCHITECTURE.md).

Next: read-only lock/account observation for Milestone 1. Credential storage and password submission are later increments; UI design remains deferred.

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

The first functional proof is a controlled, manually triggered lock-screen password submission on the declared test Mac, before connecting biometric automation. Use minimal native controls. Selecting the architecture does not start implementation or reactivate the archived prototype.

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

Compare normalized embeddings against enrolled templates with an explicitly calibrated threshold. Set false-acceptance, false-rejection, latency, and retry targets before enabling automatic unlock. Similarity values are not probabilities of identity.

Evaluate held-out genuine and impostor samples under different lighting, distance, glasses, facial changes, and camera conditions. Evaluate printed photographs, displayed photographs, and video replays independently. A blink or head turn alone is insufficient evidence for an anti-spoofing claim.

Acceptance evidence:

- Report measured outcomes and dataset limits rather than claiming security from a few successful demonstrations.
- No face, multiple faces, unknown face, poor input, uncertain liveness, timeout, or canceled attempt cannot cause an unlock.
- Define attempt throttling and verify restarting a component does not bypass the selected policy.
- If video replay remains effective, document that limitation and decide whether the convenience/security tradeoff is acceptable before release.

## Milestone 5 — connect the functional flow

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
