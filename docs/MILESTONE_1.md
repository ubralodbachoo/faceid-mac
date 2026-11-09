# Milestone 1 — manual password-entry feasibility

Status: observation-only passed and the first one-shot password unlock was reported successful by the user. Remaining hardware and failure/fallback acceptance is pending. Face recognition and liveness are not connected to this harness.

## What is built

- Local AES-256-GCM ciphertext with format/UID-bound authenticated data. No plaintext credential file.
- A 256-bit encryption key in a separate, nonsynchronizing development login-Keychain item with a creator-app ACL.
- macOS LocalAuthentication before key loading and deletion. Successful system authentication authorizes an app session for at most 90 seconds, including time asleep. Save/read does not extend the lease.
- Authenticated replacement and deletion, explicit revocation, restart-locked behavior, and refusal to generate a replacement key over orphaned ciphertext.
- Observation-only and credential-submission tests. Each must be explicitly armed from the current account's desktop and expires after 60 seconds. No automatic retries.
- Fresh lock/account checks and Accessibility checks, plus focused enabled secure-text-field ownership by code-signature-verified Apple loginwindow. Only PID-directed events are used. If any guard fails, no credential is submitted.
- A camera option that checks one frame during a locked-session test and discards it. No microphone or image persistence.
- A report containing environment/permission metadata and recent outcome messages, never credentials, camera frames, or embeddings. History stays in memory.

## Development protection policy

The ad-hoc development build uses the file-based login Keychain with an app-specific ACL and an app-enforced LocalAuthentication gate. It does **not** claim Keychain-enforced userPresence, Secure Enclave protection, or production credential isolation. This is an explicit development design, not a silent fallback from another backend. The deprecated file-Keychain APIs produce expected SDK warnings. A distribution build needs the provisioned data-protection Keychain design and a reviewed migration.

The cached key can survive a brief sleep inside the 90-second lease so the wake test is possible. An inactive-account notification, explicit revoke, app quit, expiration, or completion of a live submission clears it. A canceled or late authentication result cannot reactivate a revoked session.

Swift strings, Data, CryptoKit, and CGEvents can retain internal copies; resetting temporary buffers is best effort, not a guarantee that every memory copy was erased. Do not use a production credential for unreviewed distribution builds.

## Start with an observation-only test

1. Build with `./scripts/build-app.sh` and open `build/Face Unlock.app`.
2. Use **Accessibility setup…**, then personally enable this development app in System Settings. Return to the app and refresh status. Granting permission alone does not arm a test.
3. To test camera availability, use **Camera permission…** and enable **Check one camera frame while locked**. The OS permission must be granted by the user; the probe never asks for it while locked.
4. Choose **Arm observation-only test**, then lock your Mac normally and keep your own account's password field focused. Do not switch accounts during an armed test.
5. Return using normal macOS authentication and inspect the test report. A locked-session report, camera frame, and verified secure field are separate results. If focus cannot be verified, stop and report that result; do not weaken the guards or add global input as a workaround.

The undocumented `CGSSessionScreenIsLocked` flag may be absent. Absence remains unknown. Apple loginwindow may not expose the required Accessibility focus or may ignore PID-directed Unicode events on a particular OS. These are unresolved compatibility questions until tested on the target Mac.

## Credential and one-shot submission test

Only perform this after the observation-only test succeeds on the intended account.

1. Choose **Authorize session…** and complete the actual macOS authentication prompt yourself.
2. Enter the account's Mac password into the app's secure field and select **Save encrypted password**. Never send it in chat, screenshots, terminal arguments, or a test report. Saving encrypts it but does not establish that it is the correct login password.
3. If necessary, authorize again so the lease has sufficient time. Enable the explicit one-submission consent and choose **Arm one password submission**.
4. Within 60 seconds, lock the Mac normally. Keep your account selected and its secure password field focused. Let the test attempt run. Do not type into the field during submission.
5. The app submits at most once and then revokes the credential session. If nothing happens, unlock normally with the system's password or Touch ID. No app overlay blocks that route.
6. Return to the app. Use **Desktop reached without fallback** only if the submitted credential actually returned you to the desktop without manual password/Touch ID input. Otherwise choose **Password / Touch ID fallback needed**.
7. Copy the text from **Test report** to report the outcome. An API submission message or a fake preview is not proof of unlock. Desktop confirmation is explicitly recorded as a user report, not independent programmatic evidence.

