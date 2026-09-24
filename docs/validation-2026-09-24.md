# Validation of build 0.2.0 (4)

The app archive was signed for team `5V64BP2H3P` and uploaded to App Store Connect on 24 September 2026. Its embedded Info.plist has the Bluetooth and Contacts purpose strings and `ITSAppUsesNonExemptEncryption=false`. Apple completed processing; build 4 is Testing in the existing one-tester internal group. Installation of this build from TestFlight has not been checked yet.

## Passed

- `swift test --package-path ConferenceCore` with full Xcode selected: 12 tests, including the N-starred-plus-ten-recent history rules.
- `go test ./...` in `RockServer` and simulator build-for-testing.
- iPhone 17 Pro Max simulator: saved-name home-screen UI test. A live guest call disconnected under simulator CallKit, so that result is not evidence about the device path.
- iVitalii (iPhone 17 Pro Max, iOS 27): native guest-link autojoin; live guest chat in both directions with a browser; portrait transcript/chat panel; landscape controls reachable after rotation; synthetic incoming camera visible in All video, hidden in Audio only, and visible again on returning to All video.
- iVitalii, Rock test jam: a synthetic browser screen-share track and a separate camera track appeared together in All video; Screen shares showed the share and hid the camera; Audio only showed participant audio tiles without either video. The live room token explicitly permitted `screen_share`, and a second browser recognized the published share. No personal desktop was captured for this test.
- Earlier in this update, the Rock test jam passed native-to-browser and browser-to-native chat. The site exposes chat and its updated privacy explanation; both `rock.glowsoft.ru` and the unrelated `kachat.app` returned HTTP 200 after deployment. The isolated `rock-room` and `rock-web` Podman containers were running with restart policy `always`.
- Three genuine iPhone screenshots persisted on the App Store Connect distribution draft after reload. Its description and private reviewer steps were updated for chat, history, and Rock display modes.

## Limits

- The guest SDK's custom stream renderer did not show incoming camera video on the device. Its normal renderer remains in use. Screen-share-only display is disabled for guest invitations; All video and Audio only work.
- Simulator CallKit cannot establish a representative live guest call. Background and telephone-interruption behavior still require a physical device for each release build.
- The website's Open iPhone app button reached the iOS open-app prompt on a phone, but the automated Safari handoff test was intermittent. The in-app handoff route and native guest-link route were exercised separately.
- Xcode reported missing third-party framework dSYMs during symbol upload. The app upload succeeded, but crashes inside those frameworks may have less complete symbolication.
- The browser's new Share screen button uses the LiveKit API, but the system screen-picker flow was not exercised; doing so would transmit the tester's actual display into the public demo room.

## Build 0.2.0 (5) external-beta candidate

