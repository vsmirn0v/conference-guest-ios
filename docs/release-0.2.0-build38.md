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
access was removed. Final archive, signature validation, upload and tester-group
readback are recorded below when delivery completes.