The lock/session APIs are advisory, not an atomic binding to loginwindow's selected account or secure field. The single-account manual test relies on the user selecting their own account; broader account selection must not be advertised as supported without additional validation. The input path rechecks PID, Apple signature, field identity, lock state, account, and lease before each event packet. No global event tap fallback is allowed. If a check changes after partial input, the test stops without submitting Return; normal password fallback may require clearing that partial field.

## Current packaged-app check

The version 0.2.0 development app builds and its ad-hoc signature verifies. Its live window was inspected with no saved credential, a disabled password field and submission button, missing Camera/Accessibility permissions, and no armed test. No system authentication, permission grant, credential entry, camera capture, or keyboard submission was performed by the agent. The app is open for user-driven observation-only acceptance; this is not a completed live unlock.

## First user observation report

The user's report from the version 0.2.0 app on Mac14,2 / macOS 26.6.2 (25G83) captured **unknown → current account reported locked → unknown** in the session history. App, console, and session UIDs were 501. This establishes that the locked flag was observed during a real user lock cycle; disappearance after return still remains unknown rather than independently verified unlocked.

The manual test did not arm because Accessibility was missing. No credential was stored and the credential session was locked. Inspection of System Settings showed a Face Unlock switch already on, but Refresh status and a same-binary app restart still reported missing permission. A stale or mismatched development-build permission entry is the working explanation, not a proven diagnosis. After exact-app re-registration, the user reported **Accessibility: granted**. No rebuild/re-sign was performed during the repair. The next observation-only test armed at 16:03:15 and expired at 16:04:15 with **Screen lock state is unknown** and no logged focus check. Inspection of the full app history resolved the timing: its locked-session observation was timestamped 16:05, after the test expired at 16:04:15. A new foreground, user-armed test is needed; this is not a failed password submission, since no credential was stored or read. An automated AX click was rejected by the existing foreground-app arming guard and did not arm another test.

If this recurs after a development rebuild, remove only this app's stale Accessibility entry, then re-add `/Users/ubralodbacho/github/faceid-mac/build/Face Unlock.app` and enable it yourself. Authenticate only in macOS's own prompt. Restart the same app and refresh its permission check. Do not reset other applications' TCC permissions or bypass the Accessibility guard.

## Controlled observation-only test passed

On November 9, 2026, the agent opened the exact current build through Finder (which activated it), armed **observation-only** at 16:11:23, and locked the Mac using Control–Command–Q. The app briefly reported the focused application was not yet verified at 16:11:29, then recorded at **16:11:30**: **Observation-only test passed: locked account and secure field verified. Camera: not tested. No password submitted.** The user subsequently unlocked normally and the recorded result was read from the app.

This verifies the current build can observe the account's locked state and Apple's loginwindow secure field while locked. It does not prove event delivery, stored-password correctness, credential-session behavior under a real authentication prompt, camera capture, or an automatic desktop return. No app rebuild or permission change was needed after Accessibility repair. That observation-only stage was followed by the separately authorized credential test below.

The displayed report's environment fields refresh when its view re-evaluates, whereas session observations update separately; its screen-state line can therefore reflect an earlier sample. Submission guards always make fresh reads. Treat the timestamped events as the test evidence, not an unrefreshed report screen-state line.

## First one-shot password test — user-reported success

The user privately completed macOS authentication, saved the password encrypted, checked one-submission consent, and replied ready. The initial credential lease expired before arming, and the app correctly disabled submission. The agent opened a new macOS authentication prompt; the user completed it and the existing ciphertext was reused without re-entering the password.

The agent armed one submission at **16:18:36** and locked the Mac. At **16:18:44**, the app first waited for Apple loginwindow to become the verified focused application and then recorded **One password attempt submitted to verified loginwindow PID**. The credential session was subsequently locked, and no new test is armed. The camera option was off.

The user initially selected fallback needed, then explicitly corrected this with **Mac return to desktop automatically**. The latest clarification is recorded as a user-reported successful desktop return, superseding the earlier fallback selection. The report proves the app reached its submission path; the desktop outcome is based on the user's clarification, not independent attribution by the app. The in-app confirmation marker was not changed by the agent because the foreground confirmation guard prevented the automated click; the outcome is recorded here.

