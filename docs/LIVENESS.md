# 0.13.0: mandatory experimental passive liveness

The owner reported that a selfie unlocked the Mac in 0.12.10. That build explicitly allowed an experimental identity match with liveness unavailable. Version 0.13.0 removes that bypass and adapts Glance Heavy at the owner's request. No commercial neural PAD model or depth sensor is introduced.

## 0.13.1: real-face device-cue false positive

The owner reported a genuine-face rejection with no device in view. The 0.13.0 operational report shows an identity match and entry into password-field preparation, followed by `deviceDetected` rejection before any password consumption/submission. This was not a missing natural blink. The report retained no rectangle coordinates or image, so the exact background/detail that triggered it cannot be identified retrospectively.

The old detector accepted any candidate overlapping at least 15% of the face. This was too broad: a background monitor/window or a small partial rectangle could become a device denial. Version 0.13.1 qualifies candidates geometrically before the existing three-observation deny gate. At least 90% of the face must lie inside the candidate; the face must occupy 20–80% of its area, and each candidate dimension must exceed the matching face dimension by at least 5%. All qualifying candidates are considered, so an ignored large background rectangle cannot hide a smaller plausible phone. These bounds are engineering choices requiring real-camera calibration.

This intentionally reduces rectangle-cue sensitivity to partial screens, very large screens and photos with a small face. Positive Heavy liveness, glare denial, missing-data rejection, identity checks and evidence freshness remain required. Physical photo/video acceptance must be retested rather than inferred from synthetic geometry tests. A background object close enough to satisfy the same geometry can still cause a false positive; no RGB rectangle heuristic can establish that the rectangle is a device.

The report adds candidate/qualifying/ignored counts only (`deviceRectangles`), with no image or rectangle/face coordinates. A future denial is shown as “Screen shape detected” or “Screen glare detected” when the cue is known; generic liveness failures keep their existing caption. The new geometry and native Vision cases cover large background rectangles, partial overlaps, face-sized details, scale/translation, invalid inputs, and a genuine phone-like enclosing rectangle that still overrides a blink. Real owner-face recovery remains pending a new live test.

## Source and license

