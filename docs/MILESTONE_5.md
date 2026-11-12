# Milestone 5 — lock-screen flow foundation

November 12, 2026 · Development version 0.9.1 · Started, not complete.

## Current: 0.9.1 — investigate the generic lock-icon failure

The owner reported rejection after enablement, with only the generic lock icon and no error text. The exact live failure is unclassified: that icon represented recognition, timeout, credential/focus and input errors alike. No computer-control session was started for this investigation.

Two reproducible code defects are corrected. First, the scanner no longer returns immediately on its first different/borderline 12-frame window; rolling comparisons can acquire a later match within the existing 15-second attempt. Second, matching evidence is returned after requesting camera stop, without waiting for `stopRunning` to finish. Camera teardown is joined after the guarded attempt while the coordinator remains busy, preventing overlap. This avoids spending the unchanged 750 ms freshness allowance on camera shutdown. Input guards still reject genuinely stale results; similarity, quality, sample-count and account/focus checks are unchanged.

The indicator shows a short failure caption for four seconds, distinguishing scan-only mode, identity failure, timeout, expired evidence, missing Accessibility, password-field focus, credential authorization and unconfirmed input. The desktop page retains the same category. One atomic private report, `~/Library/Application Support/FaceUnlockDevelopment/last-lock-attempt.json`, contains app version, timestamp, active mode, failure stage/outcome/category, input-consumed versus submission flags, evidence timing, and aggregate frame counts/last acquisition issue. It excludes images, embeddings, scores, account IDs and secrets. Writes run on a serial background queue and replace the preceding report; directory/file permissions are 0700/0600, with symlink rejection. Setup failures cannot inherit input/frame metadata from an earlier attempt.

Validation: **161 tests completed: 158 passed, three opt-in integrations skipped, zero failures**, with compiled-model Vision/Core ML enabled. Added regressions cover negative/borderline warm-up followed by a match, deadline enforcement, deferred camera joining, no overlapping attempt during cleanup, classified mode/stage reports after revocation, report reset, private atomic storage and symlink rejection. The actual owner rejection is not claimed resolved until a new live attempt succeeds or supplies the classified report. The owner must quit/reopen the rebuilt app and privately re-enable the intended mode; computer control stays off.

## 0.9.0 — explicitly experimental face-triggered unlock

Live inspection after the owner's latest report found **Face looks similar / Scan-only test complete / No password entered**. Recognition during the locked scan worked; the live composition had no enabled password path. Version 0.9.0 adds that path under an explicit experimental mode. The normal verified-biometric policy remains strict. Liveness stays unavailable, and the experimental match is named separately; nothing reports a PAD pass that was never measured. Photos, videos and false matches can unlock in this mode.

Acknowledge that risk before choosing **Enable face unlock…**. macOS then authorizes reading the saved face and the stored encrypted password. A separate read-only credential key session lasts while the opted-in app session is active, including sleep; the manual vault's 90-second lease remains unchanged. No plaintext password is retained between attempts. Changing the saved credential invalidates its authorized digest and revokes the mode. Disable, quit, account/enrollment changes, consumed input errors or unconfirmed desktop return revoke authorization. Nothing is enabled on restart.

Each fresh lock or genuine sleep/wake permits one 12-frame comparison and at most one password submission within the existing 15-second scan window. The same account, lock, fresh same-attempt evidence, Accessibility grant and Apple-signed loginwindow secure field are checked before and during PID-directed input. No global typing fallback or retry after partial input exists. The ordinary password/Touch ID route remains usable.

