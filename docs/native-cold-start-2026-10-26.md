# Native Mac first-use capture and OCR

## Model and invariants

- Authorization is a cancellable human decision, separate from bounded hardware startup.
  Only denied/restricted access directs the person to System Settings. A late permission
  reply cannot revive a canceled media request.
- Media controls retain a request identity. Off can suppress an independent sender while
  another device waits for permission; future enables wait for previous cleanup. Hold
  and Leave cancel pending decisions before draining controls. Playout remains independent.
- Camera discovery/format reads and capture startup run off the UI actor. Capture owns
  its device until cleanup finishes, and canceled requests cannot publish a track.
- OCR owns one immutable captured frame and one process-wide work permit until actual
  system completion. The native app allows 60 seconds for first-use model preparation
  (measured at 30.77 seconds in the initial probe; the first bilingual integration
  test subsequently completed in 43 seconds on macOS 27.0.1). After four seconds the UI explains that
  recognition is preparing. Closing, source changes and stale callbacks preserve the
  existing ownership/cancellation rules; iOS retains its current deadline.

## Changes

- Cancellable first camera/microphone permission requests without a 30-second decision timer.
- Correct distinction between permission denial and authorized audio-device startup failure.
- Eight-second initial input/voice-processing startup allowance; ready input retains the
  two-second operation limit. No automatic overlapping native retry is introduced.
- Asynchronous camera list discovery; built-in camera selection avoids enumerating all
  external devices on the ordinary automatic path. A 30-second first-frame allowance covers cold system effects; configure,
  first sample and WebRTC forwarding durations remain separate in diagnostic snapshots.
  Camera/microphone buttons show cancellable startup progress. Rock camera device/format reads also run off-main.
- First OCR capture remains eligible for its eventual result across cold model initialization.

## Acceptance

- First OCR capture returns its result after the old deadline, without recapture/retry;
  real English/Russian selection and Copy, source end and resizing remain valid.
- Authorization allow/deny/cancel/late reply and rapid On/Off/On intent races are covered.
  Cross-device Off and transfer do not wait for an unanswered permission dialog.
- Live first and subsequent microphone/camera enables produce outgoing media, retain
  incoming audio, and record stage latency and UI responsiveness in a disposable meeting.
- Full Mac suite, Astra review, exact Release signature/notarization/CloudKit checks,
  published feed/artifact readback and actual update are required before completion.

Evidence is retained in `.build/native-cold-start31/`; release results are recorded
separately after validation.

## Mac validation

- `final-regression.xcresult`: 104 tests, 19 optional skips, zero failures, including
  real physical microphone/camera cycles, independent session-control cancellation,
  delayed permission decisions, rapid/cross-control Off and transfer races.
- The bilingual system OCR test uses one capture and no retry. The synthetic cold
  test returns its first result after 13 seconds, beyond the former 12-second limit.
- Physical first camera enable: 10.90 seconds; first valid AVFoundation sample arrived
  10.44 seconds after activation with macOS system Background active. The WebRTC
  forwarding call took 0.27 ms. Subsequent enables took 0.76/0.73 seconds. A previous
  physical run observed a 14-second first-frame wait. This does not establish a
  speedup in macOS's own effect preparation; it establishes responsive, cancellable
  startup with enough margin for the observed cold path.
- Physical first microphone enable: 1.81 seconds, of which 1.806 seconds awaited
  unmute confirmation and about 1 ms activated the device. Subsequent enables took
  69/70 ms. Input/output were 48 kHz, normal voice processing remained active, incoming
  audio samples advanced throughout, and all camera streams decoded at the receiver.
- Maximum sampled MainActor interval during live setup/toggles: 221 ms; no operation
  timed out. Microphone permission now distinguishes denial from device failure.
- Camera readiness/metadata/duration standalone tests and 27 distribution-tooling
  tests passed. Astra's final source review found no blockers.

The earlier physical test timeouts were waits for human permission approval, before
joining or opening capture hardware. Those failed runs are retained. The user then
allowed microphone and camera, and the subsequent actual-device runs passed.
