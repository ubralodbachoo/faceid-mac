# Development skeleton

## Dependency direction

```text
FaceUnlockApp ──→ FaceUnlockMac ──→ FaceUnlockCore
       └────────────────────────→ FaceUnlockCore
```

The app constructs the macOS readiness provider and passes it into its model. The view reads the model and can request another read-only inspection. The core owns setup requirements without importing Apple UI, camera, or security frameworks. The macOS module owns platform API calls.

`ReadinessProviding` is the only service interface needed now. Add operational service interfaces with their first working implementation instead of speculative camera, password, or model APIs. There are no mock success services in the production app.

## Current behavior

- Every setup requirement is enumerated in `Component`.
- A missing status defaults to `notImplemented`, so adding or omitting a component cannot silently complete setup.
- The macOS adapter only inspects existing Camera and Accessibility authorization. Availability says nothing about hardware availability, camera capture while locked, or permission to submit a password.
- Credential storage, lock/account verification, recognition, liveness, and password entry remain unimplemented.
- `isSetupComplete` is a configuration diagnostic. It must never authorize a credential read or password submission. Those need fresh per-attempt checks in the future coordinator.
- The diagnostic view always describes unlocking as inactive. There is no enable switch or success animation.
- There is no persisted app state, auto-start item, background helper, model, or biometric/credential storage.

## Next implementation increments

Stay within roadmap Milestone 1 until real lock-screen entry is proven:

1. Add read-only lock/account observation and diagnostics. Verify the observed states on the target Mac; unknown or stale state must block attempts.
2. Define the encrypted credential vault and its system-authenticated session lifetime. Implement save, replace, delete, expiry, and restart behavior before exposing password entry.
3. Add a manually triggered, controlled password-entry experiment with fresh lock/account/focus checks, one submission per attempt, cancellation, and a bounded deadline. Record submission separately from observed desktop unlock.
4. Validate ordinary password fallback, permission loss, incorrect/changed credentials, app restart, and wake timing.

Do not connect a face match to password entry until the roadmap's model, enrollment, and liveness gates pass. The manual Milestone 1 experiment and eventual biometric flow must have separate explicit entry points.

Future integrations belong in `FaceUnlockMac`, domain decisions in `FaceUnlockCore`, and composition in `FaceUnlockApp`. Add a separate inference module only if model integration creates a concrete need. No authorization plug-in or Candidate B work is planned.

## Development identity and packaging

The development bundle is `org.faceunlock.development`, separate from the archived `org.faceunlock.lab`. `scripts/build-app.sh` builds the Swift package, creates a `.app`, and applies an ad-hoc signature. Camera usage text and entitlements must be added when actual camera capture is implemented. Developer ID signing, hardened runtime, notarization, model licensing, and clean-Mac installation remain release work.

No changes to authorization policies, SIP, FileVault, system credentials, or the old prototype's data are part of this skeleton.
