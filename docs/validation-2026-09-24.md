# Validation of build 0.2.0 (4)

The app archive was signed for team `5V64BP2H3P` and uploaded to App Store Connect on 24 September 2026. Its embedded Info.plist has the Bluetooth and Contacts purpose strings and `ITSAppUsesNonExemptEncryption=false`. Apple completed processing; build 4 is Testing in the existing one-tester internal group. Installation of this build from TestFlight has not been checked yet.

## Passed

- `swift test --package-path ConferenceCore` with full Xcode selected: 12 tests, including the N-starred-plus-ten-recent history rules.
- `go test ./...` in `RockServer` and simulator build-for-testing.
- iPhone 17 Pro Max simulator: saved-name home-screen UI test. A live guest call disconnected under simulator CallKit, so that result is not evidence about the device path.
- iVitalii (iPhone 17 Pro Max, iOS 27): native guest-link autojoin; live guest chat in both directions with a browser; portrait transcript/chat panel; landscape controls reachable after rotation; synthetic incoming camera visible in All video, hidden in Audio only, and visible again on returning to All video.
- Earlier in this update, the Rock test jam passed native-to-browser and browser-to-native chat. The site exposes chat and its updated privacy explanation; both `rock.glowsoft.ru` and the unrelated `kachat.app` returned HTTP 200 after deployment. The isolated `rock-room` and `rock-web` Podman containers were running with restart policy `always`.
- Three genuine iPhone screenshots persisted on the App Store Connect distribution draft after reload. Its description and private reviewer steps were updated for chat, history, and Rock display modes.

## Limits

- The guest SDK's custom stream renderer did not show incoming camera video on the device. Its normal renderer remains in use. Screen-share-only display is disabled for guest invitations; All video and Audio only work.
- Simulator CallKit cannot establish a representative live guest call. Background and telephone-interruption behavior still require a physical device for each release build.
- The website's Open iPhone app button reached the iOS open-app prompt on a phone, but the automated Safari handoff test was intermittent. The in-app handoff route and native guest-link route were exercised separately.
- Xcode reported missing third-party framework dSYMs during symbol upload. The app upload succeeded, but crashes inside those frameworks may have less complete symbolication.
