# Rock’n’Roll for iOS

<img src="RockNRoll/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" height="128" alt="Rock’n’Roll app icon">

The icon and its generation prompts are described in [the design record](docs/icon-design.md).

A native iOS prototype for joining an existing guest-enabled conference. It has no account sign-in, meeting creation, embedded website, bundled SDK key, or token broker. The app uses the provider's binary iOS SDK for signaling and media; provider names are confined to the vendor-integration code, package/resource wiring, and invitation URLs.

Paste a complete `https://…/calls/<room>?psw=<value>` invitation, enter a display name, and tap Join. The app discovers the conference API from the invitation origin's `/.well-known/s2b-services.json` (`jazz.serverUrl`), then lets the SDK decode the invitation and join with microphone and camera off. The SDK's guest-token callback returns an empty string. This **was tested in one live guest-enabled meeting** on a signed iPhone; it is not a promise that every host policy or future backend/SDK version accepts anonymous guests.

The active call uses SDK participant video/audio transport with native microphone, camera, camera-switch, route and Leave controls. On a second browser endpoint, the phone appeared as a participant with both streams off. Microphone activation observed later in testing was a manual action on the phone, as the user clarified.

An outgoing CallKit call represents the actual conference and gives its audio session a system-managed lifecycle. With both local streams off and no inbound publisher, the phone stayed in the remote participant list through a 30-minute physical lock; the user heard a browser-published test tone while it was still locked. An answered cellular call held and resumed the conference without losing remote membership. The user reported conference audio continuing while playing X and Instagram videos, and successful switching among speaker, AirPods and earpiece. A physical-device UI test intentionally published microphone and camera streams, flipped the camera, then turned both off; a browser independently observed their On/Off states. See [the device record](docs/validation-2026-09-23.md) for the remaining acceptance gaps.

## Build

Requirements: Xcode with iOS 18+ SDK, XcodeGen, and Git LFS. The public SDK is pinned to `salute-developers/jazz-ios-sdk@6d5f92869690fa22bb489a9089aa554d733c6936` (25.3.1020).

```sh
brew install xcodegen git-lfs
git lfs install
xcodegen generate
swift test --package-path ConferenceCore
open RockNRoll.xcodeproj
```

For the connected `iVitalii` device, signing was verified with team `5V64BP2H3P`:

```sh
xcodebuild -project RockNRoll.xcodeproj -scheme RockNRoll \
  -destination 'platform=iOS,id=00008150-001238941AF0401C' \
  DEVELOPMENT_TEAM=5V64BP2H3P CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build
```

`project.yml` is the source for the checked-in Xcode project. The build script embeds vendor resources and the matching `Spench.framework`, which the binary SDK loads but omits from its Swift-package product. SDK binaries are downloaded through Swift Package Manager and are not committed here.

## Invitation handoff

The app accepts pasted invitations and `conferenceguest://join?url=<percent-encoded HTTPS invitation>`. The sample [web handoff page](web/open.html) creates that scheme URL from a pasted invitation or prefills it from its own `?url=<percent-encoded HTTPS invitation>` parameter. The user chose this custom-scheme handoff; direct Universal Links remain optional because they require a domain controlled by the app operator. The app cannot claim arbitrary provider HTTPS links without that domain owner's cooperation. The conference service address itself is resolved from each invitation, not hardcoded in the app.

The `#if DEBUG` environment variables `CONFERENCE_TEST_INVITE`, `CONFERENCE_TEST_NAME` and `CONFERENCE_TEST_LEAVE_AFTER_SECONDS` can automate a QA join and timed Leave for physical-device testing. They are not included in release builds or source-controlled with a live invitation.

`RockNRollUITests` contains an opt-in live device check for default mute, intentional microphone/video activation, camera flip and Leave. It skips unless the test runner receives `ROCKNROLL_TEST_INVITE` (pass it to `xcodebuild` as `TEST_RUNNER_ROCKNROLL_TEST_INVITE`). A second endpoint is needed to verify that media was actually published; the UI test keeps both streams on for 20 seconds for observation. A second opt-in test takes `TEST_RUNNER_ROCKNROLL_TEST_FIRST_INVITE` and `TEST_RUNNER_ROCKNROLL_TEST_SECOND_INVITE`; after it joins the first room, deliver the second custom-scheme link externally to the running app while the test waits. It verifies confirmation, completed Leave, ready state and a second Join. Use disposable invitations and keep them out of source control.

## Media policy

`Info.plist` declares background audio and VoIP. The app starts a real outgoing CallKit call for a user-requested meeting and waits for CallKit audio activation before starting SDK media. `AudioCoordinator` requests `.playAndRecord` / `.videoChat` with `.mixWithOthers` and restores mixing if the SDK later drops that option while retaining its selected mode/route settings. CallKit handles system hold, mute and end actions; the app keeps local microphone intent off while held and restores it on unhold. The SDK retains signaling and media transport ownership. The background-mode declaration alone is not evidence of persistent media; the observed physical-device results are recorded separately.
