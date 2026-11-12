# Recognition performance and window evaluation — 0.11.0

## Implementation

One `EnrollmentCameraSession` retains the configured AVCaptureSession, camera input/output and CIContext between attempts. Each attempt receives a fresh single-use `EnrollmentCamera` and bounded newest-frame stream. Stop removes the delegate, stops the sensor and finishes that stream. Delayed cancellation and timeouts are bound to the old camera instance; they cannot stop a later capture. Overlapping captures are rejected. No camera runs between attempts. First capture still pays configuration and sensor startup costs; later captures still pay sensor startup costs.

Enrollment retains its previous 90 ms delivery throttle. Desktop comparisons and lock-screen scans receive fresh camera frames without that throttle. `FaceComparisonWindow.shouldAnalyze(at:)` rejects too-early frames before Vision/Core ML work. The scoring code still checks spacing, quality, continuity, gaps and duration. No model, alignment, similarity threshold, unlock evidence age or submission guard changed.

The standard unlock policy remains 12 frames, 10 agreeing, minimum spacing 150 ms, minimum span 1.65 s. In a deterministic 30 fps simulation the new scheduler completes at 1.833 s with 12 analyses, versus 2.2 s and 23 analyses for the former 10 fps delivery. These are synthetic scheduling results, not measured camera or unlock speedups. Real cadence, exposure, analysis costs and rejected frames affect results.

The last lock-attempt report adds camera-startup time, mean completed-analysis time, scan time and scheduled-out frame count. It continues to exclude images, embeddings, scores and secrets. Successful-analysis timing excludes analyses that threw errors; rejected counts remain separate.

## Desktop evaluation

Turn off automatic face unlock, then open Tools → Test my face → Window evaluation. Select the window and presentation **before** starting each camera test. Current uses 12 frames/10 agreement/1.65 s. Candidate uses 6 frames/5 agreement/0.75 s; both retain the same score, quality, spacing and continuity cutoffs. The candidate is wired only to the desktop comparison, with no password submission capability.

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
