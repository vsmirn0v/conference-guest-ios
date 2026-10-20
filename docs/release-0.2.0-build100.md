# Rock’n’Roll 0.2.0 (100)

Application source: `02b0296`, pushed to `origin/main`. Includes `90ee437` from thread `01a145c6-f81b-7401-bda0-cb779c9fb5b2` (direct meeting More/View controls).

## Changes

An optional meeting Live Activity displays confirmed microphone and connection status, elapsed time and an Open meeting link. It is enabled by default on supported iPhones running iOS 16.2+, when the current meeting uses no System call controls. Meeting names are hidden by default and can be enabled separately in Settings → Phone calls. Mac/iPad behavior and the app’s iOS 16.0 minimum are retained.

A single serialized writer coalesces changes, suppresses recreation after dismissal, retires old meetings, handles leave during queued writes, and reconciles orphaned Activities. Links contain only an opaque local session ID and cannot join an old meeting. Stale status becomes unknown. One tolerant minute-level local freshness tick performs no network or media work. The extension has no meeting SDK, renderer, capture or audio dependencies.

The common call toolbar now exposes More and View directly, with layout and receive-video choices kept separate. One-tap Reactions remains available. These controls are already integrated from the linked thread.

GPT-6 Astra xhigh reviewed the implementation and follow-up fixes. Its sole P2 concerned guest SDK StudioModel replacement after the logical meeting started; the microphone publisher now follows replacements with `switchToLatest`, with a regression that binds before replacement and rejects the retired producer. Follow-up review found no remaining blockers. Largest accessibility text uses a two-row card; the compact Island uses one brand mark and one microphone status symbol. Elapsed time stays in the expanded and Lock Screen views. The final compact adjustment passed an additional Astra review and all 15 unit cases plus the real ActivityKit UI lifecycle test.

## Qualification

ConferenceCore: 122 tests passed. Final Mac regression: 69 cases, three expected hardware/opt-in skips, zero failures. Simulator: the initial 74 selected unit/rendering/control cases had three expected skips and no failures; all 15 final Activity/lifecycle cases pass after the review fix. iPhone SE iOS 17.5: all 21 selected unit cases, three direct More/View UI scenarios and the real ActivityKit lifecycle scenario pass.

The system ActivityKit test requests a real Activity, observes delivered `contentUpdates`, changes the microphone, opens another app, returns, simulates reconnect/recovery and ends the Activity. Early test failures exposed a stale test observation, an oversized accessibility layout, incorrect setup for the retired-studio regression, and a Simulator activation transition swallowing the first touch. The harness now observes asynchronous system delivery, reports requested versus delivered state, and waits one second after activation; this delay exists only in UI tests. Production code contains no activation delay.

Final iPhone 17 Pro Max iOS 26.5 UI check: all three scenarios passed, covering real ActivityKit background return, full-canvas sharing zoom with visible controls through rotation, and compact privacy/header behavior.

Physical iPhone checks are deferred explicitly by the user: “Use simulator checks for now.” PiP coexistence, cellular/FaceTime recovery, AirPods status, locked-device title redaction and battery impact have not been newly qualified on hardware. ActivityKit owns no audio, CallKit or PiP behavior. No hardware energy benefit or zero-regression claim is made from simulator results.

## Signed artifact

Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-20/RockNRoll-0.2.0-b100.xcarchive`.

All four bundles are 0.2.0 (100), team `5V64BP2H3P`. The app and broadcast extensions retain minimum iOS 16.0; MeetingActivity uses 16.2. Strict/deep signature checks, Production iCloud, disabled debugging and matching app/extension dSYMs passed. ActivityKit is weak-linked in the main app. The Activity executable is 166,752 bytes and links no media framework. Release excludes the new diagnostic fixture. Native WebRTC provenance still matches the pinned source and all 23 r6 patches.

App UUID: `DE8BF687-8635-391F-84A0-F29593D26CD3`. IPA SHA-256: `b38335af5bbbc32686003c8b967f4fff927decea48ff0a2e0e2384479bfda529`.

## What to Test

> Meeting status is now available on the Lock Screen and Dynamic Island when System call controls are off. Please test microphone status, returning to the meeting, and the direct View and More controls.

## Distribution

Uploaded October 20, 2026 at 18:42 MSK. App Store Connect confirms **Testing** in both **Rock’n’Roll Internal** and **Rock’n’Roll Public Beta** after group assignment and public review submission. Automatically notify testers was enabled.

Public beta: https://testflight.apple.com/join/Hd13C9U3

Proof: `.build/release100/testflight-build100.png`. Signed artifact and symbol verification reports remain in `.build/release100/`; regression evidence remains in `.build/live-activity/`. Build 99 was superseded before group assignment by the compact-layout correction above.

The user-authorized disk cleanup removed 693 older test recordings, six clean unused package caches and obsolete build/index caches. Active package/build caches, current qualification evidence, release archives, simulator runtimes and the modified SDK checkout were retained. About 35 GiB was free afterward; the exported build’s strict/deep signature verification still passed.
