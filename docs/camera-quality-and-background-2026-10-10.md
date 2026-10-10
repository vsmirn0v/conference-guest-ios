# Camera quality and background capture

Implemented with a 6-astra xhigh architecture review. Applies to ordinary
published camera video in the guest, native and jam engines.

## Output contract

| Conditions | Maximum landscape output | Cadence |
| --- | --- | --- |
| External power or qualified excellent uplink | 1280 x 720 | 24 fps |
| Battery/unknown power without excellent uplink | 960 x 540 | 20 fps |
| Poor uplink, constrained/unavailable path, or energy pressure | 640 x 360 | 15 fps |
| Severe energy pressure | 640 x 360 | 10 fps |

Portrait swaps the limits. Preserve the native aspect, do not upscale, and
round unusual dimensions to even pixels within the cap. Sensor formats may
remain larger to preserve camera field of view; the limit applies before encoding.

Two distinct poor transport samples qualify a network downgrade. Ordinary
transitions have a 10-second minimum dwell; upgrades require 30 seconds of
continuous eligibility. Thermal/low-power/path restrictions act immediately.
Old or duplicate samples cannot qualify an upgrade. A publication or route
change clears previous transport evidence. Wi-Fi membership alone is never
evidence of an excellent uplink.

Use only the camera's outbound RTP, its selected ICE pair and matching remote
feedback. Exclude screen/Presenter publications, inactive senders, old pairs
and completed room generations. Excellent requires RTT at most 150 ms and
available outgoing bitrate at least 2 Mbps. Poor includes a bandwidth/CPU
limitation, RTT over 400 ms, loss over 5%, or available bitrate below 600 kbps.
Missing or invalid metrics remain unknown.

The native engine adapts an app-owned camera source. The jam engine bounds
physical pixels through a camera-only processor. The guest frame proxy also
bounds physical pixels, so a later SDK format request cannot bypass the cap.
The latter two reuse `CameraPixelScaler`: bounded native VideoToolbox pools,
original pixel format/color attachments, and no extra conversion through I420.
Existing rotation and hardware codec selection remain intact.

Keep source-format caching: calling WebRTC adaptation before every frame would
[reset its cadence controller](https://webrtc.googlesource.com/src/+/825e4f19ce38e839d74d865b01dbe86abbec3df3/media/base/video_adapter.cc#358).
Physical pixel bounds provide the guarantee without those repeated resets.

Screen-sharing and Presenter canvas/output dimensions, encoding policies and
dedicated capture are unchanged. A Presenter overlay that reuses ordinary
published camera video naturally inherits that camera's detail; it does not
change the composed canvas resolution. A separate pre-cap frame fan-out would
be needed if a future requirement calls for preserving the overlay's full
sensor detail while ordinary publication remains bounded.

## Background camera

The jam SDK previously explicitly suspended camera tracks on backgrounding.
Disable that suspension. Configure runtime-supported AV capture sessions for
multitasking before capture starts in both app-owned engines. Enable the guest
SDK's public camera capability, keeping its separate system PiP disabled:
Rock'n'Roll remains the owner of the single floating-video controller.

Apple's [multitasking support](https://developer.apple.com/documentation/avfoundation/avcapturesession/ismultitaskingcameraaccesssupported)
is a runtime requirement, not a guarantee on every supported OS/device.
Existing VoIP mode and video-call PiP are used; no invented entitlement or
second camera session is added. Older devices, another camera owner, locking,
or stashing PiP can still cause system interruption. Existing camera-pause
status and foreground recovery remain applicable. Presenter background
privacy behavior remains unchanged.

## Validation

- Final iOS 27 Simulator: 47 targeted policy, evidence, native pixel/color,
  cadence, guest forwarding/capability and room-policy tests; zero failures.
- Final Mac: 28 targeted tests; zero failures. Includes public external-power
  bridge, native VT scaling and guest physical frame cap. Mac was on AC power.
- Earlier broader Simulator pass: 126 tests, 7 expected hardware/opt-in skips,
  zero failures. Final cap hardening was subsequently covered by the targeted
  runs above.
- Signed Release iOS build succeeded; `codesign --verify --deep --strict` passed.
- Independent Telemost receiver decoded 532 advancing frames at 640 x 360,
  rotation zero during the 40-second camera run.
- Independent guest browser received advancing 1280 x 720 video before final
  hardening; final physical-cap build received advancing 960 x 540 video.
- Independent jam browser received advancing 1280 x 720 video. The extracted
  shared scaler has the same scaling implementation and passed final tests.
- Final TrueConf run decoded 1,269 advancing frames with upright camera
  content in its server-composed 1920 x 1080 layout. The received composite
  dimensions do not establish the resolution of an individual outgoing camera.

Local logs/results are in `.build/camera-quality-background`. Development
runtime binary SHA-256 for the final guest check:
`1c6a04e8c620ab157686d9d0563bf64aab0ec11abc135a0b820d0ec01a1157c2`.
No private camera images are included in this document.

Actual iPhone/iPad camera continuity in background/PiP, interruption recovery,
phone rotation and battery savings remain unverified: iVitalii was unavailable
to Xcode. Simulator does not establish these hardware/system-camera behaviors.
Run a real-device check with both local PiP and an independent remote receiver;
confirm advancing frames through background/foreground and a competing call,
then confirm Leave stops camera and PiP. Do not describe the physical freeze
as closed until that check passes.
