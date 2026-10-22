# Background PiP continuity

## Behavior

Guest meetings retain an existing PiP controller and its source anchor across a stopped share, a change of presenter, and renderer replacement. Old pixels and captions are cleared immediately. The waiting surface retains microphone/speaker status; only a frame from the current renderer dismisses it. A normal share gap does not need another PiP activation.

Selected-source signaling is delivered before renderer availability. A new source or a distinct replacement renderer can request bounded incoming-video recovery for an existing PiP session. Conversion and network demand resume together. Repeated metadata, repeated renderer callbacks and late frames cannot replenish that request. Recovery has a ten-second deadline and at most two retries after an unsuccessful start. A parked controller alone does not keep receiving/processing video.

An unexplained background stop is treated as dismissal. Subsequent shares cannot reopen it until the app returns to the foreground. Audio only, the PiP preference and Leave cancel pending starts; Leave retires the controller and rejects late callbacks. Known call interruptions remain recoverable. AVKit provides no explicit stop-reason parameter, so dismissal during the interruption itself still requires device acceptance.

Automatic selection considers signaled shares before their renderers exist, without using the previous camera's frame to start the new share. An explicit participant pin takes precedence. With simultaneous shares, signaling and rendered selection use the same chosen share.

## First-time background opening experiment

This is opt-in and DEBUG-only. Set `CONFERENCE_EXPERIMENT_BACKGROUND_PIP=1` in the development launch environment, or enable the development preference `experiments.firstBackgroundPiP` before launch. It applies to guest meetings and requires automatic PiP to be enabled.

The experiment pre-arms a controller against a real foreground window while leaving automatic activation off until video is ready. When a selected remote share starts in the background, it requests incoming video first, waits for a current frame and AVKit readiness, then requests PiP. Cancelling an unacknowledged start retires its controller; timeout, late callbacks and duplicate metadata cannot resurrect it.

It does not create a hidden window or initialize an AVKit controller in the background. The separate background audio-join prototype remains audio-only. This work does not establish that iOS will accept the first-time background start request on a physical device.

## Validation

Final hosted regression selections:

- Mac (Designed for iPad, macOS 27.0.1): **106 passed, 2 skipped, 0 failed**.
- iPhone 17 Pro Max Simulator (iOS 27): **85 passed, 23 skipped, 0 failed**.

The Mac ran the system-controller lifecycle tests that Simulator cannot support. Both targets skipped two unrelated opt-in conversion/quality benchmarks. Coverage includes share gap/replacement, stale frames, same-presenter renderer replacement after a timeout, signaling before renderer creation, simultaneous shares, pin precedence, dismissal during waiting/recovery, Audio only, preference off, interruption recovery, startup cancellation, deadlines, Leave, and the previous background audio-join ownership tests.

The waiting-state attachment was visually checked. GPT-6-Astra xhigh reviewed planning and the implementation; all reported findings were addressed, and its final review found no remaining blockers. The Mac's existing Security/main-thread diagnostic in the background audio-owner construction test also appears in the earlier pre-PiP test result; it is not introduced by this change.

A signed iOS Release build passed. Strict signature verification passed, and binary inspection confirmed that both background PiP experiment keys and the previous background audio-join prototype keys are absent (`qualification.json`).

Evidence is under `.build/pip-continuity/`: `mac-final.xcresult`, `sim-final.xcresult`, their summaries/logs, and the waiting-state attachment. The earlier Simulator failure came from a wrapper-only test that did not establish the lifecycle state it asserted; its replacement uses a real window/controller with injected AVKit lifecycle callbacks. Earlier results are retained.

## Physical acceptance remaining

On iPhone, test A → no share → B, direct A → B, static slides, renderer/transport reconnect, and cellular/FaceTime recovery while another app stays foreground. Confirm the existing window stays visible, new frames and microphone status move, and no old presenter frame remains. Dismiss PiP during waiting/recovery and verify that new shares do not reopen it. Repeat Audio only, preference off and Leave cleanup.

Separately enable the experiment and start the first share after the app has been backgrounded with no PiP. Verify actual system acceptance, foreground app preservation, failure/timeout behavior and energy use. First-time background opening remains excluded from release until this passes. No physical iPhone was used for this task.