The black panel follows the supplied image: hardware-notch width, expanded downward with a large blue face icon, rounded bottom corners, and no camera image. An isolated optional private SkyLight bridge follows [Glance's window-space approach](https://github.com/jonnyoo/glance/blob/main/glance/NotchOverlay/NotchSkyLight.swift). The bundled Glance MIT license covers that reference. Window-level changes alone had not established lock-screen visibility. Private APIs may change and require live OS acceptance; their failure never grants input permission. A checkmark requires a submitted attempt followed by corroborated desktop return, rather than the match alone.

### Private end-to-end test

1. Under **Lock screen**, use **Password setup…** only if the encrypted Mac password has not been saved. Enter it privately inside the app, never in chat or terminal arguments. Its correctness is not known until a real test succeeds.
2. Use **Accessibility setup…** if needed for the rebuilt exact app. Return to **Lock screen**, read and check the photo/video-risk acknowledgement.
3. Choose **Enable face unlock…** and complete the macOS authentication prompts. Wait for **Face unlock · On**. Do not choose **Enable scan only** when testing password entry.
4. Lock normally and look toward the camera. Expect the reference-style indicator, one face comparison, and one guarded submission. A checkmark follows corroborated desktop return. If input or confirmation fails, unlock normally; the app disables automatic unlocking rather than retrying.
5. Return to the app and inspect its recent phase/error messages. Repeat successful cycles, then test sleep/wake and turning off separately. Do not run the separate manual password experiment concurrently.

Live 0.9.0 password submission, desktop return, lock-screen placement and repeated cycles remain pending. The owner has not yet accepted the experimental mode through its acknowledgement/system-authentication UI. This increment does not complete calibrated recognition, PAD evaluation, durable release throttling, distribution licensing/signing or FileVault/preboot login support.

### 0.9.0 validation and handoff

The native regression suite completed **152 tests: 149 passed, three opt-in integrations skipped, zero failures**, with compiled-model Vision/Core ML enabled. Tests cover explicit experimental-policy selection, risk acknowledgement and credential authorization, ciphertext binding, separate manual versus app-session credential lifetimes, repeated per-lock submissions, missing/rejected/stale evidence, cancellation before input, partial/unconfirmed submission shutdown, checked unlock-notification completion and expanded notch geometry. The app package and ad-hoc signature were verified. The old 0.8.1 scan-only process was quit on November 12 and the built 0.9.0 app opened. The saved enrollment, expanded reference-style artwork, unchecked risk acknowledgement and disabled-until-acknowledged **Enable face unlock…** control were inspected in the running app. The agent did not acknowledge or enable the mode on the owner's behalf. Private owner authentication and live end-to-end lock/unlock results are pending.

## Historical: 0.8.1 — every lock and notch-sized indicator

The owner requested scanning on every lock without one-time manual arming, and reducing the black indicator to notch size. **Enable on every lock…** authenticates once on the desktop and prepares the model/camera permission. The face template then stays in memory specifically for automatic scanning while the app is open. The encrypted vault's key is dropped after loading; its 90-second lease is unchanged. This new cache lifetime is explicit user-authorized scan behavior, not a credential lease or password authorization.

Each fresh matching-account lock starts one hidden-camera scan, up to 15 seconds. Explicit unlock observation resets the cycle; if macOS omits its desktop lock flag, a delivered unlock notification plus a fresh same-account desktop observation can reset it. Unknown observations alone cannot reset or start anything. Genuine sleep/wake can start a fresh scan; duplicate wake/lock notifications cannot. Sleep cancels capture but retains the automatic scan session for wake. Turn off, quit, account/session changes and enrollment replacement/deletion clear the cached template. The mode does not survive restart and does not install a login item. Re-enable after reopening the app. Authentication/permission sheets are allowed up to five seconds to restore foreground before setup fails.

The panel now matches the gap between macOS's unobscured top-left/top-right screen rectangles. Its icon sits in a **28-point strip below the notch**, since the hardware notch would obscure an icon drawn inside it. The prior 150×126-point drop-down is removed. Notchless displays use a 180×28-point strip. Main app artwork is also compact. Lock-screen appearance and repeated lock/wake operation still need private live acceptance.

**Automatic scanning does not enable automatic password entry.** The shipped composition remains scan-only with unavailable calibrated identity/PAD. The older one-time test remains as a secondary control; its instructions below apply only to that control.

### Historical 0.8.1 private test

1. Open **Lock screen → Preview indicator** to check the smaller panel without camera access.
2. Select **Enable on every lock…**, complete macOS authentication privately, and wait for **Every lock · On**.
3. Lock normally. Expect one scan with no camera preview. Return using password/Touch ID. Repeat several lock/unlock cycles without rearming.
4. Test sleep/wake separately. Use **Turn off** to stop monitoring and clear the retained template.

Version 0.8.1 validation: **139 tests completed: 136 passed, three opt-in tests skipped, zero failures** with compiled-model Vision/Core ML enabled. Added coverage exercises repeated locks without new authentication, operation after the original read lease is revoked, duplicate lock/wake signals, unknown desktop lock flags plus checked unlock signals, actual sleep/wake cycles, disabling during in-flight analysis, account/enrollment invalidation, failed enablement, post-authentication foreground restoration, and notch gap sizing on an offset display. The packaged app was relaunched and the new every-lock control and smaller in-app indicator illustration were inspected through accessibility and a screenshot. The agent did not enable the mode, authenticate or lock the Mac; enabling remains a private user action.

Before restart, the old 0.8.0 one-time page displayed “The locked Mac account could not be verified.” Its cause was not isolated. This must not be treated as a successful live lock-screen scan or as resolved by synthetic repeated-lock tests. Verify actual account/lock observations and overlay visibility during the next private test.

The remainder of this document records the original 0.8.0 foundation and its one-time test.

The owner requested starting Milestone 5 with the compact lock-screen presentation shown in the attached images and 0:06–0:10 of the supplied Glance launch movie. That segment was reviewed locally at two frames per second. It shows a black top-center panel, blue scanning face icon, and a checkmark around the transition to the desktop. Review frames are temporary; no movie or screenshots are bundled into the app.

## Historical 0.8.0 implementation

- **Lock screen** app page, **Preview indicator** (camera off), and **Test lock-screen scan…**.
- A native borderless nonactivating panel, black with rounded lower corners and a blue icon. It does not become key/main, intercept the pointer, replace the macOS password UI, display a camera image, or request screen recording. Built-in notch geometry and nonzero screen origins are handled. Reduced motion leaves a static indicator.
- Desktop authentication opens the existing encrypted face template. Model validation and Camera permission happen before arming. One explicit arm waits at most 60 continuous seconds for a fresh locked observation of the same account. A single hidden-camera scan runs for at most 15 seconds, including camera startup, using the unchanged 12-frame comparison policy.
- Sleep/session changes, cancel, account changes, lease loss, camera errors, manual unlock and expiry stop capture and reject late results. Repeated triggers cannot extend an attempt, start overlapping work, or cause retry. No activation/focus requirement is imposed on a locked scan.
- A one-shot domain permit and guarded password submitter, ready for a later calibrated identity/PAD provider. Verification must be fresh, bound to the same attempt, and independently pass identity and liveness. Consumption precedes credential reading/events; final Apple loginwindow secure-field/account/lock/credential checks remain in the existing input adapter.
- Submission and observed desktop return are separate phases. A checkmark requires a submission followed by an explicit same-account unlocked observation. Submission alone or manual unlock while scanning cannot display success. A later desktop observation alone cannot independently attribute the unlock to this app.

## Historical 0.8.0 live boundary

**The shipped flow is scan-only and cannot enter a password.** Its submission gate is off in application composition, without a user-facing override. The scanner explicitly reports authenticated identity and liveness as unavailable for a diagnostic match. It does not port Glance's heuristic liveness, fabricate PAD evidence, relax cutoffs, or authorize the credential vault. The existing manually armed password experiment remains separate.

This allows starting Milestone 5 without silently treating unfinished Milestone 4 as complete. Calibrated identity thresholds, evaluated print/display/video protection, durable authentication throttling and customer enablement/credential-session design remain necessary before automatic unlocking. Current arming is temporary and never survives restart. There is no login item, unattended automatic enablement, persistent retry, or authentication-policy change.

## Historical 0.8.0 private test

1. Open **Lock screen** and choose **Preview indicator**. Expect a compact black panel at the top center for three seconds, a blue face icon, no camera activity, and no keyboard-focus change. No success state is simulated.
2. Choose **Test lock-screen scan…**. Complete the system authentication privately. Grant Camera permission if requested. Wait for **Ready for one lock-screen scan**.
3. Lock the Mac normally within 60 seconds. Do not put a password into chat or terminal arguments. Expect a scanning indicator without a video preview. Its visibility above loginwindow must be verified on this Mac; the chosen window level alone does not establish it.
4. Let the one comparison finish or time out, then return using the ordinary password or Touch ID. An orange fallback indicator may appear briefly; **no face-triggered password submission occurs in 0.8.0**.
5. Return to **Lock screen** to read the last feedback/recent events. Report whether the indicator appeared and whether the camera stopped. Test no face, another face, denied/revoked permission, manual unlock during scanning, cancel, sleep, and account switch separately.

Do not run the separate manual password experiment concurrently. The app gates other face/credential work while a lock-screen test owns the camera. Images and scores are not retained; recent phase/error strings stay in memory.

## Historical 0.8.0 acceptance remaining

Live lock-screen overlay visibility, notch/notchless placement, external displays, sleep/wake capture availability and normal password/Touch ID operation remain unverified by this increment. Repeated genuine/impostor/spoof evaluation and production credential policy are Milestone 4/5 follow-up work. End-to-end face-triggered unlocking is not accepted as complete.

## Historical 0.8.0 validation

The native suite completed **131 tests: 128 passed, three opt-in tests skipped, zero failures**. The skipped tests are the two disposable Keychain integrations and local reference-video replay. Compiled-model Vision/Core ML integration was enabled. Twenty new tests cover permit consumption, independent identity/PAD gates, same-attempt/fresh evidence, explicit lock/account/focus/credential preconditions, arm/scan expiry, late cancellation, sleep, account changes, manual unlock, missing leases, failed input with no retry, submission versus desktop observation, hidden-camera temporal aggregation and indicator geometry.

The 0.8.0 development package was built, signed and relaunched. The saved enrollment was found, and the **Lock screen** page was checked through accessibility and a screenshot. **Preview indicator** was exercised without starting a camera test or system authentication; accessibility still reported the main Face Unlock window as focused. The capture was scoped to the main app window, so it does not independently establish the top-center overlay's actual position/appearance or lock-screen visibility. Those remain part of the private live test above. No Mac lock, credential authorization or real password submission was triggered by the agent.
