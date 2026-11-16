# Recognition performance and window evaluation — 0.11.0

## Implementation

One `EnrollmentCameraSession` retains the configured AVCaptureSession, camera input/output and CIContext between attempts. Each attempt receives a fresh single-use `EnrollmentCamera` and bounded newest-frame stream. Stop removes the delegate, stops the sensor and finishes that stream. Delayed cancellation and timeouts are bound to the old camera instance; they cannot stop a later capture. Overlapping captures are rejected. No camera runs between attempts. First capture still pays configuration and sensor startup costs; later captures still pay sensor startup costs.

Enrollment retains its previous 90 ms delivery throttle. Desktop comparisons and lock-screen scans receive fresh camera frames without that throttle. `FaceComparisonWindow.shouldAnalyze(at:)` rejects too-early frames before Vision/Core ML work. The scoring code still checks spacing, quality, continuity, gaps and duration. No model, alignment, similarity threshold, unlock evidence age or submission guard changed.

The standard unlock policy remains 12 frames, 10 agreeing, minimum spacing 150 ms, minimum span 1.65 s. In a deterministic 30 fps simulation the new scheduler completes at 1.833 s with 12 analyses, versus 2.2 s and 23 analyses for the former 10 fps delivery. These are synthetic scheduling results, not measured camera or unlock speedups. Real cadence, exposure, analysis costs and rejected frames affect results.

The last lock-attempt report adds camera-startup time, mean completed-analysis time, scan time and scheduled-out frame count. It continues to exclude images, embeddings, scores and secrets. Successful-analysis timing excludes analyses that threw errors; rejected counts remain separate.

## Desktop evaluation

Turn off automatic face unlock, then open Tools → Test my face → Window evaluation. Select the window and presentation **before** starting each camera test. Current uses 12 frames/10 agreement/1.65 s. Candidate uses 6 frames/5 agreement/0.75 s; both retain the same score, quality, spacing and continuity cutoffs. The desktop comparison has no password submission capability. As of 0.12.8, the six-frame candidate is also explicitly selected for the experimental lock-screen trial at the owner’s request.

Trial history retains up to 100 labeled outcomes and total camera-test times in memory. Time includes startup and scanning, excludes system authentication, and is not an end-to-end unlock measurement. Incomplete/canceled trials are retained with no completed duration. Changing windows clears the displayed per-mode average but retains labeled history. Restarting the app clears the history.

Run both modes in alternating order for each presentation:

| Presentation | Expected identity-only result | What to record |
| --- | --- | --- |
| Owner, normal lighting | Similar | Completion rate, startup, median and slow-tail camera time |
| Owner, dim/backlit, glasses and modest pose changes | Similar when usable | Acquisition failures, interrupted windows, latency |
| Other volunteers | Different | Any Similar result is an impostor acceptance |
| Printed owner photo | May be Similar | Any Similar result is a spoof acceptance |
| Owner photo on screen | May be Similar | Any Similar result is a spoof acceptance |
| Owner video replay | May be Similar | Any Similar result is a spoof acceptance |

Start with at least 10 trials per window/presentation, and repeat under several lighting conditions. Keep distance, display brightness, camera and presentation consistent between paired trials. Separate first-capture from subsequent-capture results; count failures and inconclusive outcomes alongside successful trials. Small owner tests are engineering feedback, not population-level accuracy estimates.

Both windows are identity comparisons, not presentation-attack detection. Synthetic repeated matching descriptors are accepted by both, which explicitly demonstrates that requiring more matching frames does not establish liveness. Real owner, other-person and photo/video evaluations require local physical presentations and remain pending. Do not promote the candidate to automatic unlocking based only on faster genuine-face results. Preserve a separate held-out set of trials when making a policy decision.


## 0.12.0 readiness and continuity follow-up

