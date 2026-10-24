# UDP transport comparison — 23 October 2026

The shipping guest SDK is the required baseline. A native-prototype UDP stall
alone cannot establish a replacement-engine defect. The shipping engine remains
the default; no automatic fallback or production ICE policy change is included.

## Instrumentation and scope

Prototype-only diagnostics can select advertised TURN/TCP or TURN/UDP separately
for publisher/subscriber peers. They do not invent relay endpoints. Optional,
size-bounded native RTC event logs capture packet/feedback timing; raw logs remain
local because they can contain network identifiers. The event-log-enabled native
framework is a separate diagnostic build. Temporary changes to its upstream
build/parser sources were restored after compilation.

`GuestUDPComparisonLiveTests` observes the actual shipping `NativeConferenceEngine`
inside the iPad-on-Mac application. Its normal run leaves SDK configuration
unchanged. A second renderer records decoded-frame cadence while public statistics
identify the selected candidate pair and its local/remote candidates. TURN/TCP
still reports candidate `protocol=udp`; `relayProtocol` distinguishes the relay
transport. The observer never reads sender parameters or changes SDK mute state.
Track replacement starts a separate observation epoch. Samples use monotonic
clock bounds and exclude frames received after the sample end.

The independent native publisher supplies the same generated H264 camera stream
(640×360 source, 15 fps target, 400 kbit/s cap; negotiated wire resolution may be
lower), over TURN/TCP. A second native receiver is a TCP control. Samples only
count while the source remains running and the SDK app is foreground-active.
Each SDK observation lasts twelve five-second windows. These are bounded local
comparisons, not high-resolution, multi-party, energy or production acceptance.

## Diagnostic results before the SDK comparison

- `udp-logged1`: forced UDP both ways; receive gaps up to 5.62 seconds.
- `udp-receive1`: TCP publishers and UDP subscribers; gaps up to 5.61 seconds.
- `udp-vp8-1`: same split transport with VP8; gaps up to 6.37 seconds.
- `udp-h180-1`: H264 with 320×180/15 fps/160 kbit/s profile; gaps up to 5.72 seconds.
  The normal source profile was restored afterward.

All four are failed cadence acceptance runs, not successful recovery tests.
The publisher kept encoding. Event logs show substantial gaps in downstream RTP
arrival, NACK/PLI feedback and incomplete/delayed repair. The SFU rewrites RTP
sequence numbers, so source/subscriber sequence numbers cannot be compared
numerically as if they belonged to one stream. PLI reaches the publisher and
keyframes can restore decoding. Lack of negotiated RTX does not imply all repair
is disabled: primary-SSRC retransmission remains possible. This evidence does not
identify a particular vendor server version, network hop or server bug.

## Original SDK: normal configuration

`SDK comparison 2` completed 12 windows with the actual shipping engine:

- The selected receive relay used **UDP in every window**.
- Configuration permitted all ICE candidates and TCP candidates; it advertised
  four explicit TCP TURN URLs and two UDP URLs. It did not force TCP.
- Five-second window frame rates ranged from **4.73 to 14.63 fps**.
- Individual windows contained **3.29 and 3.40 second gaps**; the latter extended
  across the next window. NACK count advanced from 13 to 255 and PLI from 0 to 2.
- The app remained active and the meeting did not end. The generated source
  continued after the final SDK sample.

Thus the original engine also exhibits the UDP stall. This rules out attributing
this reproduction solely to the native replacement. The simultaneous native TCP receiver delivered 1,745 advancing frames over
about two minutes, with a maximum gap of 0.328 seconds and zero video NACKs,
PLIs and packet loss. It received the same publisher while the original SDK
stalled on UDP. A matched SDK TCP control and repeat follow below.

`SDK comparison 1` failed to launch with macOS error -10661 and supplies no media
evidence. A Mac-destination rebuild and exact app registration restored launch.
The launch-only check then skipped without an invitation; it is not a media pass.

## Evidence

All local evidence is under `.build/native-guest/`: diagnostic run names above,
`udp-events-logged1`, `udp-receive-events1`, `udp-vp8-events1`, `udp-h180-events1`,
`udp-eventlog-framework/build-evidence.json`, and `udp-event-parser-remb`.
`udp-logged1-packet-summary.json` is superseded: its missing-packet count was
invalidated by a dictionary insertion during lookup. Do not use it as evidence.

Shipping SDK evidence: `sdk-comparison2.log`, `sdk-comparison2.xcresult`,
`sdk-comparison2-sanitized.jsonl`, `sdk-comparison2-source.jsonl`. Test completion
means observation completed; degraded cadence is recorded even when XCTest passes.