Adapted from [jonnyoo/glance, revision b97f521397ec1197ba17768ba797cae1e628848d](https://github.com/jonnyoo/glance/tree/b97f521397ec1197ba17768ba797cae1e628848d/glance/Liveness), copyright 2026 Jonathan Zhou, MIT. The source headers identify this revision, and the complete license remains in `Models/Glance-MIT-LICENSE.txt`. Packaging includes it even in a source-only build without the model.

The adapted sources in `Sources/FaceUnlockRecognition/Liveness/` contain Glance's cue evaluator, geometry/homography math, landmark helpers, glare sample/rasterization, and blink/pose scoring. The feature extractor adapts the device rectangle heuristic and original-image crop to this app's existing Vision observations; detection failure is distinguished from a successful search with no rectangle. All geometrically qualifying rectangle candidates are considered (narrowed in 0.13.1). The glare rasterization stays within the pixel buffer's valid lifetime. Blink scoring requires both eyes to dip/recover and searches for every complete event, so a window starting mid-blink does not hide a later blink. The separate `HeavyLivenessGate` binds the policy to this app's scan lifecycle. Glance's Light implementation is retained internally with the source evaluator, but the app exposes neither a Light mode nor an off switch; its only gate constructs Heavy explicitly.

## Required evidence

- Deny cues: concentrated near-white glare or a device-shaped rectangle overlapping the face. Glance's thresholds and three-observation firing counts are retained. A fired deny cue overrides a previous positive cue and ends the attempt before password access; it is not automatically retried.
- Positive cues: natural eye-close/reopen, nose/pose correlation over head rotation, or coherent landmark motion that a planar transform does not explain. Heavy requires at least one of these; sitting motionless may time out. There is no prompted challenge.
- Missing/invalid measurements never imply a pass. Rectangle-processing failure, unavailable glare/eyes/landmarks, invalid numbers and nonincreasing time discard liveness evidence.

Identity still requires six quality frames, five agreeing, at least 0.75 seconds, with unchanged similarity, quality and continuity checks. The original frame is analyzed at most every 50 ms (camera/processing speed permitting), while identity voting remains spaced by at least 150 ms so blink sampling does not inflate identity votes. Full-frame rectangle detection and face-crop glare run on the existing recognizer actor; frames and landmarks stay in memory and are never saved.

Each scan owns a new Heavy gate. Its geometry/blink history is bounded to two seconds and 40 measurements. A positive latch is valid for at most 750 ms without reacquisition. Missing or poor-quality detections, stale inference, face-bound/identity discontinuities, a gap over 600 ms, cancellation and a new attempt discard old evidence. A live face cannot deliberately hand its latched evidence across an observed tracking break to a later photo. This does not guarantee detection of a seamless substitution of an indistinguishable photo.

Only a current matching identity window plus a positive Heavy result may invoke prompt opening/preparation. The combined evidence timestamp is the earlier of the identity frame and positive liveness latch, so preparation and every credential-input check must keep both within the 750 ms freshness budget. The scanner returns `experimentalLiveness`, never `verified`, and both the controller and one-shot credential permit now reject unavailable/rejected liveness. The calibrated biometric policy still requires independently verified identity and PAD. Account/focus checks, evidence age, one-shot input and scan deadlines remain enforced. Field waiting continues to collect current evidence; a deny cue or expired positive evidence prevents a later submission. The continuous prompt-opening path from 0.12.10 is retained.

Operational diagnostics add fixed liveness decision/cue names and a waiting-frame count. No landmark coordinates, images, embeddings, face scores or passwords are recorded. A six-second recognition deadline with a matching face awaiting liveness reports a liveness failure rather than silently accepting it. Other recognition failures keep their existing bounded retries.

## Limits and live acceptance

This is heuristic RGB liveness, not evaluated authentication, Apple's TrueDepth or a guarantee against photos/video. Glance's upstream notice specifically does not promise reliable video replay resistance. Landmark jitter, lighting and camera processing can create false cues; genuine users may also fail to produce a usable cue. The adapted thresholds have not been calibrated on this Mac or on a held-out attack set. Existing enrollment does not need replacement.

After restarting the built app and privately re-enabling it:

1. Test genuine recognition with a natural blink or small head movement under ordinary lighting. Record success, failure and elapsed time; repeat lock cycles.
2. Test the exact selfie that bypassed 0.12.10 on a phone. Test different display brightness, distance, tilt and movement, including a phone filling the camera view with no visible edges. No password should be entered.
3. Test a printed photo and replayed face video, including blink/head-motion video. A successful photo or video unlock remains a failed security test; do not treat Heavy as an authentication guarantee.
4. Test no face, poor light, leaving/reentering the view, display sleep, and the password field already visible. Password/Touch ID fallback must remain available.

Synthetic mechanics regressions and native image fixtures cannot substitute for those physical presentation tests. Neither the agent nor the automated suite performs an actual lock/password submission.

## Automated validation

Final native suite: **231 tests executed, 227 passed, four opt-in integrations skipped, zero failures**, with the compiled Core ML model enabled. Coverage includes missing/rejected liveness at both controller and permit boundaries; static, translating and blinking synthetic measurements; native static/translated/brightness-varied photo fixtures; native device-rectangle overlap; deny precedence during field waiting; identity-track resets; bilateral blink recovery after starting mid-blink; stale liveness despite a fresh identity frame; and operational-only private report storage. These results establish implementation mechanics, not physical photo/video resistance or genuine-user acceptance rates.

Version 0.13.1 validation: **239 tests executed, 235 passed, four opt-in integrations skipped, zero failures**, with native Vision/Core ML and the compiled model enabled. The owner’s original failed-attempt report was read for diagnosis; no new camera capture, live lock or password submission was performed by the agent.
