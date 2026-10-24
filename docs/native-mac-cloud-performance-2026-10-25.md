# Native Mac cloud and large-room validation — 25 October 2026

This follow-up qualifies the standalone native Mac work, preserving the shipping
iPhone/iPad engine defaults. Source review is separate from physical acceptance.

## Changes found during review

- Hidden/audio-only demand clears the focus override and unsubscribes Guest
  screen video as well as cameras; audio intent is preserved.
- Mini Meeting requests one roster-backed participant. Restoring it or unpinned
  Focus no longer depends on an incoming track that was removed while hidden.
- Minimize/occlusion retires display sinks without destroying private Presenter
  preparation. The retained shell keeps zoom keyed by participant and media kind,
  rather than a transient receiver UUID.
- Unchanged SwiftUI presentation binds do not submit extra cached-frame GPU work.
- Native Handoff uses the existing opaque activity contract; no invitation,
  meeting title or display name enters its searchable activity metadata.
- Move status is visible inside the meeting. The action changes from Cancel move
  to Keep connected here when that is what the coordinator will actually do.

## Production CloudKit

The signed native Debug test host was explicitly provisioned for **Production**,
verified from its actual signature. It exercised the real production adapters
in UUID-scoped generated private zones, without enabling the user's library,
reminders or active-meeting sharing preferences.

- Read-only account baseline passed.
- Encrypted room roundtrip, incremental tombstone and deletion generation fence
  passed (11.736 seconds).
- Continuation claim conflict/actor restrictions, incremental transitions,
  replacement-session withdrawal protection and deletion fence passed (19.347 s).
- Evidence: `.build/native-cloud17-baseline`, `native-cloud17-rooms` and
  `native-cloud17-continuation`.

The old shipping iPhone test-host recipe was cancelled before launch: product
startup could touch a saved catch-up transcript. A new separately provisioned
`dev.vsmirn0v.conferenceguest.cloudprobe` host contains only the CloudKit adapter,
ConferenceCore and the exact generated-record test. It has no product model,
normal library stores or app-group access. Its signed Production container and
profile were checked. It does not replace the user's main iPhone app.

Cross-device generated-record validation and actual system Handoff delivery are
separate gates. The phone currently requires its passcode; no phone test has run.
Actual Mac↔iPhone discovery, APNs delivery and media transfer are not established
by a same-Mac adapter test.

## Controlled rendering load

`CorrectedValidation17.xcresult` passed 24 tests: 15 lifecycle/viewport tests,
5 external retirement/recovery tests, 3 load cases and 1 real-window private
preview visibility test. Eighteen actual GPU fixtures also passed.

The load uses independent mixed CV/I420 640×360 WebRTC sources at 30 fps, including
all off-page producers, with six actual GPU renderers per page. It excludes codec
and network cost. CPU includes the local generators; 100% means one CPU core.

| Participants | Visible GPU fps | CPU | Peak physical footprint | Maximum control response |
|---|---|---|---|---|
| 6 | 28.82–28.94 | 86.1% | 113.1 MiB | 7.00 ms |
| 12 | 28.88–29.00 | 87.0% | 150.0 MiB | 8.43 ms |
| 24 | 28.87–29.00 | 90.1% | 166.3 MiB | 6.83 ms |

Steady footprint growth was under 0.6 MiB in these short samples. Main-queue
heartbeat p95 was under 0.08 ms; worst sample was 30.6 ms. Hide/remount churn and
Leave drained retired renderers and preserved audio intent. These are short
Mac M4/macOS 27.0.1 observations, not a battery benchmark or a 24-decoder claim.

The initial 12/24 synthetic page checks failed. The corrected fixture retains
old sinks so allocator address reuse cannot impersonate an old renderer; it
also checks exact attached RTC track IDs. Budgets were not relaxed. Both result
bundles and the initial failed log are retained.

## Live SFU qualification

The live fixture publishes generated H.264 camera media from six or twelve
independent peers through the actual Guest SFU. It includes an explicit six-real-
decoder phase, gallery pages, focus, hidden unsubscribe, restore and an independent
cleanup observer. Combined CPU includes every local encoder peer and receiver.

