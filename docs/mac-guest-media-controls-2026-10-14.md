# Mac guest media controls and headset mute

## Reproduced causes

With six independent browser participants sending audio and video, the shipped
native r5 framework synchronously rebuilt the Mac audio unit on every microphone
transition. Warm unmute calls took 649–766 ms and mute calls 308–359 ms. Rebuilding
the common output interrupts all received audio, not just the local microphone.

A second main-thread sample found temporary `RTCRtpReceiver` wrappers synchronously
registering and unregistering native observers. Merely inspecting transceivers or
receivers triggered this work, even when no Objective-C delegate was attached.
Removing the audio restart alone therefore did not pass the responsiveness check.

## Changes

- Native patch 0018 retains an already-authorized Mac duplex audio unit across
  mute/unmute while playout is running. Muting closes recording admission first;
  microphone samples do not reach WebRTC. Leave still releases the entire unit.
  iOS retains its existing input lifecycle.
- Patch 0020 installs a receiver observer only when a real delegate is assigned.
  Its teardown remains synchronous and lifetime-bound; ordinary inspection no
  longer replaces observers or waits on unnecessary signaling-thread operations.
- Mac route notifications are coalesced, and equal device snapshots no longer
  produce redundant UI updates.
- Space toggles the microphone once per physical press on Mac. Text entry,
  focused controls, modifiers, modal panels and inactive windows keep their normal
  keyboard behavior. Losing focus resets the key-down state.
- The guest engine uses Apple's public Mac input-mute callback. Patch 0019 supplies
  a synchronous PCM mute gate; UI/network changes follow the validated notification.
  A stale unmute callback cannot open capture. Meeting and private-check ownership
  remain separate, and another engine does not inherit the guest callback owner.
- Patch 0021 queries the public Core Audio default-input transport. If Bluetooth
  input is selected and microphone permission was already granted, its input bus
  is available from a muted join so the first headset unmute can arrive. It does
  not prompt for microphone permission at a muted join. Other initial Mac routes
  retain output-only operation until microphone use is requested.

The Mac microphone privacy indicator can remain visible while muted once input is
active. This is necessary to retain headset unmute and avoid repeatedly rebuilding
the audio device; network transmission is independently gated. No recording is saved.
The application callback is currently guest-engine-specific; Space is shared with
the other native meeting controls. iPhone headset behavior is not requalified here.

## Evidence

Mac: macOS 27.0.1, signed development app, six separate browser contexts with
synthetic camera/microphone inputs. Browser outputs were muted to avoid feedback.
No native compilation or sampling ran during the final performance trial.

- Final six-audio/six-video run: microphone calls 5–24 ms; camera calls 4–55 ms;
  longest sampled main-queue delay 225 ms, below the test's 500 ms failure threshold.
  Received audio/video byte counters advanced throughout four toggle cycles.
- Thirty rounds of receiver/transceiver wrapper inspection took 61 ms combined.
  An actual receiver delegate still received the first-packet callback.
- Eleven native recovery and fourteen ownership tests passed under ASan/UBSan.
- User confirmed Space toggles both ways. Initial headset testing found first-unmute
  failure, followed by success after app unmute. After patch 0021, the user confirmed
  AirPods unmute/mute from the initial muted state without first using the app button.
- A real Mac callback test checks capture gating before/after notification, and unit
  coverage protects stale callbacks, replacement owners and private sound checks.
- Mac regression suite: 92 passed, 3 opt-in output-device tests skipped. iOS 27
  simulator: 89 passed, 5 platform/hardware cases skipped. iOS 17.5 simulator:
  56 passed, 2 Mac-only cases skipped. All selected suites had zero failures.
  The additional per-engine bridge ownership test passed on Mac.

Baseline used built-in audio; the final load trial used AirPods, so these timings
are not a controlled percentage comparison between audio routes. They establish
the final responsiveness budget and the removed blocking stacks, not an energy gain.
The 100 ms polling interval makes reported `ready_ms` an upper-bound observation,
not actual device or network startup latency.

Local evidence: `.build/guest-responsiveness/mac-baseline.*`,
`mac-candidate-full.sample.txt`, `mac-candidate-r4.*`, `mac-airpods-initial-r4.*`,
`native-tests-r4.log`. Invitations and device identifiers are not part of this note.

The normal dependency is pinned to native r6, SHA256
`6d9655dad8e0ad9fb5a77e47a43e9064b5f6c6ee40c1eeaca53d1632cb0ef789`.
The uploaded ZIP was downloaded and its checksum verified. Its release includes
the exact cumulative source recipe, provenance and third-party notices. No new
TestFlight app build was submitted as part of this work.
The regular project then built against that remote artifact and passed 58 checks;
one opt-in Mac microphone test was skipped (it passed in the preceding dedicated
Mac run). Evidence: `normal-project-r6.log` and `normal-project-r6.xcresult`.

## Separate unresolved report: overlapping speaker volume

macOS 26.2 is unavailable on this test Mac. The app's active-speaker updates change
presentation, not track volume. The inspected WebRTC mixer sums active sources and
uses a common limiter to prevent clipping. That can reduce the mix at high combined
levels, but does not prove the reported cause. No limiter, echo-cancellation or gain
policy was changed without reproduction.

Apple's [voice processing guidance](https://developer.apple.com/videos/play/wwdc2023/10235/)
describes ducking of *other* audio outside the voice stream. It is not evidence that
each participant in the same WebRTC mix gets independent system ducking. Next check:
record per-source receive levels and final output on the affected OS/route while two
controlled sources alternate and overlap, then distinguish mixer limiting, source
gain and system processing.

## Mac window close and menu-bar proposal

A menu-bar control is useful: show meeting/mute state and offer Show Meeting, Mute,
Audio Devices and Leave. During a call, the red close button should hide its window;
explicit Quit should end the call. An ordinary native Mac app can retain one process
for that behavior; a second media helper would add IPC, ownership and signing costs.

This app currently runs as Designed for iPad on Mac. A menu-bar helper alone cannot
guarantee that closing the UIKit-managed scene preserves its media lifetime. Before
shipping that change, isolate a supported lifecycle prototype and verify close,
reopen, full screen, multiple windows, explicit Quit, sleep and call recovery. No
window-close interception or background helper was added in this fix.