The new signed archive was uploaded to App Store Connect on 24 September 2026 and Xcode reported `EXPORT SUCCEEDED`. Its embedded version is `0.2.0 (5)`, team is `5V64BP2H3P`, and the Bluetooth purpose string and export-compliance setting remain present. Apple processing completed, and build 5 was submitted to the `Rock’n’Roll Public Beta` external TestFlight group. It was later approved. The [public link](https://testflight.apple.com/join/Hd13C9U3) has a 100-tester limit.

- iVitalii: repeated landscape/portrait cycles kept all Rock call controls reachable while a browser shared a live test card. A simulator layout fixture also passed both landscape orientations and a return to portrait.
- iVitalii: the Rock room made a live screen share the primary view, exposed the browser participant's mic/video/share status, pinned and unpinned that stream, changed zoom with a pinch, and passed All video, Screen shares and Audio only modes. A browser-generated microphone tone made the participant's Speaking indicator appear.
- iVitalii: the guest SDK's participant list opened, showed media icons, and exposed a working Pin the participant action. Repeated landscape/portrait cycles returned its controls to the visible portrait window.
- `go test ./...` and the final simulator app build passed. The website's synthetic demo card and short tone were tested through the live room. After the isolated `rock-web` restart, its health check passed, its restart policy remained `always`, and unrelated `kachat.app` still returned HTTP 200.
- App Store metadata, website copy, and the existing distribution screenshots were checked for provider branding; none was found in those public-facing surfaces.

App Store Connect showed build 5 as Approved in the public beta group later on 24 September 2026. Installation from the public link has not been checked on a device. Xcode reported missing third-party framework dSYMs, as it did for build 4. Safari denied a real window-share request on this Mac, so the browser's OS screen-picker route remains unverified; the synthetic card published through the same screen-share track type.

## Build 0.2.0 (6) room switching

Both room engines now use one CallKit provider. A clicked native meeting link directly replaces an active or connecting jam, with the latest link winning if several arrive during teardown. The app resolves the HTTPS service from the invitation and reuses that discovery result for later rooms on the same website in the current app session.

- iVitalii: a three-room sequence (test jam, guest room A, guest room B) became active in order; the physical-device UI regression passed in 15 seconds. A second regression delivered both guest links before the test jam finished joining and verified that the latest room connected.
- iVitalii: actual iOS URL dispatch through `devicectl --payload-url` switched from the test jam to guest room A in 1.58 seconds and from A to B in 0.74 seconds, measured from each join start to the engine's active event. The second discovery lookup used the session cache and took 0.03 seconds. These are measurements from one device and network, not latency guarantees.
- iVitalii: existing muted test-jam and native guest-link join smoke tests passed. `ConferenceCore` passed all 12 tests. The Release archive is signed for team `5V64BP2H3P`, embeds build number 6 and retains the Bluetooth purpose string.

Build 6 was uploaded successfully and is **Testing** in the one-tester `Rock’n’Roll Internal` TestFlight group. Its internal “What to Test” notes cover consecutive links, transcript-notice placement, rotation, and audio/layout reports. It has not been added to the public beta group; build 5 remains the approved public beta while build 6 is checked internally.

The user supplied an iPhone screenshot showing a transcript-start notice covering the bottom controls. The guest integration now renders its notice stream as compact top banners, including available notice actions. A simulator layout fixture passed portrait, both landscape orientations, and return to portrait; visual inspection confirmed the banner and controls do not overlap. The provider's live transcript-start event was not retested on iPhone because the device was disconnecting, so this remains a runtime check for the next physical-device session.

## Guest screen-share pinch fix

The guest SDK's normal renderer includes a zoomable scroll view for a remote screen share. The app's full-screen, transparent controls view intercepted touches above it. Empty control space now passes touches to that renderer; buttons remain active. A custom stream-renderer experiment was rejected after it displayed a black canvas during a live share.

- An iPhone 17 Pro Max simulator joined the live guest room through a Debug-only media path because simulator CallKit rejected an outgoing call. Another participant published a screen share. Before/after UI-test screenshots visibly show the shared window enlarged by a pinch; the Leave control remained hittable. `testManualGuestScreenSharePinch` passed.
- `testGuestControlsSurviveRotationCycles` passed on the simulator after the change.
- The test participants left and screen sharing stopped. A physical-device check of the distribution build remains outstanding.

## Build 0.2.0 (7): internal and public TestFlight

Build 7 includes the guest screen-share pinch fix and the guest Screen shares viewing mode. The mode follows a live screen share, hides camera feeds, and shows an empty state before or after sharing. The public test jam and compatible guest invitations remain in the same build.

- `swift test --package-path ConferenceCore`: 18 passed. The selected iPhone 17 Pro Max simulator UI tests passed: layout/rotation, notice placement, and starred-room naming; one guest-share fixture skipped because its external camera participant was absent. The live guest share, stop/restart, and display-mode behavior was verified on the simulator in the preceding source revision.
- The Release archive embedded version `0.2.0 (7)`, the Bluetooth purpose string, and `ITSAppUsesNonExemptEncryption=false`. Xcode reported `EXPORT SUCCEEDED` and `Upload succeeded`; App Store Connect processed the upload.
- App Store Connect lists build 7 as **Testing** in both `Rock’n’Roll Internal` (1 tester) and `Rock’n’Roll Public Beta` (4 testers). The public group retains [its existing invitation link](https://testflight.apple.com/join/Hd13C9U3), limited to 100 testers. The build-specific “What to Test” notes and existing distribution screenshots contain no provider branding.
- Xcode again reported missing third-party framework dSYMs during symbol upload. Upload succeeded, but crashes inside those frameworks may have incomplete symbolication. Installation and media behavior from build 7 have not yet been checked on a physical device.

## Build 0.2.0 (8): iOS 17 support

The deployment target is iOS 17.0. An iOS 17.5 iPhone 15 Pro simulator passed the core package tests and selected UI tests for muted joining, rotation, conversation modes, saved-jam renaming across an app restart, guest joining, and a live synthetic incoming screen share with pinning, pinch-to-zoom, and view-mode switching. A newer simulator also passed the renamed-jam regression test. The iOS 17 rename test exposed an alert text-binding failure; the app now uses a sheet for that editor.

On iVitalii (iOS 27.0), signed UI tests passed for a live muted public-jam join, guest-meeting rotation and conversation controls, and the app's automated hold/resume marker. A real FaceTime interruption and audio return were not retested for build 8 because a person was unavailable to place the call.

The signed Release archive embeds `0.2.0 (8)`, `MinimumOSVersion=17.0`, the Bluetooth, microphone, and camera purpose strings, and `ITSAppUsesNonExemptEncryption=false`. `codesign --verify --deep --strict` passed. Xcode reported `Upload succeeded`; App Store Connect completed processing. Build 8 is **Testing** in both `Rock’n’Roll Internal` and `Rock’n’Roll Public Beta`. The existing [public link](https://testflight.apple.com/join/Hd13C9U3) remains active with a 100-tester limit. The build-specific tester notes mention iOS 17 and contain no provider branding. Installation of build 8 through TestFlight has not yet been observed. Third-party framework dSYMs were again missing during symbol upload; this did not block delivery, but may limit symbolication of crashes inside those frameworks.

## Compact-screen follow-up

An iPhone SE (3rd generation) simulator on iOS 17.5 passed home, live room, rotation, notice placement, conversation, and large-text participant-list checks. Guest joining, repeated rotation, and the screen-share-only empty state also passed using the live guest invitation. Screenshot review found that the compact conversation panel's mic, camera, and Leave labels wrapped vertically in its 46-point control strip. The strip now places icons above single-line labels. The Catch up screenshot and label-frame assertions pass on the SE; the conversation tests also pass on an iOS 26.5 iPhone 17 Pro Max simulator. The Catch up fixture now uses a unique room identity so a previous test run cannot leave its section already reviewed. This fix was incorporated into build 9 below.

## Build 0.2.0 (9): compact controls and native invitation handoffs

Build 9 includes the compact-screen control fix. It also accepts both the existing `jcp://jazz?code=…&psw=…` handoff and `jazz://join?id=…&password=…`, converting either through the configured HTTPS meeting origin and joining automatically. The iPhone SE simulator (iOS 17.5) passed the scheme-routing UI test and connected to the live guest room through each scheme. The routing and Catch up UI tests passed on an iOS 26.5 simulator; `ConferenceCore` passed all 18 tests. The signed archive embeds build 9, iOS 17.0 minimum, and all three URL schemes; code-signature verification passed. Xcode reported `Upload succeeded` at 16:48 MSK. App Store Connect processed the upload, and build 9 is **Testing** in both `Rock’n’Roll Internal` and `Rock’n’Roll Public Beta`. The [public link](https://testflight.apple.com/join/Hd13C9U3) remains active. The build-specific tester notes contain no provider branding. Installation from TestFlight has not yet been observed on a physical device; third-party framework dSYMs were again missing during symbol upload.

[Apple's custom URL scheme guidance](https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app) says the target is undefined when multiple installed apps register the same scheme. The simulator tests prove Rock’n’Roll handles both links when it is the selected handler; they cannot guarantee that iOS chooses Rock’n’Roll over another installed app claiming `jazz` or `jcp`.

## Build 0.2.0 (10): iOS 16 support

The app and ConferenceCore deployment targets are now iOS 16.0. The Catch up empty state no longer uses the iOS 17-only `ContentUnavailableView`. The UI-test bundle separately requires iOS 16.4 because XCTest's `XCUIApplication.open(_:)` is unavailable before then; that does not raise the installable app's minimum OS.

- A generic iOS Simulator build succeeded with the new target. All 18 ConferenceCore tests passed.
- On an iOS 17.5 iPhone SE simulator, the rotation fixture, Catch up review, and native invitation-scheme tests passed. On an iOS 26.5 iPhone 17 Pro Max simulator, the Catch up and home identity tests passed.
- The signed Release archive passed `codesign --verify --deep --strict`. Its Info.plist has `0.2.0 (10)`, `MinimumOSVersion=16.0`, the existing URL schemes, the Bluetooth/microphone/camera purpose strings, and `ITSAppUsesNonExemptEncryption=false`. Xcode reported `Upload succeeded`. App Store Connect processed the build and shows it as **Testing** in both `Rock’n’Roll Internal` and `Rock’n’Roll Public Beta`. The [public link](https://testflight.apple.com/join/Hd13C9U3) remains active. Build-specific tester notes focus on iOS 16 checks and contain no provider branding.

No iOS 16 simulator is installed on this Mac. An iOS 16 device still needs to verify joining each engine, media input/output, background operation, audio-route switching, and interruption recovery. As with prior builds, the upload had missing third-party-framework dSYM warnings; this may limit crash symbolication inside those frameworks.