The first six-sender run passed RTP/control/hidden/cleanup checks but failed two
12-fps GPU cadence checks (11.88 and 11.84 fps). Decoding in those windows was
roughly 14.5 fps. Main queue remained responsive. First-page readiness in the
12-sender run timed out without enough state to attribute the cause. Both runs
cleaned up independently. Source was 640×360/15 fps; observed decoded resolutions
included 320×180 and 480×270, so source size is not received size.

The diagnostic fixture records per-track renderer callback and GPU timelines,
preparation/replacement/submission counts, full sanitized RTC statistics and
publisher encoding cadence. Readiness recomputes asynchronous camera metadata.
Thresholds and deadlines remain unchanged. The first diagnostic rerun failed before media admission: native URLSession
reported ENETDOWN/NSURLError -1009, while independent unsandboxed curl to the
same origin also failed and apple.com returned HTTPS 200. This run does not
classify the earlier cadence or readiness failures. Local cleanup completed;
the independent network cleanup observer could not connect, so remote cleanup
was not verified in that run. Both failed bundles are retained. Router/path
configuration was left unchanged.

The network chat independently verified recovery from the Mac, Moscow router
and VPN server without changes; normal discovery again returned HTTP 200. With
the compiler idle, the same diagnostic test binary then passed both cases in
`LiveLargeRoom17RecoveredPath.xcresult` (49.110 and 70.497 seconds). All gallery
pages, explicit six-decoder demand, focus, hidden drain, restoration, mute/output
controls, Leave and independent absent-participant checks passed.

| Live publishers | Visible GPU fps across measured phases | Maximum combined CPU | Peak combined physical footprint | Main queue worst dispatch delay |
|---|---|---|---|---|
| 6 | 14.24–14.59 | 123.6% | 222.4 MiB | 11.6 ms |
| 12 | 14.14–14.58 | 115.3% | 338.1 MiB | 10.4 ms |

The mute/output control sequences completed in 245 and 166 ms. Publisher media
was generated: video was active and publisher microphones stayed muted. The
optional physical microphone-unmute test was not
selected. This is a twelve-publisher room with at most six simultaneous incoming
video decoders, not twelve simultaneous rendered videos. The recovered pass does
not establish the cause of the earlier low-cadence windows or guarantee an
uninterrupted external network path. No test thresholds were loosened.

Recovered per-track diagnostics counted 955 and 1,401 advancing callbacks,
respectively. In each case preparation and GPU submission counts matched the
callbacks, with zero pending-input replacements. The largest GPU gaps were
138 and 146 ms. Received dimensions adapted between 320×180, 480×270 and
640×360; VideoToolbox encoding/decoding was observed. These samples show no
additional renderer frame loss; they do not retrospectively identify the cause
of the earlier cadence failures.

Final source regressions passed 21 lifecycle/recovery/private-preview checks in
`FinalLocal17.xcresult` and all 18 actual GPU fixtures. The signed Release
**0.3.0 (17)** build and archive passed; all 153 recorded source hashes match.
The archive is `.build/native-desktop-parity-r4/RockNRollNativeGuest-0.3.0-17.xcarchive`;
its source/artifact identity is saved in `build-evidence-release-0.3.0-17.json`.
Build 16 remains installed; this task did not publish another beta or replace
the user's iPhone app.

The pending cross-device generated zone was removed with the signed native
UUID-guarded cleanup test (`.build/native-cloud17-cross-cleanup`), which passed.
The phone never launched a test or installed a probe during this run. Astra xhigh
reviewed the implementation, fixture corrections and final evidence; no remaining
source blocker was reported within this validated scope.

## Reproduction and outstanding acceptance

Use `NativeMacGuest/Tests/run-cloud-services.py` for opt-in native cloud modes and
`prepare-ios-cloud-probe.py` for the isolated phone host. Use the signed native
XCTest classes `LargeRoomPerformanceTests`, `LiveLargeRoomPerformanceTests` and
`NativeVideoVisibilityTests`; the large tests skip unless explicitly selected
with their documented environment opt-ins and an authorized disposable room.

Physical headset/acoustics, older macOS, real-world room/server variants and
same-account Handoff/media departure remain distinct acceptance tasks.
