# Rock’n’Roll 0.2.0 (104)

## Changes

Improved guest video renderer ownership and existing Picture in Picture continuity across sharing gaps and presenter changes. Optional Mac menu-bar residence and scheduled calendar joining are included from `32dc3e1`; participant renderer fixes include `c3b539e`. The preview remains at 30 fps.

First-time background PiP and notification background audio joining remain DEBUG-only prototypes and are excluded from this release. The former exposed premature blank PiP startup on hardware; the latter still needs warm/cold notification-action qualification.

## Validation

Full evidence and deferred scenarios are recorded in [the acceptance record](next-beta-validation-2026-10-22.md). Core, Mac and simulator regression selections passed. The final four simulator UI checks cover direct meeting controls, gallery paging, rotation and Russian large text. Final isolated Mac scheduled media passed in 48.772 seconds; the foreground close/restore control passed in 11.528 seconds. A preceding remote DTLS closure remains recorded as an unassigned transient transport failure, not a proven server or app regression.

Physical iPhone checks passed existing PiP share handover, Wi-Fi/cellular switching and a manual total outage, incoming/outgoing cellular and FaceTime recovery, AirPods gestures and PiP microphone meter, quiet-background unmute/new-publisher reception, Speaker/AirPods selection, independent media mixing, and Leave cleanup. The last bounded activity test passed in 206.816 seconds. Stable DEBUG samples used 3.26% of one CPU core in audio-only mode and 23.85% with moving PiP on Speaker at 48 kHz, with nominal thermal state. These are activity measurements, not a battery or Release-performance comparison.

Receiver routing was not offered by the observed picker. Actual battery-power measurement, the stronger initial handover assertion, extended renderer permutations and real Mac lock/sleep/session switching remain deferred. No further iPhone tests ran after the user requested disconnection. The temporary independent-audio harness was removed.

Astra 6 xhigh reviewed planning, source/test changes and the final runtime disposition. Test fixtures now isolate calendar/history/sync state. Both exact disposable QA history entries were removed through normal tombstoning, preserving unrelated saved data; cloud state was not inspected. All 16 background-audio tests passed on Mac and Simulator after full fixture isolation; a final read-only audit confirmed no recurrence. These follow-up changes affect only tests and documents, with shipping-source equivalence to the archive verified.

## Distribution

Artifact source: `d7352ce` on `main`, pushed. Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-22/RockNRoll-0.2.0-b104.xcarchive`. The distribution-signed export passes strict/deep signature verification for all four bundles, matching 0.2.0/build104, team `5V64BP2H3P`, matching app/extension dSYMs, Production iCloud, no debugger entitlement and absence of DEBUG/prototype markers. The Activity extension links no media frameworks. Evidence: `.build/release104/artifact-verification.json`.

Local exported IPA SHA-256: `c2e7a63fe2e6f84597ca640590ab4ea35607e7a87224c7222961726117d3673d`. A separate development-signed local Mac Release build launched through the normal Designed for iPad wrapper, displayed Home, opened/dismissed Settings and quit through its application menu. That smoke is not a runtime test of the distribution IPA.

Upload completed successfully at 16:40 MSK on October 22, 2026. Build ID: `b0d78617-c148-4298-87a1-ec3e2baee074`. The upload reported missing vendor-framework dSYMs for six dependencies; app and extension symbols were verified separately.

Published and independently read back at 2026-10-22 16:59 MSK:

- Rock’n’Roll Internal: build 0.2.0 (104), **Testing**, 1 tester.
- Rock’n’Roll Public Beta: build 0.2.0 (104), **Testing**, 7 testers.
- Testing notes saved; automatic tester notification enabled.
- Public beta: [TestFlight](https://testflight.apple.com/join/Hd13C9U3).

Distribution evidence: `.build/release104/upload-result.json`. Test-only fixture isolation and final validation records are committed in `6a43f52`; shipping source remains identical to the archived `d7352ce`.

## What to Test

> Improved background audio/video recovery and Mac window handling. Please test PiP through call and network interruptions, switching presenters, and closing/reopening the Mac meeting window. Optional scheduled joining on Mac is available in Calendar settings.
