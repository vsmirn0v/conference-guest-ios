# Rock’n’Roll 0.2.0 (104)

## Changes

Improved guest video renderer ownership and existing Picture in Picture continuity across sharing gaps and presenter changes. Optional Mac menu-bar residence and scheduled calendar joining are included from `32dc3e1`; participant renderer fixes include `c3b539e`. The preview remains at 30 fps.

First-time background PiP and notification background audio joining remain DEBUG-only prototypes and are excluded from this release. The former exposed premature blank PiP startup on hardware; the latter still needs warm/cold notification-action qualification.

## Validation

Full evidence and deferred scenarios are recorded in [the acceptance record](next-beta-validation-2026-10-22.md). Core, Mac and simulator regression selections passed. The final four simulator UI checks cover direct meeting controls, gallery paging, rotation and Russian large text. Final isolated Mac scheduled media passed in 48.772 seconds; the foreground close/restore control passed in 11.528 seconds. A preceding remote DTLS closure remains recorded as an unassigned transient transport failure, not a proven server or app regression.

Physical iPhone checks passed existing PiP share handover, Wi-Fi/cellular switching and a manual total outage, incoming/outgoing cellular and FaceTime recovery, AirPods gestures and PiP microphone meter, quiet-background unmute/new-publisher reception, Speaker/AirPods selection, independent media mixing, and Leave cleanup. The last bounded activity test passed in 206.816 seconds. Stable DEBUG samples used 3.26% of one CPU core in audio-only mode and 23.85% with moving PiP on Speaker at 48 kHz, with nominal thermal state. These are activity measurements, not a battery or Release-performance comparison.

Receiver routing was not offered by the observed picker. Actual battery-power measurement, the stronger initial handover assertion, extended renderer permutations and real Mac lock/sleep/session switching remain deferred. No further iPhone tests ran after the user requested disconnection. The temporary independent-audio harness was removed.

Astra 6 xhigh reviewed planning, source/test changes and the final runtime disposition. Test fixtures now isolate calendar/history/sync state. The exact disposable QA history entry was removed through normal tombstoning, preserving unrelated saved data; cloud state was not inspected.

## Distribution

Pending signed distribution verification and TestFlight readback. Build 103 remains published until this record is updated with verified distribution evidence.

## What to Test

> Improved background audio/video recovery and Mac window handling. Please test PiP through call and network interruptions, switching presenters, and closing/reopening the Mac meeting window. Optional scheduled joining on Mac is available in Calendar settings.
