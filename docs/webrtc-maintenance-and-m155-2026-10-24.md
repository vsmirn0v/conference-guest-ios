# WebRTC maintenance audit and M155 experiment — 2026-10-24

## Decision

Keep both shipping dependency pins and the opt-in native Mac engine policy unchanged.
The isolated M150 maintenance candidate passed the Mac/simulator checks below.
M155 demonstrated working basic video, but remains an incomplete source port and
is not a replacement for either custom framework.

The production pins remain unprefixed guest `150.7871.03-r6` and prefixed native
`150.7871.03-r3`. Existing iOS behavior and the standard guest-engine default remain
unchanged. No beta was published for this experiment.

## M150 audit

Base source: `0385653a83f21acf3c916466d4088b29fe2f160b`.
Audited [upstream changes through the M150.7871.04 source candidate](https://github.com/webrtc-sdk/webrtc/compare/0385653a83f21acf3c916466d4088b29fe2f160b...a545de45259b47dfac5f3635863e47cb601f1bb2).
The latest published LiveKit release checked was
[150.7871.03](https://github.com/livekit/webrtc-xcframework/releases/tag/150.7871.03);
the `.04` recipe/source existed, but its release endpoint returned 404.

| Commit | Treatment |
| --- | --- |
| `67c4578` | Include stricter validation of known SFU-injected blank payloads before skipping decryption. |
| `51c367e` | Include removal of raw/derived key material from log messages. |
| `fd5c784` | Include the updated built-in root bundle; validate native Apple trust behavior separately. |
| `67366b1` | Include corrected privacy-manifest bundle path. Existing packaging already repaired it, so this removes the upstream cause rather than adding runtime behavior. |
| `f828b40` | Exclude Android hostname-verifier integration; no Apple runtime improvement. |
| `5d83551` | Exclude Android SRTP option exposure. |
| `a545de4` | Defer optional 256-bit frame-cryptor keys; preserve existing 128-bit behavior and SDK API compatibility. |

These are maintenance/security changes, not a demonstrated fix for incoming video
pauses, frame pacing, latency or battery usage. Direct app searches found no
FrameCryptor use; linked SDK use cannot be ruled out from that alone.

The root refresh changes 36 anchors to 21: 19 retained, 17 removed and two added.
An OpenSSL control restricted to only the new built-in bundle accepted Telemost
but rejected the Jazz and TrueConf sample chains. This is **not** an observed app
failure: the candidate's actual native SSL adapter, using its existing Apple trust
fallback, completed verified handshakes to `salutejazz.ru`, `telemost.yandex.ru` and
`tc.domrf.ru`. Expired, self-signed and wrong-host badssl endpoints obtained no
verified connection; the probe does not record their exact rejection reasons.

## Validation

| Check | Result |
| --- | --- |
| Unprefixed guest M150 device + simulator framework builds | Passed. |
| Prefixed native macOS M150 framework build | Passed. |
| Upstream crypto/SIF tests | 13 passed. |
| VP9 hybrid/fallback and independent-pixel fixture tests | 11 passed. |
| Native recovery and audio ownership helpers, ASan + UBSan | 11 + 14 passed. |
| Patch verifier positive/missing/extra/tampered cases | Four passed. |
| Unchanged-wrapper app tests on Mac-as-iPad | 36 passed, seven skipped, zero failures. |
| Unchanged-wrapper app tests on iOS 27 simulator | 34 passed, nine skipped, zero failures. |
| M150 synthetic H.264/VP8/VP9 send/receive + resize | Passed on native Mac framework and guest simulator framework. |
| Vendor imported RTC symbols and eight custom C exports | All resolved on both guest slices; vendor-owned RTCYUVHelper remains isolated. |
| Source/wrapper stability | 451 recorded app/package inputs and 302 vendor files unchanged during validation. |

App tests covered microphone intent/ownership, playback reservation, audio policy,
screen-share policy and integration-state behavior. The skipped tests require
physical output hardware or an explicitly authorized steady-media/capture fixture.
They are not counted as passes. No iPhone, AirPods, cellular interruption, live AEC,
long reconnect soak, actual remote screen-share quality or battery measurements
were performed in this task. No Intel runtime was tested.

The Mac app result uses the iOS device guest framework through Mac-as-iPad; it is
distinct from the separately built native macOS prefixed framework. The existing
native companion's special InputMixer framework and live capture were not replaced
or qualified by these synthetic tests.

## M155 findings

Control: [Jitsi v155.0.1](https://github.com/jitsi/webrtc/releases/tag/v155.0.1), exact
source `623fcfe044d5037b3ecd92001c2ef80ca1d932d5`, published 2026-10-22.
Archive checksum: `5189cc5864d917400174f5bcee3a62f27c55524a28bccec783575d5efbda2ae5`.

The downloaded Mac slice contained only its umbrella header and had the same
nested privacy-manifest path defect. A scratch-only repair restored 85 public
headers from the exact pristine tagged source and corrected resource placement.
The binary remained byte-identical:
`d31e293af5f0ac5f0bec8eb103c71702abce30ae3088ec738d2378289a97caaf`.
The original archive is preserved. The helper reproduced this result independently.

The repaired Mac control and original simulator binary passed H.264, VP8 and VP9
loopbacks, negotiated-codec checks, strictly advancing timestamps and at least
20 decoded frames at each of 320×180 and 640×360. These short synthetic runs do not
establish improved quality, energy usage, network behavior or latency.

The source trial applied 14 of our 23 existing patches. Nine whole-patch failures:

- `0002` conference playout lifetime.
- `0005` Mac output-only voice processing.
- `0006` audio initialization failure handling.
- `0008` audio restart status.
- `0009` accessory mute/input lifetime.
- `0016` atomic screen-sender policy.
- `0018` Mac playout preservation across microphone mute.
- `0019` Mac application capture mute gate.
- `0021` authorized Bluetooth input for headset controls.

Failures include prerequisite conflicts; this is not a count of nine independent
upstream regressions. Clean application of the remaining patches does not prove
that their changed internal C++/GN APIs compile or behave correctly.

Jitsi's source also lacks the LiveKit FrameCryptor, FrameCryptorKeyProvider and
DataPacketCryptor API family. Its bare binaries lack all eight required custom
guest exports. They cannot directly replace either shipping dependency. The
release declares iOS 14/macOS 13 minimums; preserve the app's supported targets
deliberately during any custom build.

## Next gates

1. Before promoting M150, run the skipped live hardware/capture/recovery checks and
   an independent-client guest meeting with camera/microphone/Presenter/reconnect.
   Preserve exact packaged identities and compare against current M150 under the
   same source and transport conditions. The latest maintenance changes provide
   no basis for claiming that the earlier intermittent video pause is resolved.
2. For M155, port the audio-lifecycle and sender-policy changes against its actual
   internal APIs, retaining legacy crypto selectors, EAGL export and YUV isolation.
   Start with the unprefixed guest candidate; a prefixed LiveKit upgrade separately
   needs the fork-specific API family and the companion InputMixer changes.
3. Build source-derived candidate slices and repeat ABI/selector/type checks,
   sanitizer tests, SDK wrapper/app tests, live interoperability and physical
   interruption/headset/background scenarios before changing a shipping pin.

Reproduction helpers and locks:
[`Experiments/WebRTCMaintenance`](../Experiments/WebRTCMaintenance/README.md).
Evidence: `.build/webrtc-maintenance-20261024` and `.build/webrtc-m155-20261024`.
Relevant final outputs are `app-experiment-r3/{mac,simulator}-regression.xcresult`,
`{guest,prefixed}-source.json`, `toolchain.json`, `wrapper-symbol-audit.json`,
`native-tls-probe.log`, `native-tls-negative.log`, `*-media-probe-final/result.json`,
and M155 `{mac,simulator}-probe-final/result.json` plus `reproduction/evidence.json`.
