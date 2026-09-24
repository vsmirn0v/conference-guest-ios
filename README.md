# Rock’n’Roll for iOS

<img src="RockNRoll/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" height="128" alt="Rock’n’Roll app icon">

Rock’n’Roll helps small music groups in Yerevan meet between rehearsals. Musicians open a shared jam link, join with microphone and camera off, then choose when to share sound or video. The native iPhone app keeps a real system call for background audio and uses CallKit to hold and resume around another phone call. It can also open compatible guest meeting invitations through a separate integration. There is no account or in-app room creation.

The public test jam is [rock.glowsoft.ru/jams/test](https://rock.glowsoft.ru/jams/test). The same page explains the group and lets a second participant join in a browser. The app also supports `conferenceguest://join?url=<percent-encoded HTTPS invitation>` from a web handoff. Only Rock links use the self-hosted room service; compatible guest invitations keep their existing endpoint-discovery flow.

The app saves the chosen display name and a device-only list of ten recent jams plus any starred jams. New installs show “Musician” and can fill the name from a contact selected by the user. The in-call conversation panel switches between chat and available transcript lines. Both meeting engines offer all video, screen shares, and audio-only views. In guest rooms, the screen-share view uses the SDK's shared-screen focus and covers camera-only playback when no share is live; it does not change the meeting's camera policy. Compatible guest websites can hand off a `jcp` invitation; its HTTPS website origin is editable in the app.

Meeting notices appear at the top of the call view, clear of the bottom controls.

A native app link opens its jam directly. If another jam is active or connecting, the latest native link replaces it after the current system call ends. A single CallKit provider coordinates both media engines, and service discovery is reused for later rooms on the same website during that app session.

The native jam engine uses LiveKit Swift, and the small Go service issues short-lived, room-scoped guest tokens for a single configured test room. The browser is an optional participant, not an embedded app view. Keys remain on the server. The server is isolated in two Podman containers behind a dedicated nginx virtual host; deployment inputs live in [RockServer](RockServer/).

The **Catch up** panel marks intervals that may have been missed during a held call, audio interruption or network loss. It can display only transcript lines actually supplied by a room provider. The test jam currently supplies none, so the panel does not claim to reconstruct missed speech. The local index is protected on the device, deleted on Leave, and expires after 24 hours. See [feature boundaries](docs/catch-up.md) and [privacy policy](https://rock.glowsoft.ru/privacy).

## Build and test

Requires Xcode with an iOS 18+ SDK, XcodeGen and Git LFS. The project pins both Swift SDKs. Required vendor symbols are confined to `RockNRoll/VendorIntegration` and package/resource references.

```sh
brew install xcodegen git-lfs
git lfs install
xcodegen generate
swift test --package-path ConferenceCore
open RockNRoll.xcodeproj
```

The app is signed with developer team `5V64BP2H3P`. `project.yml` generates the checked-in Xcode project. A build script copies resources required by the binary guest-integration SDK. SDK binaries are fetched through Swift Package Manager and are not committed.

`RockNRollUITests.testCommunityJamConnectsMuted` exercises the public test room on an attached iPhone. The test file also covers layout in both orientations, a saved display name, chat, and native link handoff. Live media and CallKit behavior need a device; the simulator is useful for the home screen and core logic. App Store screenshots are in [AppStore/Screenshots](AppStore/Screenshots/). See the [current validation](docs/validation-2026-09-24.md), [earlier device coverage](docs/validation-2026-09-23.md), and [App Store preparation](docs/app-store-preparation-plan.md).

## Media behavior

The app requests a genuine outgoing CallKit call for a user-requested jam and starts the selected media engine after the system activates audio. The microphone and camera start off. Routes can be selected through the in-call controls and iOS route picker. Another call holds the jam and restores the user’s media intent on return. iOS may interrupt sound while another telephone call owns audio; the app does not record it or claim to recover unheard speech. Background camera capture is not promised.
