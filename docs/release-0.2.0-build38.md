# Rock’n’Roll 0.2.0 (38)

## Changes

- Add private front-camera preview before enabling outgoing video, both before
  joining and inside either meeting engine. Release local capture before handing
  camera ownership to the meeting; live settings reuse the existing stream.
- Replace Studio with Camera & sound. Hold microphone/audio or video for direct
  settings; retain short-tap behaviour. Add secondary-click, VoiceOver and
  Command-comma access, a landscape side inspector and compact phone layouts.
- Expose native camera effects against private capture; keep microphone muted
  while configuring sound profiles/routes. Save the sound profile on this device.
- Prevent settings dismissal from dismissing the meeting and restrict secondary
  click recognition to pointer input. Keep video-off requests valid during hold.
- Include the previously committed meeting-lifetime PiP cleanup and rejection of
  late camera frames after leaving (e673023).

- Remove address-book APIs, contact picker and the Contacts purpose string.
  Edit the display name directly on the join screen; retain local persistence and
  optional iCloud sync. The first join/native link focuses the inline name field,
  preserving the invitation and requiring an explicit Join after entering it.
  Commit pending name edits when focus ends, joining starts or the app backgrounds.

Minimum iOS remains 16.0. All three bundles report 0.2.0 (38).
No backend, microphone capture, recording output, model download or privacy
permission was added. Private preview does use camera permission and the system
privacy indicator. Camera choices/effects remain dependent on each engine and OS.

## Validation

- iOS 27: five Studio UI checks and 37 accepted state/render/localization checks,
  with three opt-in/platform skips. The suite qualified portrait/landscape and
  English/Russian fixtures; subsequent small-screen checks qualified final layout.
- iOS 17.5 / iPhone SE: private preview, sound profiles, short taps, held presses,
  background dismissal, rotation and Russian layouts passed for both engines.
- Mac Release: 20 checks passed, including actual video-only AVCapture preview,
  no recording/encoding output and complete input removal when stopped.
- iVitalii / iOS 27: private guest preview with video off, Apple's Portrait effect
  before publication, explicit handoff into live video, reuse of the live stream,
  closing settings and stopping video passed. Native effect preference restored.
- Capture-state tests cover pending permission cancellation, hold/background/end,
  publication after device release, live observer lifetime and local preference
  restoration without restoring mute/video-on intent.
- Final small-screen state/render/localization suite: 34 passed, three opt-in/platform
  skips, no failures. Final merged camera card and Russian UI checks also passed.

Native microphone-mode selection while muted remains unavailable. Private preview
uses the front/default camera; live preview and live camera switching use the
engine's selected camera. No new battery/thermal or remote image-quality result
is claimed. A prior immediate weak-reference assertion depended on UIKit's
transient autorelease pool; the ownership check now drains that pool explicitly.

- Inline-name changes: 22 name, sync and localization unit checks and five home/
  sync UI checks passed. Subsequent live guest rejoin uses the edited name without
  restarting. Prejoin preview, Russian/English settings, background edit completion
  and name persistence after restart passed on the small iOS 17.5 simulator.
- Website Go tests passed. The privacy page is updated on the existing web container;
  only rock-web was restarted, with its previous binary retained for rollback and
  restart=always preserved. No nginx or room-engine configuration was changed.
- Actual private-camera/effect/publication behavior was qualified on iVitalii before
  the contact-only change. The optional real system PiP-after-Leave check could not
  start because the phone was unavailable to Xcode; that acceptance remains pending.
  Existing simulator PiP lifecycle checks passed.

## Delivery

Beta notes: “Private video preview, easier camera and sound settings, simpler name entry, and improved call stability.”

The initial archive from b1a249d was superseded before uploading when contact
access was removed. Final artifact and delivery evidence follow.


- Archive source: `7792ea7e1f3cf6910866c69d1f9626f284f8328f`; app version/build `0.2.0 / 38`, minimum iOS 16.0.
- Archive: `/Users/v.smirnov/Library/Developer/Xcode/Archives/2026-10-06/RockNRoll-0.2.0-b38-final.xcarchive`.
- Archive app SHA-256: `a0002d6847ad124e57a6c91719ac63cce1ec735f34427840e479b6a79f26bf45`.
- Matching app/dSYM UUID: `9A03B6DF-24EB-33FD-A1A7-7741F3985460`.
- Locally exported IPA SHA-256: `449aec33a1ab1f752fd3df290a6f28f0484aa208769885f3b0ede416ad58a021`.
- Strict signatures passed for the app and both extensions, with team 5V64BP2H3P,
  get-task-allow=false, production CloudKit/push and matching EN/RU resources
  (437 keys per language). Main Contacts purpose string and framework links absent.
- Xcode upload succeeded on 6 October 2026 at 20:48:58 MSK. App Store Connect
  finished processing. Existing third-party framework dSYM warnings remain;
  the app's own symbols match.
- Privacy page deployed binary SHA-256:
  `3e8475fe99f9e093977a86210b901cf27ccea9f20285b4f5d70bcca29351e13e`.

- App Store Connect build ID: `f27c68a6-665b-47f4-9df9-e0b285ec7af9`.
- Beta notes saved and read back. Both existing tester groups were selected;
  Automatically notify testers remained enabled. Submission completed and both
  Rock’n’Roll Internal and Rock’n’Roll Public Beta show 0.2.0 (38) **Testing**.
- Group-status readback: 2026-10-06 18:04:01 UTC.
- Public invitation: https://testflight.apple.com/join/Hd13C9U3
- Local publication proof: `/tmp/rock-build38-testflight-public.png`.
