# Jazz Guest for iOS

Native guest client for joining existing SaluteJazz meetings. It provides a name, invite/code entry, incoming Jazz media, mic/camera controls (off at join), a system audio route picker, and Leave. There is no meeting creation or account sign-in UI.

The implementation and its open validation gates are in [docs/implementation-plan.md](docs/implementation-plan.md). The app currently needs a Jazz SDK project key and a guest-token broker before it can join a real meeting. The public SDK is pinned to commit `6d5f92869690fa22bb489a9089aa554d733c6936` (25.3.1020); current-cloud compatibility is unverified.

## Build

Requirements: Xcode with an iOS 18+ SDK, XcodeGen, Git LFS, and enough disk space for the Jazz binary package. On a Mac with Homebrew:

```sh
brew install xcodegen git-lfs
git lfs install
xcodegen generate
open JazzGuest.xcodeproj
```

The generated `JazzGuest.xcodeproj` is checked in. `project.yml` is its source of truth; rerun XcodeGen after changing target or package settings. The build script copies Jazz resource bundles and the SDK's required Spench framework from the resolved package into the app. The vendor's pinned `Package.swift` omits Spench even though `JazzSDK.framework` loads it at launch. SDK binaries and vendor resources are not committed to this repository.

Run independent checks:

```sh
swift test --package-path JazzGuestCore
python3 -m unittest discover -s GuestTokenBroker -p 'test_*.py'
```

`JazzGuestCore` keeps link validation independent of UIKit and the vendor SDK. The app itself must also compile for an iOS Simulator; real audio/video and background behavior require a physical device.

## Configure the guest-token service

The vendor SDK needs technical authorization even though the participant does not log in. The sample broker creates a short-lived ES256/ES384/ES512 transport token from the Jazz SDK key and exchanges it at Jazz's documented `/v1/auth/login` endpoint. The key is read only from `JAZZ_SDK_KEY_B64` and must never be put in the app, Git, URL, or build settings.

```sh
python3 -m venv GuestTokenBroker/.venv
GuestTokenBroker/.venv/bin/pip install -r GuestTokenBroker/requirements.txt
export JAZZ_SDK_KEY_B64='the key from Jazz Studio'
GuestTokenBroker/.venv/bin/python GuestTokenBroker/broker.py
```

The broker listens on `127.0.0.1:8765` by default and accepts `POST /v1/guest-token` with JSON fields `guestId` (UUIDv4) and `displayName`. For a local simulator run, set the `JazzGuest` target build setting `GUEST_TOKEN_URL` to `http://127.0.0.1:8765/v1/guest-token`. On a device, host the broker behind HTTPS and set that HTTPS endpoint instead. The app keeps the returned access token in memory. The backend needs TLS, network access controls, monitoring and durable abuse controls before exposure beyond a controlled test; the included in-memory rate limit is only a development safeguard.

The app shows a configuration error if `GUEST_TOKEN_URL` is empty. The broker cannot be tested against Jazz without an actual SDK key. Vendor guest permissions may also prevent a cross-organization join; test that with a real meeting before production use.

## Links

The app registers `jazzguest://join?url=<encoded Jazz HTTPS invite>`. A website can render an explicit Open in app button using that URL. `web/open.html` is a small example that creates the link from an invite the user supplies. Paste-invite joining works even without website changes.

The parser also handles an owned-domain Universal Link shaped as `https://YOUR-DOMAIN/join?url=<encoded Jazz HTTPS invite>`. Set `JOIN_LINK_HOST`, add the associated-domains entitlement for that domain, and serve the Apple App Site Association file there before relying on it. Only the owner of `salutejazz.ru` can make original Jazz HTTPS links open this app directly.

## Media behavior

Every new call passes `JazzConferenceMediaSettings.allOff`. Once admitted, Jazz supplies participant rendering; the custom in-call bar uses its published coordinator for microphone, camera, camera switch, audio route, and leaving. Background audio is declared in `Info.plist`. The app observes interruptions, route changes, media-service resets and camera interruptions without leaving the meeting on a scene transition.

The app requests an iOS `.playAndRecord` / `.videoChat` session with `.mixWithOthers` before joining. The binary SDK may later replace that configuration. Do not treat other-app audio coexistence, PiP camera continuity, or long background calls as verified until the physical-device matrix in the plan passes with the approved Jazz SDK. Jazz's own CallKit/PiP flags are left at their defaults in this first build while audio ownership is evaluated.
