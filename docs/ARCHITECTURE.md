# Functional architecture

## Dependency direction

```text
FaceUnlockApp ──→ FaceUnlockMac ──→ FaceUnlockCore
       └────────────────────────→ FaceUnlockCore
```

The app constructs the macOS readiness provider and passes it into its model. The view reads the model and can request another read-only inspection. The core owns setup requirements without importing Apple UI, camera, or security frameworks. The macOS module owns platform API calls.

`ReadinessProviding` supplies setup inspection. `MacSessionReader` reads a point-in-time session snapshot; `MacSessionMonitor` refreshes it and handles lifecycle invalidation. Add operational service interfaces with their first working implementation instead of speculative camera, password, or model APIs. There are no mock success services in the production app.

## Current behavior

- Every setup requirement is enumerated in `Component`.
- A missing status defaults to `notImplemented`, so adding or omitting a component cannot silently complete setup.
- The readiness adapter inspects existing Camera and Accessibility authorization. Availability says nothing about hardware availability, camera capture while locked, or permission to submit a password.
- Session diagnostics, the development credential vault, and the manual password-entry harness are implemented. Live input/account checks remain diagnostic-only until hardware acceptance passes. Recognition and liveness are unimplemented. See [session observation notes](SESSION_OBSERVATION.md) and [Milestone 1 runbook](MILESTONE_1.md).
- `isSetupComplete` is a configuration diagnostic. It must never authorize a credential read or password submission. Those need fresh per-attempt checks in the future coordinator.
- The development view has explicitly armed observation-only and one-shot submission tests. There is no automatic unlock switch or simulated success animation.
- Credentials persist only as AES-GCM ciphertext with a separate development Keychain key. There is no auto-start item, background helper, face model, or biometric storage.

## Next implementation increments

Stay within roadmap Milestone 1 until real lock-screen entry is proven:

1. Implemented: read-only lock/account observation and diagnostics. Actual lock/wake transitions still need target-Mac validation; unknown or stale state blocks an observation from being classified as reported locked.
2. Implemented: the development vault, system authentication gate, 90-second continuous-time lease, save/replace/delete, and restart-locked behavior. Automated tests use synthetic credentials; live system authentication is pending.
3. Implemented: `ManualUnlockController` and `LockScreenInput`. A manually armed 60-second attempt is consumed before reading plaintext. Input is directed only to verified Apple loginwindow PID with a focused secure field. No global event fallback exists. A submission is distinct from a user-confirmed desktop return. Live event delivery is unverified.
4. Pending hardware acceptance: ordinary password fallback, permission loss, incorrect/changed credentials, app restart, and wake timing. See the runbook acceptance matrix.

Do not connect a face match to password entry until the roadmap's model, enrollment, and liveness gates pass. The manual Milestone 1 experiment and eventual biometric flow must have separate explicit entry points.

Future integrations belong in `FaceUnlockMac`, domain decisions in `FaceUnlockCore`, and composition in `FaceUnlockApp`. Add a separate inference module only if model integration creates a concrete need. No authorization plug-in or Candidate B work is planned.

## Development identity and packaging

The development bundle is `org.faceunlock.development`, separate from the archived `org.faceunlock.lab`. `scripts/build-app.sh` builds the Swift package, creates a `.app`, and applies an ad-hoc signature. Camera usage text is included for the optional one-frame probe. The non-sandboxed development app has no microphone capability or camera auto-start. Developer ID signing, hardened runtime, notarization, model licensing, and clean-Mac installation remain release work.

No changes to authorization policies, SIP, FileVault, system credentials, or the old prototype's data are part of this skeleton.

## Credential and manual-attempt boundaries

`CredentialVault` is main-actor isolated and receives key/blob/authentication adapters for deterministic tests. The development adapter uses a creator-app ACL in the file-based login Keychain; LocalAuthentication gates the app's key loading rather than enforcing a hardware ACL. AES-GCM authenticates the format/bundle namespace and UID. Replacement commits a private temporary ciphertext file with an atomic rename. Missing keys never silently regenerate over ciphertext.

`CredentialLease` expires after at most 90 seconds. `ContinuousTime` uses `mach_continuous_time`, including sleep. A cached key may survive a brief sleep only within that lease, enabling the deliberate wake experiment; switching away from the account, revoking, quitting, and finishing a live attempt clear it. Swift/CryptoKit-managed memory cannot be guaranteed completely erased. No decrypted value is logged.

`ManualAttempt` binds the UID and 60-second deadline and consumes the permit before credential reading. `LockScreenInput` freshly checks lock/account/lease and the focused secure field before clearing, each Unicode packet, and Return. Events are PID-directed to code-signature-verified Apple loginwindow; they are never globally posted. Focus unavailable or inaccessible means no submission. This is a feasibility path, not proof that macOS accepts the events.

`LockedCameraProbe` runs capture setup/stop on its own queue and sample callbacks on a separate queue. It returns only success/failure, discards frames, has a bounded streaming wait, and handles task cancellation. Hardware startup may add latency.