A live 0.11.2 report contained zero analyzed frames and a focus failure. The three-second field preflight ran before camera capture, so an unavailable loginwindow field prevented any recognition. The new flow starts the camera immediately. On a completed face match, field preparation runs; target/field unavailability keeps capture active within the existing 15-second budget. The indicator shows a distinct `waitingForPasswordField` phase. Each later submit opportunity must come from another newly analyzed matching frame, with the evidence-age guard checked again after field preparation. The password submit function is still called at most once.

After a match, a hidden password prompt may be revealed with one non-secret Space key sent directly to the focused, signature-verified Apple loginwindow process. The app checks the locked account first, skips this when the focused element is already a secure field, and never uses global event delivery. Permission, account, cancellation, and final secure-field checks still apply. Target/field transitions may be retried; successful prompt revelation is limited to once per attempt. No wake key, password, or credential access occurs merely because an arbitrary face was detected.

Geometric continuity now compares overlapping boxes and movement relative to face size, instead of a fixed fraction of the entire camera frame. Large scale changes, non-overlap and invalid bounds restart evidence. Full-frame face detection and the exactly-one-face requirement remain in place; this is geometric continuity, not an identity-aware Vision tracker. Match-to-nonmatch and nonmatch-to-match transitions start a fresh evidence window. A result also requires its newest frame to match independently, so older owner votes cannot authorize input on a newer nonmatching face. The scoring cutoff, quality requirements, 12-frame count, 10-vote agreement and 1.65-second minimum remain. The comparison policy is now v5 because continuity/decision behavior changed; unchanged model/preprocessing permits existing saved enrollment to be reused. Accuracy and spoof-resistance equivalence have not been established.


## 0.12.2: real overlay placement and AX window roots

The owner's 0.12.1 report recorded 43 matching windows but no password submission. The overlay bridge rejected initialization with `space-show:81330176`; the input search found no secure field and AXChildren returned AXError.noValue (-25212).

