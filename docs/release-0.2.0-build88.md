# Rock’n’Roll 0.2.0 (88)

## Changes

- Favorites and recent rooms use stable title, timing and website/room slots.
  Calendar enrichment replaces text without moving tap targets; full details
  remain available through accessibility and the calendar agenda.
- Calendar refresh retains resolved data and publishes the completed snapshot
  together. Revoked/deselected calendars become unavailable immediately.
- Home suggestions stay in place during the visible session. A header action
  reveals new or changed suggestions explicitly; device heartbeats stay quiet.
  Auto-join countdown appears at the bottom and leaves existing rows in place.
- Frozen cards cannot join a replacement invitation with another room identity.
  Expired/removed events show their actual availability. Cancelled drags cannot
  block VoiceOver activation of favorites.
- Own reactions use the incoming floating overlay after transport acceptance.
  The overlay starts inside the final participant area below the meeting header.
  Repeated reactions remain distinct; failed/stale completions cannot float or
  overwrite a newer confirmation. Queued sends are labelled Sending, not Sent.
- Transcription uses a document/text symbol, with the existing explanatory
  accessibility description and recording priority preserved.
- PiP uses the original microphone fill indicator shared with the main meeting
  view. Status and first-sample rendering stay synchronized; decoded video and
  sampling cadence are unchanged.
- Large-text home actions wrap within the screen; no invisible glass toolbar
  button remains when there are no suggestion updates.

## Review and qualification

- GPT-6 Astra, ultra: independent read-only planning and repeated source review.
  All five initial findings and both follow-up findings were addressed; final
  review reported no source blockers.
- Core: 12 selected policy/send-gate checks passed, including changed invitation,
  same-ID rescheduling, heartbeat, deferred update and explicit reveal cases.
- Mac: 70 selected checks, zero failures, three expected opt-in live-room skips.
- iOS 27 Simulator: the same 70 checks, zero failures, three expected skips;
  delayed enrichment, delayed countdown and own-reaction UI checks passed.
- iOS 17.5 iPhone SE: calendar/home/reaction coverage and 14 render/submission
  checks. One test was blocked by an unanswered simulator camera permission
  prompt from private preview; after granting test permissions its final rerun
  and five other focused UI checks passed without failures.
- iOS 27 iPad: delayed enrichment, accessibility text, wide portrait/landscape
  layout and reaction placement passed. Two assertions originally assumed the
  compact-phone header/width; they now check the actual visible layout and pass.
- English/Russian, large text, portrait/landscape, stable button frames, original
  press identity, accessibility activation, failed/out-of-order reactions,
  overlay burst bounds and privacy icon priority are covered.
- System-screen screenshots avoid the application-snapshot rotation/cropping
  problem observed during iPad capture. Final wide-layout pixel check passed.
- PiP glyph rendering is covered on Mac/simulator with real model level/status
  updates and static video. System PiP on a physical iPhone was not repeated for
  this visual-only restoration; no audio/capture or PiP lifecycle changes.
- Archive/export and source whitespace validation passed.

Local evidence: `.build/release88/` (logs, result bundles, screenshot captures,
artifact and symbol verification). Generated captures remain excluded from Git.

## Source and artifact

- Version 0.2.0/build 88; minimum iOS 16.0; team 5V64BP2H3P.
- Product commit: `1764dd135fca7e6d31b39e7ac990c44fc253f309`.
- Native dependency remains r6 with the same 23 cumulative patches.
- Archive: `2026-10-14/RockNRoll-0.2.0-b88.xcarchive`.
- App/dSYM UUID: `3B93FA07-6839-3593-9C4D-5B3CFA907103`; both sharing
  extension symbols match their executables too.
- IPA SHA256: `baa9f4f42a6c91da446e9ff68aaea04a22e1bf10fc83ac2c42804e66dd9c2993`.
- App and both extensions passed strict/deep signing, build, minimum OS, team,
  debugger-entitlement and symbol checks. iCloud is Production; encryption
  declaration and permission strings are present. Native provenance and APIs
  match r6; rejected selector, DEBUG helpers and direct AppKit linkage are absent.

## Distribution

Upload succeeded October 14, 2026 at 23:03 MSK. Apple accepted the package with
existing dependency missing-dSYM warnings; app/extension symbols were verified.
Processing completed; tester notes were saved and automatic tester notification
was enabled. At 23:13 MSK, App Store Connect showed **Testing** with 90 days
remaining in both existing groups:

- Rock’n’Roll Internal: one tester.
- Rock’n’Roll Public Beta: six testers.

Build ID: `8b20df66-ece6-44ad-b3e4-af4f5996c5e7`.
Public invitation: <https://testflight.apple.com/join/Hd13C9U3>.

## Tester notes

Improved launch stability and meeting controls. Clearer reaction feedback and
microphone activity in Picture in Picture.
