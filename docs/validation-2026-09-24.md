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

The new signed archive was uploaded to App Store Connect on 24 September 2026 and Xcode reported `EXPORT SUCCEEDED`. Its embedded version is `0.2.0 (5)`, team is `5V64BP2H3P`, and the Bluetooth purpose string and export-compliance setting remain present. Apple processing completed, and build 5 is **Waiting for Review** in the `Rock’n’Roll Public Beta` external TestFlight group. The [public link](https://testflight.apple.com/join/Hd13C9U3) is open to anyone with a 100-tester limit; installation awaits Apple's first external-build approval.

- iVitalii: repeated landscape/portrait cycles kept all Rock call controls reachable while a browser shared a live test card. A simulator layout fixture also passed both landscape orientations and a return to portrait.
- iVitalii: the Rock room made a live screen share the primary view, exposed the browser participant's mic/video/share status, pinned and unpinned that stream, changed zoom with a pinch, and passed All video, Screen shares and Audio only modes. A browser-generated microphone tone made the participant's Speaking indicator appear.
- iVitalii: the guest SDK's participant list opened, showed media icons, and exposed a working Pin the participant action. Repeated landscape/portrait cycles returned its controls to the visible portrait window.
- `go test ./...` and the final simulator app build passed. The website's synthetic demo card and short tone were tested through the live room. After the isolated `rock-web` restart, its health check passed, its restart policy remained `always`, and unrelated `kachat.app` still returned HTTP 200.
- App Store metadata, website copy, and the existing distribution screenshots were checked for provider branding; none was found in those public-facing surfaces.

The iPhone beta still requires external review before the public link can install build 5. Xcode reported missing third-party framework dSYMs, as it did for build 4. Safari denied a real window-share request on this Mac, so the browser's OS screen-picker route remains unverified; the synthetic card published through the same screen-share track type.