The next attempt (`sdk-comparison3`) did not establish a source baseline: the
native source peers repeatedly failed ICE establishment and exhausted their
retry budgets. The SDK therefore received no test video. This is retained as
a failed setup, not counted as an SDK UDP cadence result. TCP is not guaranteed
to establish successfully on every attempt either.

## TCP control and normal-policy repeat

A test-only factory interceptor filters **existing advertised** TURN/TURNS URLs
with `transport=tcp`, temporarily selects relay-only ICE during peer creation,
and then restores the configuration object. Both factory entry points preserve
the existing registry hooks. The control restores the original implementations
after leaving. Each sample asserts that the SDK retained the requested relay
configuration and actually selected a TCP/TLS relay. This interceptor is compiled
only in the test bundle; the shipping engine and its defaults are unchanged.

| SDK run | Requested policy | Actual receive transport | Largest five-second-window gap | Video NACK / PLI / loss at final sample |
|---|---|---|---:|---:|
| comparison 2 | Normal, unchanged | TURN/UDP | 3.399 s | 255 / 2 / 4 |
| comparison 4 | Test-only TCP relay | TURN/TCP | 0.669 s | 0 / 0 / 0 |
| comparison 5 | Normal, unchanged | TURN/TCP | 0.199 s | 0 / 0 / 0 |

All three completed twelve windows with the app active and a stable observed
track. Native SDK statistics in comparison 2 additionally recorded a **5.265 s
completed freeze** across a sampling boundary (freeze count increased by one,
with the corresponding freeze-duration increase). This is a different metric
from the clipped per-window renderer gap in the table.

The simultaneous native TCP control in comparison 4 delivered 1,633 advancing
frames, maximum gap 0.310 s, zero video NACK/PLI/loss. The source ran for about
127 seconds and completed cleanly. The original SDK's TCP control still reported
short freezes; neither TCP nor its startup is claimed flawless.

Comparison 5 explicitly reports `requestedPolicy=auto`, no factory override,
all-candidate ICE, TCP candidates enabled, and four TCP/two UDP TURN URLs. Its
natural selection of TCP therefore does **not** mean the original SDK forces
TCP. Both UDP and TCP are possible under its normal configuration.

## Conclusion

The multi-second UDP stalls reproduce in the **shipping SDK as well as the
replacement prototype**. The same generated publisher can reach a native TCP
receiver smoothly while the shipping SDK stalls over UDP. The SDK also behaves
substantially better in the matched TCP control and in a normal session that
naturally selects TCP. Treat this as a shared transport-path/forwarding/repair
problem, not evidence of a uniquely broken replacement decoder or renderer.

The responsible network hop, relay or SFU mechanism remains unidentified. These
runs do not justify changing every production meeting to TCP: normal ICE still
needs network-specific qualification, TCP can have head-of-line delays, and one
source setup failed even with TCP requested. A future bounded transport fallback
should be evaluated against this baseline, not presented as a decoder repair.
No automatic fallback was implemented here. The earlier provisional recovery
sketch was removed from the prototype's compilation inputs.

## Reproduction and checks

Build the normal Mac test target and select only
`RockNRollTests/GuestUDPComparisonLiveTests/testOriginalSDKTransportAndCadence`.
Provide `TEST_RUNNER_ROCKNROLL_TEST_GUEST_UDP_INVITE` through a private process
environment. Leave `TEST_RUNNER_ROCKNROLL_TEST_GUEST_UDP_TRANSPORT` unset for the
shipping baseline; set it to `tcp-relay` only for the explicit control. Keep the
app foreground-active and a steady source transmitting beyond the final sample.
The source fixture accepts `--pair --seconds 120 --codec h264 --pair-ice tcp-relay`.
Do not print invitation secrets or raw SDP in shared reports.

Evidence also includes `sdk-comparison4` and `sdk-comparison5` logs, result bundles,
source logs and sanitized JSONL. `sdk-transport-comparison-summary.json` aggregates
these observations. Raw SDK logs remain local with restrictive permissions.

The Mac test build passed, all three qualified observation tests completed, native
engine regression checks passed (`udp-final-engine-tests.log`), Python helper
syntax checks passed, and `git diff --check` passed. Observation completion does
not convert the degraded UDP measurements into a cadence acceptance pass.
6-astra xhigh reviewed the methodology, corrected timestamp/track-epoch accounting,
and reviewed the test-only TCP override and results. No production engine files
were changed for this comparison; existing unrelated worktree changes were kept.

Cleanup observer joined alone (`participants=1` including itself), passed
`--expect-alone`, left and shut down. No test participants remain. The exact
prototype LaunchServices registration was removed. Source/evidence hashes are
recorded in `udp-comparison-manifest.json`.