The previous private binding incorrectly interpreted `SLSShowSpaces` as returning a status. Its void return can leave arbitrary register contents, so a zero-result native run did not prove the binding correct. The bridge now treats side-effect calls as void, preserves full-width space IDs, re-shows the space on every attachment, and verifies placement through SLSCopySpacesForWindows. The query includes system spaces (mask 15), which is necessary for the elevated overlay space; querying only mask 7 failed the new native test. The native test moves an unordered invisible panel and asserts actual space membership, rather than merely asserting that initialization returned an object. Visibility above the real lock screen still needs owner observation. See the [SLSShowSpaces declaration in yabai](https://github.com/asmvik/yabai/blob/master/src/osax/payload.m#L57).

Password-field search now seeds both the focused window and loginwindow's AXWindows list, in addition to the application root. This addresses an application with empty AXChildren but independently exposed windows. Tree-discovered targets must still be owned by signature-verified, currently focused Apple loginwindow, have secure text-field role/subrole, be enabled, and be focused at submission. The graph walk deduplicates roots, does not enter foreign-process subtrees and fails on incomplete/ambiguous results. A target prepared after a fresh face match is revalidated directly during input if top-level focus attributes are unavailable, avoiding repeated full tree walks within the 750 ms evidence lifetime. It is dropped after submission or cancellation; plaintext is never cached. No global input fallback is added, and an entirely hidden AX secure field still blocks password entry.

Input reports preserve the original focused-element failure alongside tree-search metadata. Native tests cover explicit window roots with an empty application tree, duplicate/cyclic roots, foreign subtrees, traversal limits and actual window-space placement. These are implementation/integration checks, not proof of an end-to-end automatic unlock on the owner's lock screen.


### Live acceptance — November 12, 2026

The owner tested 0.12.2 without typing or Touch ID and confirmed: “Notch appears and unlocks automatically.” The corresponding report records bridge available, successful window attachment, password submitted, unlocked outcome and no failure. The input field was ready through the system focus source, with zero password-field wait frames. Camera startup was 1,465 ms, scanning 2,154 ms and mean completed analysis 26.6 ms; these are separate stage measurements from one run, not an end-to-end benchmark. Six frames were rejected (one no-face and five quality), and the recorded quality hint requested more frontal light. This confirms the requested flow in one live owner test; it does not isolate the AX-tree fallback's contribution, establish broad reliability or replace genuine/impostor/photo/video evaluation.

## 0.12.3: open the password prompt before input

On November 16 the owner reported that opening the password prompt manually let face unlock complete. The previous reveal path ran only after field preparation failed and skipped its Space key if AX reported a focused secure field. It also delivered the wake key directly to the loginwindow PID, which may bypass the system's cover/user-activity handling.

After a completed face match, the coordinator now reveals the prompt before field preparation, even if AX already reports a secure field. One fixed non-secret Space goes through the [HID entry to WindowServer](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation/cghideventtap), after Accessibility, same-account locked-session and focused Apple loginwindow signature checks. This is a narrow change from the previous all-PID reveal path; password clearing, Unicode and Return still use PID-directed delivery with all existing guards. Any Space inserted into an already visible field is cleared by the existing submission routine.

Capture continues through at least 300 ms of prompt animation and submission still needs newly analyzed matching evidence and a verified secure field within the original scan deadline. Target transitions can retry before the reveal key is sent; after it is sent, only field preparation retries. Password submission remains one-shot. Automated tests cover reveal-before-preparation even for an available field, animation delay, transition retries and account changes during the delay. Real hidden-prompt acceptance remains to be tested on the owner's Mac.

Validation: 199 tests executed, 191 passed and eight opt-in integrations skipped, with zero failures outside the execution sandbox. The sandboxed full run had five native Vision/Core Image failures; the same suite passed with native-service access. The 0.12.3 development app was packaged and its code signature verified. No live keypress, password submission or lock cycle was performed during this change.


## 0.12.4: Return opens the cover before password input

The owner clarified that the remaining problem is the closed password field: manually pressing Return reveals it, after which the app enters the password and unlocks automatically. The 0.12.3 Space-based opening step did not resolve this. This is not evidence of a failed final submission Return.

The pre-input reveal now sends one Return through the HID event stream, with a 40 ms key hold, before any saved password access. The coordinator then allows at least 500 ms for the prompt transition while collecting fresh face evidence. Password clearing, Unicode input and the final submission Return retain their existing PID-directed implementation. There is no retry after credential input. An already visible prompt may interpret the opening Return as a submission of its current contents; the app never repeats this opening key within the same attempt. Real closed-prompt acceptance of this version remains pending.


## 0.12.6: bounded recognition retries and display sleep

At the owner's request, the notch no longer displays “Unlocking” text. Opening the prompt, password entry and desktop confirmation use a blue face icon and small spinner; only the final result has an outcome caption.

A completed different or borderline 12-frame window now fails immediately without invoking input readiness. The existing comparison count, agreement, quality, score and continuity requirements are unchanged. The coordinator limits recognition to six seconds including camera startup (also enforced by the watchdog for a stalled stream). Field preparation after a match retains the existing overall 15-second bound and fresh-evidence checks.

Experimental automatic mode gets at most three recognition attempts per lock cycle. Each failed identity/recognition timeout shows “Try again”, stops and joins its camera, waits one second, then creates a fresh attempt/face window. The third failure stops with a password/Touch ID fallback. No credential submission is retried, and authorization, focus, camera and session errors do not trigger these recognition retries. Desktop return resets the allowance; sleep and display wake do not. Each attempt still replaces the operational report.

NSWorkspace screen-sleep notifications now stop the camera and cancel the in-flight operation independently of full system sleep. Screen wake can start a new scan only while attempts remain. A display sleep after input consumption revokes automatic unlocking rather than allowing another submission. Tests cover immediate nonmatch rejection with no prompt access, three distinct permits and the hard limit across display wake, owner recovery on a retry, late results after display sleep, and bounded timeout with inference cleanup before retry. Live display-sleep and three-attempt hardware acceptance remain pending.

Validation: full suite executed 203 tests with 195 passed, eight opt-in integrations skipped and zero failures using native macOS framework access.


## 0.12.8: six-frame experimental lock-screen trial

At the owner's request, the app composition explicitly selects the existing six-frame candidate for lock-screen scanning: six quality frames, five agreeing, at least 0.75 seconds. The scanner and core window retain their 12-frame default for other callers; desktop evaluation retains both options. Similarity cutoffs, 150 ms sample spacing, newest-frame matching, quality gates, face continuity, fresh evidence, field verification, one-shot password input, three-attempt limit and display-sleep cancellation are unchanged. Existing enrolled templates remain compatible.

The lock-attempt capture report adds optional requiredMatchFrames metadata so live trial reports identify the selected window. Scanner tests verify the earliest six-frame decision, rejection without prompt access for different/borderline input, and fresh owner evidence after detection loss or a face switch during prompt preparation. The output remains experimental identity evidence with liveness unavailable.

Reducing the window does not guarantee a better or worse genuine success rate: fewer samples change both evidence duration and the agreement rule. Real speed, owner rejection and other-person acceptance need side-by-side trials with the 12-frame baseline under comparable lighting/pose. Photos/video remain a known unsupported threat model. No live accuracy equivalence or speedup is claimed by this build.

Validation: 206 tests executed with 198 passed, eight opt-in integrations skipped and zero failures using native framework access. Live speed and success-rate measurements remain pending.


## 0.12.9: desktop-return confirmation and repeated-lock cleanup

The owner's 0.12.8 report records six-frame recognition and one password submission, followed by an unconfirmed desktop return. The owner reached the desktop, but the coordinator timed out and disabled automatic unlocking. This explains the missing next-lock scan; it does not establish a recognition failure.

Unlock notifications received during a submitted attempt are now retained when the lock dictionary still reports locked, then reconciled against a fresh same-account unlocked/unknown observation. A newer lock notification invalidates that pending signal. If the unlock notification is absent, an unknown lock flag can be corroborated by Accessibility focus on a regular desktop application. This observation is used only for completion, never credential access or input authorization, and cannot override an explicitly locked report.

Every confirmed desktop return resets the lock-cycle latch and retry count. Late unlock polling/notifications during camera cleanup no longer cancel a completed success. Display sleep after confirmed success no longer revokes the automatic session merely because the last attempt consumed input; unresolved input still revokes it. This lets the indicator receive its terminal success phase and dismiss normally. The six-frame trial is unchanged. Regression tests exercise the early-notification race, missing-notification desktop focus, repeated locks, pending-signal invalidation, explicit-lock rejection and display sleep during successful camera cleanup. Live repetition on the owner's Mac remains pending.

Validation: 211 tests executed, 203 passed, eight opt-in tests skipped, zero failures with native macOS framework access.


## 0.12.10: continuous prompt opening and password entry

The owner observed that Glance opens the password field and enters the password as one continuous action, while our app visibly pauses between them. The input-readiness callback now opens the cover once and immediately prepares the secure field. A ready field returns the current matching frame without the former 500 ms minimum wait or mandatory additional frame. The scanner still rejects evidence that becomes stale during preparation; field/target transitions keep scanning and retry only preparation after the opening key has been delivered. Account and cancellation checks run again immediately after revealing the prompt, before preparation. Password input remains one-shot and directed to verified Apple loginwindow.

This changes scheduling, not macOS's animation duration. Accessibility can expose a focused field before the cover animation completes, so immediate input delivery during that animation is an experimental trial pending live acceptance. The existing opening Return retains its 40 ms hold. No global password input or repeated submission was introduced.

Regression coverage verifies immediate preparation and submission without advancing to a new frame, single reveal across delayed field readiness, account loss during reveal, and stale-evidence rejection after readiness work. Live lock/unlock timing and successful delivery remain unmeasured for this build.

Validation: 211 tests executed, 207 passed, four opt-in tests skipped, zero failures with native macOS framework access and the compiled Core ML model enabled.
