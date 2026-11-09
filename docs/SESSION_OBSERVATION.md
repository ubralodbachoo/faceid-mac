# Session observation — step 2 baseline

The current Milestone 1 manual harness builds on this observation layer. The nine-test result below records the earlier step-2 baseline; see [the current runbook](MILESTONE_1.md) for expanded validation and remaining live checks.

## What is implemented

`MacSessionReader` reads the process UID, primary console UID from `SCDynamicStoreCopyConsoleUser`, and the current Quartz GUI session dictionary from `CGSessionCopyCurrentDictionary`. It compares process, console, and session UIDs, on-console status, and login-complete status. No username, credential, image, or embedding is stored.

The `CGSSessionScreenIsLocked` dictionary flag is undocumented and is only a diagnostic signal. Only an explicit CFBoolean becomes a locked/unlocked report. An absent flag stays unknown; numeric/string lookalikes are rejected. These independent API reads are not an atomic session/account transaction and do not establish secure-field focus.

`SessionSnapshot` evaluates the observation against monotonic uptime. Missing or malformed account fields, mismatching UIDs, inactive sessions, incomplete login, unknown lock state, future timestamps, and observations older than two seconds cannot produce the diagnostic `observedLocked` classification. Even that classification does not authorize credential access or keyboard submission.

`MacSessionMonitor` samples once per second while running. Sleep and inactive-session notifications invalidate the snapshot immediately. No new snapshot is read until the relevant wake and active-session signals have resumed the session. The first post-transition state is unknown until the next read. Stopping observation cancels polling and invalidates the snapshot. There is no automatic restart after quitting the app.

The app retains up to eight distinct assessment summaries in memory and displays the last three with local times. This history is only for reviewing transitions after returning to the desktop; historical entries must never drive an unlock. Nothing is written to disk. Closing the app discards the history.

The setup table deliberately shows **Diagnostics only** for lock/account verification. It remains a blocker even if the observed account matches and the lock flag is present.

## Validation performed on November 9, 2026

- Swift build and all nine tests passed. Tests cover incomplete setup, malformed fields, mismatched accounts, unknown lock state, stale/future timestamps, and monitor invalidation/stop behavior. Lifecycle tests post local synthetic notifications; they do not put the Mac to sleep or switch accounts.
- A one-shot read outside the execution sandbox returned matching process, console, and session UIDs (501), on-console true, and login-complete true.
- The lock flag was absent. The report correctly remained **Screen lock state is unknown**; it did not infer unlocked from absence.
- The same read inside the restricted execution sandbox could not obtain console/session information and remained blocked as unknown.
- The packaged app was launched and its live diagnostic window and Refresh status button were inspected. No camera, Accessibility, or Keychain prompt was requested.
- No actual lock, sleep/wake, fast-user-switch, or password-entry cycle has been tested. This increment does not complete roadmap Milestone 1.

## Manual target-Mac acceptance procedure

Use the packaged development app with the account you intend to test. This is an observation test only; use macOS's normal password/Touch ID to return to the desktop.

1. Launch `build/Face Unlock.app`. Check that app, console, and session UIDs match, with on-console/login-complete status reported. Missing fields remain unknown. Record the exact Mac and macOS build.
2. Lock the Mac normally, wait several seconds, and unlock normally. Review the in-memory recent changes. Record whether an explicit locked flag was observed; do not count a lock animation, screen saver, or unknown report as a confirmed locked result.
3. Repeat with a real sleep/wake cycle. Check that previous observations are invalidated and the resumed session is freshly sampled.
4. If a second account is available, test fast-user switching. The inactive process must not be classified as the current locked console owner.
5. Quit/relaunch and verify that the history starts fresh. No background observer or login item should remain.

A one-second sampler can miss brief transitions. Session observation is still advisory and needs fresh per-attempt checks plus a separate focus/credential-submission design before password entry can be added. If the lock flag does not behave consistently on the target OS, resolve that integration limitation before attempting automatic input.

## References

- [Apple: CGSessionCopyCurrentDictionary](https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary())
- [Apple: SCDynamicStoreCopyConsoleUser](https://developer.apple.com/documentation/systemconfiguration/scdynamicstorecopyconsoleuser(_:_:_:))
- [Apple: sessionDidResignActiveNotification](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification)
- The current Xcode SDK's `CoreGraphics.framework/Headers/CGSession.h` defines the documented UID/on-console/login-complete fields. It does not define the screen-lock flag used here.
