# Conference Guest for iOS

A native iOS prototype for joining an existing guest-enabled conference. It has no account sign-in, meeting creation, embedded website, bundled SDK key, or token broker. The app uses the provider's binary iOS SDK for signaling and media; provider names are confined to the vendor-integration code, package/resource wiring, and invitation URLs.

Paste a complete `https://…/calls/<room>?psw=<value>` invitation, enter a display name, and tap Join. The app discovers the conference API from the invitation origin's `/.well-known/s2b-services.json` (`jazz.serverUrl`), then lets the SDK decode the invitation and join with microphone and camera off. The SDK's guest-token callback returns an empty string. This **was tested in one live guest-enabled meeting** on a signed iPhone; it is not a promise that every host policy or future backend/SDK version accepts anonymous guests.

The active call uses SDK participant video/audio transport with native microphone, camera, camera-switch, route and Leave controls. On a second browser endpoint, the phone appeared as a participant with both streams off. Microphone activation observed later in testing was a manual action on the phone, as the user clarified.

An outgoing CallKit call now represents the actual conference and gives its audio session a system-managed lifecycle. With both local streams off and no inbound publisher, the phone stayed in the remote participant list for over seven minutes in the background, through a one-minute physical screen lock and a 15-second competing nonmixable playback. A normal cellular call held the conference and, after hang-up, CallKit reported unhold and audio reactivation while remote membership remained intact. The user then heard a browser-published test tone on the phone. Real speech over a longer background run, camera uplink and route switching still need device acceptance. See [the device record](docs/validation-2026-09-23.md) and [implementation plan](docs/implementation-plan.md).

## Build

Requirements: Xcode with iOS 18+ SDK, XcodeGen, and Git LFS. The public SDK is pinned to `salute-developers/jazz-ios-sdk@6d5f92869690fa22bb489a9089aa554d733c6936` (25.3.1020).

```sh
brew install xcodegen git-lfs
git lfs install
xcodegen generate
swift test --package-path ConferenceCore
open ConferenceGuest.xcodeproj
```

For the connected `iVitalii` device, signing was verified with team `5V64BP2H3P`:

```sh
xcodebuild -project ConferenceGuest.xcodeproj -scheme ConferenceGuest \
  -destination 'platform=iOS,id=00008150-001238941AF0401C' \
  DEVELOPMENT_TEAM=5V64BP2H3P CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build
```

`project.yml` is the source for the checked-in Xcode project. The build script embeds vendor resources and the matching `Spench.framework`, which the binary SDK loads but omits from its Swift-package product. SDK binaries are downloaded through Swift Package Manager and are not committed here.

## Invitation handoff

The app accepts pasted invitations and `conferenceguest://join?url=<percent-encoded HTTPS invitation>`. The sample [web handoff page](web/open.html) creates that scheme URL from a user-supplied invitation. A Universal Link on a domain you control needs `JOIN_LINK_HOST`, an associated-domains entitlement, and an Apple App Site Association file. The app cannot claim arbitrary provider HTTPS links without that domain owner's cooperation. The conference service address itself is resolved from each invitation, not hardcoded in the app.

The `#if DEBUG` environment variables `CONFERENCE_TEST_INVITE`, `CONFERENCE_TEST_NAME` and `CONFERENCE_TEST_LEAVE_AFTER_SECONDS` can automate a QA join and timed Leave for physical-device testing. They are not included in release builds or source-controlled with a live invitation.

## Media policy

`Info.plist` declares background audio and VoIP. The app starts a real outgoing CallKit call for a user-requested meeting and waits for CallKit audio activation before starting SDK media. `AudioCoordinator` requests `.playAndRecord` / `.videoChat` with `.mixWithOthers` and restores mixing if the SDK later drops that option while retaining its selected mode/route settings. CallKit handles system hold, mute and end actions; the app keeps local microphone intent off while held and restores it on unhold. The SDK retains signaling and media transport ownership. The background-mode declaration alone is not evidence of persistent media; the observed physical-device results are recorded separately.
