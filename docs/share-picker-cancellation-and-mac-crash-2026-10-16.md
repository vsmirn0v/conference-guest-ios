# Share-picker cancellation and Mac crash investigation

## Scope

The reported iOS failure is Share → dismiss the system chooser before starting → Share no longer opens the chooser. A separate Mac crash occurred while experimenting with sharing in build 96. These are investigated separately; there is no evidence yet that they have the same cause.

## iOS picker retry

`NativeGuestScreenCapture.start()` previously returned whenever `picking` remained true. If the chooser disappeared without a cancellation callback, an explicit subsequent Share action could never reopen it. Native capture is selected on iVitalii's iOS 27.0.1; older iOS versions use the SDK's ReplayKit launcher.

An explicit tap may now reopen a native chooser until a filter has been accepted. Accepted selection/startup remains protected from repeated taps. Each presentation owns its observer identity and generation, so callbacks queued by a retired chooser cannot cancel or start a replacement. `isActive` continues to represent system registration, not chooser visibility. There is no timeout, automatic consent, or permission override.

Telemost and TrueConf retain a sender during selection. Their explicit Share actions now forward a retry to that sender before the first frame, retaining their connected/hold/privacy guards. Composer and retired senders cannot retry selection. Guest meetings already forward the explicit action to their existing capture.

Legacy ReplayKit does not expose a picker-cancel callback in its public view API. The unchanged SDK launcher uses that view. Its cancellation behavior is not established by the native-picker tests and is not claimed fixed here.

## Mac evidence

Unified logging records creation of `RockNRoll-2026-10-16-200137.ips` at 20:01:38 MSK. That file is no longer in the accessible DiagnosticReports directory; `/cores` is empty. Xcode has no matching local crash bundle, and App Store Connect's available feedback has no report for this incident. TestFlight cache access is denied by macOS privacy controls.

The process image UUID in the nearby diagnostic events is `D7102274-8009-3416-B44A-93A6740B75AF`, matching the retained build-96 app/dSYM. The pinned SDK image UUID also matches its archived binary. Symbolicated error-log backtraces show:

- 20:00:41: `SocketConnectionClientImpl.tryOpen()`, line 81, logging a connection error.
- 20:01:00: SDK `SocketConnectionServerImpl.stream(_:handle:)`, line 195, logging a stream error near capture stop.

These are backtraces from logging calls, **not the crash's faulting-thread stack**. They do not establish a use-after-free, a fatal exception, or a complete root cause. Public sender start/send/finish calls are already serialized; that barrier does not prove quiescence of the SDK's private network queues. No speculative sleep or extra-retain workaround is introduced.

Ignored raw evidence: `.build/share-cancel-crash/`.

## Qualification

- Mac regression selection: **103 passed, 10 skipped, zero failures** (`regress-final-mac.xcresult`). Includes four native phone-picker callback tests, capture lifecycle, bounded uploader, Presenter, Telemost and TrueConf tests.
- iOS 27 Simulator regression selection: **98 passed, 11 skipped, zero failures** (`regress-final-simulator.xcresult`). The Simulator SDK does not expose ScreenCaptureKit, so the four native-picker tests run on Mac using the injected phone-picker contract instead.
- Isolated live guest canvas sharing: **20 start/stop cycles passed**, then Leave; one test passed in 13.4 seconds (`mac-canvas-final.xcresult`).
- Isolated live guest owned-window capture: **10 changing-window capture/upload cycles passed**, including stop during asynchronous SCStream startup and Leave during the final active share; one test passed in 10.3 seconds (`mac-owned-clean.xcresult`). Stopped capture must not deliver more frames. The DEBUG-only fixture captures its own generated window and belongs only to the unit-test target.
- `gpt-6-astra` xhigh reviewed the retry, callback fences, engine guards and lifecycle tests; no blocking finding remained.
- Mac and Simulator test builds and `git diff --check` passed. An existing Mac runtime warning concerns peer construction in `TelemostFeatureTests.testClosedPeerRejectsPublishingAndSharingWhileNewPeerWorks`, outside the changed picker path.

The live SDK initializes once per test process. Run the opt-in guest methods individually in fresh test hosts. An initial combined run exhausted a shared test deadline during cleanup and then rejected the second SDK initialization. The captured-window test now reserves a separate Leave budget; isolated reruns passed. Those harness failures are not treated as a reproduction of the reported production crash.

Native-picker callback tests do not reproduce the actual system dialog on a physical iPhone. A physical dismiss-by-tapping-outside check, legacy ReplayKit cancellation behavior and the missing Mac faulting-thread report remain unverified. No new beta has been published for this investigation, and no Mac crash fix is claimed.
