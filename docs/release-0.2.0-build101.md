# Rock’n’Roll 0.2.0 (101)

Archived production source: `15700cd`; qualification/source push: `e19409f`. Later changes are tests and release documentation only (`.build/release101/source-identity.json`). Includes `90ee437` and `1e02e07` from the meeting-controls thread, `8cc467d` calendar reminders, and `0656fdc` optional setup. All four app/extension bundles use build 101.

## Changes

- Direct View/More access and the Share, Video, Audio, Mic, Reactions, Leave dock order. Camera & sound adapts its Share/Video/Audio selector and action area to portrait phones, landscape, and wider windows.
- Optional local Calendar reminders, per-occurrence choices, and quiet follow-up while using another meeting. Optional setup reuses the existing Calendar, reminder, and private iCloud settings without enabling them implicitly.
- Opening an old meeting Live Activity suppresses Calendar auto-join for that foreground entry. An expired status link cannot start an unrelated calendar countdown or replace the current room.
- Additional DEBUG-only device fixtures cover real notification delivery, ActivityKit/PiP coexistence, and selected-calendar reads. Test fixes use localized labels, responsive presentation outcomes, explicit foreground state, and bounded scrolling.

## Review and regression

GPT-6-Astra xhigh reviewed the integrated candidate and the follow-up routing fix. Its confirmed P2 was an Activity-link early return preceding calendar auto-join suppression. A regression reproduced the countdown before the fix. The final test covers cold entry, cancellation of an eligible existing warm countdown, and a later Calendar refresh. Follow-up review found no new production blockers. The final test review caught the UI runner querying its own app-group access; the harness was corrected to inject the target app’s measured socket-path length. The final rerun passed its private SDK UI check and explicitly skipped transport at 171/103 bytes, with zero failures. Final Astra xhigh review found no unresolved blocker.

Counts below overlap; they are separate runs rather than a unique-test total.

| Target | Result | Evidence |
|---|---|---|
| ConferenceCore | 139 passed, zero failures | `.build/core-release101.log` |
| Mac hosted regression | 199 selected, seven expected hardware/opt-in skips, zero failures | `.build/release101/mac-regression.xcresult` |
| Mac final routing, setup, sync, continuation | 82 selected, one expected platform skip, zero failures | `.build/release101/mac-routing-final.xcresult` |
| iOS 27 Simulator | 252 passed, 14 expected skips; one localized test-helper failure passed on corrected rerun | `.build/release101/sim-final.xcresult`, `.build/release101/russian-final.xcresult` |
| iPhone SE-sized iOS 17.5 Simulator | 61 passed, zero failures/skips; includes Russian large text, rotation, real ActivityKit lifecycle, setup and routing/Studio checks | `.build/release101/sim17-small-final.xcresult` |
| Live guest Mac SDK | Three tests passed, including actual More/View hit tests and 20 Presenter sender start/stop cycles | `.build/release101/mac-live-tools-share.xcresult` |
| Restored production Mac sharing | Three tests passed again with original production transport settings, including 20 sender lifecycle cycles | `.build/release101/mac-production-final.xcresult` |
| Live guest Simulator SDK UI | Private Presenter navigation passed; real transport acceptance explicitly skipped after measuring the target socket path | `.build/release101/sim-live-qualified.xcresult` |

The initial iOS 27 attempt could not launch either test host because SpringBoard crashed. The older iOS 17.5 Home SE simulator also failed before launching the test hosts; the existing isolated Reminder Small QA simulator booted normally and completed the selection. Restarting that isolated simulator restored ordinary system-app launch. No production timing or launch workaround was added for the simulator failure. The Russian reminder test initially used the English Settings label as its launch anchor; its selector was corrected to match the requested test language and the full occurrence/rotation test passed on rerun. A separate opt-in live Simulator Presenter check reached the real guest SDK/More/Studio path but its sender failed to open the SDK socket (`connectionFailedToOpen`, error 10001). Qualification resolved this as the provider Unix-socket path limit, described below. The failed attempt is not counted as a transport pass.

Physical checks are not being rerun for this release task. Earlier device recordings include native notification and moving PiP checks, but the opt-in live guest Presenter test had an unresolved one-third-scale XCTest accessibility hierarchy. That failed hardware test is not counted as a pass. Simulator and hosted Mac checks do not establish physical call, headset, locked-device privacy, reachability, or battery behavior.

## Simulator transport qualification

The provider constructs its socket path as the app-group directory plus `rtc_SSFD`. The installed test target's Simulator path is 171 UTF-8 bytes; the pinned SDK rejects paths longer than 103 bytes before binding, with the failure string `path is too long`. Darwin's `sockaddr_un.sun_path` has 104 bytes including termination. Sender startup already posts `jazzBroadcastStarted`; this did not establish a missing production startup call.

A nil-launcher/public-toggle prototype still failed on Simulator, while the same prototype passed another 20 Mac sender lifecycle cycles. It was fully discarded: production sharing code and the signed archive remain unchanged. The SDK's ordinary toggle with a configured broadcast extension also opens ReplayKit's whole-device picker, so it was not substituted for private canvas startup.

The optional transport test now accepts the target path byte count measured by the host using `simctl get_app_container ... groups`; it does not query the UI runner's unrelated entitlement. The current 171-byte measurement yields an explicit 103-byte-limit skip. Missing measurement does not silently skip. A separate live SDK UI test joins normally, opens More/Presenter, selects a private canvas, checks that sharing remains off, and dismisses Studio. That test passes. The shared launcher uses the stable microphone accessibility identifier and fails fast with cleanup registered before launch.

Mac validates sender lifecycle. This run does not independently establish remote-peer picture quality or physical iPhone Presenter transport; those remain separate acceptance items. Evidence: `.build/release101/sim-socket-preflight.json`, initial/prototype failure diagnostics, `.build/release101/mac-nil-transport.xcresult`, and `.build/release101/sim-live-qualified.xcresult`.

## Signed artifact and distribution

Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-21/RockNRoll-0.2.0-b101.xcarchive`. Export succeeded. All four bundles pass strict/deep signature verification, use team `5V64BP2H3P`, and have matching app/extension dSYMs. Main/broadcast deployment remains iOS 16.0; MeetingActivity uses 16.2. The app has Production iCloud and no debugger entitlement. Release excludes the diagnostic fixtures; the Activity extension links no meeting/media framework. The bundled native WebRTC source and 23 patches match the qualified r6 provenance.

IPA SHA-256: `ee03af2e9e945fbb9cff5fb64e25809608ef1a8f5daface3891881b0b0d65e64`.

Upload succeeded on October 21, 2026 at approximately 07:57 MSK (`.build/release101/upload.log`). App/extension dSYMs match; Apple reports missing symbols for some closed vendor frameworks, recorded in `.build/release101/upload-result.json`. This does not block upload, but symbolication inside those vendor binaries remains limited. App Store Connect readback at approximately 08:04 MSK confirms **Testing** for build 101 with **Rock’n’Roll Internal** and **Rock’n’Roll Public Beta** assigned (one internal tester, seven public testers). Testing notes were saved and automatic tester notification was enabled. Build ID: `f1c86414-1607-4146-8f29-2db40a363182`. Public invitation: https://testflight.apple.com/join/Hd13C9U3. Screenshot and accessibility readback are retained at `.build/release101/testflight-build101.png` and `.build/release101/testflight-build101-ax.txt`.

## What to Test

> Improved meeting controls and optional calendar reminders. Please test the meeting setup, switching View modes, opening Camera & sound, and returning to meetings from their status or reminders.
