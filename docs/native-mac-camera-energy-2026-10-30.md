# Native Mac camera energy with Background replacement — 2026-10-30

Reported: enabling the camera raised app CPU from 43% to 101% in a two-person
meeting with macOS Background replacement selected.

## Findings

- **The camera never ran at 720p.** `GuestCamera` selected the 1280x720 format
  and 30 fps but released the device lock before `startRunning()`. The native
  macOS session then reapplied its preset format: every logged activation ran
  and delivered 1920x1080, which WebRTC scaled to 720p before encoding.
- **Background replacement runs in the capturing process.** A raw capture probe
  that did nothing with frames used 47–58% process CPU plus 18–24% in
  `cameracaptured`. Most of the reported increase is this system effect, not
  encoding or rendering.
- The built-in camera (Mac16,12) supports Background at 640x480 through
  1920x1080, 15–30 fps, so a true 720p capture keeps the effect.

## Change

- Hold the device configuration lock from format/cadence selection until
  `startRunning()` returns (released on every cleanup path). Requested 1280x720
  now runs and is delivered as 1280x720.
- When Background replacement is selected, cap capture at 24 fps (formats that
  cannot reach 24 keep the 30 fps cap and stay eligible), use the format's
  Background frame-rate range, and prefer formats that support Background so the
  selected effect is not silently dropped. Without Background, 30 fps is unchanged.
- Encoder resolution (1280x720), bitrate ceiling, codec and screen sharing are unchanged.

## Measurements (M4 MacBook Air, AC power, Background active in every window)

Real `GuestCamera` → `LKRTCVideoSource` → hardware H.264 at 1280x720, 1100 kbps
ceiling. Three alternating 30-second windows per variant after 8-second warmup.
CPU is the probe process plus `cameracaptured`.

| Variant | Capture | Encoded | CPU mean (range) | Encoded kbps |
| --- | --- | --- | ---: | ---: |
| Shipped (build 33) | 1920x1080 @30 | 1280x720 @30 | 82.0% (78.1–86.3) | 767 |
| True 720p, 30 fps | 1280x720 @30 | 1280x720 @30 | 79.9% (77.7–82.4) | 873 |
| True 720p, 24 fps (new Background default) | 1280x720 @24 | 1280x720 @24 | **67.8% (65.7–69.2)** | 984 |

24 fps with Background lowers CPU by ~14 percentage points (−17%) with no
overlap between ranges. True 720p alone is within noise for CPU but removes the
hidden 1080p capture. Per-frame bits rise at 24 fps (≈41 vs 26 kbit/frame), so
the trade is motion smoothness rather than detail; this matches the existing
iOS 1280x720/24 fps output contract. Camera start time was unchanged
(first frame 849–883 ms vs 871–980 ms shipped).

A raw-AVFoundation probe (no encoder) agreed: 1080p30 ≈ 81%, locked 720p30
≈ 75%, locked 720p24 ≈ 65% (process + `cameracaptured`).

Not measured: whole-device power (no privileged `powermetrics`), a live meeting
with remote receivers, or cameras other than the built-in one. The rest of the
reported 43% camera-off baseline (incoming video decode/render) is separate.

Probes: `Experiments/NativeMacCameraEnergy`. Raw rows stay local under
`.build/camera-energy-720p-20261030` (no images were captured).
