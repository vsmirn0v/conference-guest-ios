# Background audio join prototype

## Scope and use

This is an opt-in DEBUG prototype for guest SDK meetings. It is excluded from Release notification categories, settings and startup ownership. Build 103 remains the published beta. No server component or push service is added.

In a development build, open Settings → Calendars → Meeting reminders → Delivery and privacy and enable **Experimental background audio join**. Calendar reminders must also be configured. Expand a reminder and choose **Join audio**; a normal notification tap and **Join** still use the foreground path. The action requires an unlocked device, a saved display name, existing microphone permission, accessible protected data and System call controls off. It starts with mic/camera off, incoming audio on, incoming video off and no PiP.

The initial audio session retains built-in receiver/speaker intent or the current external route. Route and Bluetooth behavior still need physical-device qualification; route preferences are not a hardware guarantee.

## Ownership and invariants

- One attempt owns calendar resolution, endpoint discovery and media startup, with a 20-second deadline and an iOS background assertion. iOS may expire that assertion earlier.
- Fresh calendar resolution precedes joining; ended, deleted, unsupported or ambiguous entries cannot start a hidden meeting. Another active or transitioning room is not replaced; the already active requested room is a no-op.
- Signaling connection alone is insufficient. Success requires SDK and media connection, a coordinator, audio activation, no hold/interruption/reconnect and mic/camera intent off.
- A retained model and detached container own a cold start. No hidden window or synthetic appearance events are created. Opening the app adopts the same objects. Scene reconnection replaces only the Home child, retaining the SDK host and restoring accessibility on departure.
- An explicit foreground entry supersedes the background transaction without disconnecting its started session or replaying an older unresolved reference. Normal foreground routing handles same-room and different-room requests.
- Duplicate actions share one startup; a conflicting request cannot replace it. Timeout/cancellation revokes the attempt before provider teardown. Tokens prevent late callbacks from affecting a replacement session.
- Failure submits one generic, secret-free local notification synchronously before completing background execution. Its action opens the app; it offers no background retry or automatic reconnection loop.
- Opting out cancels an in-flight attempt. Completed meetings remain under normal meeting controls.

GPT-6-Astra xhigh reviewed planning and implementation. Initial review findings addressed foreground ordering, retained scene ownership, late Home accessibility, duplicate Home children and fallback submission ordering.

## Validation

Mac final hosted selection: **104 passed**, no skips or failures (`.build/background-audio-join/mac-reviewed.xcresult`). iOS 27 Simulator hosted selection: **104 passed**, no skips or failures (`sim-reviewed.xcresult`). These selections include transaction expiry/deduplication, late resolution, foreground handoff, retained scene ownership, media-readiness gating, reminder routing, display names, audio-worker and Live Activity regressions. An earlier Mac selection passed 57 tests; counts overlap.

The first two Simulator UI attempts exposed automation timing/targeting mistakes around the SwiftUI switch and rotation. Earlier results remain in the evidence folder and are not counted as passing. The corrected opt-in/rotation UI scenario passes (`sim-ui-screen.xcresult`); the existing reminder settings/Home stability scenario also passes in `sim-ui-final.xcresult`. The experimental toggle does not enable calendar notifications. A full-screen landscape capture was visually checked; the earlier app-only screenshot was clipped by XCTest's rotation capture.

A signed Release build passed. Binary inspection confirms that the prototype notification identifiers, preference key and owner type are absent (`release-verification.json`). English/Russian strings and whitespace checks pass. Final GPT-6-Astra xhigh review reported no remaining blockers. No physical iPhone has been used.

## Required iPhone acceptance before release

Use a disposable guest meeting with controlled remote audio. Test warm and cold notification actions, locked/unlocked entry, speaker/receiver/AirPods, missing permission/name, system controls on, slow/offline service and lobby timeout. Confirm the other app remains foreground; audio is audible; no camera capture, outgoing microphone media or PiP starts; and opening Rock’n’Roll shows the same meeting without another join. Repeat scene reconnection, default-tap ordering, opt-out/cancellation, call interruption/recovery and Leave cleanup. Verify remote mute state and short energy measurements on hardware.

Mac/Simulator hosted tests validate state, ownership and UI behavior. They cannot establish iOS background scheduling or actual audible cold-start playback in the binary SDK. Release enablement remains deferred until those checks pass.
