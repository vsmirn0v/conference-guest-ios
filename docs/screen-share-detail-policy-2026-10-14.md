# Guest screen-share detail policy

The installed build 81 sends Mac screen shares through a 1920×1080 capture/composition budget. Native Retina detail is lost before encoding. The existing capture fix preserves aspect ratio and native pixels up to 3840 per edge and 8,294,400 total pixels; this change qualifies that path and improves its encoding policy.

## Selected implementation

- Identify screen tracks from the current joined publisher's `SCREEN_SHARE` signaling, independently of camera dimensions, participant names or viewing mode.
- Set their public RTP degradation preference to `maintainResolution`. Retain codec, bitrate limits, active layers, network priority and transaction identity. Congestion control may lower update rate to retain text pixels.
- Bind a sender even when signaling precedes AddTrack or follows its first parameter write. Retry for at most two seconds; later SDK parameter writes retain the policy. Retired generations cannot configure a replacement meeting.
- For Mac guest H.264 screen encoders, use VideoToolbox's quality preference and a normal-budget maximum frame QP of 24. Below 0.03125 bits per source pixel per second, permit the upstream QP 39 to prevent delivery stalls; a 25% recovery margin restores detail without boundary oscillation. Cameras, iPhone/iPad sending and other engines retain existing encoder settings. An annotated Presenter canvas qualifies as a screen share.
- The native extension is per encoder, rejects camera mode, invalid limits and released sessions, and keeps settings across compression-session recreation. Unsupported properties roll back to the working upstream defaults. Older binaries without the extension keep working.
- Keep VP9 screen sending as a Debug-only experiment. Incoming codec negotiation is unchanged.

The native extension is in `Experiments/GuestSDKRebuild/patches/0015-screen-detail-encoder.patch`. It must be included in both slices of the selected rebuilt WebRTC artifact before release. The normal dependency pin is not changed in this isolated feature checkout: parallel SDK/audio work is modifying the next artifact. Do not substitute an older feature-only binary for that newer artifact.

## Real SDK comparison

Mac16,12 / macOS 27.0.1, signed development app, rebuilt M150 guest component, real guest meeting service, independent Chrome receiver. Source: generated 3840×2160 chart, 16–64 px text, 1–4 px patterns, 5 fps; stationary, scrolling and annotated Presenter phases. Mic/camera off; no desktop content is recorded. Each steady interval measures native-process CPU and RTP counters. PNGs are captured directly from decoded video at native resolution.

Matched visible-receiver trials, before the final changing-marker qualification:

| Encoder policy | Static text PSNR | Settled text after scrolling | Native process CPU, scrolling | Actual outgoing rate, scrolling |
| --- | ---: | ---: | ---: | ---: |
| Hardware H.264, upstream QP 39 / speed preference | 38.12 dB | 36.35 dB | 52.7% of one core | 280 kb/s |
| Hardware H.264, QP 28 / quality preference | 46.65 dB | 46.49 dB | 55.1% | 268 kb/s |
| Hardware H.264, QP 24 / quality preference | 50.11 dB | 47.39 dB | 55.6% | 271 kb/s |
| Software VP9 | 55.02 dB | 56.39 dB | 78.4% | 1,094 kb/s |

All these cases delivered native 3840×2160 video, with approximately 4.8–4.9 encoded fps. Hardware use was also confirmed by VideoToolbox's `UsingHardwareAcceleratedVideoEncoder` query in the native log, not just the codec name. QP is codec-specific; do not compare H.264 and VP9 QP values.

The fidelity metric is RGB PSNR in the chart's text region. It is a synthetic pixel-error measure, not a perceptual score or an equal-byte comparison. Bitrate ceilings/source/cadence were kept comparable, but congestion control selected different actual rates. Measurements include capture/composition/private preview and SDK work, not just the encoder. The chart does not represent every desktop or server configuration.

The initial hidden-browser VP9 failures were invalid presentation observations: Chromium can suppress presentation callbacks when occluded. Repeating with the receiver kept visible successfully delivered VP9. A tighter cap plus speed preference did not produce a useful CPU result; it is not selected.

## Qualification and reproduction

1. Build both device and Simulator slices with the source verifier and native patch series. Prepare the experimental project with the pinned vendor wrapper.
2. Open an authorized disposable room in a named Playwright CLI receiver session. Join with mic/camera off; install `Experiments/ScreenSharing/receiver.js`.
3. Run `receiver_bridge.py --cli /path/to/playwright_cli.sh --session SESSION --port PORT --evidence /absolute/path/frames.json --keep-visible`.
4. Set `TEST_RUNNER_ROCKNROLL_TEST_SCREEN_QUALITY_INVITE` and `TEST_RUNNER_ROCKNROLL_TEST_SCREEN_RECEIVER`; run `ScreenShareQualityLiveTests/testGuestNativeScreenDetail` on Mac. Without benchmark mode it qualifies 1920→2560→3840 and annotated 3840 output through the independent decoder.
5. Add `TEST_RUNNER_ROCKNROLL_TEST_SCREEN_BENCHMARK=1` and a unique alphanumeric/hyphen `TEST_RUNNER_ROCKNROLL_TEST_SCREEN_LABEL`. This qualifies static text, scrolling, annotation and a 300 kb/s sender budget and restoration to the normal ceiling. A small changing marker outside the measured text area prevents a stale image from passing as a live stream. Lower refresh rate under the constrained budget is expected; resolution and changing decoded pixels must remain intact.
6. Reference variant: `TEST_RUNNER_ROCKNROLL_TEST_SCREEN_DETAIL_PRESET=reference`. Experimental VP9: `TEST_RUNNER_ROCKNROLL_TEST_SCREEN_CODEC=vp9`. The codec experiment requires explicit server capability; unknown formats remain unchanged.
7. Run `measure-detail.py /path/to/evidence` using Python with Pillow and NumPy. It reports settled and moving text PSNR, CPU, actual bitrate, encoded cadence, encoder and sender-parameter readback. Moving snapshots are matched against the three exact synthetic source positions.
8. Leave both clients, close the owned browser and stop the loopback bridge.

Mac/Simulator policy tests cover current-session ownership, late sender binding, subsequent SDK writes, bounded identifiers, camera/audio isolation, fallback, invalid native requests, release, capture sizing and resize lifecycle. The hardware encoder tests use the same baseline profile and fully initialized settings as live publishing.

Evidence is under `.build/quality-test` in the isolated checkout. Normal tests do not depend on live connectivity; live qualification is opt-in.

## Limits

Mac Power Profiler rejected recording because it does not support macOS. Similar app CPU and confirmed hardware encoding do not establish equal or lower whole-device energy. No physical iPhone battery comparison was run for this change. The stricter encoder policy is intentionally Mac-only. Real packet-loss/reordering and slow external servers remain separate from the sender-budget test.

Parallel development uses the normal app bundle identifier. The final isolated Mac test uses a separate identifier but retains the App Group entitlements: the SDK's share sender needs its shared transport container. Removing those entitlements causes a ReplayKit transport startup failure and does not qualify encoding.
