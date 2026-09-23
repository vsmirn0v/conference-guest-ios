# Conference Guest for iOS

A native iOS prototype for joining an existing meeting without account sign-in or meeting creation. It uses the provider's iOS media SDK, joins with microphone and camera off, renders participants through the SDK, and offers microphone, camera, camera switch, audio route, and Leave controls. No website is embedded in the app.

The app-facing target, bundle ID, URL scheme, UI, and core module use neutral names. The required `JazzSDK` import and binary/resource names are confined to `ConferenceGuest/VendorIntegration`, the package declaration, and its resource-copy script. Invitation hostnames remain in the link parser and sample handoff page. These names are part of the vendor's binary API and URL format, not app branding.

The [implementation plan](docs/implementation-plan.md) and [validation record](docs/validation-2026-09-23.md) distinguish implemented behavior from device acceptance. A real meeting cannot be joined until an SDK project credential and a token service are configured. No SDK key is bundled in the app.

## Build and checks

Requirements: Xcode with an iOS 18+ SDK, XcodeGen, and Git LFS. The public SDK is pinned at commit `6d5f92869690fa22bb489a9089aa554d733c6936` (25.3.1020). Run:

```sh
brew install xcodegen git-lfs
git lfs install
xcodegen generate
open ConferenceGuest.xcodeproj
swift test --package-path ConferenceCore
python3 -m unittest discover -s GuestTokenBroker -p 'test_*.py'
```

The generated Xcode project is checked in; `project.yml` is its source of truth. The build script embeds vendor resource bundles and `Spench.framework`, which the pinned SDK binary loads but its Swift package does not include in the product. SDK binaries are fetched from the vendor package and are not stored in this repository.

## Native guest authorization

The public SDK needs technical authorization even when the participant does not sign in. The sample token broker signs a short-lived transport JWT from an SDK project key, exchanges it for an access token at the provider API, and returns the access token to the app. Configure the broker on a controlled host:

```sh
export PROVIDER_SDK_KEY_B64='your SDK project key'
export PROVIDER_API_BASE_URL='https://api.salutejazz.ru'
python3 -m venv GuestTokenBroker/.venv
GuestTokenBroker/.venv/bin/pip install -r GuestTokenBroker/requirements.txt
GuestTokenBroker/.venv/bin/python GuestTokenBroker/broker.py
```

The broker listens on `127.0.0.1:8765` and accepts `POST /v1/guest-token` with `guestId` (UUIDv4) and `displayName`. Set the app target build setting `GUEST_TOKEN_URL` to `http://127.0.0.1:8765/v1/guest-token` for a local simulator run. A physical device needs a reachable HTTPS broker. Protect that endpoint with network controls and abuse monitoring before exposing it beyond a controlled test. With no endpoint configured, the Join button is disabled and the app reports that conference access is unavailable.

The broker's protocol implementation and the pinned SDK have not been tested against a live project key or current meeting. Guest permissions may also prevent joining conferences from another organization.

## Links and media

The app registers `conferenceguest://join?url=<encoded HTTPS invitation>`. The sample [handoff page](web/open.html) creates that URL from a user-supplied invitation. To use Universal Links, set `JOIN_LINK_HOST`, add an associated-domains entitlement, and host the Apple App Site Association file on a domain you control. Directly claiming the provider's invitation domain requires its owner's cooperation.

The app passes `JazzConferenceMediaSettings.allOff` to the SDK before joining. `Info.plist` declares background audio; `AudioCoordinator` requests `.playAndRecord` / `.videoChat` with `.mixWithOthers` and observes interruptions and route changes. This is an initial policy, not proof that the binary SDK preserves it after joining or that an incoming call or another app's audio cannot interrupt the conference. Those cases need a signed iPhone build, a real meeting, a second participant, and the test matrix in the plan.
