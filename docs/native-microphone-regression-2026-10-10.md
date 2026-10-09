# Native microphone regression checks

Baseline: `2379b8e` (beta 59). Fixed source: the working-tree changes in `NativeRTCPeer.swift`, `TelemostCallEngine.swift`, and `TrueConfCallEngine.swift`. No physical iPhone was used.

## Failure and change

The baseline publisher negotiated a send-only audio transceiver without a track. Muting removed `sender.track`; the UI then inferred that capture was muted because no enabled track existed. With the real default Mac audio device, that initial trackless sender still emitted microphone audio. Server device-state metadata could not provide a reliable sample-level mute gate.

TrueConf reproduced the reported initial-muted leak: a spoken marker was audible at an independent receiver while the publisher reported `enabled=false`. Telemost reproduced the other failure: the default device captured the spoken marker and emitted RTP after unmute, while the independent receiver remained silent.

The publisher now negotiates a real, disabled audio track from its first offer, keeps its microphone identity through mute/unmute, and gates content with `track.isEnabled`. A replaced processing-profile track is disabled before replacement. Closing a peer disables its retained track before asynchronous camera teardown and rejects later attempts to enable it.

Both engines recheck current microphone intent and call-audio availability after camera teardown/capture and SDP waits. This also fixes a separate race in which a suspended media update could re-enable capture after the user had muted it. Audio interruption/hold immediately disables the sender. Transfer hold applies the same gate before awaiting the system acknowledgement, so an enabled sender cannot keep forwarding samples during that wait; its intent is retained for an authorized resume.

## Real microphone to independent service receiver

The CLI used the production admission, transport, and peer implementations with the existing pinned WebRTC framework. The sender used the default Mac hardware audio device. Short `say` speech markers played through the speaker into the physical microphone during initial mute, enabled, mute, and resumed phases. The independent receiver used a custom playout device to measure decoded PCM silently; the sender received no generated PCM. No PCM recordings or credentials were saved.

Per-second remote RMS measurements, after discarding the decoder tail on mute:

| Service/source | Initial muted marker | Enabled marker | Muted after tail | Resumed marker |
| --- | ---: | ---: | ---: | ---: |
| Telemost baseline | 0.0000021 | 0.0000021 | 0.0000021 | 0.0000021 |
| Telemost fixed | 0.0000021 | 0.0075984 | 0.0000021 | 0.0078896 |
| TrueConf baseline | **0.0121096** | 0.0072614 | 0.0000032 | 0.0069941 |
| TrueConf fixed | 0.0000995 | 0.0075656 | 0.0000032 | 0.0075483 |

Initial-muted TrueConf output drops by more than two orders of magnitude; Telemost enabled output contains actual microphone speech after the fix. RTP silence/comfort noise is acceptable. Packet counts alone cannot establish capture content. WebRTC media-source statistics may measure input before the mute gate and remain nonzero while encoded output is silent.

An additional default-device direct decoded loopback, with the same profile renegotiation as the engines, measured initial mute `0.0000024`, enabled `0.0059034`, mute `0`, and resumed `0.0057364` RMS.

## Actual app on Mac

The signed development app was then launched normally without XCTest and controlled through its native microphone button. This exercises the normal iOS-on-Mac `AudioCoordinator`, `SystemCallCoordinator`, AVAudioSession, and manual WebRTC audio-session path. The separate service receiver decoded and measured its real microphone input. Microphone and camera started off, and camera remained off throughout.

| App/service | Initial muted spoken marker | Enabled spoken marker | Muted spoken marker |
| --- | ---: | ---: | ---: |
| Telemost | 0.0000021 | 0.0107594 | 0.0000022 |
| TrueConf | 0.0000028 | 0.0098207 | 0.0000032 |

Both actual app routes passed. Each call was muted and left at completion; the original name and empty invitation input were restored. The Telemost app's later repeated-on marker occurred after its bounded receiver had left, so that particular app phase is not claimed as decoded acceptance. Repeated on/off is covered by the independent default-device CLI and generated-input regressions above. No physical iPhone route was tested.

The Mac-as-iPad XCTest harness did not resume asynchronous work on this host. A bounded synchronous XCTest wrapper entered its pre-await checks but also timed out after requesting microphone permission, without reaching capture or marker phases. That failed harness attempt does not count as an audio acceptance pass. The workaround was reverted; the canonical opt-in async test remains, and the normal direct app workflow supplies the Mac runtime evidence.

## Regressions

- `NativeMicrophoneTests`: automatically exercises production split and server-first composite peers with generated input and decoded PCM. Covers initially muted negotiation, enabled content, immediate mute without an SDP round trip, processing-profile replacement, repeated unmute, retained-track disable, and closed-peer rejection. Mac CLI runs of these checks passed for both topologies.
- `NativeMicrophoneTests/testMacDefaultMicrophonePublishesRealInputAndMutesSamples`: opt-in (`ROCKNROLL_TEST_NATIVE_MICROPHONE=1`) actual Mac app microphone/session check with a silent independent decoded receiver. Play the spoken marker at each `NATIVE_REAL_MICROPHONE_*MARKER_READY` log line. Its async XCTest execution remains unverified because of the Mac host limitation above.
- `NativeMicrophoneRaceTests`: opt-in real-room engine regressions using `ROCKNROLL_TEST_TELEMOST_INVITE` and `ROCKNROLL_TEST_TRUECONF_INVITE`. They establish enabled intent, suspend a media update at the camera-release boundary, mute, then sample through resumed negotiation to catch even a transient re-enable. A second barrier suspends transfer hold before requesting system acknowledgement and checks that the enabled sender is already muted, then verifies resume with sending disabled. Microphone permission must already be granted; these opt-in live barrier regressions were not executed on this host.

The final focused Simulator run passed 3/3 checks: both `NativeMicrophoneTests` topology selectors and `SessionOwnershipTests/testHandoffHoldCannotBeAutomaticallyReactivated`. Split decoded RMS was initial `0`, enabled `0.0386841`, muted `0`, muted profile change `0`, resumed `0.0324177`; composite was initial `0.0000044`, enabled `0.0366148`, muted `0`, muted profile change `0`, resumed `0.0291008`. The run used `test-without-building` against the latest complete integrated Simulator artifact, which included the audio changes and live-barrier test code. It did not execute the opt-in live engine barriers. Results: `/tmp/rock-native-audio-20261009/final-focused-simulator.xcresult` and `final-focused-simulator.log`.

Temporary redacted CLI logs and comparison metrics are under `/tmp/rock-native-audio-20261009/`; these are diagnostics, not distributable application artifacts.