This establishes the first positive feasibility result on this Mac/build. It does not establish repeated sleep/wake reliability, spoof resistance, camera capture while locked, or complete failure/fallback acceptance. No extra submission, credential access, permission change, rebuild, or re-sign was performed to record the correction.

## Acceptance matrix

| Requirement | Current evidence | Remaining live check |
| --- | --- | --- |
| Target environment | Development host previously observed as Mac14,2 / M2 Air, macOS 26.6.2 (25G83); report includes current model/OS/architecture/bundle | Record the exact app/permission configuration during test |
| Encryption and storage lifecycle | Synthetic lifecycle tests; user saved ciphertext and reauthorized the real app before its successful submission path | Actual restart/re-sign continuity, replacement and authenticated deletion |
| Keychain adapter | Isolated opt-in synthetic key round trip passed; item deleted | App signature continuity and real session authorization |
| Session/account observation | Matching UIDs and unknown → locked → unknown captured in the user’s real lock-cycle report | Sleep/wake, fast-user switching, and repeated locked-state sampling |
| Focus and delivery | Secure field verified at 16:11:30; PID-directed password submission at 16:18:44 followed by user-reported automatic return | Repeat delivery, different layouts/Unicode passwords; no global fallback |
| One-shot/expiry/cancellation | Deterministic tests reject missing guards, duplicate permits, expired/reversed time and late auth | Cancel/permission revocation during real lock/wake |
| Camera while locked | Optional frame probe implemented; no frames retained | Granted camera permission and actual locked-session frame |
| Actual desktop return | First one-shot submission followed by latest user report of automatic return, superseding earlier fallback selection | Repeat trials and sleep/wake; independent outcome attribution is not implemented |
| Incorrect/changed password | No automatic retry, fixed limits and normal system fallback path | On a designated test account, record one failed attempt and normal fallback; never brute-force |
| Restart/expired session | Restarts have no cached key; 90-second continuous lease tested | Restart app and try arming without authorization; sleep past lease and verify no input |
| Touch ID and normal password | No authentication policy, PAM, SIP, FileVault or system password changes | Confirm ordinary macOS authentication remains usable |

**The main feasibility test has its first user-reported positive result. Milestone 1 remains incomplete until the remaining hardware and failure/fallback checks pass.** A single successful trial does not establish reliability or authorize more credential submissions.

## Automated verification

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" swift test --disable-sandbox
```

The normal run contains 21 tests: 20 pass and one real-Keychain integration test is skipped by default. The opt-in test has also passed separately using a randomly named synthetic key and removes that item. It does not test LocalAuthentication UI, real passwords, key access after re-signing, camera capture, AX focus while locked, or actual event delivery.

For the isolated Keychain adapter check (no real credentials):

```sh
FACEUNLOCK_RUN_KEYCHAIN_TEST=1 CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" swift test --disable-sandbox --filter CredentialVaultTests/testOptInRealKeychainRoundTripUsesDisposableSyntheticKeyOnly
```

The terminal diagnostic remains read-only: `swift run --disable-sandbox FaceUnlockDiagnostics`. It reports session fields and focus eligibility without retrieving credentials or posting events.

## Data removal and recovery

Use **Revoke / cancel** to stop a test and clear the in-memory key. **Delete stored password…** confirms intent, authenticates with macOS, deletes the key first, then removes ciphertext. If key deletion fails, ciphertext is left in place. If only file removal fails, the remaining ciphertext has no key and the error is reported; repeat deletion to finish cleanup.

Ciphertext: `~/Library/Application Support/FaceUnlockDevelopment/credential-v1.enc` in a private owner-only directory, excluded from backup. Keychain service: `org.faceunlock.development.credential-key.v1`, account: current numeric UID, label: **Face Unlock development encryption key**. This is separate from all archived prototype data. Deleting just the app does not remove these items.

Ad-hoc rebuilds can invalidate Keychain/Accessibility trust. The app fails instead of broadening its ACL or generating a replacement key over existing ciphertext. Restore the intended app's trust through macOS settings/Keychain Access or explicitly delete/recreate the development credential. Do not change the Mac's login password or reset its Keychain to repair this app.

There is no helper, login item, installed authorization mechanism, or system policy to roll back. Quit the app to stop monitoring; revoke permissions in System Settings if desired. The archive stays untouched.
